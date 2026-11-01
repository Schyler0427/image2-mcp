package gemini

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"image"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebPResponseConvertsToPNGAndReferenceMIME(t *testing.T) {
	// Fixture from golang.org/x/image v0.37.0 testdata/gopher-doc.1bpp.lossless.webp.
	// The upstream BSD license is retained beside it.
	webp, err := os.ReadFile("testdata/reference.webp")
	if err != nil {
		t.Fatal(err)
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(webp))
	if err != nil {
		t.Fatal(err)
	}
	pngData, w, h, err := normalizeImage(webp, "image/webp")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(pngData, []byte{0x89, 'P', 'N', 'G'}) || w != cfg.Width || h != cfg.Height {
		t.Fatalf("WebP conversion dimensions=%dx%d", w, h)
	}
	absolute, err := filepath.Abs("testdata/reference.webp")
	if err != nil {
		t.Fatal(err)
	}
	reference, mime, err := readReference(absolute, maxInputBytes)
	if err != nil {
		t.Fatal(err)
	}
	if mime != "image/webp" || !bytes.Equal(reference, webp) {
		t.Fatal("WebP reference MIME or bytes changed")
	}
}

func TestImagesRejectMismatchedMIMEAndOversizedDimensions(t *testing.T) {
	data := testPNG(t)
	if _, _, _, err := normalizeImage(data, "image/jpeg"); err == nil {
		t.Fatal("mismatched MIME accepted")
	}
	oversized := append([]byte(nil), data...)
	binary.BigEndian.PutUint32(oversized[16:20], 70000)
	binary.BigEndian.PutUint32(oversized[20:24], 70000)
	binary.BigEndian.PutUint32(oversized[29:33], crc32.ChecksumIEEE(oversized[12:29]))
	if _, _, _, err := normalizeImage(oversized, "image/png"); err == nil || !strings.Contains(err.Error(), "32 million") {
		t.Fatalf("dimension bound error=%v", err)
	}
	path := filepath.Join(t.TempDir(), "oversized.png")
	if err := os.WriteFile(path, oversized, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readReference(path, maxInputBytes); err == nil || !strings.Contains(err.Error(), "32 million") {
		t.Fatalf("reference dimension bound error=%v", err)
	}
}

func TestReferenceAggregateBoundAndRegularFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "reference.png")
	data := testPNG(t)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readReference(path, int64(len(data)-1)); err == nil {
		t.Fatal("aggregate input size bound ignored")
	}
	if _, _, err := readReference(dir, maxInputBytes); err == nil {
		t.Fatal("directory accepted as image")
	}
	sparse := filepath.Join(dir, "sparse.png")
	f, err := os.Create(sparse)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(maxInputBytes + 1); err != nil {
		_ = f.Close()
		t.Fatal(err)
	}
	_ = f.Close()
	if _, _, err := readReference(sparse, maxInputBytes); err == nil {
		t.Fatal("oversized reference accepted")
	}
}

func TestContentLengthBoundAndThoughtOnlyOutput(t *testing.T) {
	for _, tc := range []struct {
		name   string
		body   string
		length string
	}{
		{"oversized response", "", "67108865"},
		{"thought only", `{"candidates":[{"content":{"parts":[{"thought":true,"inlineData":{"mimeType":"image/png","data":"bad"}}]}}]}`, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if tc.length != "" {
					w.Header().Set("Content-Length", tc.length)
				}
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			c, err := New("key", server.URL, "model", t.TempDir(), nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := c.Generate(context.Background(), Request{Prompt: "test"}); err == nil {
				t.Fatal("invalid response accepted")
			}
		})
	}
}

func TestDiagnosticOmitsCredentialAndPromptObjectKeys(t *testing.T) {
	c, err := New("private-key", "https://example.test", "model", t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	err = c.responseError("no image", []byte(`{"private-key":"value","private prompt":"value","candidates":[]}`), http.Header{}, 200, dir, "private prompt")
	if err == nil {
		t.Fatal("expected diagnostic error")
	}
	paths, _ := filepath.Glob(filepath.Join(dir, "gemini-response-*.json"))
	data, readErr := os.ReadFile(paths[0])
	if readErr != nil {
		t.Fatal(readErr)
	}
	var parsed any
	if json.Unmarshal(data, &parsed) != nil || strings.Contains(string(data), "private-key") || strings.Contains(string(data), "private prompt") {
		t.Fatalf("diagnostic leaked keys: %s", data)
	}
}

func TestOutputFilenameStaysInsideDirectory(t *testing.T) {
	dir := t.TempDir()
	path, err := saveOutput(testPNG(t), dir, "../../escape.jpg")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != dir || filepath.Ext(path) != ".png" {
		t.Fatalf("unsafe output path=%s", path)
	}
	second, err := saveOutput(testPNG(t), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	third, err := saveOutput(testPNG(t), dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if second == third {
		t.Fatal("default filename collision")
	}
}

func TestDiagnosticOmitsAllUnknownObjectKeys(t *testing.T) {
	c, err := New("key-with-private-tail", "https://example.test", "model", t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	body := []byte(`{"candidates":[],"cHJpdmF0ZSBpbWFnZSBieXRlcw==":{"private-tail":"value"}}`)
	_ = c.responseError("no image", body, http.Header{}, 200, dir, "private prompt")
	paths, _ := filepath.Glob(filepath.Join(dir, "gemini-response-*.json"))
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "cHJpdmF0ZSBpbWFnZSBieXRlcw==") || strings.Contains(string(data), "private-tail") {
		t.Fatalf("diagnostic leaked unknown object keys: %s", data)
	}
	if !strings.Contains(string(data), "candidates") {
		t.Fatal("diagnostic lost protocol field names")
	}
}
