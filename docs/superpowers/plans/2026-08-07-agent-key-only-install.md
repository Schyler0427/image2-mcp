# Image2 MCP Agent Key-Only Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a customer send one fixed sentence to an Agent, enter only an API Key, and receive a verified Image2 MCP installation from `Schyler0427/image2-mcp`.

**Architecture:** Keep the existing Bash and PowerShell installers as the platform entry points and add a strict key-only preset to each. A root `AGENT_INSTALL.md` owns Git/archive bootstrapping into fixed user-data directories, while mocked installer tests exercise secret handling, Release extraction, atomic config replacement, and non-billable verification without using a real key or network service.

**Tech Stack:** Bash 3.2+, Windows PowerShell 5.1+, Go 1.25, GitHub Actions, GitHub Releases, Codex TOML configuration.

## Global Constraints

- The only customer-supplied value is `OPENAI_IMAGE_API_KEY`.
- Repository is fixed to `https://github.com/Schyler0427/image2-mcp` and slug `Schyler0427/image2-mcp`.
- Base URL is fixed to `https://api.schyler.top` in key-only mode.
- Install directory is `$HOME/.local/share/image2-mcp` on macOS/Linux and `%LOCALAPPDATA%\image2-mcp` on Windows.
- Key-only installation always downloads a prebuilt Release and never requires Git or Go on the customer machine.
- The API Key must never appear in command arguments, Codex config, or output, including partial and derived forms.
- Key-only mode reads one key line exactly once; blank or whitespace-only input fails without re-prompting.
- Only the `mcp_servers.image2` TOML namespace may be replaced; all unrelated Codex configuration must be preserved.
- Installation verification is local and must not call an image API.
- Existing non-key-only installer modes remain behaviorally compatible.
- Customer rollout is blocked until a public, non-prerelease `v0.2.1` Release contains all six platform assets.

## File Structure

- Create `tests/test-install-key-only.sh`: dependency-free Bash integration tests with fake Release downloads and isolated `HOME`.
- Create `tests/test-install-key-only.ps1`: Windows integration tests with fake Release downloads and isolated user directories.
- Create `tests/test-agent-install-contract.sh`: static contract test for customer prompt constants and fixed bootstrap commands.
- Modify `scripts/setup.sh`: Bash key-only preset, secret input, atomic env/config/binary writes, and verification.
- Modify `install.ps1`: PowerShell parity for key-only behavior and verification.
- Create `AGENT_INSTALL.md`: deterministic Agent instructions for Git and no-Git bootstrap paths.
- Modify `.gitignore`: ignore the local managed-install identity marker.
- Modify `README.md`: make the one-sentence Agent flow the primary customer installation path while retaining maintainer instructions.
- Modify `cmd/image2-mcp/main.go`: report server version `0.2.1` through a named constant.
- Modify `cmd/image2-mcp/main_test.go`: assert the published MCP version.
- Modify `.github/workflows/release.yml`: gate all Release builds on Bash and Windows installer tests.

---

### Task 1: Bash Key-Only Installation

**Files:**
- Create: `tests/test-install-key-only.sh`
- Modify: `scripts/setup.sh`

**Interfaces:**
- Consumes: `install.sh` forwarding arguments to `scripts/setup.sh`, GitHub asset naming already used by `download_prebuilt`.
- Produces: `./install.sh --key-only`; sourceable helpers `platform_name`, `arch_name`, `remove_image2_config_namespace`; successful output containing `Verification: OK` but no key material.

- [ ] **Step 1: Add a failing Bash integration test**

Create an executable `tests/test-install-key-only.sh`. The test copies the repository scripts into a temporary installation, prepends a fake `curl` that copies a fixture archive, isolates `HOME`, and invokes the real entry point:

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "$1 does not contain $2"; }
assert_not_contains() { ! grep -Fq "$2" "$1" || fail "$1 contains secret text"; }

home="$tmp/home"
repo="$tmp/repo"
fakebin="$tmp/bin"
fixture="$tmp/image2-mcp.tar.gz"
mkdir -p "$home/.codex" "$repo/scripts" "$fakebin" "$tmp/payload"
cp "$root/install.sh" "$repo/install.sh"
cp "$root/scripts/setup.sh" "$repo/scripts/setup.sh"
cp "$root/scripts/run-image2-mcp.sh" "$repo/scripts/run-image2-mcp.sh"
chmod +x "$repo/install.sh" "$repo/scripts/"*.sh

cat > "$tmp/payload/image2-mcp" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod +x "$tmp/payload/image2-mcp"
tar -czf "$fixture" -C "$tmp/payload" image2-mcp

cat > "$fakebin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$IMAGE2_MCP_TEST_ASSET" "$out"
CURL
chmod +x "$fakebin/curl"

cat > "$home/.codex/config.toml" <<'TOML'
model = "gpt-5"

[mcp_servers.image2]
command = "/old/runner"

[mcp_servers.image2.env]
OLD = "value"

[mcp_servers.keep]
command = "/keep/runner"
TOML

secret='sk-test-do-not-print'
output="$tmp/output.log"
printf '%s\nignored-second-line\n' "$secret" |
  HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  IMAGE2_MCP_REPO='Schyler0427/image2-mcp' \
  "$repo/install.sh" --key-only >"$output" 2>&1

assert_contains "$output" 'Verification: OK'
assert_not_contains "$output" "$secret"
assert_contains "$repo/.env.local" 'OPENAI_IMAGE_BASE_URL=https://api.schyler.top'
assert_contains "$repo/.env.local" 'OPENAI_IMAGE_API_KEY='
assert_contains "$home/.codex/config.toml" 'model = "gpt-5"'
assert_contains "$home/.codex/config.toml" '[mcp_servers.keep]'
assert_not_contains "$home/.codex/config.toml" '/old/runner'
assert_not_contains "$home/.codex/config.toml" 'OLD = "value"'
[[ "$(grep -c '^\[mcp_servers\.image2\]$' "$home/.codex/config.toml")" -eq 1 ]] || fail 'image2 root table count is not 1'
[[ "$(stat -f '%Lp' "$repo/.env.local" 2>/dev/null || stat -c '%a' "$repo/.env.local")" == 600 ]] || fail '.env.local mode is not 600'
[[ -x "$repo/dist/image2-mcp" ]] || fail 'binary is missing or not executable'
(
  set -a
  source "$repo/.env.local"
  set +a
  [[ "$OPENAI_IMAGE_API_KEY" == "$secret" ]] || fail 'stored key did not round-trip'
  [[ "$OPENAI_IMAGE_BASE_URL" == 'https://api.schyler.top' ]] || fail 'stored base URL is not fixed'
)

before="$(cksum "$repo/.env.local")"
if printf '   \n' | HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/blank.log" 2>&1; then
  fail 'blank key unexpectedly succeeded'
fi
[[ "$(cksum "$repo/.env.local")" == "$before" ]] || fail 'blank key changed .env.local'

if printf '%s\n' "$secret" | HOME="$home" "$repo/install.sh" --key-only --base-url https://example.invalid \
  >"$tmp/conflict.log" 2>&1; then
  fail 'conflicting key-only flags unexpectedly succeeded'
fi

source "$root/scripts/setup.sh"
[[ "$(platform_name Darwin)" == darwin ]] || fail 'Darwin mapping failed'
[[ "$(platform_name Linux)" == linux ]] || fail 'Linux mapping failed'
[[ "$(arch_name arm64)" == arm64 ]] || fail 'arm64 mapping failed'
[[ "$(arch_name aarch64)" == arm64 ]] || fail 'aarch64 mapping failed'
[[ "$(arch_name x86_64)" == amd64 ]] || fail 'x86_64 mapping failed'
[[ "$(arch_name amd64)" == amd64 ]] || fail 'amd64 mapping failed'
if platform_name FreeBSD >/dev/null 2>&1 || arch_name riscv64 >/dev/null 2>&1; then
  fail 'unsupported target mapping unexpectedly succeeded'
fi

printf 'PASS: Bash key-only installer\n'
```

- [ ] **Step 2: Run the test and verify the new mode is missing**

Run: `bash tests/test-install-key-only.sh`

Expected: non-zero exit with `error: unknown option: --key-only`.

- [ ] **Step 3: Refactor `scripts/setup.sh` into sourceable helpers**

Wrap argument handling and execution in `main()` and use this guard so tests can source mapping/config helpers without performing an install. Make `platform_name` and `arch_name` accept an optional value for deterministic tests, defaulting to `uname -s` and `uname -m` in production:

```bash
main() {
  parse_args "$@"
  apply_mode_defaults
  run_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

Keep legacy defaults unchanged. Add `--key-only` to usage and reject every behavior-changing flag combined with it. `apply_mode_defaults` must assign:

```bash
readonly_key_only_base_url='https://api.schyler.top'
readonly_key_only_repo='Schyler0427/image2-mcp'

if [[ "$key_only" -eq 1 ]]; then
  base_url="$readonly_key_only_base_url"
  configure_codex=1
  force_config=1
  prefer_prebuilt=1
  run_tests=0
  run_smoke=0
  export IMAGE2_MCP_REPO="$readonly_key_only_repo"
fi
```

- [ ] **Step 4: Implement one-read secret handling and atomic `.env.local`**

Add these interfaces and call them before downloading in key-only mode:

```bash
restore_terminal_echo() {
  if [[ "${key_input_echo_disabled:-0}" -eq 1 ]]; then
    stty echo 2>/dev/null || true
    key_input_echo_disabled=0
  fi
}

read_key_once() {
  local value
  printf 'OPENAI_IMAGE_API_KEY: ' >&2
  if [[ -t 0 ]]; then
    trap restore_terminal_echo EXIT HUP INT TERM
    stty -echo
    key_input_echo_disabled=1
  fi
  IFS= read -r value || {
    restore_terminal_echo
    printf '\nerror: API Key input was not received\n' >&2
    return 1
  }
  restore_terminal_echo
  printf '\n' >&2
  [[ "$value" == *$'\r'* ]] && { echo 'error: API Key must be one line' >&2; return 1; }
  [[ "$value" =~ [^[:space:]] ]] || { echo 'error: API Key cannot be blank' >&2; return 1; }
  key_only_api_key="$value"
}

write_key_only_env() {
  local target="${repo_dir}/.env.local" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  chmod 600 "$tmp"
  {
    printf 'OPENAI_IMAGE_BASE_URL=%q\n' "$readonly_key_only_base_url"
    printf 'OPENAI_IMAGE_API_KEY=%q\n' "$key_only_api_key"
  } >"$tmp"
  mv -f "$tmp" "$target"
  chmod 600 "$target"
}
```

Do not load `.env` in key-only mode. Explicitly export the two values after the atomic write so verification uses only the newly entered key and fixed URL.

- [ ] **Step 5: Make binary and Codex config replacement atomic**

Change `download_prebuilt` to extract into its temporary directory, verify the expected `image2-mcp` file, apply execute permission, and rename it into `dist` only after all checks pass. Replace `remove_image2_config_block` with an AWK namespace filter:

```bash
remove_image2_config_namespace() {
  local input="$1" output="$2"
  awk '
    function image2_header(line) {
      return line ~ /^[[:space:]]*\[mcp_servers\.image2(\.[^]]+)?\][[:space:]]*(#.*)?$/
    }
    function table_header(line) {
      return line ~ /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/
    }
    {
      if (table_header($0)) skip = image2_header($0)
      if (!skip) print
    }
  ' "$input" >"$output"
}
```

Before filtering, reject a table header that mentions the Image2 namespace but is not recognized. Write the new config to a same-directory temporary file, append one TOML-escaped runner block, verify exactly one root table and no `OPENAI_IMAGE_API_KEY`, then rename over the original. Extend the integration test with a fake `curl` failure and assert the checksum of an existing working binary is unchanged.

- [ ] **Step 6: Add non-billable verification**

Implement and call `verify_key_only_install` after config writing:

```bash
verify_key_only_install() {
  local binary="${repo_dir}/dist/image2-mcp"
  local runner="${repo_dir}/scripts/run-image2-mcp.sh"
  local config="${HOME}/.codex/config.toml"
  [[ -s "$binary" && -x "$binary" ]] || { echo 'error: binary verification failed' >&2; return 1; }
  [[ -x "$runner" ]] || { echo 'error: runner verification failed' >&2; return 1; }
  "$runner" </dev/null >/dev/null 2>"${repo_dir}/.verify-image2-mcp.log" || {
    rm -f "${repo_dir}/.verify-image2-mcp.log"
    echo 'error: runner startup verification failed' >&2
    return 1
  }
  rm -f "${repo_dir}/.verify-image2-mcp.log"
  [[ "$OPENAI_IMAGE_BASE_URL" == "$readonly_key_only_base_url" && -n "$OPENAI_IMAGE_API_KEY" ]] || {
    echo 'error: environment verification failed' >&2
    return 1
  }
  [[ "$(grep -c '^\[mcp_servers\.image2\]$' "$config")" -eq 1 ]] || {
    echo 'error: Codex config verification failed' >&2
    return 1
  }
  ! grep -q 'OPENAI_IMAGE_API_KEY' "$config" || {
    echo 'error: Codex config contains forbidden key setting' >&2
    return 1
  }
  echo 'Verification: OK'
}
```

Never print the runner's stderr because it could include environment-derived errors. Remove the temporary log on success and failure.

- [ ] **Step 7: Run Bash tests and existing Go tests**

Run:

```bash
bash -n install.sh scripts/setup.sh scripts/run-image2-mcp.sh tests/test-install-key-only.sh
bash tests/test-install-key-only.sh
go test ./...
```

Expected: syntax checks produce no output; installer test prints `PASS: Bash key-only installer`; all Go packages pass.

- [ ] **Step 8: Commit the Bash deliverable**

```bash
git add scripts/setup.sh tests/test-install-key-only.sh
git commit -m "feat: add Bash key-only installation"
```

### Task 2: PowerShell Key-Only Installation

**Files:**
- Create: `tests/test-install-key-only.ps1`
- Modify: `install.ps1`

**Interfaces:**
- Consumes: the fixed values and behavior produced by Task 1.
- Produces: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -KeyOnly`; `Remove-Image2ConfigNamespace`; `Test-KeyOnlyInstall`; output parity with Bash.

- [ ] **Step 1: Add a failing Windows integration test**

Create `tests/test-install-key-only.ps1` with strict assertions, isolated `USERPROFILE`/`HOME`/`LOCALAPPDATA`, a fixture ZIP containing an `image2-mcp.exe` command shim, and a mocked Release download selected by `IMAGE2_MCP_TEST_RELEASE_ZIP`. The key invocation and central assertions are:

```powershell
$SecretText = "sk-test-do-not-print"
$Output = @($SecretText, "ignored-second-line") |
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer -KeyOnly 2>&1 |
  Out-String

Assert-True ($LASTEXITCODE -eq 0) "Key-only install failed"
Assert-True ($Output.Contains("Verification: OK")) "Verification marker missing"
Assert-True (-not $Output.Contains($SecretText)) "Secret leaked to output"
Assert-True ((Get-Content $ConfigFile -Raw).Contains("[mcp_servers.keep]")) "Unrelated MCP config was removed"
Assert-True (-not (Get-Content $ConfigFile -Raw).Contains("/old/runner")) "Old Image2 config remains"
Assert-True ((Select-String -Path $ConfigFile -Pattern '^\[mcp_servers\.image2\]$').Count -eq 1) "Image2 table count is not one"
```

Add separate blank-key and conflicting-option assertions. Record the old `.env.local` checksum and assert it is unchanged after blank input. Test both `AMD64` and `ARM64` asset-name mapping plus rejection of an unsupported architecture. Make the fake download fail once and assert an existing working binary is unchanged. The fixture executable is a copy of `$env:COMSPEC`, exits zero with closed stdin, and never accesses the network.

- [ ] **Step 2: Run the Windows test and verify `-KeyOnly` is missing**

Run on `windows-latest` or a Windows development host:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-install-key-only.ps1
```

Expected: non-zero exit reporting that parameter `KeyOnly` cannot be found.

- [ ] **Step 3: Add the strict PowerShell preset and one-read key input**

Add `[switch]$KeyOnly` to the parameter block. Reject it when any legacy behavior-changing parameter is explicitly bound by checking `$PSBoundParameters.Keys`. Apply these values:

```powershell
$KeyOnlyBaseUrl = "https://api.schyler.top"
$KeyOnlyRepo = "Schyler0427/image2-mcp"

if ($KeyOnly) {
  $Conflicts = @($PSBoundParameters.Keys | Where-Object { $_ -notin @("KeyOnly") })
  if ($Conflicts.Count -gt 0) {
    throw "-KeyOnly cannot be combined with other options"
  }
  $BaseUrl = $KeyOnlyBaseUrl
  $ConfigureCodex = $true
  $ForceConfig = $true
  $Prebuilt = $true
  $SkipTests = $true
  $Smoke = $false
  $env:IMAGE2_MCP_REPO = $KeyOnlyRepo
}
```

Use `Read-Host -AsSecureString` only when input is interactive; otherwise call `[Console]::In.ReadLine()` once. Convert secure input through BSTR inside a `try/finally` that calls `ZeroFreeBSTR`. Reject blank, CR, LF, or NUL input immediately.

- [ ] **Step 4: Implement round-trip dotenv storage and Windows ACLs**

Make `ConvertTo-DotEnvValue` and `ConvertFrom-DotEnvValue` exact inverses for backslash, quote, carriage return, and tab escapes. Write UTF-8 without BOM to a sibling temporary file and atomically move it into place. Preserve the existing Windows ACL and add a full-control rule for the current user without disabling inheritance or requiring elevation:

```powershell
$Security = Get-Acl -Path $EnvFile
$CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
  $CurrentSid,
  [System.Security.AccessControl.FileSystemRights]::FullControl,
  [System.Security.AccessControl.AccessControlType]::Allow
)
$Security.SetAccessRule($Rule)
Set-Acl -Path $EnvFile -AclObject $Security
```

An ACL failure is fatal and must not print the key.

- [ ] **Step 5: Add atomic binary/config replacement and verification**

Implement `Remove-Image2ConfigNamespace` with the same accepted table syntax as the Bash AWK function. Write the filtered content plus one escaped Windows runner block to a temporary file; validate the root table count, expected runner, and absence of `OPENAI_IMAGE_API_KEY`; then replace `config.toml`.

`Install-Prebuilt` uses `IMAGE2_MCP_TEST_RELEASE_ZIP` only when that variable is present, otherwise retains the fixed GitHub URL. Extract to a temporary directory and replace `dist\image2-mcp.exe` only after it exists and is non-empty.

`Test-KeyOnlyInstall` starts the runner using an empty temporary file as `-RedirectStandardInput`, waits for exit code zero, checks `.env.local` through `Import-DotEnv`, and prints exactly `Verification: OK` on success.

- [ ] **Step 6: Run the PowerShell and Go tests**

Run on Windows:

```powershell
powershell.exe -NoProfile -Command "$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\install.ps1'), [ref]$null, [ref]$errors); if ($errors.Count) { $errors; exit 1 }"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-install-key-only.ps1
go test ./...
```

Expected: no parser errors; installer test prints `PASS: PowerShell key-only installer`; all Go packages pass.

- [ ] **Step 7: Commit the Windows deliverable**

```bash
git add install.ps1 tests/test-install-key-only.ps1
git commit -m "feat: add PowerShell key-only installation"
```

### Task 3: Agent Bootstrap Contract

**Files:**
- Create: `AGENT_INSTALL.md`
- Create: `tests/test-agent-install-contract.sh`
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1 `--key-only` and Task 2 `-KeyOnly` commands.
- Produces: the exact raw GitHub instruction URL used in the customer sentence and deterministic fixed-directory bootstrap procedures.

- [ ] **Step 1: Add a failing contract test**

Create `tests/test-agent-install-contract.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doc="$root/AGENT_INSTALL.md"
[[ -f "$doc" ]] || { echo 'FAIL: AGENT_INSTALL.md missing' >&2; exit 1; }
for required in \
  'https://github.com/Schyler0427/image2-mcp' \
  'Schyler0427/image2-mcp' \
  'https://api.schyler.top' \
  '$HOME/.local/share/image2-mcp' \
  '%LOCALAPPDATA%\image2-mcp' \
  './install.sh --key-only' \
  '.\install.ps1 -KeyOnly' \
  '.image2-mcp-managed'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: missing $required" >&2; exit 1; }
done
if grep -Eiq 'ask (for|the user for).*(url|path|repo|branch|go)|T[B]D|TO[D]O|<yo[u]r' "$doc"; then
  echo 'FAIL: Agent guide contains a forbidden prompt or placeholder' >&2
  exit 1
fi
echo 'PASS: Agent install contract'
```

- [ ] **Step 2: Run the contract test and verify the guide is missing**

Run: `bash tests/test-agent-install-contract.sh`

Expected: `FAIL: AGENT_INSTALL.md missing`.

- [ ] **Step 3: Write the deterministic Agent guide**

Create `AGENT_INSTALL.md` with these exact normative sections:

```markdown
# Image2 MCP Agent Installation

Follow this procedure to completion. Do not ask the customer for any value
except `OPENAI_IMAGE_API_KEY`. Never print the key or place it in a command.

## Fixed values

- Repository: `https://github.com/Schyler0427/image2-mcp`
- Base URL: `https://api.schyler.top`
- macOS/Linux target: `$HOME/.local/share/image2-mcp`
- Windows target: `%LOCALAPPDATA%\image2-mcp`

## Secret input

Start the platform key-only installer and let it read one line from standard
input. If chat collection is required, ask exactly `请输入 API Key：`, then feed
the response to the already-running process through standard input. Never use a
command argument or printed environment assignment.

## Completion

Do not stop after download. Require `Verification: OK`, report installed paths
and `API Key 已配置（未显示）`, then tell the customer to restart Codex or open a
new task.
```

Between those sections include complete macOS/Linux and Windows algorithms that:

- detect only the six supported Release targets;
- stage a shallow Git clone when Git exists;
- otherwise download the default-branch archive with curl/wget or `Invoke-WebRequest` and set `IMAGE2_MCP_REPO=Schyler0427/image2-mcp` for the child installer process;
- validate `install.sh`, `install.ps1`, `scripts/`, and `go.mod` before moving;
- write `.image2-mcp-managed` containing only the fixed slug;
- on repeat installs, accept only the fixed Git remote or matching marker;
- preserve `.env.local` and `output/` in a sibling backup;
- restore the old target if bootstrap or installer verification fails;
- run only the key-only command for the detected platform;
- delete temporary and backup directories only after success.

- [ ] **Step 4: Update customer and repository metadata**

Add `.image2-mcp-managed` to `.gitignore`. At the top of README installation instructions, add the exact customer sentence in a fenced text block and state that the customer only enters the API Key. Keep existing options below under a `维护者和高级安装` heading.

- [ ] **Step 5: Run guide and regression checks**

Run:

```bash
bash tests/test-agent-install-contract.sh
bash tests/test-install-key-only.sh
git diff --check
go test ./...
```

Expected: both shell tests print `PASS`; diff check has no output; Go tests pass.

- [ ] **Step 6: Commit the customer flow**

```bash
git add AGENT_INSTALL.md README.md .gitignore tests/test-agent-install-contract.sh
git commit -m "docs: add one-sentence Agent installation"
```

### Task 4: Version and Release Gates

**Files:**
- Modify: `cmd/image2-mcp/main.go`
- Modify: `cmd/image2-mcp/main_test.go`
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: all tests from Tasks 1-3.
- Produces: MCP implementation version `0.2.1`; a Release build that cannot publish assets unless Linux Bash and Windows PowerShell installer tests pass.

- [ ] **Step 1: Add a failing version assertion**

Add this test first:

```go
func TestServerVersion(t *testing.T) {
	if serverVersion != "0.2.1" {
		t.Fatalf("serverVersion = %q, want 0.2.1", serverVersion)
	}
}
```

Run: `go test ./cmd/image2-mcp -run TestServerVersion -count=1`

Expected: FAIL because `serverVersion` is not yet defined.

- [ ] **Step 2: Implement the version constant**

Add and use:

```go
const serverVersion = "0.2.1"

server := mcp.NewServer(&mcp.Implementation{
	Name:    "image2-mcp",
	Version: serverVersion,
}, &mcp.ServerOptions{
```

Run the focused test again and expect PASS.

- [ ] **Step 3: Gate Release assets on installer tests**

Add an `installer-tests` job with Ubuntu and Windows matrix entries. Add `needs: installer-tests` to the existing `build` job:

```yaml
  installer-tests:
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Test Bash installer
        if: runner.os == 'Linux'
        run: |
          bash tests/test-install-key-only.sh
          bash tests/test-agent-install-contract.sh
      - name: Test PowerShell installer
        if: runner.os == 'Windows'
        shell: powershell
        run: .\tests\test-install-key-only.ps1

  build:
    needs: installer-tests
```

- [ ] **Step 4: Run the full local suite and inspect workflow syntax**

Run:

```bash
bash tests/test-install-key-only.sh
bash tests/test-agent-install-contract.sh
go test ./...
git diff --check
```

Expected: both script tests and all Go tests pass; diff check has no output. Inspect `.github/workflows/release.yml` and confirm the matrix still contains all six asset names from the design spec.

- [ ] **Step 5: Commit release readiness**

```bash
git add cmd/image2-mcp/main.go cmd/image2-mcp/main_test.go .github/workflows/release.yml
git commit -m "ci: gate v0.2.1 release on installer tests"
```

### Task 5: End-to-End Verification and Publication

**Files:**
- Verify only; do not create source changes unless a failing check identifies a defect.

**Interfaces:**
- Consumes: reviewed commits from Tasks 1-4 and Git push access to `Schyler0427/image2-mcp`.
- Produces: fork default branch containing the installer, public `v0.2.1` Release with six assets, and acceptance evidence for the customer sentence.

- [ ] **Step 1: Run a clean local verification**

Run:

```bash
bash -n install.sh scripts/setup.sh scripts/run-image2-mcp.sh tests/test-install-key-only.sh tests/test-agent-install-contract.sh
bash tests/test-install-key-only.sh
bash tests/test-agent-install-contract.sh
go test ./...
go build -o ./dist/image2-mcp ./cmd/image2-mcp
git diff --check
git status --short
```

Expected: all commands pass; status contains no uncommitted source changes other than ignored `dist/` output.

- [ ] **Step 2: Review the complete branch against the approved spec**

Run:

```bash
git diff --stat fork/main...HEAD
git log --oneline fork/main..HEAD
```

Confirm the diff contains only the already-approved Image2 edit hardening plus the key-only installation files, and does not modify upstream PR #1.

- [ ] **Step 3: Update the fork default branch**

Fetch and verify that `fork/main` is still an ancestor of the reviewed HEAD, then push the reviewed commit as a fast-forward only:

```bash
git fetch fork main
git merge-base --is-ancestor fork/main HEAD
git push fork HEAD:main
```

Expected: the ancestry check exits zero and Git reports a fast-forward update. If the remote moved and the ancestry check fails, stop and integrate the new remote state without force-pushing.

- [ ] **Step 4: Publish `v0.2.1`**

Create the tag only after the fork default branch points at the reviewed commit:

```bash
git tag -a v0.2.1 -m "Image2 MCP v0.2.1"
git push fork v0.2.1
```

Do not reuse or force-update an existing tag. If the tag already exists, inspect it and stop unless it points at the exact reviewed commit.

- [ ] **Step 5: Verify the public Release and all assets**

Poll the public GitHub API until the workflow completes, then require these exact asset names:

```text
image2-mcp_darwin_arm64.tar.gz
image2-mcp_darwin_amd64.tar.gz
image2-mcp_linux_arm64.tar.gz
image2-mcp_linux_amd64.tar.gz
image2-mcp_windows_arm64.zip
image2-mcp_windows_amd64.zip
```

Download the current macOS asset to a temporary directory, extract it, and run it with closed stdin to verify the published artifact rather than the local build. Do not expose or use a customer API Key.

- [ ] **Step 6: Run Agent-driven acceptance checks**

In a temporary macOS `HOME`, follow the public `AGENT_INSTALL.md`, feed a test key through stdin, and confirm `Verification: OK`, fixed paths, config preservation, and no key in output. Run the same public procedure on a Windows host or the successful `windows-latest` acceptance job. Neither check makes an image API request.

- [ ] **Step 7: Deliver the customer sentence**

Return exactly this ready-to-send instruction, followed by the verified Release version and supported platforms:

```text
请安装并配置 Image2 MCP：读取并严格执行 https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/AGENT_INSTALL.md，除 API Key 外不要向我询问其他配置，完成安装和验证后再结束。
```
