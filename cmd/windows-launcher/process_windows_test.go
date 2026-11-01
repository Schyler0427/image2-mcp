//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunInstallerCancellationAfterResumeCompletesTransaction(t *testing.T) {
	for _, rollback := range []bool{false, true} {
		name := "commit"
		if rollback {
			name = "rollback"
		}
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			marker := filepath.Join(dir, "transaction-state.txt")
			state := "committed"
			exit := "0"
			if rollback {
				state = "restored"
				exit = "23"
			}
			script := "$ErrorActionPreference = 'Stop'\n" +
				"$Key = [Console]::In.ReadLine()\n" +
				"$Gemini = [Console]::In.ReadLine()\n" +
				"if ($Gemini -cne 'fixture-gemini-key') { exit 20 }\n" +
				"if ($Key -cne 'fixture-image-key') { exit 19 }\n" +
				"Write-Output 'transaction-started'\n" +
				"Start-Sleep -Milliseconds 300\n" +
				"[IO.File]::WriteAllText('" + strings.ReplaceAll(marker, "'", "''") + "', '" + state + "')\n" +
				"exit " + exit + "\n"
			if err := os.WriteFile(filepath.Join(dir, "install-offline.ps1"), []byte(script), 0o600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			err := RunInstaller(ctx, dir, InstallerCredentials{Image2Key: "fixture-image-key", GeminiKey: "fixture-gemini-key"}, func(line string) {
				if line == "transaction-started" {
					cancel()
				}
			})
			if ctx.Err() == nil {
				t.Fatal("fixture did not request cancellation during transaction")
			}
			if rollback {
				if err == nil || err.Error() != installerFailureMessage(23) {
					t.Fatalf("RunInstaller() = %v, want rollback exit 23", err)
				}
			} else if err != nil {
				t.Fatalf("RunInstaller() = %v, want completed commit", err)
			}
			data, readErr := os.ReadFile(marker)
			if readErr != nil || string(data) != state {
				t.Fatalf("transaction state = %q, %v, want %q", data, readErr, state)
			}
		})
	}
}
