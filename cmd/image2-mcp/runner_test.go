package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Exercise the exact stdio wrapper Codex uses, including UTF-8 prompts and paths.
func TestRunnerStdio(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct{ Model, Prompt string }
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if request.Model != "gpt-image-2.5-sunburst" || request.Prompt != "画一只戴帽子的猫" {
			t.Errorf("unexpected model or corrupted prompt: %+v", request)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString([]byte("png"))}},
		})
	}))
	defer api.Close()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repo := filepath.Clean(filepath.Join(wd, "..", ".."))
	root := filepath.Join(t.TempDir(), "客户安装")
	for _, dir := range []string{"dist", "scripts"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	runnerName, binaryName := "run-image2-mcp.sh", "image2-mcp"
	if runtime.GOOS == "windows" {
		runnerName, binaryName = "run-image2-mcp.ps1", "image2-mcp.exe"
	}
	for _, path := range []string{"go.mod", filepath.Join("scripts", runnerName)} {
		data, err := os.ReadFile(filepath.Join(repo, path))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, path), data, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	environment := "OPENAI_IMAGE_API_KEY=runner-test-key\nOPENAI_IMAGE_BASE_URL=" + api.URL + "\n"
	if err := os.WriteFile(filepath.Join(root, ".env.local"), []byte(environment), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	build := exec.CommandContext(ctx, "go", "build", "-o", filepath.Join(root, "dist", binaryName), "./cmd/image2-mcp")
	build.Dir = repo
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build runner fixture: %v: %s", err, output)
	}
	command := exec.CommandContext(ctx, filepath.Join(root, "scripts", runnerName))
	if runtime.GOOS == "windows" {
		command = exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(root, "scripts", runnerName))
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "runner-test", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: command, TerminateDuration: time.Second}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if !strings.Contains(session.InitializeResult().Instructions, "帮我生成一张图") {
		t.Fatal("runner corrupted UTF-8 server instructions")
	}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      "generate_image2",
		Arguments: generateParams{Prompt: "画一只戴帽子的猫", Version: "2.5", OutputName: "runner-test.png"},
	})
	if err != nil || result.IsError {
		t.Fatalf("runner image call: result=%+v, error=%v", result, err)
	}
	if data, err := os.ReadFile(filepath.Join(root, "output", "imagegen", "runner-test.png")); err != nil || string(data) != "png" {
		t.Fatalf("runner output: data=%q, error=%v", data, err)
	}
}
