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

before="$(cksum "$repo/dist/image2-mcp")"
if printf '%s\n' "$secret" | HOME="$home" PATH="$fakebin:$PATH" IMAGE2_MCP_TEST_ASSET="$fixture" \
  IMAGE2_MCP_REPO='Schyler0427/image2-mcp' IMAGE2_MCP_TEST_CURL_FAIL=1 \
  "$repo/install.sh" --key-only >"$tmp/download-failure.log" 2>&1; then
  fail 'failed prebuilt download unexpectedly succeeded'
fi
[[ "$(cksum "$repo/dist/image2-mcp")" == "$before" ]] || fail 'failed download changed existing binary'

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
