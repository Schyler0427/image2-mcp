package main

import (
	"io"
	"os"
	"runtime"
	"testing"
)

func TestVersionWithoutCredentials(t *testing.T) {
	t.Setenv("OPENAI_IMAGE_API_KEY", "")
	t.Setenv("OPENAI_IMAGE_BASE_URL", "invalid://no-network")
	oldArgs, oldStdout := os.Args, os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer func() { os.Args, os.Stdout = oldArgs, oldStdout }()
	os.Args, os.Stdout = []string{"image2-mcp", "--version"}, writer
	err = run()
	writer.Close()
	if err != nil {
		t.Fatalf("credential-free version: %v", err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	want := "image2-mcp " + serverVersion + " offline-v1 " + runtime.GOOS + " " + runtime.GOARCH + "\n"
	if string(output) != want {
		t.Fatalf("version = %q, want %q", output, want)
	}
}
