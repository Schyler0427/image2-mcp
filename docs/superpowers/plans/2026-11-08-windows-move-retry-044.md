# Windows installer directory-move retry 0.4.4

**Goal:** Ship a Windows 0.4.4 installer containing the bounded directory-move retry that resolved the reported Windows 11 installation failure.

**Architecture:** Add one PowerShell helper beside the existing bootstrap directory helpers. Retry only access-denied and sharing/lock errors, with six total attempts and one second between attempts. Keep the existing activation intent flags, transaction ordering, credential handling, and rollback behavior. Use the helper for all transaction directory moves so backup and restoration have the same protection.

**Tech Stack:** Go, Windows PowerShell 5.1-compatible PowerShell, existing universal Windows launcher builder.

## Constraints

- Preserve the original error after the sixth failed attempt; do not retry unrelated failures.
- Do not change permissions, remove files, terminate processes, print credentials, or call image APIs.
- Keep the online installer pinned to the existing published v0.4.0 path; this release is a local Windows deliverable.
- Preserve 0.4.3 artifacts; build 0.4.4 into a new release directory.
- PowerShell 7 on macOS can exercise retry semantics and native directory moves, but cannot establish Windows GUI or PowerShell 5.1 end-to-end acceptance.

## Task 1: Reproduce transient and permanent move failures

**Files:** `tests/test-bootstrap-directory-move.ps1`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`.

- [ ] Write focused tests that load the bootstrap without invoking installation and exercise `Move-AgentBootstrapDirectory(Source, Destination)`.
- [ ] Verify transient access-denied and sharing violations recover, six failures preserve the original exception, and unrelated errors fail immediately.
- [ ] Verify a real directory and its sentinel file move intact; verify the helper is used by activation, old-target backup, failed-target retention, and restoration.
- [ ] Run the tests before adding the helper and confirm failure because the helper is missing.
- [ ] Add the test to the existing Windows PowerShell 5.1 CI and release test steps.

## Task 2: Implement bounded retries and bump the release

**Files:** `scripts/bootstrap-agent-install.ps1`, `cmd/image2-mcp/main.go`, `cmd/image2-mcp/main_test.go`, fixed offline version checks and fixtures.

- [ ] Add the helper using only Windows PowerShell 5.1-compatible syntax and .NET APIs.
- [ ] Replace each transaction directory move with the helper, preserving surrounding transaction flags.
- [ ] Run the focused PowerShell test and confirm it passes.
- [ ] Set the server and fixed offline-version checks/fixtures to 0.4.4; preserve published online v0.4.0 references and historical 0.4.3 documentation.
- [ ] Update Windows release documentation with the fix and test limits.

## Task 3: Verify and package

- [ ] Run the Go suite with a complete installed toolchain, `go vet ./...`, and `git diff --check`.
- [ ] Run installer, bootstrap, offline packaging/install, and universal-launcher regression scripts applicable to macOS.
- [ ] Run focused PowerShell behavior tests and parse all changed PowerShell files.
- [ ] Build the universal 386 GUI launcher with embedded Windows 386, amd64, and arm64 backends using `scripts/build-universal-windows-launcher.sh`.
- [ ] Verify the final EXE contains the retry-enabled bootstrap, version 0.4.4, and real platform payloads with matching hashes.
- [ ] Place the EXE, manifest, SHA-256 checksums, release notes, and verification record in `dist/releases/0.4.4`.
- [ ] Report the local artifact path and distinguish local delivery from online update publication and Windows native acceptance.
