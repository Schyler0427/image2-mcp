package gemini

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	DefaultBaseURL         = "https://api.schyler.top"
	maxResponseBytes int64 = 64 << 20
	maxInputBytes    int64 = 64 << 20
	maxImagePixels   int64 = 32 << 20
	maxReferences          = 16
)

var modelPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// Client calls the native Gemini image protocol with its own explicit key.
type Client struct {
	apiKey     string
	endpoint   string
	model      string
	outputDir  string
	httpClient *http.Client
}

type Request struct {
	Prompt      string
	ImagePaths  []string
	AspectRatio string
	ImageSize   string
	OutputDir   string
	OutputName  string
}

type Result struct {
	FilePath string `json:"file_path"`
	Model    string `json:"model"`
	Size     string `json:"size"`
}

func New(apiKey, baseURL, model, outputDir string, httpClient *http.Client) (*Client, error) {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" {
		return nil, errors.New("GEMINI_IMAGE_API_KEY is required")
	}
	if len(apiKey) > 1024 || strings.ContainsAny(apiKey, "\r\n\x00") {
		return nil, errors.New("Gemini image key must be a single line of at most 1024 bytes")
	}
	model = strings.TrimSpace(model)
	if !modelPattern.MatchString(model) {
		return nil, errors.New("a valid Gemini image model ID is required")
	}
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Hostname() == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("Gemini base URL must be an absolute HTTP(S) URL without credentials, query, or fragment")
	}
	parsed.Path = strings.TrimSuffix(strings.TrimRight(parsed.Path, "/"), "/v1beta") + "/v1beta/models/" + model + ":generateContent"
	parsed.RawPath = ""
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 300 * time.Second}
	}
	clientCopy := *httpClient
	if clientCopy.Timeout == 0 {
		clientCopy.Timeout = 300 * time.Second
	}
	clientCopy.Jar = nil
	clientCopy.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("Gemini image API redirects are not allowed")
	}
	if outputDir == "" {
		outputDir = filepath.Join("output", "imagegen")
	}
	outputDir, err = expandPath(outputDir)
	if err != nil {
		return nil, err
	}
	outputDir, err = filepath.Abs(outputDir)
	if err != nil {
		return nil, errors.New("resolve Gemini output directory failed")
	}
	return &Client{apiKey: apiKey, endpoint: parsed.String(), model: model, outputDir: outputDir, httpClient: &clientCopy}, nil
}

func (c *Client) Generate(ctx context.Context, input Request) (Result, error) {
	if len(input.ImagePaths) != 0 {
		return Result{}, errors.New("use Gemini edit for reference images")
	}
	return c.run(ctx, input, false)
}

func (c *Client) Edit(ctx context.Context, input Request) (Result, error) {
	return c.run(ctx, input, true)
}

func (c *Client) run(ctx context.Context, input Request, edit bool) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	prompt := strings.TrimSpace(input.Prompt)
	if prompt == "" {
		return Result{}, errors.New("prompt is required")
	}
	ratio := strings.TrimSpace(input.AspectRatio)
	if ratio == "" {
		ratio = "1:1"
	}
	switch ratio {
	case "1:1", "1:4", "1:8", "2:3", "3:2", "3:4", "4:1", "4:3", "4:5", "5:4", "8:1", "9:16", "16:9", "21:9":
	default:
		return Result{}, errors.New("unsupported Gemini aspect_ratio")
	}
	size := strings.ToUpper(strings.TrimSpace(input.ImageSize))
	if size == "" {
		size = "1K"
	}
	if size != "1K" && size != "2K" && size != "4K" {
		return Result{}, errors.New("Gemini image_size must be 1K, 2K, or 4K")
	}
	outputDir := c.outputDir
	if strings.TrimSpace(input.OutputDir) != "" {
		var err error
		outputDir, err = expandPath(input.OutputDir)
		if err != nil {
			return Result{}, err
		}
		if !filepath.IsAbs(outputDir) {
			return Result{}, errors.New("output_dir must be an absolute path")
		}
	}
	parts := []map[string]any{{"text": prompt}}
	if edit {
		if len(input.ImagePaths) == 0 {
			return Result{}, errors.New("at least one image path is required")
		}
		if len(input.ImagePaths) > maxReferences {
			return Result{}, errors.New("Gemini accepts at most 16 reference images")
		}
		var total int64
		for _, path := range input.ImagePaths {
			data, mime, err := readReference(path, maxInputBytes-total)
			if err != nil {
				return Result{}, err
			}
			total += int64(len(data))
			parts = append(parts, map[string]any{"inlineData": map[string]string{"mimeType": mime, "data": encodeImage(data)}})
		}
	}
	payload := map[string]any{"contents": []map[string]any{{"role": "user", "parts": parts}}, "generationConfig": map[string]any{"responseModalities": []string{"TEXT", "IMAGE"}, "imageConfig": map[string]string{"aspectRatio": ratio, "imageSize": size}}}
	body, err := json.Marshal(payload)
	if err != nil {
		return Result{}, errors.New("encode Gemini image request failed")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return Result{}, errors.New("create Gemini image request failed")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-goog-api-key", c.apiKey)
	response, err := c.httpClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return Result{}, fmt.Errorf("Gemini image request timed out: %w", context.DeadlineExceeded)
		}
		return Result{}, errors.New("Gemini image request failed; network, timeout, or redirect rejected")
	}
	defer response.Body.Close()
	fail := func(reason string, raw []byte) (Result, error) {
		return Result{}, c.responseError(reason, raw, response.Header, response.StatusCode, outputDir, prompt)
	}
	if response.ContentLength > maxResponseBytes {
		return fail("Gemini image response exceeds 64 MiB", nil)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		return Result{}, errors.New("read Gemini image response failed")
	}
	if int64(len(raw)) > maxResponseBytes {
		return fail("Gemini image response exceeds 64 MiB", nil)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fail(fmt.Sprintf("Gemini image API returned HTTP %d", response.StatusCode), raw)
	}
	imageData, mime, err := extractImage(raw)
	if err != nil {
		return fail(err.Error(), raw)
	}
	pngData, width, height, err := normalizeImage(imageData, mime)
	if err != nil {
		return fail(err.Error(), raw)
	}
	path, err := saveOutput(pngData, outputDir, input.OutputName)
	if err != nil {
		return Result{}, err
	}
	return Result{FilePath: path, Model: c.model, Size: fmt.Sprintf("%dx%d", width, height)}, nil
}
