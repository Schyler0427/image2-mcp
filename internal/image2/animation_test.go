package image2

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/gif"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func animatedGIF(t *testing.T) []byte {
	t.Helper()
	palette := color.Palette{color.Black, color.White}
	frames := make([]*image.Paletted, 2)
	for i := range frames {
		frames[i] = image.NewPaletted(image.Rect(0, 0, 2, 2), palette)
		frames[i].Pix[0] = uint8(i)
	}
	var out bytes.Buffer
	if err := gif.EncodeAll(&out, &gif.GIF{Image: frames, Delay: []int{5, 9}, LoopCount: 0}); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func generationInput(t *testing.T, raw string) GenerateRequest {
	t.Helper()
	var input GenerateRequest
	if err := json.Unmarshal([]byte(raw), &input); err != nil {
		t.Fatal(err)
	}
	return input
}

func TestGenerateGIFDefaultsAndActualMetadata(t *testing.T) {
	want := animatedGIF(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		for key, expected := range map[string]any{"model": "gpt-image-2.6-sunburst", "size": "auto", "output_format": "gif", "frame_count": float64(9), "frame_duration_ms": float64(200)} {
			if payload[key] != expected {
				t.Errorf("%s=%v, want %v", key, payload[key], expected)
			}
		}
		if _, hasQuality := payload["quality"]; hasQuality {
			t.Error("unspecified quality was forwarded")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(want)}}})
	}))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	result, err := client.Generate(context.Background(), generationInput(t, `{"prompt":"animate","version":"2.6","output_format":"gif","output_name":"scene.png"}`))
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Ext(result.FilePath) != ".gif" || filepath.Base(result.FilePath) != "scene.gif" {
		t.Fatalf("GIF file path = %q", result.FilePath)
	}
	if result.Size != "2x2" {
		t.Fatalf("GIF size = %q, want decoded 2x2 dimensions", result.Size)
	}
	got, err := os.ReadFile(result.FilePath)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("GIF bytes changed: %v", err)
	}
	encoded, _ := json.Marshal(result)
	var fields map[string]any
	_ = json.Unmarshal(encoded, &fields)
	for key, expected := range map[string]any{"output_format": "gif", "frame_count": float64(2), "duration_ms": float64(140)} {
		if fields[key] != expected {
			t.Errorf("result %s=%v, want %v", key, fields[key], expected)
		}
	}
}

func TestSaveGIFZeroDelayIncludesDurationInJSON(t *testing.T) {
	palette := color.Palette{color.Black, color.White}
	frames := []*image.Paletted{
		image.NewPaletted(image.Rect(0, 0, 2, 2), palette),
		image.NewPaletted(image.Rect(0, 0, 2, 2), palette),
	}
	var encoded bytes.Buffer
	if err := gif.EncodeAll(&encoded, &gif.GIF{Image: frames, Delay: []int{0, 0}, LoopCount: 0}); err != nil {
		t.Fatal(err)
	}
	result, err := saveGIF(encoded.Bytes(), t.TempDir(), "zero.gif", "test-model")
	if err != nil {
		t.Fatal(err)
	}
	saved, err := os.ReadFile(result.FilePath)
	if err != nil || !bytes.Equal(saved, encoded.Bytes()) {
		t.Fatalf("zero-delay GIF bytes changed: %v", err)
	}
	data, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	if value, present := fields["duration_ms"]; !present || value != float64(0) {
		t.Fatalf("duration_ms = %v, present = %v; JSON = %s", value, present, data)
	}
	if fields["output_format"] != "gif" || fields["frame_count"] != float64(2) {
		t.Fatalf("wrong animation metadata: %s", data)
	}
	var roundTrip GenerateResult
	if err := json.Unmarshal(data, &roundTrip); err != nil {
		t.Fatal(err)
	}
	roundTripJSON, err := json.Marshal(roundTrip)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(roundTripJSON, []byte(`"duration_ms":0`)) {
		t.Fatalf("zero duration lost after JSON round trip: %s", roundTripJSON)
	}
}

func TestGenerateGIFExplicitParametersAndURLBytes(t *testing.T) {
	want := animatedGIF(t)
	var gets atomic.Int32
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			gets.Add(1)
			if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
				t.Error("credentials leaked to image URL")
			}
			_, _ = w.Write(want)
			return
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		for key, expected := range map[string]any{"model": "gpt-image-2.6-flare", "size": "512x512", "output_format": "gif", "quality": "high", "frame_count": float64(4), "frame_duration_ms": float64(350)} {
			if payload[key] != expected {
				t.Errorf("%s=%v, want %v", key, payload[key], expected)
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"url": server.URL + "/animation.gif?signature=private"}}})
	}))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	result, err := client.Generate(context.Background(), generationInput(t, `{"prompt":"animate","version":"2.6快速版","output_format":"gif","size":"512x512","quality":"high","frame_count":4,"frame_duration_ms":350}`))
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(result.FilePath)
	if err != nil || !bytes.Equal(got, want) || filepath.Ext(result.FilePath) != ".gif" || gets.Load() != 1 {
		t.Fatalf("GIF download changed: file=%q gets=%d err=%v", result.FilePath, gets.Load(), err)
	}
}

func TestGenerateRejectsInvalidAnimationRequestBeforeHTTP(t *testing.T) {
	var posts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { posts.Add(1) }))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	for _, raw := range []string{
		`{"prompt":"x","output_format":"gif"}`,
		`{"prompt":"x","version":"2.5","output_format":"gif"}`,
		`{"prompt":"x","version":"2.6","output_format":"webp"}`,
		`{"prompt":"x","version":"2.6","frame_count":2}`,
		`{"prompt":"x","version":"2.6","output_format":"png","frame_duration_ms":200}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","frame_count":1}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","frame_count":65}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","frame_duration_ms":19}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","frame_duration_ms":2001}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"bad"}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"0x512"}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"512x0"}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"513x512"}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"512x513"}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"1024x1024","frame_count":64}`,
		`{"prompt":"x","version":"2.6","output_format":"gif","size":"18446744073709551616x16","frame_count":2}`,
	} {
		t.Run(raw, func(t *testing.T) {
			if _, err := client.Generate(context.Background(), generationInput(t, raw)); err == nil {
				t.Fatal("expected local validation error")
			}
		})
	}
	if posts.Load() != 0 {
		t.Fatalf("invalid requests sent %d HTTP calls", posts.Load())
	}
}

func TestGenerateGIFAcceptsValidExplicitSizes(t *testing.T) {
	want := animatedGIF(t)
	for _, tc := range []struct {
		name, size, wantSize string
		frames               int
	}{
		{"normalized auto", " AUTO ", "auto", 9},
		{"exact pixel budget", "4000X4000", "4000x4000", 2},
		{"maximum frames within budget", "512x512", "512x512", 64},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var payload map[string]any
				if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
					t.Error(err)
				}
				if payload["size"] != tc.wantSize || payload["frame_count"] != float64(tc.frames) {
					t.Errorf("size=%v frames=%v; want %s, %d", payload["size"], payload["frame_count"], tc.wantSize, tc.frames)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(want)}}})
			}))
			defer server.Close()
			client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
			result, err := client.Generate(context.Background(), GenerateRequest{
				Prompt: "animate", Version: "2.6", OutputFormat: "gif", Size: tc.size, FrameCount: tc.frames,
			})
			if err != nil || result.Size != "2x2" {
				t.Fatalf("result=%#v error=%v; want decoded GIF size 2x2", result, err)
			}
		})
	}
}

func TestGenerateGIFRequiresExplicitVersionDespiteConfiguredModel(t *testing.T) {
	t.Setenv("OPENAI_IMAGE_MODEL", "gpt-image-2.6-sunburst")
	client, _ := New("test-key", "http://127.0.0.1:1", t.TempDir(), nil)
	_, err := client.Generate(context.Background(), generationInput(t, `{"prompt":"x","output_format":"gif"}`))
	if err == nil || !strings.Contains(err.Error(), "2.6") {
		t.Fatalf("error=%v; expected explicit 2.6 validation", err)
	}
}

func TestGenerateGIFRejectsWrongFormatStaticAndCorruptResponse(t *testing.T) {
	animated := animatedGIF(t)
	// A valid single-frame GIF is deliberately distinct from a truncated animation.
	var one bytes.Buffer
	if err := gif.Encode(&one, image.NewPaletted(image.Rect(0, 0, 2, 2), color.Palette{color.Black}), nil); err != nil {
		t.Fatal(err)
	}
	oversized := append([]byte(nil), animated...)
	oversized[6], oversized[7], oversized[8], oversized[9] = 0x88, 0x13, 0x88, 0x13 // 5000x5000 canvas, 2 frames
	for _, tc := range []struct {
		name, reason string
		data         []byte
	}{
		{"png", "invalid signature", responseTestPNG(t)},
		{"static", "at least two frames", one.Bytes()},
		{"corrupt", "truncated", animated[:len(animated)-3]},
		{"oversized", "32 million", oversized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(tc.data)}}})
			}))
			defer server.Close()
			dir := t.TempDir()
			client, _ := New("test-key", server.URL, dir, server.Client())
			_, err := client.Generate(context.Background(), generationInput(t, `{"prompt":"x","version":"2.6","output_format":"gif"}`))
			if err == nil || !strings.Contains(err.Error(), tc.reason) {
				t.Fatalf("invalid GIF error=%v, want %q", err, tc.reason)
			}
			if paths, _ := filepath.Glob(filepath.Join(dir, "*.gif")); len(paths) != 0 {
				t.Fatalf("invalid GIF wrote file: %v", paths)
			}
		})
	}
}

func TestGIFPreflightExactCumulativePixelLimit(t *testing.T) {
	gifBytes := animatedGIF(t)
	gifBytes[6], gifBytes[7], gifBytes[8], gifBytes[9] = 0xa0, 0x0f, 0xa0, 0x0f // 4000x4000, two frames = 32 million
	if err := preflightGIF(gifBytes); err != nil {
		t.Fatalf("exactly 32 million pixels rejected: %v", err)
	}
	gifBytes[6] = 0xa1 // 4001x4000, two frames = 32,008,000
	if err := preflightGIF(gifBytes); err == nil || !strings.Contains(err.Error(), "32 million") {
		t.Fatalf("over-limit GIF accepted or wrong error: %v", err)
	}
}

func TestEditVersion26Models(t *testing.T) {
	input := filepath.Join(t.TempDir(), "input.png")
	if err := os.WriteFile(input, responseTestPNG(t), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ version, model string }{{"2.6", "gpt-image-2.6-sunburst"}, {"2.6-flare", "gpt-image-2.6-flare"}} {
		t.Run(tc.version, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if err := r.ParseMultipartForm(1 << 20); err != nil {
					t.Error(err)
				}
				if got := r.FormValue("model"); got != tc.model {
					t.Errorf("model=%q, want %q", got, tc.model)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(responseTestPNG(t))}}})
			}))
			defer server.Close()
			client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
			if _, err := client.Edit(context.Background(), EditRequest{Prompt: "edit", Version: tc.version, ImagePaths: []string{input}}); err != nil {
				t.Fatal(err)
			}
		})
	}
}
