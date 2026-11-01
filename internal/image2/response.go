package image2

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	"image/png"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func (c *Client) saveImageResponse(ctx context.Context, body []byte, headers http.Header, status int, size, dir, name, model string) (GenerateResult, error) {
	var parsed struct {
		Data []struct {
			B64JSON string `json:"b64_json"`
			URL     string `json:"url"`
		} `json:"data"`
	}
	fail := func(reason string) (GenerateResult, error) {
		return GenerateResult{}, c.imageResponseError(reason, body, headers, status, dir)
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return fail("parse image response: unexpected JSON format")
	}
	if len(parsed.Data) == 0 {
		return fail("image response missing data[0].b64_json and data[0].url")
	}
	first := parsed.Data[0]
	var data []byte
	var err error
	if encoded := strings.TrimSpace(first.B64JSON); encoded != "" {
		data, err = base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return fail("decode data[0].b64_json: invalid base64 image")
		}
	} else if link := strings.TrimSpace(first.URL); link != "" {
		data, err = c.downloadImage(ctx, link)
		if err != nil {
			return fail(err.Error())
		}
	} else {
		return fail("image response missing data[0].b64_json and data[0].url")
	}
	if len(data) == 0 {
		return fail("image response contains empty image")
	}
	return savePNG(data, size, dir, name, model)
}

func validImageURL(u *url.URL) bool {
	return u != nil && (u.Scheme == "http" || u.Scheme == "https") && u.Hostname() != "" && u.User == nil
}

func (c *Client) downloadImage(ctx context.Context, link string) ([]byte, error) {
	u, err := url.Parse(link)
	if err != nil || !validImageURL(u) {
		return nil, errors.New("image URL must be an absolute HTTP(S) URL without credentials")
	}
	// Use the existing transport (including its proxy/TLS settings), but never
	// attach the API key, API cookies, or signed URLs to diagnostics.
	downloader := *c.httpClient
	downloader.Jar = nil
	if downloader.Timeout == 0 {
		downloader.Timeout = 180 * time.Second
	}
	downloader.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("too many image redirects")
		}
		if !validImageURL(req.URL) {
			return errors.New("invalid image redirect")
		}
		req.Header.Del("Authorization")
		req.Header.Del("Cookie")
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, errors.New("create image download request failed")
	}
	resp, err := downloader.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("download image: %w", ctx.Err())
		}
		return nil, errors.New("download image failed (network, timeout, or redirect); URL redacted")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("download image returned HTTP %d; URL and response body redacted", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxImageResponseBytes+1))
	if err != nil {
		return nil, errors.New("read downloaded image failed")
	}
	if len(data) > maxImageResponseBytes {
		return nil, errors.New("downloaded image exceeds 64 MiB")
	}
	if len(data) == 0 {
		return nil, errors.New("download returned empty image")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("download returned unsupported or invalid image (expected PNG, JPEG, or GIF)")
	}
	if config.Width <= 0 || config.Height <= 0 || int64(config.Width)*int64(config.Height) > 32<<20 {
		return nil, errors.New("downloaded image dimensions exceed 32 million pixels")
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("download returned unsupported or invalid image")
	}
	if format == "png" {
		return data, nil
	}
	var output bytes.Buffer
	if err := png.Encode(&output, decoded); err != nil {
		return nil, errors.New("convert downloaded image to PNG failed")
	}
	return output.Bytes(), nil
}

const (
	maxDiagnosticDepth   = 16
	maxDiagnosticNodes   = 2048
	maxDiagnosticMembers = 64
	maxDiagnosticBytes   = 256 << 10
	diagnosticTruncated  = "[truncated: diagnostic structure limit]"
)

var diagnosticProtocolFields = map[string]bool{
	"created": true, "data": true, "b64_json": true, "url": true,
	"revised_prompt": true, "error": true, "message": true,
	"type": true, "param": true, "code": true, "status": true,
	"details": true, "model": true, "id": true, "object": true,
	"usage": true, "input_tokens": true, "input_tokens_details": true,
	"image_tokens": true, "text_tokens": true, "output_tokens": true,
	"output_tokens_details": true, "total_tokens": true, "cached_tokens": true,
	"background": true, "output_format": true, "quality": true, "size": true,
}

// Preserve bounded protocol structure, never arbitrary field names or string
// values: either can contain prompts, image bytes, signed URLs, or credentials.
func responseShape(value any) any {
	budget := diagnosticShapeBudget{remaining: maxDiagnosticNodes}
	return budget.redact(value, 1)
}

type diagnosticShapeBudget struct {
	remaining int
}

func (b *diagnosticShapeBudget) redact(value any, depth int) any {
	b.remaining--
	if depth >= maxDiagnosticDepth {
		return diagnosticTruncated
	}
	switch v := value.(type) {
	case map[string]any:
		result := make(map[string]any, min(len(v), maxDiagnosticMembers))
		unknown, processed := 0, 0
		for key, item := range v {
			if b.remaining == 0 {
				break
			}
			if (len(v) > maxDiagnosticMembers && processed == maxDiagnosticMembers-1) || b.remaining == 1 {
				result["[truncated]"] = diagnosticTruncated
				b.remaining--
				break
			}
			if !diagnosticProtocolFields[key] {
				unknown++
				key = fmt.Sprintf("[redacted field %d]", unknown)
			}
			result[key] = b.redact(item, depth+1)
			processed++
		}
		return result
	case []any:
		result := make([]any, 0, min(len(v), maxDiagnosticMembers))
		for i, item := range v {
			if b.remaining == 0 {
				break
			}
			if (len(v) > maxDiagnosticMembers && i == maxDiagnosticMembers-1) || b.remaining == 1 {
				result = append(result, diagnosticTruncated)
				b.remaining--
				break
			}
			result = append(result, b.redact(item, depth+1))
		}
		return result
	case string:
		return fmt.Sprintf("[redacted string: %d bytes]", len(v))
	default:
		return value
	}
}

func (c *Client) imageResponseError(reason string, body []byte, headers http.Header, status int, dir string) error {
	var value any
	var shape any
	if json.Unmarshal(body, &value) == nil {
		shape = responseShape(value)
	} else {
		shape = "[non-JSON body redacted]"
	}
	requestID := firstHeader(headers, "X-Request-ID", "Request-ID")
	requestID = strings.ReplaceAll(requestID, c.apiKey, "[redacted]")
	if strings.ContainsAny(requestID, "/?#\r\n") || len(requestID) > 200 {
		requestID = "[redacted]"
	}
	diagnostic := map[string]any{
		"reason": reason, "http_status": status, "request_id": requestID,
		"response_bytes": len(body), "response_structure": shape,
		"redaction": "Response string values and unknown field names are omitted; protocol structure is bounded and non-JSON bodies are omitted.",
	}
	// Compact encoding avoids quadratic indentation growth on nested input.
	encoded, err := json.Marshal(diagnostic)
	if err == nil && len(encoded) > maxDiagnosticBytes {
		diagnostic["reason"] = "[truncated: diagnostic exceeds byte limit]"
		diagnostic["response_structure"] = diagnosticTruncated
		encoded, err = json.Marshal(diagnostic)
		if err == nil && len(encoded) > maxDiagnosticBytes {
			err = errors.New("diagnostic exceeds byte limit")
		}
	}
	if err == nil {
		err = os.MkdirAll(dir, 0755)
	}
	if err != nil {
		return fmt.Errorf("%s; could not save redacted response diagnostic", reason)
	}
	file, err := os.CreateTemp(dir, "image2-response-*.json")
	if err != nil {
		return fmt.Errorf("%s; could not save redacted response diagnostic", reason)
	}
	path := file.Name()
	_, writeErr := file.Write(encoded)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(path)
		return fmt.Errorf("%s; could not save redacted response diagnostic", reason)
	}
	return fmt.Errorf("%s; redacted response diagnostic: %s", reason, path)
}
