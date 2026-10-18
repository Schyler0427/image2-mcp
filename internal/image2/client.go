package image2

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultBaseURL        = "https://api.schyler.top"
	DefaultModel          = "gpt-image-2"
	Image25Model          = "gpt-image-2.5-sunburst"
	DefaultSize           = "1024x1024"
	DefaultQuality        = "auto"
	maxAttempts           = 3
	maxRetryAfter         = 10 * time.Second
	maxImageResponseBytes = 64 << 20
	maxErrorResponseBytes = 64 << 10
)

var safeNameRE = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

type Client struct {
	apiKey        string
	model         string
	endpoint      string
	editsEndpoint string
	outputDir     string
	httpClient    *http.Client
}

type GenerateRequest struct {
	Prompt     string `json:"prompt"`
	Version    string `json:"version,omitempty"`
	Size       string `json:"size,omitempty"`
	OutputDir  string `json:"output_dir,omitempty"`
	OutputName string `json:"output_name,omitempty"`
}

type GenerateResult struct {
	FilePath string `json:"file_path"`
	Model    string `json:"model"`
	Size     string `json:"size"`
}

type EditRequest struct {
	Prompt     string   `json:"prompt"`
	Version    string   `json:"version,omitempty"`
	Size       string   `json:"size,omitempty"`
	Quality    string   `json:"quality,omitempty"`
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
		model:         configuredModel(),
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
		model:         configuredModel(),
		endpoint:      BuildGenerationsEndpoint(baseURL),
		editsEndpoint: BuildEditsEndpoint(baseURL),
		outputDir:     outputDir,
		httpClient:    httpClient,
	}, nil
}

func configuredModel() string {
	model := strings.TrimSpace(os.Getenv("OPENAI_IMAGE_MODEL"))
	if model == "" {
		return DefaultModel
	}
	return model
}

func resolveRequestedModel(version string, configured string) (string, error) {
	version = strings.ToLower(strings.TrimSpace(version))
	if version == "" {
		return configured, nil
	}
	version = strings.ReplaceAll(version, " ", "")
	version = strings.TrimSuffix(version, "生图")
	version = strings.TrimPrefix(version, "image")
	switch version {
	case "2.0":
		return DefaultModel, nil
	case "2.5":
		return Image25Model, nil
	default:
		return "", errors.New("image version must be 2.0 or 2.5")
	}
}

func BuildGenerationsEndpoint(baseURL string) string {
	return buildImagesEndpoint(baseURL, "generations")
}

func BuildEditsEndpoint(baseURL string) string {
	return buildImagesEndpoint(baseURL, "edits")
}

func buildImagesEndpoint(baseURL, operation string) string {
	u := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	for _, existing := range []string{"generations", "edits"} {
		suffix := "/images/" + existing
		if strings.HasSuffix(u, suffix) {
			return strings.TrimSuffix(u, suffix) + "/images/" + operation
		}
	}
	if strings.HasSuffix(u, "/v1") {
		return u + "/images/" + operation
	}
	return u + "/v1/images/" + operation
}

func (c *Client) Generate(ctx context.Context, input GenerateRequest) (GenerateResult, error) {
	model, err := resolveRequestedModel(input.Version, c.model)
	if err != nil {
		return GenerateResult{}, err
	}
	prompt := strings.TrimSpace(input.Prompt)
	if prompt == "" {
		return GenerateResult{}, errors.New("prompt is required")
	}
	size := strings.TrimSpace(input.Size)
	if size == "" {
		size = DefaultSize
	}
	explicitOutputDir := strings.TrimSpace(input.OutputDir)
	outputDir := explicitOutputDir
	if outputDir == "" {
		outputDir = c.outputDir
	}
	outputDir, err = expandPath(outputDir)
	if err != nil {
		return GenerateResult{}, err
	}
	if explicitOutputDir != "" && !filepath.IsAbs(outputDir) {
		return GenerateResult{}, errors.New("output_dir must be an absolute path")
	}

	payload := map[string]any{
		"model":  model,
		"prompt": prompt,
		"size":   size,
		"n":      1,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return GenerateResult{}, err
	}

	respBody, _, _, _, err := c.doImageRequest(ctx, http.MethodPost, c.endpoint, body, "application/json")
	if err != nil {
		return GenerateResult{}, err
	}
	return saveImageResponse(respBody, size, outputDir, input.OutputName, model)
}

func (c *Client) Edit(ctx context.Context, input EditRequest) (EditResult, error) {
	model, err := resolveRequestedModel(input.Version, c.model)
	if err != nil {
		return EditResult{}, err
	}
	prompt := strings.TrimSpace(input.Prompt)
	if prompt == "" {
		return EditResult{}, errors.New("prompt is required")
	}
	size := strings.TrimSpace(input.Size)
	if size == "" {
		size = DefaultSize
	}
	quality := strings.TrimSpace(input.Quality)
	if quality == "" {
		quality = DefaultQuality
	}
	explicitOutputDir := strings.TrimSpace(input.OutputDir)
	outputDir := explicitOutputDir
	if outputDir == "" {
		outputDir = c.outputDir
	}
	outputDir, err = expandPath(outputDir)
	if err != nil {
		return EditResult{}, err
	}
	if explicitOutputDir != "" && !filepath.IsAbs(outputDir) {
		return EditResult{}, errors.New("output_dir must be an absolute path")
	}

	var imagePaths []string
	for _, path := range input.ImagePaths {
		path = strings.TrimSpace(path)
		if path != "" {
			path, err = expandPath(path)
			if err != nil {
				return EditResult{}, err
			}
			imagePaths = append(imagePaths, path)
		}
	}
	if len(imagePaths) == 0 {
		return EditResult{}, errors.New("at least one image path is required")
	}
	for _, path := range imagePaths {
		if !filepath.IsAbs(path) {
			return EditResult{}, fmt.Errorf("image path must be an absolute path: %s", path)
		}
		if err := requireRegularFile(path, "image"); err != nil {
			return EditResult{}, err
		}
	}

	maskPath := strings.TrimSpace(input.MaskPath)
	if maskPath != "" {
		maskPath, err = expandPath(maskPath)
		if err != nil {
			return EditResult{}, err
		}
		if !filepath.IsAbs(maskPath) {
			return EditResult{}, errors.New("mask_path must be an absolute path")
		}
		if err := requireRegularFile(maskPath, "mask"); err != nil {
			return EditResult{}, err
		}
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	fields := []struct {
		name  string
		value string
	}{
		{name: "model", value: model},
		{name: "prompt", value: prompt},
		{name: "size", value: size},
		{name: "quality", value: quality},
		{name: "n", value: "1"},
	}
	for _, field := range fields {
		if err := writer.WriteField(field.name, field.value); err != nil {
			return EditResult{}, fmt.Errorf("write multipart field %s: %w", field.name, err)
		}
	}
	for _, path := range imagePaths {
		if err := writeMultipartFile(writer, "image[]", path); err != nil {
			return EditResult{}, err
		}
	}
	if maskPath != "" {
		if err := writeMultipartFile(writer, "mask", maskPath); err != nil {
			return EditResult{}, err
		}
	}
	if err := writer.Close(); err != nil {
		return EditResult{}, fmt.Errorf("finalize multipart image edit: %w", err)
	}

	respBody, _, _, _, err := c.doImageRequest(ctx, http.MethodPost, c.editsEndpoint, body.Bytes(), writer.FormDataContentType())
	if err != nil {
		return EditResult{}, err
	}
	return saveImageResponse(respBody, size, outputDir, input.OutputName, model)
}

func (c *Client) doImageRequest(ctx context.Context, method, endpoint string, body []byte, contentType string) ([]byte, http.Header, int, int, error) {
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(body))
		if err != nil {
			return nil, nil, 0, attempt, err
		}
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
		req.Header.Set("Content-Type", contentType)

		resp, err := c.httpClient.Do(req)
		if err != nil {
			return nil, nil, 0, attempt, fmt.Errorf("request image API: %w", err)
		}
		limit := int64(maxErrorResponseBytes)
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			limit = maxImageResponseBytes
		}
		respBody, readErr := io.ReadAll(io.LimitReader(resp.Body, limit+1))
		headers := resp.Header.Clone()
		status := resp.StatusCode
		_ = resp.Body.Close()
		if readErr != nil {
			return nil, headers, status, attempt, fmt.Errorf("read image response: %w", readErr)
		}
		if status >= 200 && status < 300 {
			if int64(len(respBody)) > limit {
				return nil, headers, status, attempt, fmt.Errorf("image response exceeds %d MiB; request a smaller image", maxImageResponseBytes>>20)
			}
			return respBody, headers, status, attempt, nil
		}

		if attempt < maxAttempts && isRetryableStatus(status) {
			if err := waitForRetry(ctx, retryDelay(headers, attempt)); err != nil {
				return nil, headers, status, attempt, fmt.Errorf("image API returned HTTP %d after %d attempt(s): %w", status, attempt, err)
			}
			continue
		}
		return nil, headers, status, attempt, formatImageAPIError(status, attempt, headers, respBody)
	}

	return nil, nil, 0, maxAttempts, errors.New("image API request exhausted retry attempts")
}

func expandPath(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path != "~" && !strings.HasPrefix(path, "~/") && !strings.HasPrefix(path, `~\`) {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, path[2:]), nil
}

func isRetryableStatus(status int) bool {
	switch status {
	case http.StatusTooManyRequests, http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	default:
		return false
	}
}

func retryDelay(headers http.Header, attempt int) time.Duration {
	if raw := strings.TrimSpace(headers.Get("Retry-After")); raw != "" {
		if seconds, err := strconv.Atoi(raw); err == nil && seconds >= 0 {
			if seconds >= int(maxRetryAfter/time.Second) {
				return maxRetryAfter
			}
			return time.Duration(seconds) * time.Second
		}
	}
	return time.Duration(1<<(attempt-1)) * time.Second
}

func waitForRetry(ctx context.Context, delay time.Duration) error {
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func formatImageAPIError(status, attempts int, headers http.Header, body []byte) error {
	message := fmt.Sprintf("image API returned HTTP %d after %d attempt(s): %s", status, attempts, summarize(body))
	if isRetryableStatus(status) {
		message += "; transient failure, retry later"
	}
	if requestID := firstHeader(headers, "X-Request-ID", "Request-ID"); requestID != "" {
		message += " request_id=" + requestID
	}
	if retryAfter := strings.TrimSpace(headers.Get("Retry-After")); retryAfter != "" {
		message += " retry_after=" + retryAfter
	}
	return errors.New(message)
}

func firstHeader(headers http.Header, names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(headers.Get(name)); value != "" {
			return value
		}
	}
	return ""
}

func requireRegularFile(path, kind string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("%s file not found: %s: %w", kind, path, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s path must be a regular file: %s", kind, path)
	}
	return nil
}

func writeMultipartFile(writer *multipart.Writer, fieldName, path string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()

	header := make([]byte, 512)
	n, err := file.Read(header)
	if err != nil && err != io.EOF {
		return fmt.Errorf("read %s: %w", path, err)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("rewind %s: %w", path, err)
	}
	disposition := mime.FormatMediaType("form-data", map[string]string{
		"name":     fieldName,
		"filename": filepath.Base(path),
	})
	part, err := writer.CreatePart(textproto.MIMEHeader{
		"Content-Disposition": {disposition},
		"Content-Type":        {http.DetectContentType(header[:n])},
	})
	if err != nil {
		return fmt.Errorf("create multipart file for %s: %w", path, err)
	}
	if _, err := io.Copy(part, file); err != nil {
		return fmt.Errorf("write multipart file for %s: %w", path, err)
	}
	return nil
}

func saveImageResponse(respBody []byte, size, outputDir, outputName, model string) (GenerateResult, error) {
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
		Model:    model,
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
