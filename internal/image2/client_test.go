package image2

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
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
		"https://api.schyler.top/images/edits":          "https://api.schyler.top/images/generations",
		"https://api.schyler.top/v1/images/edits":       "https://api.schyler.top/v1/images/generations",
		"https://api.schyler.top/v1/images/generations": "https://api.schyler.top/v1/images/generations",
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
		"https://api.schyler.top/images/generations":    "https://api.schyler.top/images/edits",
		"https://api.schyler.top/v1/images/generations": "https://api.schyler.top/v1/images/edits",
		"https://api.schyler.top/images/edits":          "https://api.schyler.top/images/edits",
		"https://api.schyler.top/v1/images/edits":       "https://api.schyler.top/v1/images/edits",
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

func TestEditRejectsInvalidInput(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("HTTP server should not be called for invalid edit input")
	}))
	defer server.Close()

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	imagePath := filepath.Join(t.TempDir(), "reference.png")
	if err := os.WriteFile(imagePath, []byte("image"), 0o644); err != nil {
		t.Fatal(err)
	}
	missingPath := filepath.Join(t.TempDir(), "missing.png")
	directoryPath := t.TempDir()

	tests := []struct {
		name  string
		input EditRequest
		want  string
	}{
		{
			name:  "empty prompt",
			input: EditRequest{ImagePaths: []string{imagePath}},
			want:  "prompt is required",
		},
		{
			name:  "empty image paths",
			input: EditRequest{Prompt: "edit"},
			want:  "image_paths must contain at least one image",
		},
		{
			name:  "relative image path",
			input: EditRequest{Prompt: "edit", ImagePaths: []string{"reference.png"}},
			want:  "image path must be absolute: reference.png",
		},
		{
			name:  "missing image",
			input: EditRequest{Prompt: "edit", ImagePaths: []string{missingPath}},
			want:  missingPath,
		},
		{
			name:  "directory image path",
			input: EditRequest{Prompt: "edit", ImagePaths: []string{directoryPath}},
			want:  "image path must be a regular file: " + directoryPath,
		},
		{
			name: "relative output directory",
			input: EditRequest{
				Prompt:     "edit",
				ImagePaths: []string{imagePath},
				OutputDir:  "relative/path",
			},
			want: "output_dir must be an absolute path",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := client.Edit(context.Background(), tt.input)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err = %v, want error containing %q", err, tt.want)
			}
		})
	}
}

func TestEditSendsMultipartImagesAndWritesPNG(t *testing.T) {
	firstImage := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	secondImage := []byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00}
	resultPNG := append([]byte(nil), firstImage...)

	imageDir := t.TempDir()
	firstPath := filepath.Join(imageDir, "first.png")
	secondPath := filepath.Join(imageDir, "second.jpg")
	if err := os.WriteFile(firstPath, firstImage, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secondPath, secondImage, 0o644); err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/images/edits" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("Authorization = %q", got)
		}
		if got := r.Header.Get("Content-Type"); !strings.HasPrefix(got, "multipart/form-data; boundary=") {
			t.Fatalf("Content-Type = %q", got)
		}

		reader, err := r.MultipartReader()
		if err != nil {
			t.Fatal(err)
		}
		fields := map[string]string{}
		type uploadedImage struct {
			name        string
			contentType string
			data        string
		}
		var images []uploadedImage
		for {
			part, err := reader.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(part)
			if err != nil {
				t.Fatal(err)
			}
			if part.FormName() == "image" {
				images = append(images, uploadedImage{
					name:        part.FileName(),
					contentType: part.Header.Get("Content-Type"),
					data:        string(data),
				})
				continue
			}
			fields[part.FormName()] = string(data)
		}

		wantFields := map[string]string{
			"model":   DefaultModel,
			"prompt":  "make them cinematic",
			"size":    DefaultSize,
			"quality": DefaultQuality,
		}
		for name, want := range wantFields {
			if got := fields[name]; got != want {
				t.Fatalf("field %q = %q, want %q", name, got, want)
			}
		}
		if len(images) != 2 {
			t.Fatalf("image parts = %d, want 2", len(images))
		}
		if images[0].name != "first.png" || images[0].contentType != "image/png" || images[0].data != string(firstImage) {
			t.Fatalf("first image part = %#v", images[0])
		}
		if images[1].name != "second.jpg" || images[1].contentType != "image/jpeg" || images[1].data != string(secondImage) {
			t.Fatalf("second image part = %#v", images[1])
		}

		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(resultPNG)}},
		})
	}))
	defer server.Close()

	outDir := t.TempDir()
	client, err := New("test-key", server.URL, outDir, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Edit(context.Background(), EditRequest{
		Prompt:     "  make them cinematic  ",
		ImagePaths: []string{firstPath, secondPath},
		OutputName: "../edited image",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Model != DefaultModel || result.Size != DefaultSize {
		t.Fatalf("unexpected result: %#v", result)
	}
	if filepath.Dir(result.FilePath) != outDir || filepath.Base(result.FilePath) != "edited-image.png" {
		t.Fatalf("file path = %q", result.FilePath)
	}
	got, err := os.ReadFile(result.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(resultPNG) {
		t.Fatalf("written bytes = %v, want %v", got, resultPNG)
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

func TestRealEditImage2Smoke(t *testing.T) {
	if os.Getenv("RUN_IMAGE2_EDIT_SMOKE") != "1" {
		t.Skip("set RUN_IMAGE2_EDIT_SMOKE=1 and IMAGE2_EDIT_INPUT=/absolute/path.png to call the real image edit API")
	}
	imagePath := os.Getenv("IMAGE2_EDIT_INPUT")
	if imagePath == "" {
		t.Fatal("IMAGE2_EDIT_INPUT is required")
	}
	outputDir, err := filepath.Abs(filepath.Join("..", "..", "output", "imagegen"))
	if err != nil {
		t.Fatal(err)
	}
	client, err := NewFromEnv(outputDir)
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Edit(context.Background(), EditRequest{
		Prompt:     "Preserve the subject and composition, with polished cinematic lighting and natural photographic detail",
		ImagePaths: []string{imagePath},
		OutputName: "mcp-edit-smoke-test.png",
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
