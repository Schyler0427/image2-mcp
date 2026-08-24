# Fast Key-Only Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `v0.2.3` with bounded GitHub waits and a single-turn, current-user Agent flow so customers still supply only one API Key without multi-minute silent stalls.

**Architecture:** Change the Agent contract to collect the secret before launching a helper, then forward it only through the helper's attached stdin in the same Agent turn. Make public Release pages the fast metadata path, retain a single short API fallback, separate metadata and payload time budgets, and preserve the existing transaction, archive, ACL, configuration, and local-verification boundaries.

**Tech Stack:** Bash 3.2, curl/wget, Windows PowerShell 5.1, GitHub Actions, Go.

## Global Constraints

- Fixed repository: `Schyler0427/image2-mcp`.
- Fixed base URL: `https://api.schyler.top`.
- Customer supplies only `OPENAI_IMAGE_API_KEY`, once; never print or derive it.
- No Git, Go, elevation, administrator helper, forwarding script, or third-party download proxy on customer machines.
- Keep strict six-asset public Release validation, archive validation, ownership proof, atomic writes, rollback, and retained evidence.
- Keep Bash 3.2 and Windows PowerShell 5.1 compatibility.
- Verification remains local and never calls an image API.
- Publish a new immutable `v0.2.3`; never move `v0.2.1` or `v0.2.2`.

---

### Task 1: Make The Agent Flow Single-Turn

**Files:**
- Modify: `tests/test-agent-install-contract.sh`
- Modify: `AGENT_INSTALL.md`

**Interfaces:**
- Consumes: existing helper stdin prompt `OPENAI_IMAGE_API_KEY:`.
- Produces: Agent contract that asks `请输入 API Key：` before helper launch and then uses one attached process with no elevation or forwarding script.

- [ ] **Step 1: Write the failing contract assertions**

Add exact checks after the existing helper-contract loop:

```bash
for required in \
  'Ask exactly `请输入 API Key：` before starting the platform helper.' \
  'Do not request elevation or start an administrator process.' \
  'Do not create a forwarding script or a second process to relay stdin.' \
  'Keep this download, helper launch, key forwarding, installation, and verification in one Agent turn.' \
  'Do not inspect `.env.local`, the target, or Codex config while the helper is still running.'; do
  grep -Fq "$required" "$doc" || {
    echo "FAIL: missing single-turn Agent contract: $required" >&2
    exit 1
  }
done
if grep -Fq 'Start the selected helper and wait until it requests stdin. Then ask exactly' "$doc"; then
  echo 'FAIL: Agent guide still starts a long-running helper before asking for the key' >&2
  exit 1
fi
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-agent-install-contract.sh`

Expected: FAIL with `missing single-turn Agent contract`.

- [ ] **Step 3: Rewrite the obtain/secret sequence minimally**

Keep the fixed helper URLs and TLS instructions, but make the normative sequence explicit:

```markdown
Before starting the platform helper, ask exactly `请输入 API Key：` and wait for
the customer's one-line response. Keep it only as the pending stdin secret.

Download the platform helper, then start it once as the current user with its
real stdin/stdout/stderr attached. Do not request elevation or start an
administrator process. Do not create a forwarding script or a second process
to relay stdin. Keep this download, helper launch, key forwarding,
installation, and verification in one Agent turn.

When the attached child prints `OPENAI_IMAGE_API_KEY:`, send the pending secret
as exactly one line through that same process stdin. Do not inspect `.env.local`,
the target, or Codex config while the helper is still running.
```

Retain the prohibition on command arguments, variables, environment values,
temporary files, diagnostics, and output streams.

- [ ] **Step 4: Run the contract test and verify GREEN**

Run: `bash tests/test-agent-install-contract.sh`

Expected: `PASS: Agent install contract`.

- [ ] **Step 5: Commit the Agent flow**

```bash
git add AGENT_INSTALL.md tests/test-agent-install-contract.sh
git commit -m "fix: keep key-only install in one Agent turn"
```

### Task 2: Add The Bash Metadata Fast Path

**Files:**
- Modify: `tests/test-agent-bootstrap.sh`
- Modify: `scripts/bootstrap-agent-install.sh`

**Interfaces:**
- Produces: `download_metadata URL OUTPUT`, `download_source URL OUTPUT`, `validate_release_api`, and zero-argument `validate_release_gate`.
- `validate_release_gate` attempts validated public pages first and a validated API response second.

- [ ] **Step 1: Add RED fixtures for order, bounds, and progress**

Extend fake `curl` to append every URL and option vector to
`$BOOTSTRAP_FIXTURE_NETWORK_LOG` when set. Add a page-success run and assert:

```bash
assert_contains "$page_first_log" 'Checking public Release...'
assert_contains "$page_first_log" 'Downloading source package...'
! grep -Fq 'api.github.com' "$network_log" || fail 'page success still called the API'
[[ "$(grep -c '/releases/tag/v0.2.2' "$network_log")" -eq 1 ]] || fail 'Release page was retried'
[[ "$(grep -c '/releases/expanded_assets/v0.2.2' "$network_log")" -eq 1 ]] || fail 'assets page was retried'
grep -Fq -- '--connect-timeout 5 --max-time 15' "$network_log" || fail 'metadata timeout is not bounded'
```

Add a page-failure/API-success fixture and require exactly one page call, no
expanded-assets call after the page fails, exactly one API call, and
`Verification: OK`.

- [ ] **Step 2: Run the Bash bootstrap test and verify RED**

Run: `bash tests/test-agent-bootstrap.sh`

Expected: FAIL because the current main path downloads the API first and uses
three retries.

- [ ] **Step 3: Split metadata and source downloads**

Replace the shared downloader with bounded functions:

```bash
download_metadata() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL -sS --connect-timeout 5 --max-time 15 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=1 --timeout=15 -O "$output" "$url"
  else
    fail 'curl or wget is required'
  fi
}

download_source() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL -sS --connect-timeout 10 --max-time 60 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=1 --timeout=60 -O "$output" "$url"
  else
    fail 'curl or wget is required'
  fi
}
```

Change page validation to use `download_metadata`. Add
`validate_release_api`, which downloads to `$txn/release.json` once and calls
`validate_release_json`. Make `validate_release_gate` call
`validate_release_page` first and `validate_release_api` only on failure.

- [ ] **Step 4: Add milestones to `main`**

Use exact non-secret output and source downloader:

```bash
printf 'Checking public Release...\n'
validate_release_gate || fail 'public v0.2.2 Release gate failed; public pages and GitHub API did not pass'
printf 'Downloading source package...\n'
download_source "$readonly_source_url" "$archive"
printf 'Preparing installation...\n'
```

Print `Installing platform binary...` immediately before
`run_key_only_installer` and `Verifying local installation...` after it returns.

- [ ] **Step 5: Run the Bash bootstrap test and verify GREEN**

Run: `bash -n scripts/bootstrap-agent-install.sh && bash tests/test-agent-bootstrap.sh`

Expected: `PASS: Bash Agent bootstrap helper`.

- [ ] **Step 6: Commit the Bash fast path**

```bash
git add scripts/bootstrap-agent-install.sh tests/test-agent-bootstrap.sh
git commit -m "fix: bound Bash bootstrap metadata waits"
```

### Task 3: Add The PowerShell Metadata Fast Path

**Files:**
- Modify: `tests/test-agent-bootstrap.ps1`
- Modify: `scripts/bootstrap-agent-install.ps1`

**Interfaces:**
- Produces: `Invoke-AgentBootstrapMetadata([string]$Uri)` with one
  `Invoke-WebRequest -TimeoutSec 15`, and page-first Release validation with
  one `Invoke-RestMethod -TimeoutSec 15` fallback.

- [ ] **Step 1: Add RED network-call recording**

In the PowerShell harness, record each mocked call as
`METHOD|TIMEOUT|URI` in a list. Make page responses return objects with fixture
`Content`, and the source response copy the fixture when `OutFile` is present.
After `Invoke-AgentBootstrap`, require:

```powershell
Assert-True ($NetworkCalls[0] -eq "WEB|15|https://github.com/Schyler0427/image2-mcp/releases/tag/v0.2.2") "Release page was not first"
Assert-True ($NetworkCalls[1] -eq "WEB|15|https://github.com/Schyler0427/image2-mcp/releases/expanded_assets/v0.2.2") "assets page was not second"
Assert-True (-not ($NetworkCalls -match '^REST\|')) "API was called after page success"
```

Add a page-failure/API-success case and require one page call followed by one
REST call with timeout 15. Also require all five progress milestones and no key
text in output.

- [ ] **Step 2: Run native PowerShell test and verify RED**

Run on Windows PowerShell 5.1:

```powershell
.\tests\test-agent-bootstrap.ps1
```

Expected: FAIL because the current helper calls the API first and retries three
times.

- [ ] **Step 3: Implement a single-attempt metadata helper**

Replace `Invoke-AgentBootstrapWebPage` with:

```powershell
function Invoke-AgentBootstrapMetadata([string]$Uri) {
  return Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $Uri
}
```

In `Invoke-AgentBootstrap`, print `Checking public Release...`, validate the
Release page and expanded-assets page first, then make one
`Invoke-RestMethod -UseBasicParsing -TimeoutSec 15` call only if page validation
fails. Retain `Assert-AgentBootstrapRelease` for strict JSON validation.

- [ ] **Step 4: Add payload milestones without changing transaction order**

Print `Downloading source package...` before the existing source request,
`Preparing installation...` after archive validation, `Installing platform
binary...` before `Invoke-AgentBootstrapInstaller`, and `Verifying local
installation...` after it returns. Keep all target/config snapshots and moves
in their current order.

- [ ] **Step 5: Run native PowerShell test and verify GREEN**

Run: `.\tests\test-agent-bootstrap.ps1`

Expected: `PASS: PowerShell Agent bootstrap helper`.

- [ ] **Step 6: Commit the PowerShell fast path**

```bash
git add scripts/bootstrap-agent-install.ps1 tests/test-agent-bootstrap.ps1
git commit -m "fix: bound PowerShell bootstrap metadata waits"
```

### Task 4: Bound Platform Binary Downloads

**Files:**
- Modify: `tests/test-install-key-only.sh`
- Modify: `tests/test-install-key-only.ps1`
- Modify: `scripts/setup.sh`
- Modify: `install.ps1`

**Interfaces:**
- Produces: Bash payload download with connect timeout 10 seconds and total
  timeout 90 seconds; PowerShell payload request with `TimeoutSec 90`.

- [ ] **Step 1: Add Bash RED option assertions**

Make fake `curl` capture arguments and, after key-only installation, require:

```bash
assert_contains "$curl_args" '--connect-timeout'
assert_contains "$curl_args" '10'
assert_contains "$curl_args" '--max-time'
assert_contains "$curl_args" '90'
```

Keep the existing failed-download atomicity assertion.

- [ ] **Step 2: Add PowerShell RED timeout assertion**

Add `[int]$TimeoutSec` to the mocked `Invoke-WebRequest` and fail unless it is
exactly 90:

```powershell
if ($TimeoutSec -ne 90) {
  throw "fixture binary download timeout was $TimeoutSec instead of 90"
}
```

- [ ] **Step 3: Run tests and verify RED**

Run `bash tests/test-install-key-only.sh` locally and
`.\tests\test-install-key-only.ps1` on Windows.

Expected: both fail because production binary downloads have no timeouts.

- [ ] **Step 4: Implement bounded downloads**

Use these exact platform calls:

```bash
curl -fL --connect-timeout 10 --max-time 90 "$url" -o "${tmp}/${asset}"
```

```powershell
Invoke-WebRequest -UseBasicParsing -TimeoutSec 90 -Uri $Url -OutFile $ZipPath
```

Do not add unbounded retries or change temporary staging and archive validation.

- [ ] **Step 5: Run installer tests and verify GREEN**

Run `bash tests/test-install-key-only.sh` and native
`.\tests\test-install-key-only.ps1`.

Expected: both key-only installer suites pass.

- [ ] **Step 6: Commit payload bounds**

```bash
git add scripts/setup.sh install.ps1 tests/test-install-key-only.sh tests/test-install-key-only.ps1
git commit -m "fix: bound platform binary downloads"
```

### Task 5: Prepare The Immutable v0.2.3 Contract

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `AGENT_INSTALL.md`
- Modify: `README.md`
- Modify: `cmd/image2-mcp/main.go`
- Modify: `cmd/image2-mcp/main_test.go`
- Modify: `install.ps1`
- Modify: `scripts/bootstrap-agent-install.ps1`
- Modify: `scripts/bootstrap-agent-install.sh`
- Modify: `scripts/setup.sh`
- Modify: `tests/test-agent-bootstrap.ps1`
- Modify: `tests/test-agent-bootstrap.sh`
- Modify: `tests/test-agent-install-contract.sh`
- Modify: `tests/test-install-key-only.ps1`
- Modify: `tests/test-install-key-only.sh`
- Modify: `docs/superpowers/specs/2026-08-24-fast-key-only-install-design.md`

**Interfaces:**
- Produces: exact `v0.2.3` workflow, source roots, Release URLs, binary version,
  documentation, and fixtures.

- [ ] **Step 1: Change contract tests to expect v0.2.3**

Replace active `v0.2.2` expectations in tests with `v0.2.3`, including
`image2-mcp-0.2.3` archive roots and `serverVersion == "0.2.3"`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/test-agent-install-contract.sh
bash tests/test-agent-bootstrap.sh
bash tests/test-install-key-only.sh
go test ./...
```

Expected: failures name remaining production `v0.2.2` references.

- [ ] **Step 3: Replace active production references**

Change fixed Release/API/page/archive/download URLs, source roots, workflow tag,
README release commands, and server version to `v0.2.3`/`0.2.3`. Do not rewrite
historical `v0.2.1` or `v0.2.2` descriptions in older design/plan documents.
Change the new design status to `approved design; implemented` only after all
tests pass.

- [ ] **Step 4: Verify no active old contract remains**

Run:

```bash
rg -n 'v0\.2\.2|0\.2\.2' \
  AGENT_INSTALL.md README.md .github/workflows/release.yml cmd install.ps1 scripts tests
```

Expected: no output.

- [ ] **Step 5: Run the complete local suite**

Run:

```bash
bash -n scripts/bootstrap-agent-install.sh
bash -n scripts/setup.sh
bash tests/test-agent-install-contract.sh
bash tests/test-agent-bootstrap.sh
bash tests/test-install-key-only.sh
go test ./...
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 6: Commit the release contract**

```bash
git add -A
git commit -m "release: prepare v0.2.3"
```

### Task 6: Publish And Verify v0.2.3

**Files:**
- Git ref: `main`
- Git tag: `v0.2.3`

**Interfaces:**
- Consumes: reviewed and locally green release commit.
- Produces: public non-draft/non-prerelease `v0.2.3` with six exact assets.

- [ ] **Step 1: Verify remote refs before mutation**

Run:

```bash
git ls-remote --heads fork main
git ls-remote --tags fork 'refs/tags/v0.2.1' 'refs/tags/v0.2.2' 'refs/tags/v0.2.3*'
```

Expected: old tags exist and `v0.2.3` does not.

- [ ] **Step 2: Push default branch and annotated tag**

```bash
git push fork HEAD:main
git tag -a v0.2.3 -m "Image2 MCP v0.2.3"
git push fork v0.2.3
```

Never force-push or move an old tag.

- [ ] **Step 3: Wait for the exact Release workflow**

Use `gh run list` to locate the `v0.2.3` tag run, then:

```bash
gh run watch RUN_ID --repo Schyler0427/image2-mcp --exit-status
```

Expected: Ubuntu installer tests, Windows PowerShell installer tests, and all
six platform builds succeed.

- [ ] **Step 4: Verify public Release metadata and assets**

Fetch `repos/Schyler0427/image2-mcp/releases/tags/v0.2.3` and assert exact tag,
`draft=false`, `prerelease=false`, and these six names:

```text
image2-mcp_darwin_arm64.tar.gz
image2-mcp_darwin_amd64.tar.gz
image2-mcp_linux_arm64.tar.gz
image2-mcp_linux_amd64.tar.gz
image2-mcp_windows_arm64.zip
image2-mcp_windows_amd64.zip
```

Require HTTP 200 for each public asset URL.

- [ ] **Step 5: Verify delivered source and raw helpers**

Fetch both raw helpers from `main` and the `v0.2.3` source archive. Require the
page-first route, 15-second metadata timeout, 60-second source timeout,
90-second binary timeout, single-turn Agent wording, Windows current-user ACL,
and fixed `v0.2.3` URLs. Do not invoke either image endpoint.

- [ ] **Step 6: Report exact release evidence**

Report commit SHA, workflow URL/status, Release URL, six-asset result, raw
helper result, and any skipped local-only check. Do not report a success before
fresh remote verification is complete.
