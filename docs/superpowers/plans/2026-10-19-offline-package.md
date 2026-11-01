# Offline Installation Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build six platform-specific offline Image2 MCP packages that install without GitHub, Git, Go, or network access while retaining API Key protection, transactional rollback, and local MCP verification.

**Architecture:** Add an offline mode to the existing Bash and PowerShell bootstrap helpers. The package contains a small wrapper, the helper, a validated source-like payload, and the matching platform binary. The helper stages the local payload into the existing fixed target and invokes the existing installer with an offline flag; the installer uses the bundled binary instead of any download. Extend the release build to publish additional offline archives without changing v0.3.3.

**Tech Stack:** Bash 3.2+, Windows PowerShell 5.1+, Go, tar/gzip, zip, GitHub Actions.

## Global Constraints

- Offline mode must make zero network requests, including GitHub Release checks and binary downloads.
- Offline mode must use one local package payload and never fall back to source compilation or a remote download.
- The package must contain the platform binary, both installers, both runners, `go.mod`, and both bootstrap helpers.
- Existing target ownership checks, API Key stdin handling, Codex config snapshots, rollback, retained backups, archive safety checks, and local MCP handshake verification remain active.
- The package must support macOS/Linux tar.gz and Windows zip for darwin/linux amd64/arm64 and windows amd64/arm64.
- Published v0.3.3 remains immutable; the new package assets are additive and use the current server version at build time.
- No API Key is written into package metadata, command arguments, network requests, or logs.
- A package or payload validation failure must occur before target mutation or API Key input.

---

### Task 1: Add local offline bootstrap paths

**Files:**
- Modify: `scripts/bootstrap-agent-install.sh`
- Modify: `scripts/bootstrap-agent-install.ps1`
- Create: `install-offline.sh`
- Create: `install-offline.ps1`
- Test: `tests/test-agent-bootstrap.sh`
- Test: `tests/test-agent-bootstrap.ps1`

**Interfaces:**
- `scripts/bootstrap-agent-install.sh --offline-package DIRECTORY` stages the local DIRECTORY payload and performs the normal fixed-target transaction without network calls.
- `scripts/bootstrap-agent-install.ps1 -OfflinePackage DIRECTORY` provides the equivalent Windows behavior.
- The wrapper scripts locate their sibling `scripts/bootstrap-agent-install.*` and pass the sibling `payload` directory.

- [ ] **Step 1: Write failing offline bootstrap tests**

Add fixtures that invoke each available helper with a valid local payload and assert `Verification: OK`, zero fake network calls, the fixed target, and the bundled binary marker. Add a failure case with a missing bundled binary and assert the target/config fingerprints remain unchanged and no Key prompt is reached.

- [ ] **Step 2: Run the focused tests and observe the expected failure**

Run `bash tests/test-agent-bootstrap.sh`; the new offline cases must fail because the helper does not yet accept `--offline-package`.

- [ ] **Step 3: Implement the Bash local path**

Parse exactly one `--offline-package DIRECTORY` option. Validate the directory as a regular non-symlink tree with the existing staged-source checks plus `dist/image2-mcp`. Copy it into the transaction directory, skip Release metadata/source downloads, set the installer mode to offline, and invoke `./install.sh --key-only --offline`. Keep target/config snapshot, backup, rollback, and verification paths unchanged.

- [ ] **Step 4: Implement the PowerShell local path**

Add `-OfflinePackage` parsing, validate the payload with the existing reparse-point and required-file checks plus `dist\image2-mcp.exe`, copy it under the transaction directory, skip TLS/network calls, and invoke `install.ps1 -KeyOnly -Offline`. Preserve all existing rollback and evidence reporting.

- [ ] **Step 5: Add the customer-facing wrappers**

`install-offline.sh` must resolve its own directory and execute `scripts/bootstrap-agent-install.sh --offline-package "$root/payload"`. `install-offline.ps1` must resolve its own directory and execute the PowerShell helper with `-OfflinePackage (Join-Path $root 'payload')`.

- [ ] **Step 6: Run the focused tests and commit**

Run `bash tests/test-agent-bootstrap.sh` and, on Windows CI, `./tests/test-agent-bootstrap.ps1`. Commit as `feat: add offline bootstrap installation path`.

### Task 2: Make the platform installers consume a bundled binary

**Files:**
- Modify: `scripts/setup.sh`
- Modify: `install.ps1`
- Test: `tests/test-install-key-only.sh`
- Test: `tests/test-install-key-only.ps1`

**Interfaces:**
- Bash `./install.sh --key-only --offline` requires `dist/image2-mcp` and never calls `download_prebuilt`.
- PowerShell `install.ps1 -KeyOnly -Offline` requires `dist\image2-mcp.exe` and never calls `Install-Prebuilt`.

- [ ] **Step 1: Write failing installer tests**

Add tests that place a fixture binary in `dist`, replace `curl`/`Invoke-WebRequest` with a failing command, run offline key-only installation, and assert local verification succeeds. Add missing-binary failure assertions.

- [ ] **Step 2: Run the focused tests and observe the expected failure**

Run `bash tests/test-install-key-only.sh`; the offline invocation must initially be rejected as an unknown option.

- [ ] **Step 3: Implement Bash offline mode**

Add `offline=0`, parse `--offline`, require it only with `--key-only`, document it in help, and branch before the prebuilt/source selection. Check `dist/image2-mcp` is a regular file, set executable permission, and keep the rest of installation and verification unchanged.

- [ ] **Step 4: Implement PowerShell offline mode**

Add `[switch]$Offline`, reject combinations outside `-KeyOnly`, document it, require a regular `dist\image2-mcp.exe`, and branch before `Install-Prebuilt`. Do not call `Invoke-WebRequest` in this branch.

- [ ] **Step 5: Run focused tests and commit**

Run the Bash installer suite and the PowerShell installer suite in Windows CI. Commit as `feat: install from bundled platform binary`.

### Task 3: Build and publish complete offline assets

**Files:**
- Create: `scripts/build-offline-package.sh`
- Modify: `.github/workflows/release.yml`
- Create: `OFFLINE_INSTALL.md`
- Test: `tests/test-offline-package.sh`

**Interfaces:**
- `scripts/build-offline-package.sh --os OS --arch ARCH --binary PATH --version VERSION --output PATH` creates one tar.gz or zip package with a `payload/` directory and matching wrapper/helper files.
- Package names are `image2-mcp-offline_<os>_<arch>.tar.gz` for darwin/linux and `.zip` for windows.
- Each package contains `payload/dist/image2-mcp[.exe]`, both installers, both runners, `payload/go.mod`, and both bootstrap helpers.

- [ ] **Step 1: Write the package-shape test**

Create a fake binary and call the packaging script for Linux and Windows. List the resulting archives and assert the required paths, platform-specific binary name, wrapper scripts, version marker, and absence of API Key material.

- [ ] **Step 2: Run the package test and observe the expected failure**

Run `bash tests/test-offline-package.sh`; it must fail because the packaging script does not exist.

- [ ] **Step 3: Implement deterministic package assembly**

Validate the OS/architecture pair and binary path, read the server version from the explicit argument, create a temporary package root, copy only the required files, write a non-secret `OFFLINE_PACKAGE_VERSION` marker, and create tar.gz or zip. Refuse missing or non-regular files and clean temporary state on every exit.

- [ ] **Step 4: Extend the release workflow**

After each existing matrix build, call the packaging script with the built binary and upload the resulting offline archive as an additional artifact. In the publish job merge both existing binary assets and six offline assets, and generate `SHA256SUMS.txt` for the offline assets. Keep existing six binary asset names for compatibility.

- [ ] **Step 5: Add offline customer instructions and commit**

Document extracting the platform package, running `./install-offline.sh` or `powershell -ExecutionPolicy Bypass -File .\install-offline.ps1`, the one-time API Key input, local verification, and the fact that the package does not access GitHub. Commit as `feat: publish complete offline installation packages`.

### Task 4: Contract tests and release documentation

**Files:**
- Modify: `AGENT_INSTALL.md`
- Modify: `README.md`
- Modify: `tests/test-agent-install-contract.sh`
- Modify: `docs/superpowers/specs/2026-10-19-github-independent-install-design.md`

- [ ] **Step 1: Add documentation assertions**

Require the docs to identify offline packages as the supported GitHub-independent path, state the exact wrapper commands, and state that offline verification is local and does not call the image API.

- [ ] **Step 2: Update documentation**

Keep the current GitHub bootstrap path documented for maintainers, add the offline package path for customers, and do not claim the self-hosted download source is already deployed.

- [ ] **Step 3: Run all tests and commit**

Run `go test ./...`, `go vet ./...`, `bash tests/test-install-key-only.sh`, `bash tests/test-agent-install-contract.sh`, `bash tests/test-agent-bootstrap.sh`, and `bash tests/test-offline-package.sh`. Commit as `docs: document offline package installation`.

### Task 5: Whole-branch verification

- [ ] **Step 1: Review the complete diff against `main`**

Check that offline mode has no network branch, package files are platform-correct, API Key handling is unchanged, and v0.3.3 files are not rewritten as a release.

- [ ] **Step 2: Run all available local verification**

Run the full Go suite, shell contract/bootstrap/package suites, archive listings, `git diff --check`, and package tests using a fake binary. Record Windows PowerShell results when CI is available.

- [ ] **Step 3: Commit any required corrections and report the exact evidence**

Do not publish, tag, or push until a later explicit request.
