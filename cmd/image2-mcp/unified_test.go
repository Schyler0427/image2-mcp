package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func unifiedSession(t *testing.T) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	s := newServer(t.TempDir(), t.TempDir())
	client := mcp.NewClient(&mcp.Implementation{Name: "unified-test", Version: "1"}, nil)
	a, b := mcp.NewInMemoryTransports()
	serverSession, err := s.Connect(ctx, a, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })
	session, err := client.Connect(ctx, b, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return session
}

func TestUnifiedGenerateRoutesAndKeepsKeysSeparate(t *testing.T) {
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewNRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ model, path, auth, actualModel string }{
		{"", "/v1/images/generations", "image-only-test", "gpt-image-2"},
		{"gemini", "/v1beta/models/gemini-3.1-flash-image:generateContent", "gemini-only-test", "gemini-3.1-flash-image"},
		{"banana", "/v1beta/models/gemini-3.1-flash-image:generateContent", "gemini-only-test", "gemini-3.1-flash-image"},
		{"香蕉", "/v1beta/models/gemini-3.1-flash-image:generateContent", "gemini-only-test", "gemini-3.1-flash-image"},
		{"image2", "/v1/images/generations", "image-only-test", "gpt-image-2"},
		{"image2.5", "/v1/images/generations", "image-only-test", "gpt-image-2.5-sunburst"},
		{"image2.6", "/v1/images/generations", "image-only-test", "gpt-image-2.6-sunburst"},
		{"image2.6-flare", "/v1/images/generations", "image-only-test", "gpt-image-2.6-flare"},
	} {
		t.Run(tc.actualModel, func(t *testing.T) {
			calls := 0
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Path != tc.path {
					t.Errorf("path=%q want=%q", r.URL.Path, tc.path)
				}
				if tc.actualModel == "gemini-3.1-flash-image" {
					if r.Header.Get("x-goog-api-key") != tc.auth || r.Header.Get("Authorization") != "" {
						t.Error("Gemini used incorrect credential")
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"inlineData": map[string]any{"mimeType": "image/png", "data": base64.StdEncoding.EncodeToString(pngData.Bytes())}}}}}}})
				} else {
					if r.Header.Get("Authorization") != "Bearer "+tc.auth || r.Header.Get("x-goog-api-key") != "" {
						t.Error("Image2 used incorrect credential")
					}
					var payload map[string]any
					if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
						t.Error(err)
					}
					if payload["model"] != tc.actualModel {
						t.Errorf("model=%v", payload["model"])
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"b64_json": base64.StdEncoding.EncodeToString(pngData.Bytes())}}})
				}
			}))
			defer api.Close()
			t.Setenv("OPENAI_IMAGE_API_KEY", "image-only-test")
			t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-only-test")
			t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
			t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
			t.Setenv("GEMINI_IMAGE_MODEL", "gemini-3.1-flash-image")
			t.Setenv("OPENAI_IMAGE_MODEL", "maintainer-override-is-not-explicit-image2")
			out := t.TempDir()
			result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "generate_image", Arguments: map[string]any{"prompt": "画一朵花", "model": tc.model, "output_dir": out, "output_name": "test.png"}})
			if err != nil || result.IsError {
				t.Fatalf("unified call=%+v, %v", result, err)
			}
			if calls != 1 {
				t.Fatalf("calls=%d want=1", calls)
			}
			data, err := os.ReadFile(filepath.Join(out, "test.png"))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := png.Decode(bytes.NewReader(data)); err != nil {
				t.Fatalf("saved image invalid: %v", err)
			}
		})
	}
}

func TestUnifiedMissingGeminiKeyDoesNotFallback(t *testing.T) {
	t.Setenv("GEMINI_IMAGE_API_KEY", "")
	t.Setenv("OPENAI_IMAGE_API_KEY", "another-provider-key")
	result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "generate_image", Arguments: map[string]any{"prompt": "test", "model": "gemini"}})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError || len(result.Content) == 0 || !strings.Contains(result.Content[0].(*mcp.TextContent).Text, "GEMINI_IMAGE_API_KEY is required") {
		t.Fatalf("expected dedicated missing key error: %+v", result)
	}
}

func TestUnifiedRejectsUnknownModel(t *testing.T) {
	result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "generate_image", Arguments: map[string]any{"prompt": "test", "model": "not-a-model"}})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError {
		t.Fatal("unknown model was silently accepted")
	}
}

func TestUnifiedGeminiMaskIsRejectedWithoutFallback(t *testing.T) {
	result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "edit_image", Arguments: map[string]any{"model": "gemini", "prompt": "edit", "image_paths": []string{"/fake/source.png"}, "mask_path": "/fake/mask.png"}})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError || len(result.Content) == 0 || !strings.Contains(result.Content[0].(*mcp.TextContent).Text, "mask") {
		t.Fatalf("expected unsupported mask error: %+v", result)
	}
}

func TestUnifiedEditRoutesAndPreservesReferences(t *testing.T) {
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewNRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, model := range []string{"", "gemini", "image2", "image2.5", "image2.6", "image2.6-flare"} {
		t.Run(model, func(t *testing.T) {
			input := t.TempDir()
			paths := []string{filepath.Join(input, "主体.png"), filepath.Join(input, "风格.png")}
			for _, path := range append(append([]string{}, paths...), filepath.Join(input, "mask.png")) {
				if err := os.WriteFile(path, pngData.Bytes(), 0600); err != nil {
					t.Fatal(err)
				}
			}
			calls := 0
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if model == "gemini" {
					if r.URL.Path != "/v1beta/models/gemini-3.1-flash-image:generateContent" || r.Header.Get("x-goog-api-key") != "gemini-only" || r.Header.Get("Authorization") != "" {
						t.Error("incorrect Gemini endpoint or credential")
					}
					var payload struct {
						Contents []struct {
							Parts []struct {
								Text       string
								InlineData struct {
									MIMEType string `json:"mimeType"`
									Data     string
								} `json:"inlineData"`
							}
						}
						GenerationConfig struct {
							ImageConfig struct{ AspectRatio, ImageSize string }
						}
					}
					if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
						t.Error(err)
						return
					}
					if len(payload.Contents) != 1 || len(payload.Contents[0].Parts) != 3 {
						t.Errorf("reference parts=%+v", payload)
						return
					}
					if payload.Contents[0].Parts[0].Text != "第一张为主体，第二张为风格" {
						t.Error("prompt not preserved")
					}
					for _, part := range payload.Contents[0].Parts[1:] {
						if part.InlineData.MIMEType != "image/png" || part.InlineData.Data != base64.StdEncoding.EncodeToString(pngData.Bytes()) {
							t.Error("reference data not preserved")
						}
					}
					if payload.GenerationConfig.ImageConfig.AspectRatio != "16:9" || payload.GenerationConfig.ImageConfig.ImageSize != "2K" {
						t.Error("Gemini settings not mapped")
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": "完成"}, map[string]any{"inline_data": map[string]any{"mime_type": "image/png", "data": base64.StdEncoding.EncodeToString(pngData.Bytes())}}}}}}})
				} else {
					if r.URL.Path != "/v1/images/edits" || r.Header.Get("Authorization") != "Bearer image-only" || r.Header.Get("x-goog-api-key") != "" {
						t.Error("incorrect Image2 endpoint or credential")
					}
					if err := r.ParseMultipartForm(1 << 20); err != nil {
						t.Error(err)
						return
					}
					defer r.MultipartForm.RemoveAll()
					wantModel := "gpt-image-2"
					if model == "image2.5" {
						wantModel = "gpt-image-2.5-sunburst"
					} else if model == "image2.6" {
						wantModel = "gpt-image-2.6-sunburst"
					} else if model == "image2.6-flare" {
						wantModel = "gpt-image-2.6-flare"
					}
					if r.FormValue("model") != wantModel || r.FormValue("size") != "1024x1536" || r.FormValue("quality") != "high" {
						t.Error("Image2 settings not mapped")
					}
					files := r.MultipartForm.File["image[]"]
					if len(files) != 2 || files[0].Filename != filepath.Base(paths[0]) || files[1].Filename != filepath.Base(paths[1]) || len(r.MultipartForm.File["mask"]) != 1 {
						t.Error("reference order or mask lost")
						return
					}
					for _, f := range files {
						file, err := f.Open()
						if err != nil {
							t.Error(err)
							return
						}
						data, err := io.ReadAll(file)
						_ = file.Close()
						if err != nil || !bytes.Equal(data, pngData.Bytes()) {
							t.Error("reference bytes changed")
						}
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"b64_json": base64.StdEncoding.EncodeToString(pngData.Bytes())}}})
				}
			}))
			defer api.Close()
			t.Setenv("OPENAI_IMAGE_API_KEY", "image-only")
			t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-only")
			t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
			t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
			t.Setenv("GEMINI_IMAGE_MODEL", "")
			out := t.TempDir()
			args := map[string]any{"model": model, "prompt": "第一张为主体，第二张为风格", "image_paths": paths, "output_dir": out, "output_name": "edited.png"}
			if model == "gemini" {
				args["aspect_ratio"], args["image_size"] = "16:9", "2K"
			} else {
				args["size"], args["quality"], args["mask_path"] = "1024x1536", "high", filepath.Join(input, "mask.png")
			}
			result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "edit_image", Arguments: args})
			if err != nil || result.IsError {
				t.Fatalf("edit=%+v error=%v", result, err)
			}
			if calls != 1 {
				t.Fatalf("calls=%d", calls)
			}
			data, err := os.ReadFile(filepath.Join(out, "edited.png"))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := png.Decode(bytes.NewReader(data)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestUnifiedInvalidOptionsNeverSendRequest(t *testing.T) {
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls++ }))
	defer api.Close()
	t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-only")
	t.Setenv("OPENAI_IMAGE_API_KEY", "image-only")
	t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
	t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
	for _, tc := range []struct {
		tool string
		args map[string]any
	}{
		{"generate_image", map[string]any{"model": "gemini", "size": "1024x1024"}},
		{"generate_image", map[string]any{"model": "image2", "image_size": "2K"}},
		{"edit_image", map[string]any{"model": "gemini", "quality": "high", "image_paths": []string{"/fake/ref.png"}}},
		{"edit_image", map[string]any{"model": "image2.5", "aspect_ratio": "16:9", "image_paths": []string{"/fake/ref.png"}}},
	} {
		tc.args["prompt"] = "test"
		result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: tc.tool, Arguments: tc.args})
		if err != nil || !result.IsError {
			t.Fatalf("expected invalid option error for %v: %+v %v", tc.args, result, err)
		}
	}
	if calls != 0 {
		t.Fatalf("invalid inputs made %d calls", calls)
	}
}

func TestUnifiedMissingImage2KeyDoesNotFallback(t *testing.T) {
	t.Setenv("OPENAI_IMAGE_API_KEY", "")
	t.Setenv("GEMINI_IMAGE_API_KEY", "other-provider-only")
	for _, model := range []string{"", "image2", "image2.5", "image2.6", "image2.6-flare"} {
		result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "generate_image", Arguments: map[string]any{"model": model, "prompt": "test"}})
		if err != nil || !result.IsError || !strings.Contains(result.Content[0].(*mcp.TextContent).Text, "OPENAI_IMAGE_API_KEY is required") {
			t.Fatalf("expected independent Image2 key error: %+v %v", result, err)
		}
	}
}

func TestGeminiClientConfirmedDefaultAndModelOverride(t *testing.T) {
	for _, model := range []string{"", "gemini-3-pro-image"} {
		t.Run(model, func(t *testing.T) {
			var pngData bytes.Buffer
			if err := png.Encode(&pngData, image.NewNRGBA(image.Rect(0, 0, 1, 1))); err != nil {
				t.Fatal(err)
			}
			want := model
			if want == "" {
				want = "gemini-3.1-flash-image"
			}
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1beta/models/"+want+":generateContent" {
					t.Errorf("model URL=%s", r.URL.Path)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"inlineData": map[string]any{"mimeType": "image/png", "data": base64.StdEncoding.EncodeToString(pngData.Bytes())}}}}}}})
			}))
			defer api.Close()
			t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-key")
			t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
			t.Setenv("GEMINI_IMAGE_MODEL", model)
			result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "generate_image", Arguments: map[string]any{"prompt": "test", "model": "gemini"}})
			if err != nil || result.IsError {
				t.Fatalf("generation=%+v %v", result, err)
			}
		})
	}
}
