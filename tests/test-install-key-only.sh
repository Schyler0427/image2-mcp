#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 contains secret text"; }
assert_line() { grep -Fxq "$2" "$1" || fail "$1 does not preserve $2"; }
file_fingerprint() {
  if [[ -e "$1" ]]; then
    cksum "$1"
  else
    printf 'absent\n'
  fi
}
file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

if grep -Fq 'IMAGE2_MCP_TEST_RELEASE_ZIP' "$root/install.ps1"; then
  fail 'production PowerShell installer contains a local Release override'
fi

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
if [[ -n "${IMAGE2_MCP_TEST_CURL_ARGS:-}" ]]; then
  printf '%s\n' "$*" >"$IMAGE2_MCP_TEST_CURL_ARGS"
fi
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "${IMAGE2_MCP_TEST_CURL_FAIL:-0}" == 1 ]]; then
  exit 22
fi
cp "$IMAGE2_MCP_TEST_ASSET" "$out"
CURL
chmod +x "$fakebin/curl"

cat > "$home/.codex/config.toml" <<'TOML'
model = "gpt-5"

[mcp_servers.image2]
command = "/old/runner"

[[profiles]]
name = "keep-array"
command = "/keep/array-runner"

[mcp_servers.image2.env]
OLD = "value"

[mcp_servers.keep]
command = "/keep/runner"

[mcp_servers.image20]
command = "/keep/image20-runner"
TOML

help_config_before="$(cksum "$home/.codex/config.toml")"
help_output="$tmp/help.log"
HOME="$home" "$repo/install.sh" --help </dev/null >"$help_output" 2>&1 || fail '--help unexpectedly failed'
assert_contains "$help_output" 'Usage: ./install.sh [options]'
assert_not_contains "$help_output" 'Downloading prebuilt binary'
[[ "$(cksum "$home/.codex/config.toml")" == "$help_config_before" ]] || fail '--help changed Codex config'
[[ ! -e "$repo/.env.local" ]] || fail '--help wrote .env.local'
[[ ! -e "$repo/dist" ]] || fail '--help created dist'

key_help_output="$tmp/key-help.log"
HOME="$home" "$repo/install.sh" --key-only --help </dev/null >"$key_help_output" 2>&1 || fail '--key-only --help unexpectedly failed'
assert_contains "$key_help_output" 'Usage: ./install.sh [options]'
assert_not_contains "$key_help_output" 'OPENAI_IMAGE_API_KEY:'
[[ "$(cksum "$home/.codex/config.toml")" == "$help_config_before" ]] || fail '--key-only --help changed Codex config'
[[ ! -e "$repo/.env.local" ]] || fail '--key-only --help wrote .env.local'
[[ ! -e "$repo/dist" ]] || fail '--key-only --help created dist'

secret='sk-test-do-not-print'
output="$tmp/output.log"
curl_args="$tmp/curl-args.log"
printf '%s\nignored-second-line\n' "$secret" |
  HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  IMAGE2_MCP_TEST_CURL_ARGS="$curl_args" \
  IMAGE2_MCP_REPO='Schyler0427/image2-mcp' \
  "$repo/install.sh" --key-only >"$output" 2>&1

assert_contains "$output" 'Verification: OK'
source "$root/scripts/setup.sh"
expected_asset="image2-mcp_$(platform_name)_$(arch_name).tar.gz"
assert_contains "$output" "https://github.com/Schyler0427/image2-mcp/releases/download/v0.2.3/$expected_asset"
assert_contains "$curl_args" '--connect-timeout'
assert_contains "$curl_args" '10'
assert_contains "$curl_args" '--max-time'
assert_contains "$curl_args" '90'

wget_repo="$tmp/wget-repo"
wget_args="$tmp/wget-args.log"
mkdir -p "$wget_repo"
(
  source "$root/scripts/setup.sh"
  repo_dir="$wget_repo"
  key_only=1
  IMAGE2_MCP_REPO='Schyler0427/image2-mcp'
  command() {
    if [[ "$1" == '-v' && "$2" == 'curl' ]]; then
      return 1
    fi
    if [[ "$1" == '-v' && "$2" == 'wget' ]]; then
      return 0
    fi
    builtin command "$@"
  }
  wget() {
    printf '%s\n' "$*" >"$wget_args"
    local out=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -O) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "$fixture" "$out"
  }
  download_prebuilt
)
assert_contains "$wget_args" '--tries=1'
assert_contains "$wget_args" '--timeout=90'

assert_not_contains "$output" "$secret"
assert_contains "$repo/.env.local" 'OPENAI_IMAGE_BASE_URL=https://api.schyler.top'
assert_contains "$repo/.env.local" 'OPENAI_IMAGE_API_KEY='
assert_contains "$home/.codex/config.toml" 'model = "gpt-5"'
assert_contains "$home/.codex/config.toml" '[[profiles]]'
assert_contains "$home/.codex/config.toml" 'name = "keep-array"'
assert_contains "$home/.codex/config.toml" '/keep/array-runner'
assert_contains "$home/.codex/config.toml" '[mcp_servers.keep]'
assert_contains "$home/.codex/config.toml" '[mcp_servers.image20]'
assert_contains "$home/.codex/config.toml" '/keep/image20-runner'
assert_not_contains "$home/.codex/config.toml" '/old/runner'
assert_not_contains "$home/.codex/config.toml" 'OLD = "value"'
[[ "$(grep -c '^\[mcp_servers\.image2\]$' "$home/.codex/config.toml")" -eq 1 ]] || fail 'image2 root table count is not 1'
[[ "$(file_mode "$repo/.env.local")" == 600 ]] || fail '.env.local mode is not 600'
[[ -x "$repo/dist/image2-mcp" ]] || fail 'binary is missing or not executable'
(
  set -a
  source "$repo/.env.local"
  set +a
  [[ "$OPENAI_IMAGE_API_KEY" == "$secret" ]] || fail 'stored key did not round-trip'
  [[ "$OPENAI_IMAGE_BASE_URL" == 'https://api.schyler.top' ]] || fail 'stored base URL is not fixed'
)

spaced_home="$tmp/spaced-home"
mkdir -p "$spaced_home/.codex"
cat > "$spaced_home/.codex/config.toml" <<'TOML'
model = "gpt-5"

[mcp_servers . image2]
command = "/spaced/old-runner"

[mcp_servers . image2 . env]
OLD = "spaced value"

[mcp_servers.image20]
command = "/keep/image20-runner"
TOML
printf '%s\n' "$secret" | HOME="$spaced_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/spaced-header.log" 2>&1
assert_not_contains "$spaced_home/.codex/config.toml" '/spaced/old-runner'
assert_not_contains "$spaced_home/.codex/config.toml" 'spaced value'
assert_contains "$spaced_home/.codex/config.toml" '[mcp_servers.image20]'
assert_contains "$spaced_home/.codex/config.toml" '/keep/image20-runner'
[[ "$(grep -c '^\[mcp_servers\.image2\]$' "$spaced_home/.codex/config.toml")" -eq 1 ]] || fail 'spaced Image2 root table count is not 1'

before="$(cksum "$repo/dist/image2-mcp")"
if printf '%s\n' "$secret" | HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  IMAGE2_MCP_REPO='Schyler0427/image2-mcp' IMAGE2_MCP_TEST_CURL_FAIL=1 \
  "$repo/install.sh" --key-only >"$tmp/download-failure.log" 2>&1; then
  fail 'failed prebuilt download unexpectedly succeeded'
fi
[[ "$(cksum "$repo/dist/image2-mcp")" == "$before" ]] || fail 'failed download changed existing binary'

symlink_target="$tmp/external-target"
symlink_payload="$tmp/symlink-payload"
symlink_fixture="$tmp/image2-mcp-symlink.tar.gz"
printf 'external target\n' >"$symlink_target"
mkdir -p "$symlink_payload"
ln -s "$symlink_target" "$symlink_payload/image2-mcp"
tar -czf "$symlink_fixture" -C "$symlink_payload" image2-mcp
symlink_mode_before="$(file_mode "$symlink_target")"
symlink_binary_before="$(cksum "$repo/dist/image2-mcp")"
if printf '%s\n' "$secret" | HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$symlink_fixture" \
  IMAGE2_MCP_REPO='Schyler0427/image2-mcp' \
  "$repo/install.sh" --key-only >"$tmp/symlink-archive.log" 2>&1; then
  fail 'symlink prebuilt archive unexpectedly succeeded'
fi
assert_contains "$tmp/symlink-archive.log" 'prebuilt archive contains a link or unsupported path type'
[[ "$(file_mode "$symlink_target")" == "$symlink_mode_before" ]] || fail 'symlink archive changed external target'
[[ "$(cksum "$repo/dist/image2-mcp")" == "$symlink_binary_before" ]] || fail 'symlink archive changed existing binary'
[[ ! -L "$repo/dist/image2-mcp" ]] || fail 'symlink archive installed a symlink'

array_home="$tmp/array-home"
mkdir -p "$array_home/.codex"
cat > "$array_home/.codex/config.toml" <<'TOML'
model = "gpt-5"

[[mcp_servers.image2]]
command = "/ambiguous/runner"
TOML
array_before="$(cksum "$array_home/.codex/config.toml")"
if printf '%s\n' "$secret" | HOME="$array_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/array-header.log" 2>&1; then
  fail 'array-of-tables Image2 config unexpectedly succeeded'
fi
assert_contains "$tmp/array-header.log" 'unsupported Image2 TOML table header'
[[ "$(cksum "$array_home/.codex/config.toml")" == "$array_before" ]] || fail 'array-of-tables Image2 config changed'

quoted_home="$tmp/quoted-home"
mkdir -p "$quoted_home/.codex"
cat > "$quoted_home/.codex/config.toml" <<'TOML'
model = "gpt-5"

["mcp_servers"."image2"]
command = "/quoted/old-runner"

["mcp_servers"."image2"."env"]
OLD = "quoted value"
TOML
quoted_before="$(cksum "$quoted_home/.codex/config.toml")"
if printf '%s\n' "$secret" | HOME="$quoted_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/quoted-header.log" 2>&1; then
  fail 'quoted Image2 config unexpectedly succeeded'
fi
assert_contains "$tmp/quoted-header.log" 'unsupported Image2 TOML table header'
[[ "$(cksum "$quoted_home/.codex/config.toml")" == "$quoted_before" ]] || fail 'quoted Image2 config changed'

quoted_image20_home="$tmp/quoted-image20-home"
mkdir -p "$quoted_image20_home/.codex"
cat > "$quoted_image20_home/.codex/config.toml" <<'TOML'
model = "gpt-5"

["mcp_servers"."image\u00320"]
command = "/keep/quoted-image20-runner"
TOML
printf '%s\n' "$secret" | HOME="$quoted_image20_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/quoted-image20.log" 2>&1
assert_contains "$tmp/quoted-image20.log" 'Verification: OK'
assert_contains "$quoted_image20_home/.codex/config.toml" '["mcp_servers"."image\u00320"]'
assert_contains "$quoted_image20_home/.codex/config.toml" '/keep/quoted-image20-runner'

literal_quoted_home="$tmp/literal-quoted-home"
mkdir -p "$literal_quoted_home/.codex"
cat > "$literal_quoted_home/.codex/config.toml" <<'TOML'
model = "gpt-5"

['mcp_servers'.'image2']
command = "/literal/old-runner"
TOML
literal_quoted_before="$(cksum "$literal_quoted_home/.codex/config.toml")"
if printf '%s\n' "$secret" | HOME="$literal_quoted_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/literal-quoted.log" 2>&1; then
  fail 'literal quoted Image2 config unexpectedly succeeded'
fi
assert_contains "$tmp/literal-quoted.log" 'unsupported Image2 TOML table header'
[[ "$(cksum "$literal_quoted_home/.codex/config.toml")" == "$literal_quoted_before" ]] || fail 'literal quoted Image2 config changed'

escaped_quoted_home="$tmp/escaped-quoted-home"
mkdir -p "$escaped_quoted_home/.codex"
cat > "$escaped_quoted_home/.codex/config.toml" <<'TOML'
model = "gpt-5"

["mcp_servers"."image\u0032"]
command = "/escaped/old-runner"
TOML
escaped_quoted_before="$(cksum "$escaped_quoted_home/.codex/config.toml")"
if printf '%s\n' "$secret" | HOME="$escaped_quoted_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/escaped-quoted.log" 2>&1; then
  fail 'escaped quoted Image2 config unexpectedly succeeded'
fi
assert_contains "$tmp/escaped-quoted.log" 'unsupported Image2 TOML table header'
[[ "$(cksum "$escaped_quoted_home/.codex/config.toml")" == "$escaped_quoted_before" ]] || fail 'escaped quoted Image2 config changed'

assert_conflicting_assignment_refused() {
  local name="$1" conflict_home config_file config_before env_before binary_before output
  conflict_home="$tmp/conflicting-assignment-$name"
  config_file="$conflict_home/.codex/config.toml"
  output="$tmp/conflicting-assignment-$name.log"
  mkdir -p "$conflict_home/.codex"
  cat >"$config_file"
  config_before="$(cksum "$config_file")"
  env_before="$(file_fingerprint "$repo/.env.local")"
  binary_before="$(file_fingerprint "$repo/dist/image2-mcp")"
  if printf '%s\n' "$secret" | HOME="$conflict_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
    "$repo/install.sh" --key-only >"$output" 2>&1; then
    fail "conflicting Image2 TOML assignment $name unexpectedly succeeded"
  fi
  assert_contains "$output" 'unsupported conflicting Image2 TOML assignment'
  assert_not_contains "$output" 'old'
  assert_not_contains "$output" 'OPENAI_IMAGE_API_KEY:'
  [[ "$(cksum "$config_file")" == "$config_before" ]] || fail "conflicting Image2 TOML assignment $name changed config"
  [[ "$(file_fingerprint "$repo/.env.local")" == "$env_before" ]] || fail "conflicting Image2 TOML assignment $name changed .env.local"
  [[ "$(file_fingerprint "$repo/dist/image2-mcp")" == "$binary_before" ]] || fail "conflicting Image2 TOML assignment $name changed binary"
}

assert_conflicting_assignment_refused dotted <<'TOML'
mcp_servers.image2.command = "old"
TOML

assert_conflicting_assignment_refused quoted-dotted <<'TOML'
"mcp_servers" . "image2" . command = "old"
TOML

assert_conflicting_assignment_refused inline <<'TOML'
mcp_servers = { image2 = { command = "old" } }
TOML

assert_conflicting_assignment_refused table-dotted <<'TOML'
[mcp_servers]
image2.command = "old"
TOML

assert_conflicting_assignment_refused quoted-table-inline <<'TOML'
[mcp_servers]
'image2' = { command = "old" }
TOML

sibling_assignment_home="$tmp/sibling-assignment-home"
mkdir -p "$sibling_assignment_home/.codex"
cat >"$sibling_assignment_home/.codex/config.toml" <<'TOML'
mcp_servers.keep.command = "ok"
"mcp_servers" . "keep-quoted" . command = "quoted ok"
TOML
printf '%s\n' "$secret" | HOME="$sibling_assignment_home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/sibling-assignment.log" 2>&1
assert_contains "$tmp/sibling-assignment.log" 'Verification: OK'
assert_line "$sibling_assignment_home/.codex/config.toml" 'mcp_servers.keep.command = "ok"'
assert_line "$sibling_assignment_home/.codex/config.toml" '"mcp_servers" . "keep-quoted" . command = "quoted ok"'

nul_env_before="$(cksum "$repo/.env.local")"
nul_binary_before="$(cksum "$repo/dist/image2-mcp")"
nul_config_before="$(cksum "$home/.codex/config.toml")"
if printf 'nul-prefix\0nul-suffix\nignored-second-line\n' |
  HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  "$repo/install.sh" --key-only >"$tmp/nul.log" 2>&1; then
  fail 'NUL-containing API Key unexpectedly succeeded'
fi
assert_contains "$tmp/nul.log" 'API Key must be one line and cannot contain NUL'
assert_not_contains "$tmp/nul.log" 'nul-prefix'
assert_not_contains "$tmp/nul.log" 'nul-suffix'
[[ "$(cksum "$repo/.env.local")" == "$nul_env_before" ]] || fail 'NUL input changed .env.local'
[[ "$(cksum "$repo/dist/image2-mcp")" == "$nul_binary_before" ]] || fail 'NUL input changed binary'
[[ "$(cksum "$home/.codex/config.toml")" == "$nul_config_before" ]] || fail 'NUL input changed Codex config'

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
