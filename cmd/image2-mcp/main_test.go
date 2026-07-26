package main

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

	"image2-mcp/internal/image2"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestServerListsImage2Tools(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	server := newServer(root, t.TempDir())
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.1.0"}, nil)

	t1, t2 := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, t1, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer serverSession.Close()

	clientSession, err := client.Connect(ctx, t2, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer clientSession.Close()

	var names []string
	for tool, err := range clientSession.Tools(ctx, nil) {
		if err != nil {
			t.Fatal(err)
		}
		names = append(names, tool.Name)
	}
	want := map[string]bool{
		"generate_image2": true,
		"edit_image2":     true,
	}
	if len(names) != len(want) {
		t.Fatalf("tools = %v, want generate_image2 and edit_image2", names)
	}
	for _, name := range names {
		if !want[name] {
			t.Fatalf("unexpected tool %q in %v", name, names)
		}
	}
}

func TestGenerateImage2ToolReportsMissingAPIKey(t *testing.T) {
	t.Setenv("OPENAI_IMAGE_API_KEY", "")
	t.Setenv("OPENAI_IMAGE_BASE_URL", "https://api.schyler.top")

	ctx := context.Background()
	root := t.TempDir()
	server := newServer(root, t.TempDir())
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.1.0"}, nil)

	t1, t2 := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, t1, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer serverSession.Close()

	clientSession, err := client.Connect(ctx, t2, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer clientSession.Close()

	result, err := clientSession.CallTool(ctx, &mcp.CallToolParams{
		Name: "generate_image2",
		Arguments: generateParams{
			Prompt: "test",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError {
		t.Fatal("expected tool error for missing OPENAI_IMAGE_API_KEY")
	}
	if len(result.Content) == 0 {
		t.Fatal("expected error content")
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok || !strings.Contains(text.Text, "OPENAI_IMAGE_API_KEY is required") {
		t.Fatalf("unexpected error content: %#v", result.Content)
	}
}

func TestEditImage2ToolMapsParameters(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	imagePath := filepath.Join(t.TempDir(), "reference.png")
	if err := os.WriteFile(imagePath, png, 0o644); err != nil {
		t.Fatal(err)
	}

	apiServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/images/edits" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Fatal(err)
		}
		wantFields := map[string]string{
			"model":   image2.DefaultModel,
			"prompt":  "make it cinematic",
			"size":    "1536x1024",
			"quality": "high",
		}
		for name, want := range wantFields {
			if got := r.FormValue(name); got != want {
				t.Fatalf("field %q = %q, want %q", name, got, want)
			}
		}
		files := r.MultipartForm.File["image"]
		if len(files) != 1 || files[0].Filename != "reference.png" {
			t.Fatalf("image files = %#v", files)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(png)}},
		})
	}))
	defer apiServer.Close()

	t.Setenv("OPENAI_IMAGE_API_KEY", "test-key")
	t.Setenv("OPENAI_IMAGE_BASE_URL", apiServer.URL)
	outDir := t.TempDir()

	ctx := context.Background()
	server := newServer(t.TempDir(), t.TempDir())
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.1.0"}, nil)
	t1, t2 := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, t1, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer serverSession.Close()
	clientSession, err := client.Connect(ctx, t2, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer clientSession.Close()

	result, err := clientSession.CallTool(ctx, &mcp.CallToolParams{
		Name: "edit_image2",
		Arguments: editParams{
			Prompt:     "make it cinematic",
			ImagePaths: []string{imagePath},
			Size:       "1536x1024",
			Quality:    "high",
			OutputDir:  outDir,
			OutputName: "edited.png",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.IsError {
		t.Fatalf("unexpected tool error: %#v", result.Content)
	}
	if _, err := os.Stat(filepath.Join(outDir, "edited.png")); err != nil {
		t.Fatal(err)
	}
	if len(result.Content) != 1 {
		t.Fatalf("content = %#v", result.Content)
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok || !strings.Contains(text.Text, filepath.Join(outDir, "edited.png")) {
		t.Fatalf("unexpected result content: %#v", result.Content)
	}
}
