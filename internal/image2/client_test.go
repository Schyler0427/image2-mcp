package image2

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildGenerationsEndpoint(t *testing.T) {
	tests := map[string]string{
		"https://api.schyler.top":                       "https://api.schyler.top/v1/images/generations",
		"https://api.schyler.top/":                      "https://api.schyler.top/v1/images/generations",
		"https://api.schyler.top/v1":                    "https://api.schyler.top/v1/images/generations",
		"https://api.schyler.top/v1/":                   "https://api.schyler.top/v1/images/generations",
		"https://api.schyler.top/v1/images/generations": "https://api.schyler.top/v1/images/generations",
		"https://api.schyler.top/v1/images/edits":       "https://api.schyler.top/v1/images/generations",
	}
	for in, want := range tests {
		if got := BuildGenerationsEndpoint(in); got != want {
			t.Fatalf("BuildGenerationsEndpoint(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBuildEditsEndpoint(t *testing.T) {
	tests := map[string]string{
		"https://api.schyler.top":                       "https://api.schyler.top/v1/images/edits",
		"https://api.schyler.top/":                      "https://api.schyler.top/v1/images/edits",
		"https://api.schyler.top/v1":                    "https://api.schyler.top/v1/images/edits",
		"https://api.schyler.top/v1/":                   "https://api.schyler.top/v1/images/edits",
		"https://api.schyler.top/v1/images/edits":       "https://api.schyler.top/v1/images/edits",
		"https://api.schyler.top/v1/images/generations": "https://api.schyler.top/v1/images/edits",
	}
	for in, want := range tests {
		if got := BuildEditsEndpoint(in); got != want {
			t.Fatalf("BuildEditsEndpoint(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNewRequiresAPIKey(t *testing.T) {
	if _, err := New("", DefaultBaseURL, t.TempDir(), nil); err == nil {
		t.Fatal("expected missing OPENAI_IMAGE_API_KEY error")
	}
}

func TestGenerateDecodesB64JSONAndWritesPNG(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/images/generations" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("Authorization = %q", got)
		}
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatal(err)
		}
		if req["model"] != DefaultModel || req["prompt"] != "hello" || req["size"] != DefaultSize || req["n"].(float64) != 1 {
			t.Fatalf("unexpected request payload: %#v", req)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(png)}},
		})
	}))
	defer server.Close()

	outDir := t.TempDir()
	client, err := New("test-key", server.URL, outDir, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Generate(context.Background(), GenerateRequest{
		Prompt:     "hello",
		OutputName: "../unsafe name",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Model != DefaultModel || result.Size != DefaultSize {
		t.Fatalf("unexpected result: %#v", result)
	}
	if filepath.Dir(result.FilePath) != outDir {
		t.Fatalf("file path escaped output dir: %s", result.FilePath)
	}
	got, err := os.ReadFile(result.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(png) {
		t.Fatalf("written bytes = %v, want %v", got, png)
	}
}

func TestGenerateUsesRequestedOutputDir(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(png)}},
		})
	}))
	defer server.Close()

	defaultDir := t.TempDir()
	requestedDir := filepath.Join(t.TempDir(), "custom")
	client, err := New("test-key", server.URL, defaultDir, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Generate(context.Background(), GenerateRequest{
		Prompt:     "hello",
		OutputDir:  requestedDir,
		OutputName: "custom.png",
	})
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(result.FilePath) != requestedDir {
		t.Fatalf("file dir = %q, want %q", filepath.Dir(result.FilePath), requestedDir)
	}
	if _, err := os.Stat(result.FilePath); err != nil {
		t.Fatal(err)
	}
}

func TestGenerateRejectsRelativeOutputDir(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("HTTP server should not be called for invalid output_dir")
	}))
	defer server.Close()

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Generate(context.Background(), GenerateRequest{
		Prompt:    "hello",
		OutputDir: "relative/path",
	})
	if err == nil || err.Error() != "output_dir must be an absolute path" {
		t.Fatalf("err = %v, want output_dir must be an absolute path", err)
	}
}

func TestEditDecodesB64JSONAndWritesPNG(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/images/edits" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("Authorization = %q", got)
		}
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "multipart/form-data") {
			t.Fatalf("Content-Type = %q, want multipart/form-data", ct)
		}
		if err := r.ParseMultipartForm(8 << 20); err != nil {
			t.Fatal(err)
		}
		if r.FormValue("model") != DefaultModel {
			t.Fatalf("model = %q, want %q", r.FormValue("model"), DefaultModel)
		}
		if r.FormValue("prompt") != "edit hello" {
			t.Fatalf("prompt = %q", r.FormValue("prompt"))
		}
		if r.FormValue("size") != DefaultSize {
			t.Fatalf("size = %q", r.FormValue("size"))
		}
		if r.FormValue("n") != "1" {
			t.Fatalf("n = %q", r.FormValue("n"))
		}
		if r.FormValue("response_format") != "b64_json" {
			t.Fatalf("response_format = %q", r.FormValue("response_format"))
		}
		f, _, err := r.FormFile("image[]")
		if err != nil {
			t.Fatalf("FormFile image[]: %v", err)
		}
		f.Close()
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(png)}},
		})
	}))
	defer server.Close()

	imgDir := t.TempDir()
	imgPath := filepath.Join(imgDir, "input.png")
	if err := os.WriteFile(imgPath, png, 0o644); err != nil {
		t.Fatal(err)
	}

	outDir := t.TempDir()
	client, err := New("test-key", server.URL, outDir, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Edit(context.Background(), EditRequest{
		Prompt:     "edit hello",
		ImagePaths: []string{imgPath},
		OutputName: "edited.png",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Model != DefaultModel || result.Size != DefaultSize {
		t.Fatalf("unexpected result: %#v", result)
	}
	if filepath.Dir(result.FilePath) != outDir {
		t.Fatalf("file path escaped output dir: %s", result.FilePath)
	}
	got, err := os.ReadFile(result.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(png) {
		t.Fatalf("written bytes = %v, want %v", got, png)
	}
}

func TestEditRequiresAtLeastOneImage(t *testing.T) {
	client, err := New("test-key", DefaultBaseURL, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Edit(context.Background(), EditRequest{Prompt: "hello", ImagePaths: nil})
	if err == nil || err.Error() != "at least one image path is required" {
		t.Fatalf("err = %v, want at least one image path is required", err)
	}
	_, err = client.Edit(context.Background(), EditRequest{Prompt: "hello", ImagePaths: []string{}})
	if err == nil || err.Error() != "at least one image path is required" {
		t.Fatalf("err = %v, want at least one image path is required", err)
	}
	_, err = client.Edit(context.Background(), EditRequest{Prompt: "hello", ImagePaths: []string{"   "}})
	if err == nil || err.Error() != "at least one image path is required" {
		t.Fatalf("err = %v, want at least one image path is required", err)
	}
}

func TestEditRejectsRelativeImagePath(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("HTTP server should not be called for relative image path")
	}))
	defer server.Close()

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Edit(context.Background(), EditRequest{
		Prompt:     "hello",
		ImagePaths: []string{"relative/input.png"},
	})
	if err == nil || err.Error() != "image path must be an absolute path: relative/input.png" {
		t.Fatalf("err = %v, want image path must be an absolute path: relative/input.png", err)
	}
}

func TestEditRejectsMissingImageFile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("HTTP server should not be called for missing image file")
	}))
	defer server.Close()

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Edit(context.Background(), EditRequest{
		Prompt:     "hello",
		ImagePaths: []string{"/no/such/file.png"},
	})
	if err == nil || !strings.Contains(err.Error(), "image file not found") {
		t.Fatalf("err = %v, want image file not found", err)
	}
}

func TestEditRejectsRelativeOutputDir(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("HTTP server should not be called for invalid output_dir")
	}))
	defer server.Close()

	imgDir := t.TempDir()
	imgPath := filepath.Join(imgDir, "input.png")
	if err := os.WriteFile(imgPath, []byte{0x89, 'P', 'N', 'G'}, 0o644); err != nil {
		t.Fatal(err)
	}

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Edit(context.Background(), EditRequest{
		Prompt:     "hello",
		ImagePaths: []string{imgPath},
		OutputDir:  "relative/path",
	})
	if err == nil || err.Error() != "output_dir must be an absolute path" {
		t.Fatalf("err = %v, want output_dir must be an absolute path", err)
	}
}

func TestEditRejectsRelativeMaskPath(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("HTTP server should not be called for invalid mask_path")
	}))
	defer server.Close()

	imgDir := t.TempDir()
	imgPath := filepath.Join(imgDir, "input.png")
	if err := os.WriteFile(imgPath, []byte{0x89, 'P', 'N', 'G'}, 0o644); err != nil {
		t.Fatal(err)
	}

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Edit(context.Background(), EditRequest{
		Prompt:     "hello",
		ImagePaths: []string{imgPath},
		MaskPath:   "relative/mask.png",
	})
	if err == nil || err.Error() != "mask_path must be an absolute path" {
		t.Fatalf("err = %v, want mask_path must be an absolute path", err)
	}
}

func TestRealGenerateImage2Smoke(t *testing.T) {
	if os.Getenv("RUN_IMAGE2_SMOKE") != "1" {
		t.Skip("set RUN_IMAGE2_SMOKE=1 to call the real image API")
	}
	client, err := NewFromEnv(filepath.Join("..", "..", "output", "imagegen"))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Generate(context.Background(), GenerateRequest{
		Prompt:     "A compact clean desk setup for MCP smoke testing, realistic photo, soft studio light",
		OutputName: "mcp-smoke-test.png",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.FilePath == "" {
		t.Fatal("expected output file path")
	}
	if _, err := os.Stat(result.FilePath); err != nil {
		t.Fatal(err)
	}
}
