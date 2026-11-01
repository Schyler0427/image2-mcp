//go:build windows

package main

import "context"

// InstallEmbedded verifies and extracts the selected native MCP payload into a
// private temporary workspace, then delegates the transaction to the existing
// offline PowerShell bootstrap. The workspace is removed on every return path.
func InstallEmbedded(ctx context.Context, credentials InstallerCredentials, arch string, status func(string)) error {
	return installEmbeddedWithRunner(ctx, credentials, arch, status, RunInstaller)
}
