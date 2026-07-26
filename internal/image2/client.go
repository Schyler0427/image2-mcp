package image2

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	DefaultBaseURL = "https://api.schyler.top"
	DefaultModel   = "gpt-image-2"
	DefaultSize    = "1024x1024"
	DefaultQuality = "auto"
)

var safeNameRE = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

type Client struct {
	apiKey        string
	endpoint      string
	editsEndpoint string
	outputDir     string
	httpClient    *http.Client
}

type GenerateRequest struct {
	Prompt     string `json:"prompt"`
	Size       string `json:"size,omitempty"`
	OutputDir  string `json:"output_dir,omitempty"`
	OutputName string `json:"output_name,omitempty"`
}

type EditRequest struct {
	Prompt     string   `json:"prompt"`
	ImagePaths []string `json:"image_paths"`
	Size       string   `json:"size,omitempty"`
	Quality    string   `json:"quality,omitempty"`
	OutputDir  string   `json:"output_dir,omitempty"`
	OutputName string   `json:"output_name,omitempty"`
}

type GenerateResult struct {
	FilePath string `json:"file_path"`
	Model    string `json:"model"`
	Size     string `json:"size"`
}

type EditRequest struct {
	Prompt     string   `json:"prompt"`
	Size       string   `json:"size,omitempty"`
	OutputDir  string   `json:"output_dir,omitempty"`
	OutputName string   `json:"output_name,omitempty"`
	ImagePaths []string `json:"image_paths"`
	MaskPath   string   `json:"mask_path,omitempty"`
}

type EditResult = GenerateResult

func NewFromEnv(outputDir string) (*Client, error) {
	apiKey := strings.TrimSpace(os.Getenv("OPENAI_IMAGE_API_KEY"))
	if apiKey == "" {
		return nil, errors.New("OPENAI_IMAGE_API_KEY is required")
	}
	baseURL := strings.TrimSpace(os.Getenv("OPENAI_IMAGE_BASE_URL"))
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	return &Client{
		apiKey:        apiKey,
		endpoint:      BuildGenerationsEndpoint(baseURL),
		editsEndpoint: BuildEditsEndpoint(baseURL),
		outputDir:     outputDir,
		httpClient: &http.Client{
			Timeout: 180 * time.Second,
		},
	}, nil
}

func New(apiKey, baseURL, outputDir string, httpClient *http.Client) (*Client, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, errors.New("OPENAI_IMAGE_API_KEY is required")
	}
	if strings.TrimSpace(baseURL) == "" {
		baseURL = DefaultBaseURL
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 180 * time.Second}
	}
	return &Client{
		apiKey:        apiKey,
		endpoint:      BuildGenerationsEndpoint(baseURL),
		editsEndpoint: BuildEditsEndpoint(baseURL),
		outputDir:     outputDir,
		httpClient:    httpClient,
	}, nil
}

func BuildGenerationsEndpoint(baseURL string) string {
	return buildImagesEndpoint(baseURL, "generations")
}

func BuildEditsEndpoint(baseURL string) string {
	return buildImagesEndpoint(baseURL, "edits")
}

func buildImagesEndpoint(baseURL, operation string) string {
	u := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if strings.HasSuffix(u, "/v1/images/generations") {
		return u
	}
	if strings.HasSuffix(u, "/v1/images/edits") {
		return strings.TrimSuffix(u, "/edits") + "/generations"
	}
	if strings.HasSuffix(u, "/images/generations") {
		return u
	}
	if strings.HasSuffix(u, "/images/edits") {
		return strings.TrimSuffix(u, "/edits") + "/generations"
	}
	if strings.HasSuffix(u, "/v1") {
		return u + "/images/" + operation
	}
	return u + "/v1/images/" + operation
}

func (c *Client) Edit(ctx context.Context, input EditRequest) (GenerateResult, error) {
	prompt := strings.TrimSpace(input.Prompt)
	if prompt == "" {
		return GenerateResult{}, errors.New("prompt is required")
	}
	if len(input.ImagePaths) == 0 {
		return GenerateResult{}, errors.New("image_paths must contain at least one image")
	}
	size := strings.TrimSpace(input.Size)
	if size == "" {
		size = DefaultSize
	}
	quality := strings.TrimSpace(input.Quality)
	if quality == "" {
		quality = DefaultQuality
	}
	outputDir := strings.TrimSpace(input.OutputDir)
	if outputDir == "" {
		outputDir = c.outputDir
	} else if !filepath.IsAbs(outputDir) {
		return GenerateResult{}, errors.New("output_dir must be an absolute path")
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for name, value := range map[string]string{
		"model":   DefaultModel,
		"prompt":  prompt,
		"size":    size,
		"quality": quality,
	} {
		if err := writer.WriteField(name, value); err != nil {
			return GenerateResult{}, fmt.Errorf("write multipart field %s: %w", name, err)
		}
	}
	for _, imagePath := range input.ImagePaths {
		if !filepath.IsAbs(imagePath) {
			return GenerateResult{}, fmt.Errorf("image path must be absolute: %s", imagePath)
		}
		info, err := os.Stat(imagePath)
		if err != nil {
			return GenerateResult{}, fmt.Errorf("inspect image path %s: %w", imagePath, err)
		}
		if !info.Mode().IsRegular() {
			return GenerateResult{}, fmt.Errorf("image path must be a regular file: %s", imagePath)
		}

		file, err := os.Open(imagePath)
		if err != nil {
			return GenerateResult{}, fmt.Errorf("open image path %s: %w", imagePath, err)
		}
		header := make([]byte, 512)
		n, readErr := file.Read(header)
		if readErr != nil && readErr != io.EOF {
			file.Close()
			return GenerateResult{}, fmt.Errorf("read image path %s: %w", imagePath, readErr)
		}
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			file.Close()
			return GenerateResult{}, fmt.Errorf("rewind image path %s: %w", imagePath, err)
		}
		contentType := http.DetectContentType(header[:n])
		disposition := mime.FormatMediaType("form-data", map[string]string{
			"name":     "image",
			"filename": filepath.Base(imagePath),
		})
		part, err := writer.CreatePart(textproto.MIMEHeader{
			"Content-Disposition": {disposition},
			"Content-Type":        {contentType},
		})
		if err != nil {
			file.Close()
			return GenerateResult{}, fmt.Errorf("create multipart image part for %s: %w", imagePath, err)
		}
		if _, err := io.Copy(part, file); err != nil {
			file.Close()
			return GenerateResult{}, fmt.Errorf("write multipart image part for %s: %w", imagePath, err)
		}
		if err := file.Close(); err != nil {
			return GenerateResult{}, fmt.Errorf("close image path %s: %w", imagePath, err)
		}
	}
	if err := writer.Close(); err != nil {
		return GenerateResult{}, fmt.Errorf("finalize multipart image edit: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.editEndpoint, &body)
	if err != nil {
		return GenerateResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return GenerateResult{}, fmt.Errorf("request image edit: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return GenerateResult{}, fmt.Errorf("read image response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return GenerateResult{}, fmt.Errorf("image API returned HTTP %d: %s", resp.StatusCode, summarize(respBody))
	}
	return writeImageResponse(respBody, outputDir, input.OutputName, size)
}

func BuildEditsEndpoint(baseURL string) string {
	u := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if strings.HasSuffix(u, "/v1/images/edits") {
		return u
	}
	if strings.HasSuffix(u, "/v1/images/generations") {
		return strings.TrimSuffix(u, "/generations") + "/edits"
	}
	if strings.HasSuffix(u, "/images/edits") {
		return u
	}
	if strings.HasSuffix(u, "/images/generations") {
		return strings.TrimSuffix(u, "/generations") + "/edits"
	}
	if strings.HasSuffix(u, "/v1") {
		return u + "/images/edits"
	}
	return u + "/v1/images/edits"
}

func (c *Client) Generate(ctx context.Context, input GenerateRequest) (GenerateResult, error) {
	prompt := strings.TrimSpace(input.Prompt)
	if prompt == "" {
		return GenerateResult{}, errors.New("prompt is required")
	}
	size := strings.TrimSpace(input.Size)
	if size == "" {
		size = DefaultSize
	}
	outputDir := strings.TrimSpace(input.OutputDir)
	if outputDir == "" {
		outputDir = c.outputDir
	} else if !filepath.IsAbs(outputDir) {
		return GenerateResult{}, errors.New("output_dir must be an absolute path")
	}

	payload := map[string]any{
		"model":  DefaultModel,
		"prompt": prompt,
		"size":   size,
		"n":      1,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return GenerateResult{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return GenerateResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return GenerateResult{}, fmt.Errorf("request image generation: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return GenerateResult{}, fmt.Errorf("read image response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return GenerateResult{}, fmt.Errorf("image API returned HTTP %d: %s", resp.StatusCode, summarize(respBody))
	}
	return saveImageResponse(respBody, size, outputDir, input.OutputName)
}

func (c *Client) Edit(ctx context.Context, input EditRequest) (EditResult, error) {
	prompt := strings.TrimSpace(input.Prompt)
	if prompt == "" {
		return EditResult{}, errors.New("prompt is required")
	}
	size := strings.TrimSpace(input.Size)
	if size == "" {
		size = DefaultSize
	}
	outputDir := strings.TrimSpace(input.OutputDir)
	if outputDir == "" {
		outputDir = c.outputDir
	} else if !filepath.IsAbs(outputDir) {
		return EditResult{}, errors.New("output_dir must be an absolute path")
	}

	var imagePaths []string
	for _, p := range input.ImagePaths {
		p = strings.TrimSpace(p)
		if p != "" {
			imagePaths = append(imagePaths, p)
		}
	}
	if len(imagePaths) == 0 {
		return EditResult{}, errors.New("at least one image path is required")
	}
	for _, p := range imagePaths {
		if !filepath.IsAbs(p) {
			return EditResult{}, fmt.Errorf("image path must be an absolute path: %s", p)
		}
		if _, err := os.Stat(p); err != nil {
			return EditResult{}, fmt.Errorf("image file not found: %s: %w", p, err)
		}
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("model", DefaultModel)
	_ = writer.WriteField("prompt", prompt)
	_ = writer.WriteField("size", size)
	_ = writer.WriteField("n", "1")
	_ = writer.WriteField("response_format", "b64_json")
	for _, p := range imagePaths {
		imgBytes, err := os.ReadFile(p)
		if err != nil {
			return EditResult{}, fmt.Errorf("read image %s: %w", p, err)
		}
		part, err := writer.CreateFormFile("image[]", filepath.Base(p))
		if err != nil {
			return EditResult{}, fmt.Errorf("create form file: %w", err)
		}
		if _, err := part.Write(imgBytes); err != nil {
			return EditResult{}, fmt.Errorf("write image to form: %w", err)
		}
	}
	maskPath := strings.TrimSpace(input.MaskPath)
	if maskPath != "" {
		if !filepath.IsAbs(maskPath) {
			return EditResult{}, errors.New("mask_path must be an absolute path")
		}
		maskBytes, err := os.ReadFile(maskPath)
		if err != nil {
			return EditResult{}, fmt.Errorf("read mask: %w", err)
		}
		part, err := writer.CreateFormFile("mask", filepath.Base(maskPath))
		if err != nil {
			return EditResult{}, fmt.Errorf("create mask form file: %w", err)
		}
		if _, err := part.Write(maskBytes); err != nil {
			return EditResult{}, fmt.Errorf("write mask to form: %w", err)
		}
	}
	writer.Close()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.editsEndpoint, &body)
	if err != nil {
		return EditResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return EditResult{}, fmt.Errorf("request image generation: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return EditResult{}, fmt.Errorf("read image response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return EditResult{}, fmt.Errorf("image API returned HTTP %d: %s", resp.StatusCode, summarize(respBody))
	}
	return saveImageResponse(respBody, size, outputDir, input.OutputName)
}

func saveImageResponse(respBody []byte, size, outputDir, outputName string) (GenerateResult, error) {

	return writeImageResponse(respBody, outputDir, input.OutputName, size)
}

func writeImageResponse(respBody []byte, outputDir, outputName, size string) (GenerateResult, error) {
	var parsed struct {
		Data []struct {
			B64JSON string `json:"b64_json"`
		} `json:"data"`
		Error any `json:"error,omitempty"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return GenerateResult{}, fmt.Errorf("parse image response: %w: %s", err, summarize(respBody))
	}
	if len(parsed.Data) == 0 || strings.TrimSpace(parsed.Data[0].B64JSON) == "" {
		return GenerateResult{}, fmt.Errorf("image response missing data[0].b64_json: %s", summarize(respBody))
	}

	pngBytes, err := base64.StdEncoding.DecodeString(parsed.Data[0].B64JSON)
	if err != nil {
		return GenerateResult{}, fmt.Errorf("decode data[0].b64_json: %w", err)
	}
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return GenerateResult{}, fmt.Errorf("create output directory: %w", err)
	}

	fileName := cleanOutputName(outputName)
	if fileName == "" {
		fileName = "image2-" + time.Now().Format("20060102-150405") + ".png"
	}
	filePath := filepath.Join(outputDir, fileName)
	if err := os.WriteFile(filePath, pngBytes, 0o644); err != nil {
		return GenerateResult{}, fmt.Errorf("write PNG: %w", err)
	}

	return GenerateResult{
		FilePath: filePath,
		Model:    DefaultModel,
		Size:     size,
	}, nil
}

func cleanOutputName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	name = filepath.Base(name)
	name = safeNameRE.ReplaceAllString(name, "-")
	name = strings.Trim(name, ".-")
	if name == "" {
		return ""
	}
	if !strings.HasSuffix(strings.ToLower(name), ".png") {
		name += ".png"
	}
	return name
}

func summarize(body []byte) string {
	const max = 800
	s := strings.TrimSpace(string(body))
	if len(s) > max {
		return s[:max] + "...(truncated)"
	}
	return s
}
