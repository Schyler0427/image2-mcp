# Universal Windows Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one `SchylerAI-Image2-mcp.exe` for Windows 10/11 that prompts for an Image2 key, selects the correct embedded MCP payload, installs transactionally, and can check for and launch signed newer EXE releases.

**Architecture:** Add a Windows-only Go launcher built as `windows/386`. The launcher embeds architecture-specific MCP binaries and the existing offline installer resources, displays a native Win32 GUI, sends the key only through a redirected stdin pipe, and delegates installation/rollback to the existing PowerShell transaction. A signed HTTPS JSON manifest drives optional EXE updates; the current embedded version remains usable when the network is unavailable.

**Tech Stack:** Go 1.25, `go:embed`, `golang.org/x/sys/windows`, Win32 user32/kernel32 APIs, Ed25519 signatures, existing PowerShell bootstrap, GitHub Actions Windows build.

## Global Constraints

- User-visible file name is exactly `SchylerAI-Image2-mcp.exe`.
- The launcher must support Windows 10/11 x86, x64, and ARM64 systems without user architecture selection.
- The launcher embeds `windows/386`, `windows/amd64`, and `windows/arm64` MCP payloads.
- Every install or update prompts for a separate Image2 API Key; never copy a previous `.env.local` into the active install.
- The key must never appear in command arguments, child environment variables, logs, GUI output, or update requests.
- Update checks use one fixed HTTPS manifest endpoint, verify Ed25519 signature plus SHA-256 before launching a downloaded EXE, and never send the API Key.
- Offline installation of the embedded version continues to work when the update endpoint is unavailable.
- Existing Codex configuration, ACL handling, MCP handshake, and rollback behavior remain the source of truth.

---

### Task 1: Define launcher payload and update metadata formats

**Files:**
- Create: `cmd/windows-launcher/metadata.go`
- Create: `cmd/windows-launcher/metadata_test.go`
- Create: `cmd/windows-launcher/update.go`
- Create: `cmd/windows-launcher/update_test.go`
- Create: `cmd/windows-launcher/update_public_key.go`

**Interfaces:**
- `PayloadManifest` records launcher version and SHA-256/size for `386`, `amd64`, and `arm64` payloads.
- `UpdateManifest` contains `version`, `published_at`, `notes`, `asset_url`, `sha256`, `size`, `signature`, and `architectures`.
- `VerifyUpdateManifest(raw []byte, publicKey ed25519.PublicKey, current string) (UpdateInfo, error)` rejects malformed versions, non-HTTPS URLs, cross-host URLs, oversized assets, unsupported architectures, downgrade versions, and invalid signatures.
- `DownloadVerifiedUpdate(ctx context.Context, info UpdateInfo, client *http.Client, dir string) (string, error)` downloads once to a temporary file, enforces size limits, checks SHA-256, and atomically retains the verified EXE.

- [ ] Write table-driven failing tests for valid updates, no-update, downgrade, malformed JSON, invalid signature, HTTP URL, wrong host, redirect, size mismatch, hash mismatch, and download cancellation.
- [ ] Run `go test ./cmd/windows-launcher -run 'TestVerify|TestDownload'` and confirm failures are due to missing types/functions.
- [ ] Implement metadata parsing, Ed25519 verification, bounded HTTPS download, and redacted errors without logging response bodies or URLs containing credentials.
- [ ] Run the focused tests and confirm all pass.

### Task 2: Implement architecture selection and native Win32 GUI

**Files:**
- Create: `cmd/windows-launcher/arch_windows.go`
- Create: `cmd/windows-launcher/gui_windows.go`
- Create: `cmd/windows-launcher/process_windows.go`
- Create: `cmd/windows-launcher/main_windows.go`
- Create: `cmd/windows-launcher/gui_test.go`

**Interfaces:**
- `NativeArchitecture() (string, error)` returns exactly `386`, `amd64`, or `arm64` using `GetNativeSystemInfo`, independent of the launcher process architecture.
- `RunInstaller(ctx context.Context, payloadDir, key string, onOutput func(string)) error` starts PowerShell with redirected stdin/stdout/stderr and never places `key` in args or environment.
- `ShowLauncher(version string, callbacks LauncherCallbacks) error` provides a password edit, install/update button, check-update button, cancel button, and status text.

- [ ] Write failing architecture mapping tests using representative `SYSTEM_INFO.wProcessorArchitecture` values and rejecting unknown values.
- [ ] Run the tests and confirm failure before adding the Win32 implementation.
- [ ] Implement `NativeArchitecture` with `GetNativeSystemInfo`; implement Win32 window creation, password edit control, buttons, message loop, cancellation, and UTF-16 conversion.
- [ ] Implement stdin-piped PowerShell execution with hidden window, bounded cancellation, output redaction, and exit-code reporting.
- [ ] Run focused tests plus a Windows cross-build with `CGO_ENABLED=0 GOOS=windows GOARCH=386`.

### Task 3: Embed payloads and delegate transactional installation

**Files:**
- Create: `cmd/windows-launcher/embed.go`
- Create: `cmd/windows-launcher/install_windows.go`
- Create: `scripts/build-universal-windows-launcher.ps1`
- Create: `scripts/build-universal-windows-launcher.sh`
- Modify: `scripts/bootstrap-agent-install.ps1`
- Modify: `install-offline.ps1`
- Test: `tests/test-universal-launcher.sh`

**Interfaces:**
- `EmbeddedPayload` contains the selected MCP executable, installer scripts, manifest, and version marker.
- `ExtractEmbeddedPayload(arch, dir string) error` safely creates regular files, verifies the embedded manifest, and rejects traversal/reparse paths.
- `InstallEmbedded(ctx context.Context, key string, arch string, status func(string)) error` extracts resources, runs the existing offline bootstrap through stdin, and removes the temporary workspace after exit.

- [ ] Add a fixture-based failing test for extracting each architecture, rejecting a tampered manifest, rejecting path traversal, and deleting temporary files after success/failure.
- [ ] Run the fixture tests and confirm they fail before implementation.
- [ ] Add generated `internal/launcherassets` files or a deterministic build-time asset directory consumed by `go:embed`; build all three MCP binaries with `-trimpath` and generate a manifest.
- [ ] Implement safe extraction and invoke the existing `install-offline.ps1` without passing the key in args or environment.
- [ ] Verify the universal launcher binary is reproducible enough for manifest hashes and that `--version` reports launcher and embedded MCP versions.

### Task 4: Add update handoff and version-aware installation

**Files:**
- Modify: `cmd/windows-launcher/main_windows.go`
- Modify: `cmd/windows-launcher/update.go`
- Create: `scripts/update-manifest.example.json`
- Modify: `.github/workflows/release.yml`
- Create: `.github/workflows/universal-windows-launcher.yml`
- Modify: `README.md`
- Modify: `OFFLINE_INSTALL.md`

**Interfaces:**
- The GUI’s “检查更新” action invokes `CheckForUpdate` without reading the key.
- The “立即更新” action downloads and verifies the newer `SchylerAI-Image2-mcp.exe`, launches it with a one-time handoff token that contains no key, and exits the old process.
- The new process starts the normal key prompt and installation path. It must not silently install or reuse a saved key.

- [ ] Add tests for no-update, newer-version handoff, manifest/network failure, invalid signature, and ensuring update requests contain no key.
- [ ] Run the tests before implementation and verify the new update cases fail.
- [ ] Implement update check/download/handoff with a fixed host allowlist, size cap, signed manifest verification, and a temporary verified executable.
- [ ] Add CI jobs that build `windows/386`, `windows/amd64`, and `windows/arm64`, embed them into one `windows/386` launcher named `SchylerAI-Image2-mcp.exe`, sign the release manifest, and publish the single user-facing EXE.
- [ ] Document manual offline installation, automatic update behavior, supported Windows versions, and the requirement to enter the separate Image2 key on every install/update.

### Task 5: Full verification and review

**Files:**
- Modify: `tests/test-universal-launcher.sh`
- Modify: `tests/test-offline-install.ps1`
- Modify: `tests/test-offline-install.sh`

- [ ] Run `go test ./...` and `go test -race ./...`.
- [ ] Run `go vet ./...` and `git diff --check`.
- [ ] Run the offline package, bootstrap, key-only, and universal-launcher fixture tests.
- [ ] Cross-build the launcher and all three payload architectures; inspect `--version` output and manifest hashes.
- [ ] On a Windows runner, exercise first install, key replacement, update handoff, canceled update, invalid signature, damaged payload, MCP handshake, and rollback.
- [ ] Run a security review for key exposure in process arguments, environment, logs, update requests, and temporary files.
