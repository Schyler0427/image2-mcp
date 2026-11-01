package gemini

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
)

const (
	maxDiagnosticDepth   = 16
	maxDiagnosticNodes   = 2048
	maxDiagnosticMembers = 64
	maxDiagnosticBytes   = 256 << 10
	diagnosticTruncated  = "[truncated: diagnostic structure limit]"
)

var diagnosticProtocolFields = map[string]bool{
	"candidates": true, "content": true, "role": true, "parts": true,
	"text": true, "inlineData": true, "inline_data": true, "mimeType": true,
	"mime_type": true, "data": true, "thought": true, "thoughtSignature": true,
	"thought_signature": true, "finishReason": true, "finish_reason": true,
	"promptFeedback": true, "prompt_feedback": true, "blockReason": true,
	"block_reason": true, "error": true, "code": true, "message": true,
	"status": true, "details": true, "usageMetadata": true, "usage_metadata": true,
	"modelVersion": true, "model_version": true, "responseId": true, "response_id": true,
	"safetyRatings": true, "safety_ratings": true, "category": true,
	"probability": true, "blocked": true, "promptTokenCount": true,
	"candidatesTokenCount": true, "totalTokenCount": true, "thoughtsTokenCount": true,
}

func redactedShape(value any, secrets []string) any {
	budget := diagnosticShapeBudget{remaining: maxDiagnosticNodes}
	return budget.redact(value, secrets, 1)
}

type diagnosticShapeBudget struct {
	remaining int
}

func (b *diagnosticShapeBudget) redact(value any, secrets []string, depth int) any {
	b.remaining--
	if depth >= maxDiagnosticDepth {
		return diagnosticTruncated
	}
	switch v := value.(type) {
	case map[string]any:
		result := make(map[string]any, min(len(v), maxDiagnosticMembers))
		unknown := 0
		processed := 0
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
			for _, secret := range secrets {
				if secret != "" {
					key = strings.ReplaceAll(key, secret, "[redacted]")
				}
			}
			result[key] = b.redact(item, secrets, depth+1)
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
			result = append(result, b.redact(item, secrets, depth+1))
		}
		return result
	case string:
		return fmt.Sprintf("[redacted string: %d bytes]", len(v))
	default:
		return value
	}
}

func (c *Client) responseError(reason string, body []byte, headers http.Header, status int, dir, prompt string) error {
	var parsed any
	var shape any = "[non-JSON body omitted]"
	if json.Unmarshal(body, &parsed) == nil {
		shape = redactedShape(parsed, []string{c.apiKey, prompt})
	}
	// Header values are untrusted too. Only record presence, not raw IDs.
	requestIDPresent := headers.Get("X-Request-ID") != "" || headers.Get("Request-ID") != ""
	diagnostic := map[string]any{"reason": reason, "http_status": status, "response_bytes": len(body), "request_id_present": requestIDPresent, "response_structure": shape, "redaction": "All response string values are omitted; image bytes, prompts, and credentials are not stored."}
	// Compact encoding avoids quadratic indentation growth on nested input.
	encoded, err := json.Marshal(diagnostic)
	if err != nil {
		return errors.New(reason + "; could not encode redacted diagnostic")
	}
	if len(encoded) > maxDiagnosticBytes {
		diagnostic["reason"] = "[truncated: diagnostic exceeds byte limit]"
		diagnostic["response_structure"] = diagnosticTruncated
		encoded, err = json.Marshal(diagnostic)
		if err != nil || len(encoded) > maxDiagnosticBytes {
			return errors.New(reason + "; could not encode bounded redacted diagnostic")
		}
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		return errors.New(reason + "; could not save redacted diagnostic")
	}
	file, err := os.CreateTemp(dir, "gemini-response-*.json")
	if err != nil {
		return errors.New(reason + "; could not save redacted diagnostic")
	}
	_, writeErr := file.Write(encoded)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(file.Name())
		return errors.New(reason + "; could not save redacted diagnostic")
	}
	return fmt.Errorf("%s; redacted diagnostic: %s", reason, file.Name())
}
