package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"image2-mcp/internal/image2"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The installer invokes this through the real runner, so its environment has
// already been loaded. Start the binary directly to avoid an intermediary shell
// surviving a timed-out handshake, especially on Windows.
func verifyInstallation(outputDir string) error {
	if err := validateConfiguredProviders(outputDir); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve MCP executable: %w", err)
	}
	command := exec.CommandContext(ctx, executable)
	if err := verifyMCPProcess(ctx, command); err != nil {
		return err
	}
	fmt.Println("MCP verification: OK")
	return nil
}

func validateConfiguredProviders(outputDir string) error {
	image2Configured := strings.TrimSpace(os.Getenv("OPENAI_IMAGE_API_KEY")) != ""
	geminiConfigured := strings.TrimSpace(os.Getenv("GEMINI_IMAGE_API_KEY")) != ""
	if !image2Configured && !geminiConfigured {
		return fmt.Errorf("at least one of OPENAI_IMAGE_API_KEY or GEMINI_IMAGE_API_KEY is required")
	}
	if image2Configured {
		if baseURL := strings.TrimSpace(os.Getenv("OPENAI_IMAGE_BASE_URL")); baseURL != "" {
			parsed, err := url.Parse(baseURL)
			if err != nil || parsed.Hostname() == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
				return fmt.Errorf("Image2 base URL must be an absolute HTTP(S) URL without credentials, query, or fragment")
			}
		}
		if _, err := image2.NewFromEnv(outputDir); err != nil {
			return err
		}
	}
	if geminiConfigured {
		if _, err := newGeminiImageClient(outputDir); err != nil {
			return err
		}
	}
	return nil
}

func verifyMCPProcess(ctx context.Context, command *exec.Cmd) error {
	client := mcp.NewClient(&mcp.Implementation{Name: "image2-mcp-install-check", Version: serverVersion}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: command, TerminateDuration: time.Second}, nil)
	if err != nil {
		return fmt.Errorf("initialize MCP: %w", err)
	}
	defer session.Close()
	info := session.InitializeResult().ServerInfo
	if info == nil {
		return fmt.Errorf("MCP server did not report its version")
	}
	if info.Name != "image2-mcp" || info.Version != serverVersion {
		return fmt.Errorf("MCP server version mismatch: got %s %s, expected image2-mcp %s", info.Name, info.Version, serverVersion)
	}
	tools, err := session.ListTools(ctx, nil)
	if err != nil {
		return fmt.Errorf("list MCP tools: %w", err)
	}
	found := make(map[string]bool)
	for _, tool := range tools.Tools {
		found[tool.Name] = true
	}
	for _, name := range []string{"generate_image", "edit_image", "generate_image2", "edit_image2"} {
		if !found[name] {
			return fmt.Errorf("MCP missing required tool: %s", name)
		}
	}
	return nil
}
