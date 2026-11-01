package gemini

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	_ "golang.org/x/image/webp"
)

func encodeImage(data []byte) string { return base64.StdEncoding.EncodeToString(data) }

func expandPath(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path != "~" && !strings.HasPrefix(path, "~/") && !strings.HasPrefix(path, `~\`) {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("resolve home directory failed")
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, path[2:]), nil
}

func readReference(path string, remaining int64) ([]byte, string, error) {
	path, err := expandPath(path)
	if err != nil {
		return nil, "", err
	}
	if !filepath.IsAbs(path) {
		return nil, "", errors.New("reference image path must be absolute")
	}
	beforeOpen, err := os.Stat(path)
	if err != nil || !beforeOpen.Mode().IsRegular() {
		return nil, "", errors.New("reference image must be a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, "", errors.New("open reference image failed")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, "", errors.New("reference image must be a regular file")
	}
	if info.Size() <= 0 || info.Size() > remaining {
		return nil, "", errors.New("reference image inputs must be nonempty and total at most 64 MiB")
	}
	data, err := io.ReadAll(io.LimitReader(file, remaining+1))
	if err != nil {
		return nil, "", errors.New("read reference image failed")
	}
	if int64(len(data)) > remaining {
		return nil, "", errors.New("reference images exceed 64 MiB")
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, "", errors.New("reference image is invalid or unsupported")
	}
	if !validDimensions(cfg) {
		return nil, "", errors.New("reference image exceeds 32 million pixels")
	}
	mime := formatMIME(format)
	if mime == "" {
		return nil, "", errors.New("reference image must be PNG, JPEG, or WebP")
	}
	if _, _, err := image.Decode(bytes.NewReader(data)); err != nil {
		return nil, "", errors.New("reference image cannot be decoded")
	}
	return data, mime, nil
}

type responseInline struct {
	MIME      string `json:"mimeType"`
	SnakeMIME string `json:"mime_type"`
	Data      string `json:"data"`
}

func extractImage(raw []byte) ([]byte, string, error) {
	var response struct {
		Error      json.RawMessage `json:"error"`
		Candidates []struct {
			Content struct {
				Parts []struct {
					Thought     bool            `json:"thought"`
					Inline      *responseInline `json:"inlineData"`
					SnakeInline *responseInline `json:"inline_data"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, "", errors.New("Gemini image response has invalid JSON")
	}
	if len(response.Error) > 0 && string(response.Error) != "null" {
		return nil, "", errors.New("Gemini image response contains an API error")
	}
	for _, candidate := range response.Candidates {
		for _, part := range candidate.Content.Parts {
			if part.Thought {
				continue
			}
			inline := part.Inline
			if inline == nil {
				inline = part.SnakeInline
			}
			if inline == nil || strings.TrimSpace(inline.Data) == "" {
				continue
			}
			mime := inline.MIME
			if mime == "" {
				mime = inline.SnakeMIME
			}
			switch mime {
			case "image/png", "image/jpeg", "image/webp":
			default:
				return nil, "", errors.New("Gemini returned an unsupported image MIME type")
			}
			data, err := base64.StdEncoding.DecodeString(inline.Data)
			if err != nil {
				return nil, "", errors.New("Gemini returned invalid Base64 image data")
			}
			if len(data) == 0 {
				continue
			}
			return data, mime, nil
		}
	}
	return nil, "", errors.New("Gemini response contains no final image; inspect redacted diagnostic for candidate or prompt-feedback structure")
}

func validDimensions(cfg image.Config) bool {
	return cfg.Width > 0 && cfg.Height > 0 && int64(cfg.Width)*int64(cfg.Height) <= maxImagePixels
}

func formatMIME(format string) string {
	switch format {
	case "png":
		return "image/png"
	case "jpeg":
		return "image/jpeg"
	case "webp":
		return "image/webp"
	}
	return ""
}

func normalizeImage(data []byte, declared string) ([]byte, int, int, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, errors.New("Gemini returned invalid image bytes")
	}
	if !validDimensions(cfg) {
		return nil, 0, 0, errors.New("Gemini returned image dimensions exceeding 32 million pixels")
	}
	if declared != formatMIME(format) {
		return nil, 0, 0, errors.New("Gemini image MIME type does not match actual format")
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, errors.New("Gemini returned an image that cannot be decoded")
	}
	if format == "png" {
		return data, cfg.Width, cfg.Height, nil
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, 0, 0, errors.New("convert Gemini image to PNG failed")
	}
	return b.Bytes(), cfg.Width, cfg.Height, nil
}

var safeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func saveOutput(data []byte, dir, name string) (string, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", errors.New("create Gemini output directory failed")
	}
	name = strings.Trim(safeName.ReplaceAllString(filepath.Base(strings.TrimSpace(name)), "-"), ".-")
	if name == "" {
		name = "gemini-*.png"
	} else if !strings.HasSuffix(strings.ToLower(name), ".png") {
		name += ".png"
	}
	temporary, err := os.CreateTemp(dir, ".gemini-image-*.tmp")
	if err != nil {
		return "", errors.New("create Gemini image file failed")
	}
	tempPath := temporary.Name()
	defer os.Remove(tempPath)
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return "", errors.New("write Gemini image failed")
	}
	if err := temporary.Close(); err != nil {
		return "", errors.New("close Gemini image failed")
	}
	if strings.Contains(name, "*") {
		name = "gemini-" + strings.TrimSuffix(strings.TrimPrefix(filepath.Base(tempPath), ".gemini-image-"), ".tmp") + ".png"
	}
	path := filepath.Join(dir, name)
	if err := os.Rename(tempPath, path); err != nil {
		return "", errors.New("save Gemini image failed")
	}
	return path, nil
}
