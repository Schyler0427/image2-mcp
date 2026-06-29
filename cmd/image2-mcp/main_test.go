package main

import (
	"context"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestServerListsGenerateImage2AndEditImage2Tools(t *testing.T) {
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
	if len(names) != 2 {
		t.Fatalf("tools = %v, want [edit_image2 generate_image2]", names)
	}
	want := map[string]bool{"generate_image2": true, "edit_image2": true}
	for _, n := range names {
		if !want[n] {
			t.Fatalf("unexpected tool %q", n)
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

func TestEditImage2ToolReportsMissingAPIKey(t *testing.T) {
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
		Name: "edit_image2",
		Arguments: editParams{
			Prompt:     "edit test",
			ImagePaths: []string{"/tmp/test.png"},
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

func TestEditImage2ToolReportsMissingImages(t *testing.T) {
	t.Setenv("OPENAI_IMAGE_API_KEY", "test-key")

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
		Name:      "edit_image2",
		Arguments: editParams{Prompt: "edit test"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.IsError {
		t.Fatal("expected tool error for missing images")
	}
	if len(result.Content) == 0 {
		t.Fatal("expected error content")
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok || !strings.Contains(text.Text, "at least one image path is required") {
		t.Fatalf("unexpected error content: %#v", result.Content)
	}
}
