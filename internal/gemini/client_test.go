package gemini

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testPNG(t *testing.T) []byte {
	t.Helper()
	var b bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 2, 3))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func imageReply(data []byte) map[string]any {
	return map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{
		map[string]any{"text": "a textual preface"},
		map[string]any{"thought": true, "inlineData": map[string]any{"mimeType": "image/png", "data": "bad-thought-image"}},
		map[string]any{"inlineData": map[string]any{"mimeType": "image/png", "data": base64.StdEncoding.EncodeToString(data)}},
	}}}}}
}

func TestGenerateNativeProtocolAndDedicatedCredential(t *testing.T) {
	expected := testPNG(t)
	t.Setenv("OPENAI_IMAGE_API_KEY", "wrong-image2-key")
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/v1beta/models/gemini-test-image:generateContent" {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		if r.URL.RawQuery != "" || r.Header.Get("x-goog-api-key") != "dedicated-gemini-key" || r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("request credential isolation failed")
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
			return
		}
		if _, ok := payload["model"]; ok {
			t.Error("native Gemini body must not contain model")
		}
		config := payload["generationConfig"].(map[string]any)
		imageConfig := config["imageConfig"].(map[string]any)
		if imageConfig["aspectRatio"] != "16:9" || imageConfig["imageSize"] != "4K" {
			t.Errorf("imageConfig=%v", imageConfig)
		}
		content := payload["contents"].([]any)[0].(map[string]any)
		if content["role"] != "user" || content["parts"].([]any)[0].(map[string]any)["text"] != "draw a cup" {
			t.Errorf("content=%v", content)
		}
		_ = json.NewEncoder(w).Encode(imageReply(expected))
	}))
	defer server.Close()
	out := t.TempDir()
	client, err := New("dedicated-gemini-key", server.URL, "gemini-test-image", out, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	got, err := client.Generate(context.Background(), Request{Prompt: "draw a cup", AspectRatio: "16:9", ImageSize: "4K", OutputName: "cup"})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(got.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, expected) || got.Model != "gemini-test-image" || got.Size != "2x3" || filepath.Ext(got.FilePath) != ".png" {
		t.Fatalf("result=%#v", got)
	}
	if hits.Load() != 1 {
		t.Fatalf("hits=%d", hits.Load())
	}
}

func TestEditPreservesReferenceOrderAndSniffsMIME(t *testing.T) {
	pngData := testPNG(t)
	var jpegData bytes.Buffer
	if err := jpeg.Encode(&jpegData, image.NewRGBA(image.Rect(0, 0, 4, 2)), nil); err != nil {
		t.Fatal(err)
	}
	input := t.TempDir()
	first := filepath.Join(input, "reference-wrong-extension.dat")
	second := filepath.Join(input, "second.png")
	if err := os.WriteFile(first, jpegData.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, pngData, 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Contents []struct {
				Parts []struct {
					Text   string `json:"text"`
					Inline struct {
						MIME string `json:"mimeType"`
						Data string `json:"data"`
					} `json:"inlineData"`
				} `json:"parts"`
			} `json:"contents"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
			return
		}
		parts := payload.Contents[0].Parts
		if len(parts) != 3 || parts[1].Inline.MIME != "image/jpeg" || parts[2].Inline.MIME != "image/png" {
			t.Errorf("parts=%#v", parts)
		}
		firstData, _ := base64.StdEncoding.DecodeString(parts[1].Inline.Data)
		secondData, _ := base64.StdEncoding.DecodeString(parts[2].Inline.Data)
		if !bytes.Equal(firstData, jpegData.Bytes()) || !bytes.Equal(secondData, pngData) {
			t.Error("reference ordering changed")
		}
		_ = json.NewEncoder(w).Encode(imageReply(pngData))
	}))
	defer server.Close()
	client, err := New("gemini-key", server.URL, "test-model", t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Edit(context.Background(), Request{Prompt: "edit these", ImagePaths: []string{first, second}}); err != nil {
		t.Fatal(err)
	}
}

func TestResponseSnakeCaseAndJPEGConversion(t *testing.T) {
	var jpegData bytes.Buffer
	if err := jpeg.Encode(&jpegData, image.NewRGBA(image.Rect(0, 0, 5, 3)), nil); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"candidates":[{"content":{"parts":[{"inline_data":{"mime_type":"image/jpeg","data":"`+base64.StdEncoding.EncodeToString(jpegData.Bytes())+`"}}]}}]}`)
	}))
	defer server.Close()
	c, err := New("key", server.URL, "model", t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := c.Generate(context.Background(), Request{Prompt: "test"})
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(got.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	cfg, format, err := image.DecodeConfig(f)
	if err != nil || format != "png" || cfg.Width != 5 || cfg.Height != 3 {
		t.Fatalf("saved format=%s cfg=%v err=%v", format, cfg, err)
	}
}

func TestFailureDiagnosticsAreRedactedAndNotRetried(t *testing.T) {
	secret := "gemini-secret-do-not-print"
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"HTTP error", 503, `{"error":{"message":"` + secret + ` private prompt"}}`},
		{"blocked", 200, `{"promptFeedback":{"blockReason":"SAFETY"},"sensitive":"` + secret + `"}`},
		{"text only", 200, `{"candidates":[{"content":{"parts":[{"text":"private prompt"}]},"finishReason":"STOP"}]}`},
		{"invalid base64", 200, `{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"private prompt !"}}]}}]}`},
		{"invalid image", 200, `{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"cHJpdmF0ZSBwcm9tcHQ="}}]}}]}`},
		{"non-json", 200, secret + " private prompt"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var hits atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				w.Header().Set("X-Request-ID", secret)
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			out := t.TempDir()
			c, err := New(secret, server.URL, "model", out, nil)
			if err != nil {
				t.Fatal(err)
			}
			_, err = c.Generate(context.Background(), Request{Prompt: "private prompt"})
			if err == nil {
				t.Fatal("expected failure")
			}
			if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "private prompt") {
				t.Fatalf("error leaked private data: %v", err)
			}
			if hits.Load() != 1 {
				t.Fatalf("HTTP attempts=%d", hits.Load())
			}
			paths, _ := filepath.Glob(filepath.Join(out, "gemini-response-*.json"))
			if len(paths) != 1 {
				t.Fatalf("diagnostics=%v error=%v", paths, err)
			}
			data, readErr := os.ReadFile(paths[0])
			if readErr != nil {
				t.Fatal(readErr)
			}
			if strings.Contains(string(data), secret) || strings.Contains(string(data), "private prompt") || strings.Contains(string(data), "cHJpdmF0ZSBwcm9tcHQ=") {
				t.Fatalf("diagnostic leaked: %s", data)
			}
		})
	}
}

func TestRejectRedirectWithoutCredentialForward(t *testing.T) {
	var forwarded atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded.Add(1) }))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()
	c, err := New("dedicated-key", source.URL, "model", t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Generate(context.Background(), Request{Prompt: "test"}); err == nil {
		t.Fatal("redirect accepted")
	}
	if forwarded.Load() != 0 {
		t.Fatal("redirect forwarded request or credential")
	}
}

func TestCancellation(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	c, err := New("key", server.URL, "model", t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := c.Generate(ctx, Request{Prompt: "test"}); done <- err }()
	select {
	case <-started:
		cancel()
	case <-time.After(2 * time.Second):
		t.Fatal("request did not start")
	}
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("error=%v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation stalled")
	}
}

func TestValidationBeforeNetwork(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
	defer server.Close()
	for _, tc := range []struct {
		name    string
		edit    bool
		request Request
	}{
		{"empty prompt", false, Request{}},
		{"bad size", false, Request{Prompt: "test", ImageSize: "3K"}},
		{"bad aspect", false, Request{Prompt: "test", AspectRatio: "arbitrary"}},
		{"relative output", false, Request{Prompt: "test", OutputDir: "relative"}},
		{"edit missing references", true, Request{Prompt: "test"}},
		{"too many references", true, Request{Prompt: "test", ImagePaths: make([]string, 17)}},
		{"relative reference", true, Request{Prompt: "test", ImagePaths: []string{"relative.png"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := New("key", server.URL, "model", t.TempDir(), nil)
			if err != nil {
				t.Fatal(err)
			}
			if tc.edit {
				_, err = c.Edit(context.Background(), tc.request)
			} else {
				_, err = c.Generate(context.Background(), tc.request)
			}
			if err == nil {
				t.Fatal("invalid request accepted")
			}
		})
	}
	if hits.Load() != 0 {
		t.Fatalf("invalid requests reached network: %d", hits.Load())
	}
	for _, tc := range []struct{ key, base, model string }{{"", server.URL, "model"}, {"key", server.URL, ""}, {"key", server.URL, "../escape"}, {"key", "https://user:secret@example.test", "model"}, {"key", "https://example.test?key=secret", "model"}} {
		if _, err := New(tc.key, tc.base, tc.model, t.TempDir(), nil); err == nil {
			t.Errorf("invalid client configuration accepted")
		}
	}
}
