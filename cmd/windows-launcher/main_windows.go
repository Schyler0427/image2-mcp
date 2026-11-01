//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"runtime"
)

func main() {
	version, err := embeddedVersion()
	if err != nil {
		showLauncherMessage("SchylerAI Image2 MCP", launcherOperationError(err))
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Printf("SchylerAI-Image2-mcp %s embedded-mcp %s %s %s\n", version, version, runtime.GOOS, runtime.GOARCH)
		return
	}
	arch, err := NativeArchitecture()
	if err != nil {
		showLauncherMessage("SchylerAI Image2 MCP", launcherOperationError(err))
		return
	}
	callbacks := LauncherCallbacks{
		Install: func(ctx context.Context, credentials InstallerCredentials, status func(string)) error {
			return InstallEmbedded(ctx, credentials, arch, status)
		},
		CheckUpdate: func(ctx context.Context) (UpdateInfo, error) {
			return CheckLatestUpdate(ctx, version)
		},
		ApplyUpdate: func(ctx context.Context, info UpdateInfo) error {
			return applyLauncherUpdate(ctx, info, arch)
		},
	}
	if err := ShowLauncher(version, callbacks); err != nil {
		showLauncherMessage("SchylerAI Image2 MCP", launcherOperationError(err))
	}
}
