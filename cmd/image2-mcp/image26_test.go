package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func image26AnimatedFixture(t *testing.T) []byte {
	t.Helper()
	palette := color.Palette{color.Black, color.White}
	first := image.NewPaletted(image.Rect(0, 0, 2, 2), palette)
	second := image.NewPaletted(image.Rect(0, 0, 2, 2), palette)
	second.SetColorIndex(0, 0, 1)
	var out bytes.Buffer
	if err := gif.EncodeAll(&out, &gif.GIF{Image: []*image.Paletted{first, second}, Delay: []int{20, 20}, LoopCount: 0}); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestImage26FriendlySelectors(t *testing.T) {
	for _, tc := range []struct{ input, provider, version string }{
		{"", "image2", "2.0"}, {"Image 2.6", "image2.6", "2.6"}, {"2.6", "image2.6", "2.6"},
		{"image2.6-sunburst", "image2.6", "2.6"}, {"Image 2.6 Flare", "image2.6-flare", "2.6-flare"},
		{"2.6快速版", "image2.6-flare", "2.6-flare"}, {"image2.6快速版", "image2.6-flare", "2.6-flare"},
	} {
		t.Run(tc.input, func(t *testing.T) {
			provider, err := selectedImageProvider(tc.input)
			if err != nil || provider != tc.provider {
				t.Fatalf("provider=%q err=%v want=%q", provider, err, tc.provider)
			}
			if got := image2VersionForProvider(provider); got != tc.version {
				t.Fatalf("version=%q want=%q", got, tc.version)
			}
		})
	}
}

func TestImage26GIFGenerationThroughMCP(t *testing.T) {
	fixture := image26AnimatedFixture(t)
	for _, tc := range []struct{ tool, selector string }{{"generate_image", "image2.6-flare"}, {"generate_image", ""}, {"generate_image2", "2.6-flare"}, {"generate_image2", ""}} {
		tool := tc.tool
		t.Run(tool+"-"+tc.selector, func(t *testing.T) {
			calls := 0
			api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Path != "/v1/images/generations" || r.Header.Get("Authorization") != "Bearer image26-only" || r.Header.Get("x-goog-api-key") != "" {
					t.Error("wrong endpoint or provider credential")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
					return
				}
				for k, want := range map[string]any{"model": "gpt-image-2.6-flare", "output_format": "gif", "frame_count": float64(2), "frame_duration_ms": float64(200), "size": "auto", "quality": "low"} {
					if body[k] != want {
						t.Errorf("%s=%v want=%v", k, body[k], want)
					}
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"b64_json": base64.StdEncoding.EncodeToString(fixture)}}})
			}))
			defer api.Close()
			t.Setenv("OPENAI_IMAGE_API_KEY", "image26-only")
			t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-not-to-be-used")
			t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
			t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
			out := t.TempDir()
			args := map[string]any{"prompt": "小猫挥手 GIF", "output_format": "gif", "quality": "low", "frame_count": 2, "frame_duration_ms": 200, "output_dir": out, "output_name": "wave.gif"}
			if tc.selector != "" {
				if tool == "generate_image" {
					args["model"] = tc.selector
				} else {
					args["version"] = tc.selector
				}
			}
			result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
			if err != nil || result.IsError {
				t.Fatalf("GIF call=%+v err=%v", result, err)
			}
			if calls != 1 {
				t.Fatalf("calls=%d", calls)
			}
			saved, err := os.ReadFile(filepath.Join(out, "wave.gif"))
			if err != nil || !bytes.Equal(saved, fixture) {
				t.Fatalf("animation bytes changed or missing: %v", err)
			}
			var metadata map[string]any
			if err := json.Unmarshal([]byte(result.Content[0].(*mcp.TextContent).Text), &metadata); err != nil {
				t.Fatal(err)
			}
			if metadata["output_format"] != "gif" || metadata["frame_count"] != float64(2) || metadata["duration_ms"] != float64(400) || metadata["size"] != "2x2" {
				t.Fatalf("wrong GIF metadata: %v", metadata)
			}
		})
	}
}

func TestImage26GIFInvalidMCPOptionsNeverSend(t *testing.T) {
	calls := 0
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewNRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"b64_json": base64.StdEncoding.EncodeToString(pngData.Bytes())}}})
	}))
	defer api.Close()
	t.Setenv("OPENAI_IMAGE_API_KEY", "image26-only")
	t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-only")
	t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
	t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
	reference := filepath.Join(t.TempDir(), "reference.png")
	if err := os.WriteFile(reference, pngData.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		tool string
		args map[string]any
	}{
		{"generate_image", map[string]any{"model": "image2", "output_format": "gif"}},
		{"generate_image", map[string]any{"model": "image2.5", "output_format": "gif"}},
		{"generate_image", map[string]any{"model": "gemini", "output_format": "gif"}},
		{"generate_image", map[string]any{"model": "gemini", "quality": "low"}},
		{"generate_image", map[string]any{"model": "gemini", "frame_count": 9}},
		{"generate_image", map[string]any{"model": "image2.6", "output_format": "png", "frame_count": 9}},
		{"generate_image", map[string]any{"model": "image2.6", "output_format": "gif", "frame_count": 65}},
		{"generate_image", map[string]any{"model": "image2.6", "output_format": "svg"}},
		{"generate_image2", map[string]any{"version": "2.5", "output_format": "gif"}},
		{"edit_image", map[string]any{"model": "image2.6", "output_format": "gif", "image_paths": []string{reference}}},
		{"edit_image2", map[string]any{"version": "2.6", "output_format": "gif", "image_paths": []string{reference}}},
	} {
		tc.args["prompt"] = "test"
		tc.args["output_dir"] = t.TempDir()
		result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: tc.tool, Arguments: tc.args})
		if err == nil && !result.IsError {
			t.Errorf("invalid option accepted for %s: %v", tc.tool, tc.args)
		}
	}
	if calls != 0 {
		t.Fatalf("invalid options sent %d requests", calls)
	}
}

func TestImage26MCPRejectsExplicitZeroAnimationOptionsBeforeHTTP(t *testing.T) {
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer api.Close()
	t.Setenv("OPENAI_IMAGE_API_KEY", "image26-only")
	t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-only")
	t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
	t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
	session := unifiedSession(t)
	for _, tool := range []string{"generate_image", "generate_image2"} {
		for _, format := range []string{"png", "gif"} {
			for _, field := range []string{"frame_count", "frame_duration_ms"} {
				t.Run(tool+"/"+format+"/"+field, func(t *testing.T) {
					args := map[string]any{"prompt": "test", "output_format": format, field: 0, "output_dir": t.TempDir()}
					result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
					if err == nil && !result.IsError {
						t.Fatalf("explicit zero %s accepted", field)
					}
				})
			}
		}
	}
	if calls != 0 {
		t.Fatalf("invalid animation options sent %d HTTP requests", calls)
	}
}

func TestImage26MCPRejectsGeminiExplicitZeroAnimationOptions(t *testing.T) {
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer api.Close()
	t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-only")
	t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
	for _, field := range []string{"frame_count", "frame_duration_ms"} {
		t.Run(field, func(t *testing.T) {
			result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{
				Name: "generate_image", Arguments: map[string]any{"prompt": "test", "model": "gemini", field: 0},
			})
			if err == nil && !result.IsError {
				t.Fatalf("Gemini accepted explicit zero %s", field)
			}
		})
	}
	if calls != 0 {
		t.Fatalf("Gemini animation options sent %d HTTP requests", calls)
	}
}

func TestImage26MCPAnimationOmissionPreservesDefaults(t *testing.T) {
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewNRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	gifData := image26AnimatedFixture(t)
	for _, tool := range []string{"generate_image", "generate_image2"} {
		for _, format := range []string{"png", "gif"} {
			t.Run(tool+"/"+format, func(t *testing.T) {
				calls := 0
				api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls++
					var payload map[string]any
					if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
						t.Error(err)
					}
					if format == "gif" {
						if payload["model"] != "gpt-image-2.6-flare" || payload["frame_count"] != float64(9) || payload["frame_duration_ms"] != float64(200) {
							t.Errorf("GIF defaults missing: %v", payload)
						}
					} else if _, hasFrames := payload["frame_count"]; hasFrames {
						t.Errorf("PNG request gained animation fields: %v", payload)
					} else if _, hasDuration := payload["frame_duration_ms"]; hasDuration {
						t.Errorf("PNG request gained animation fields: %v", payload)
					}
					data := pngData.Bytes()
					if format == "gif" {
						data = gifData
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(data)}}})
				}))
				defer api.Close()
				t.Setenv("OPENAI_IMAGE_API_KEY", "image26-only")
				t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
				t.Setenv("OPENAI_IMAGE_MODEL", "")
				result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{
					Name: tool, Arguments: map[string]any{"prompt": "test", "output_format": format, "output_dir": t.TempDir()},
				})
				if err != nil || result.IsError || calls != 1 {
					t.Fatalf("omitted animation options: result=%+v err=%v calls=%d", result, err, calls)
				}
				var fields map[string]any
				if err := json.Unmarshal([]byte(result.Content[0].(*mcp.TextContent).Text), &fields); err != nil {
					t.Fatal(err)
				}
				if format == "png" && len(fields) != 3 {
					t.Fatalf("PNG result gained animation fields: %v", fields)
				}
			})
		}
	}
}

func TestImage26MetadataExplainsSelectionAndGIF(t *testing.T) {
	session := unifiedSession(t)
	instructions := session.InitializeResult().Instructions
	for _, phrase := range []string{"用2.6生图", "image2.6-flare", "output_format", "frame_count", "frame_duration_ms", "GIF", "生成动图", "循环动图", "default is Image2"} {
		if !strings.Contains(instructions, phrase) {
			t.Errorf("instructions missing %q", phrase)
		}
	}
	tools, err := session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range tools.Tools {
		if tool.Name != "generate_image" && tool.Name != "generate_image2" {
			continue
		}
		schema, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatal(err)
		}
		for _, field := range []string{"output_format", "frame_count", "frame_duration_ms", "quality"} {
			if !bytes.Contains(schema, []byte(`"`+field+`"`)) {
				t.Errorf("%s schema missing %s", tool.Name, field)
			}
		}
	}
}

func TestImage26ExplicitModelFailureDoesNotSwitch(t *testing.T) {
	calls := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/v1/images/generations" || r.Header.Get("Authorization") != "Bearer image26-only" {
			t.Error("request switched endpoint or provider")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body["model"] != "gpt-image-2.6-sunburst" {
			t.Errorf("explicit Sunburst replaced: %v", body["model"])
		}
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"type": "invalid_request_error", "code": "model_unavailable"}})
	}))
	defer api.Close()
	t.Setenv("OPENAI_IMAGE_API_KEY", "image26-only")
	t.Setenv("GEMINI_IMAGE_API_KEY", "gemini-never-used")
	t.Setenv("OPENAI_IMAGE_BASE_URL", api.URL)
	t.Setenv("GEMINI_IMAGE_BASE_URL", api.URL)
	result, err := unifiedSession(t).CallTool(context.Background(), &mcp.CallToolParams{Name: "generate_image", Arguments: map[string]any{"prompt": "动图", "model": "image2.6", "output_format": "gif", "output_dir": t.TempDir()}})
	if err != nil || !result.IsError {
		t.Fatalf("expected explicit model failure: %+v %v", result, err)
	}
	if calls != 1 {
		t.Fatalf("failure caused additional model calls: %d", calls)
	}
}
