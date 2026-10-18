package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"image2-mcp/internal/image2"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The installer invokes this through the real runner, so its environment has
// already been loaded. Start the binary directly to avoid an intermediary shell
// surviving a timed-out handshake, especially on Windows.
func verifyInstallation(outputDir string) error {
	if _, err := image2.NewFromEnv(outputDir); err != nil {
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
	for _, name := range []string{"generate_image2", "edit_image2"} {
		if !found[name] {
			return fmt.Errorf("MCP missing required tool: %s", name)
		}
	}
	return nil
}
