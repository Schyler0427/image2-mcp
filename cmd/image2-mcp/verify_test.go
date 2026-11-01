package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestVerifyInstallationConfiguredProviders(t *testing.T) {
	var requests atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		http.Error(w, "installation verification must not call image APIs", http.StatusInternalServerError)
	}))
	defer api.Close()
	binaryName := "image2-mcp"
	if runtime.GOOS == "windows" {
		binaryName += ".exe"
	}
	binary := filepath.Join(t.TempDir(), binaryName)
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build verification binary: %v: %s", err, output)
	}
	for _, tc := range []struct {
		name, image2Key, geminiKey, image2URL, geminiURL, wantError string
	}{
		{name: "both", image2Key: "image-fixture", geminiKey: "gemini-fixture"},
		{name: "Image2 only", image2Key: "image-fixture"},
		{name: "Gemini only", geminiKey: "gemini-fixture"},
		{name: "whitespace Gemini is unconfigured", image2Key: "image-fixture", geminiKey: " \t", geminiURL: "://invalid"},
		{name: "whitespace Image2 is unconfigured", image2Key: "　 \t", geminiKey: "gemini-fixture", image2URL: "://invalid"},
		{name: "no keys", wantError: "at least one"},
		{name: "whitespace keys", image2Key: " \t", geminiKey: "　", wantError: "at least one"},
		{name: "invalid configured Image2 URL", image2Key: "image-fixture", image2URL: "://invalid", wantError: "Image2 base URL"},
		{name: "invalid configured Gemini URL", geminiKey: "gemini-fixture", geminiURL: "://invalid", wantError: "Gemini base URL"},
		{name: "invalid configured Image2 URL with Gemini", image2Key: "image-fixture", geminiKey: "gemini-fixture", image2URL: "https://user:password@example.test", wantError: "Image2 base URL"},
		{name: "invalid configured Gemini URL with Image2", image2Key: "image-fixture", geminiKey: "gemini-fixture", geminiURL: "https://example.test?token=fixture", wantError: "Gemini base URL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			image2URL, geminiURL := tc.image2URL, tc.geminiURL
			if image2URL == "" {
				image2URL = api.URL
			}
			if geminiURL == "" {
				geminiURL = api.URL
			}
			for name, value := range map[string]string{
				"OPENAI_IMAGE_API_KEY": tc.image2Key, "OPENAI_IMAGE_BASE_URL": image2URL, "OPENAI_IMAGE_MODEL": "gpt-image-2",
				"GEMINI_IMAGE_API_KEY": tc.geminiKey, "GEMINI_IMAGE_BASE_URL": geminiURL, "GEMINI_IMAGE_MODEL": "gemini-3.1-flash-image",
			} {
				t.Setenv(name, value)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, binary, "--verify-mcp")
			output, err := command.CombinedOutput()
			if tc.wantError == "" {
				if err != nil || !strings.Contains(string(output), "MCP verification: OK") {
					t.Fatalf("verification = %v: %s", err, output)
				}
			} else if err == nil || !strings.Contains(string(output), tc.wantError) {
				t.Fatalf("verification = %v: %s; want %q", err, output, tc.wantError)
			}
			if got := requests.Load(); got != 0 {
				t.Fatalf("verification called image APIs %d times", got)
			}
		})
	}
}

func TestVerificationServerProcess(t *testing.T) {
	mode := os.Getenv("IMAGE2_MCP_VERIFY_TEST")
	if mode == "" {
		return
	}
	if mode == "silent" {
		<-time.After(time.Minute)
		os.Exit(0)
	}
	server := newServer("", "")
	if mode == "missing-tools" || mode == "old-version" {
		version := serverVersion
		if mode == "old-version" {
			version = "0.0.0"
		}
		server = mcp.NewServer(&mcp.Implementation{Name: "image2-mcp", Version: version}, nil)
	}
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		os.Exit(1)
	}
	os.Exit(0)
}

func TestVerifyMCPProcess(t *testing.T) {
	for _, tc := range []struct{ mode, wantError string }{
		{"normal", ""},
		{"missing-tools", "missing required tool"},
		{"old-version", "version mismatch"},
		{"silent", "initialize MCP"},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestVerificationServerProcess$")
			command.Env = append(os.Environ(), "IMAGE2_MCP_VERIFY_TEST="+tc.mode)
			err := verifyMCPProcess(ctx, command)
			if tc.wantError == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatalf("error = %v, want %q", err, tc.wantError)
			}
		})
	}
}
