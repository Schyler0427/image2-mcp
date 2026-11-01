package image2

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
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

func responseTestPNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestImageResponseURL(t *testing.T) {
	for _, operation := range []string{"generate", "edit"} {
		t.Run(operation, func(t *testing.T) {
			imageBytes := responseTestPNG(t)
			var posts, downloads atomic.Int32
			var server *httptest.Server
			server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					downloads.Add(1)
					if r.Header.Get("Authorization") != "" {
						t.Error("download leaked API authorization")
					}
					if r.URL.Path == "/redirect" {
						http.Redirect(w, r, "/image.png?signature=secret", http.StatusFound)
						return
					}
					_, _ = w.Write(imageBytes)
					return
				}
				posts.Add(1)
				_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"url": server.URL + "/redirect?signature=secret"}}})
			}))
			defer server.Close()
			dir := t.TempDir()
			client, _ := New("test-key", server.URL, dir, server.Client())
			var result GenerateResult
			var err error
			if operation == "edit" {
				input := filepath.Join(t.TempDir(), "input.png")
				if err := os.WriteFile(input, imageBytes, 0600); err != nil {
					t.Fatal(err)
				}
				result, err = client.Edit(context.Background(), EditRequest{Prompt: "edit", ImagePaths: []string{input}, OutputName: "saved.png"})
			} else {
				result, err = client.Generate(context.Background(), GenerateRequest{Prompt: "generate", OutputName: "saved.png"})
			}
			if err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(result.FilePath)
			if err != nil || !bytes.Equal(got, imageBytes) {
				t.Fatalf("downloaded image mismatch: %v", err)
			}
			if posts.Load() != 1 || downloads.Load() != 2 {
				t.Fatalf("posts=%d downloads=%d", posts.Load(), downloads.Load())
			}
		})
	}
}

func TestImageResponsePrefersBase64(t *testing.T) {
	want := responseTestPNG(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Error("unexpected download")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(want), "url": "https://unused.invalid/image"}}})
	}))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	result, err := client.Generate(context.Background(), GenerateRequest{Prompt: "test"})
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(result.FilePath)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("base64 image mismatch: %v", err)
	}
}

func TestImageResponseURLFailures(t *testing.T) {
	for _, tc := range []struct {
		name, url, body string
		status          int
		want            string
	}{
		{name: "expired", status: 403, body: "signed-secret test-key", want: "HTTP 403"},
		{name: "html", status: 200, body: "<html>not an image</html>", want: "unsupported or invalid image"},
		{name: "empty", status: 200, want: "empty image"},
		{name: "file", url: "file:///private/test-key", want: "absolute HTTP(S)"},
		{name: "relative", url: "/image.png?token=signed-secret", want: "absolute HTTP(S)"},
		{name: "userinfo", url: "https://user:test-key@example.invalid/image", want: "absolute HTTP(S)"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			var posts atomic.Int32
			var server *httptest.Server
			server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					posts.Add(1)
					link := tc.url
					if link == "" {
						link = server.URL + "/image?token=signed-secret"
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"url": link}}})
					return
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			client, _ := New("test-key", server.URL, dir, server.Client())
			_, err := client.Generate(context.Background(), GenerateRequest{Prompt: "test"})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error=%v, want %s", err, tc.want)
			}
			for _, secret := range []string{"signed-secret", "test-key"} {
				if strings.Contains(err.Error(), secret) {
					t.Fatal("error leaked secret")
				}
			}
			if posts.Load() != 1 {
				t.Fatal("image API request repeated")
			}
			paths, _ := filepath.Glob(filepath.Join(dir, "*.png"))
			if len(paths) != 0 {
				t.Fatal("failure wrote image file")
			}
		})
	}
}

func TestImageResponseURLConvertsJPEG(t *testing.T) {
	var jpegBytes bytes.Buffer
	if err := jpeg.Encode(&jpegBytes, image.NewRGBA(image.Rect(0, 0, 1, 1)), nil); err != nil {
		t.Fatal(err)
	}
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write(jpegBytes.Bytes())
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"url": server.URL + "/photo.jpg"}}})
	}))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	result, err := client.Generate(context.Background(), GenerateRequest{Prompt: "test"})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(result.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := png.Decode(bytes.NewReader(data)); err != nil {
		t.Fatalf("output is not PNG: %v", err)
	}
}

func TestImageResponseDiagnostics(t *testing.T) {
	for _, body := range []string{
		`{"padding":"` + strings.Repeat("private prompt", 200) + `","data":[{"revised_prompt":"private prompt","unexpected_image":"https://images.invalid/a?token=signed-secret"}],"api_key":"test-key","error":{"message":"Bearer test-key","code":"upstream_failure"}}`,
		`{"data":[],"authorization":"Bearer test-key"}`,
		`{"data":null}`,
		`<html>test-key https://images.invalid/a?token=signed-secret</html>`,
	} {
		t.Run(body[:12], func(t *testing.T) {
			dir := t.TempDir()
			var posts atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				posts.Add(1)
				w.Header().Set("X-Request-ID", "req-diagnostic")
				_, _ = w.Write([]byte(body))
			}))
			defer server.Close()
			client, _ := New("test-key", server.URL, dir, server.Client())
			_, err := client.Generate(context.Background(), GenerateRequest{Prompt: "test"})
			if err == nil {
				t.Fatal("expected missing image error")
			}
			paths, _ := filepath.Glob(filepath.Join(dir, "image2-response-*.json"))
			if len(paths) != 1 {
				t.Fatalf("missing diagnostic file: error=%v", err)
			}
			diagnostic, readErr := os.ReadFile(paths[0])
			if readErr != nil {
				t.Fatal(readErr)
			}
			if !json.Valid(diagnostic) {
				t.Fatal("invalid diagnostic JSON")
			}
			combined := err.Error() + string(diagnostic)
			for _, secret := range []string{"test-key", "signed-secret", "private prompt", "https://images.invalid"} {
				if strings.Contains(combined, secret) {
					t.Fatalf("diagnostic leaked %s", secret)
				}
			}
			if !strings.Contains(err.Error(), paths[0]) {
				t.Fatal("error missing diagnostic path")
			}
			// Unknown names can themselves contain private data. Retain known
			// structure after the long string rather than an arbitrary field name.
			if strings.Contains(body, "unexpected_image") && (!strings.Contains(string(diagnostic), "revised_prompt") || !strings.Contains(string(diagnostic), "redacted field")) {
				t.Fatal("diagnostic lost protocol structure after long prompt")
			}
			if !strings.Contains(string(diagnostic), "req-diagnostic") {
				t.Fatal("missing request ID")
			}
			if posts.Load() != 1 {
				t.Fatal("image API request repeated")
			}
		})
	}
}

func TestImageResponseDownloadSizeLimit(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"url": server.URL + "/large.png"}}})
			return
		}
		chunk := bytes.Repeat([]byte{0}, 1<<20)
		for i := 0; i < 65; i++ {
			if _, err := w.Write(chunk); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	_, err := client.Generate(context.Background(), GenerateRequest{Prompt: "test"})
	if err == nil || !strings.Contains(err.Error(), "exceeds 64 MiB") {
		t.Fatalf("error=%v", err)
	}
}

func TestImageResponseDownloadCancellation(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := client.downloadImage(ctx, server.URL+"/image?secret=test-key"); done <- err }()
	<-started
	cancel()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "context canceled") || strings.Contains(err.Error(), "test-key") {
			t.Fatalf("error=%v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("download ignored cancellation")
	}
}

func TestImageResponseDownloadNetworkErrorRedactsURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "unused")
	}))
	server.Close()
	client, _ := New("test-key", server.URL, t.TempDir(), server.Client())
	_, err := client.downloadImage(context.Background(), server.URL+"/image?signature=test-key")
	if err == nil || strings.Contains(err.Error(), "test-key") || strings.Contains(err.Error(), server.URL) {
		t.Fatalf("error=%v", err)
	}
}

func imageDiagnosticForTest(t *testing.T, reason string, body []byte) ([]byte, map[string]any) {
	t.Helper()
	dir := t.TempDir()
	client, err := New("private-key-with-tail", "https://example.test", dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = client.imageResponseError(reason, body, http.Header{}, 200, dir)
	paths, err := filepath.Glob(filepath.Join(dir, "image2-response-*.json"))
	if err != nil || len(paths) != 1 {
		t.Fatalf("diagnostics=%v error=%v", paths, err)
	}
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("invalid diagnostic JSON: %v", err)
	}
	return data, parsed
}

func imageShapeStats(value any) (nodes, depth, maxMembers int) {
	nodes, depth = 1, 1
	visit := func(item any) {
		n, d, m := imageShapeStats(item)
		nodes += n
		depth = max(depth, d+1)
		maxMembers = max(maxMembers, m)
	}
	switch v := value.(type) {
	case map[string]any:
		maxMembers = len(v)
		for _, item := range v {
			visit(item)
		}
	case []any:
		maxMembers = len(v)
		for _, item := range v {
			visit(item)
		}
	}
	return
}

func TestImageDiagnosticOmitsUnknownObjectKeys(t *testing.T) {
	body := []byte(`{"data":[],"cHJpdmF0ZSBpbWFnZSBieXRlcw==":{"private-key-with-tail":"private prompt"},"https://images.invalid/a?token=private-tail":"image bytes"}`)
	data, _ := imageDiagnosticForTest(t, "no image", body)
	for _, secret := range []string{"cHJpdmF0ZSBpbWFnZSBieXRlcw==", "private-key-with-tail", "private prompt", "https://images.invalid", "private-tail", "image bytes"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("diagnostic leaked unknown object key or string: %q", secret)
		}
	}
	if !strings.Contains(string(data), `"data"`) || !strings.Contains(string(data), "redacted field") {
		t.Fatal("diagnostic lost protocol structure or unknown-key placeholder")
	}
}

func TestImageDiagnosticBoundsDeepSmallInput(t *testing.T) {
	body := []byte(`{"error":` + strings.Repeat("[", 2200) + "0" + strings.Repeat("]", 2200) + "}")
	data, parsed := imageDiagnosticForTest(t, "no image", body)
	_, depth, _ := imageShapeStats(parsed["response_structure"])
	t.Logf("input=%d bytes diagnostic=%d bytes shape depth=%d", len(body), len(data), depth)
	if len(data) > 256<<10 || depth > 16 {
		t.Fatalf("unbounded diagnostic: bytes=%d depth=%d", len(data), depth)
	}
	if !strings.Contains(string(data), "truncated") {
		t.Fatal("diagnostic missing truncation marker")
	}
}

func TestImageDiagnosticBoundsWideContainers(t *testing.T) {
	t.Run("array", func(t *testing.T) {
		data, parsed := imageDiagnosticForTest(t, "no image", []byte(`{"data":[`+strings.Repeat("0,", 4095)+"0]}"))
		_, _, members := imageShapeStats(parsed["response_structure"])
		if members > 64 || !strings.Contains(string(data), "truncated") {
			t.Fatalf("wide array was not truncated: members=%d bytes=%d", members, len(data))
		}
	})
	t.Run("object", func(t *testing.T) {
		fields := make([]string, 1000)
		for i := range fields {
			fields[i] = fmt.Sprintf(`"private-key-%d":"private prompt"`, i)
		}
		data, parsed := imageDiagnosticForTest(t, "no image", []byte("{"+strings.Join(fields, ",")+"}"))
		_, _, members := imageShapeStats(parsed["response_structure"])
		if members > 64 || !strings.Contains(string(data), "truncated") {
			t.Fatalf("wide object was not truncated: members=%d bytes=%d", members, len(data))
		}
		if strings.Contains(string(data), "private-key") || strings.Contains(string(data), "private prompt") {
			t.Fatal("wide diagnostic leaked private keys or string values")
		}
	})
}

func TestImageDiagnosticBoundsTotalShapeNodes(t *testing.T) {
	row := "[" + strings.Repeat("0,", 63) + "0]"
	body := []byte(`{"data":[` + strings.Repeat(row+",", 63) + row + "]}")
	data, parsed := imageDiagnosticForTest(t, "no image", body)
	nodes, _, _ := imageShapeStats(parsed["response_structure"])
	if nodes > 2048 || !strings.Contains(string(data), "truncated") {
		t.Fatalf("total shape nodes unbounded: nodes=%d bytes=%d", nodes, len(data))
	}
}

func TestImageDiagnosticFileHasIndependentByteLimit(t *testing.T) {
	data, _ := imageDiagnosticForTest(t, strings.Repeat("internal reason ", 30000), []byte(`{"data":[]}`))
	if len(data) > 256<<10 || !strings.Contains(string(data), "truncated") {
		t.Fatalf("diagnostic file byte limit not enforced: bytes=%d", len(data))
	}
}
