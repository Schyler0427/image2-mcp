package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

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
