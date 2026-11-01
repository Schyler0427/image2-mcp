#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
version="$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")"
go build -o "$tmp/image2-mcp" "$root/cmd/image2-mcp"
"$root/scripts/build-offline-package.sh" --os "$os" --arch "$arch" --binary "$tmp/image2-mcp" --version "$version" --output "$tmp/assets" >/dev/null
mkdir -p "$tmp/package" "$tmp/home/.codex" "$tmp/forbid"
tar -xzf "$tmp/assets/image2-mcp-offline_${os}_${arch}.tar.gz" -C "$tmp/package"
for name in curl wget git go; do
  cat > "$tmp/forbid/$name" <<'BLOCK'
#!/usr/bin/env bash
printf 'forbidden command: %s\n' "$0" >>"$IMAGE2_OFFLINE_FORBIDDEN_LOG"
exit 97
BLOCK
  chmod +x "$tmp/forbid/$name"
done
printf '[mcp_servers.keep]\ncommand = "/keep/runner"\n' >"$tmp/home/.codex/config.toml"
run_package() {
  env -u OPENAI_IMAGE_API_KEY -u OPENAI_IMAGE_BASE_URL -u OPENAI_IMAGE_MODEL \
    HOME="$tmp/home" PATH="$tmp/forbid:$PATH" \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
    IMAGE2_OFFLINE_FORBIDDEN_LOG="$tmp/forbidden.log" bash "$tmp/package/install-offline.sh"
}
printf 'offline-install-test-value\ngemini-offline-test-value\n' | run_package >"$tmp/first.log" 2>&1 || {
  cat "$tmp/first.log" >&2; fail 'real offline package installation failed'
}
grep -Fxq 'Verification: OK' "$tmp/first.log" || fail 'real installation did not verify MCP'
target="$tmp/home/.local/share/image2-mcp"
env_before="$(shasum -a 256 "$target/.env.local")"
printf 'new-image-key-value\nnew-gemini-key-value\n' | run_package >"$tmp/repeat.log" 2>&1 || { cat "$tmp/repeat.log" >&2; fail 'real offline repeat failed'; }
grep -Fq 'OPENAI_IMAGE_API_KEY:' "$tmp/repeat.log" || fail 'repeat did not request Image2 Key'
! grep -Fq 'reusing it' "$tmp/repeat.log" || fail 'repeat reused saved Key'
grep -Fq 'Previous installation retained at:' "$tmp/repeat.log" || fail 'real repeat did not retain backup'
[[ "$(shasum -a 256 "$target/.env.local")" != "$env_before" ]] || fail 'repeat ignored new Image2 Key'
( source "$target/.env.local"; [[ "$OPENAI_IMAGE_API_KEY" == new-image-key-value && "$GEMINI_IMAGE_API_KEY" == new-gemini-key-value ]] ) || fail 'repeat saved wrong Key'
backup="$(find "$tmp/home/.local/share" -name previous -type d | head -1)"
[[ "$(shasum -a 256 "$backup/.env.local" | cut -d ' ' -f1)" == "${env_before%% *}" ]] || fail 'backup lost old Key'
# Replacing keys with one provider must clear the other provider rather than
# inheriting ambient credentials or retaining a previous installation's key.
for provider in image2 gemini; do
  if [[ "$provider" == image2 ]]; then
    key_input=$'only-image-key\n\xe3\x80\x80\n'
  else
    key_input=$'\xc2\xa0\nonly-gemini-key\n'
  fi
  printf '%s' "$key_input" | OPENAI_IMAGE_API_KEY=ambient-image-key GEMINI_IMAGE_API_KEY=ambient-gemini-key run_package >"$tmp/$provider-only.log" 2>&1 || {
    cat "$tmp/$provider-only.log" >&2; fail "$provider-only offline installation failed"
  }
  grep -Fxq 'Verification: OK' "$tmp/$provider-only.log" || fail "$provider-only MCP verification failed"
  (
    source "$target/.env.local"
    if [[ "$provider" == image2 ]]; then
      [[ "$OPENAI_IMAGE_API_KEY" == only-image-key && -z "$GEMINI_IMAGE_API_KEY" ]]
    else
      [[ -z "$OPENAI_IMAGE_API_KEY" && "$GEMINI_IMAGE_API_KEY" == only-gemini-key ]]
    fi
  ) || fail "$provider-only installation reused an omitted provider key"
done
config_replaced="$(shasum -a 256 "$tmp/home/.codex/config.toml")"
env_replaced="$(shasum -a 256 "$target/.env.local")"
if run_package </dev/null >"$tmp/no-key.log" 2>&1; then fail 'repeat with no new Key reused saved Key'; fi
[[ "$(shasum -a 256 "$target/.env.local")" == "$env_replaced" ]] || fail 'failed replacement lost Key'
[[ "$(shasum -a 256 "$tmp/home/.codex/config.toml")" == "$config_replaced" ]] || fail 'failed replacement changed config'
grep -Fq '[mcp_servers.keep]' "$tmp/home/.codex/config.toml" || fail 'offline installation removed unrelated MCP'
[[ ! -e "$tmp/forbidden.log" ]] || fail 'offline installation called a forbidden network/build command'
! grep -Eq 'offline-install-test-value|new-image-key-value|gemini-offline-test-value|new-gemini-key-value' "$tmp/first.log" "$tmp/repeat.log" || fail 'offline installation exposed test Key'
config_before="$(shasum -a 256 "$tmp/home/.codex/config.toml")"
binary_before="$(shasum -a 256 "$target/dist/image2-mcp")"
printf 'damaged\n' >>"$tmp/package/payload/dist/image2-mcp"
if run_package </dev/null >"$tmp/damaged.log" 2>&1; then fail 'damaged real package was accepted'; fi
! grep -Fq 'OPENAI_IMAGE_API_KEY:' "$tmp/damaged.log" || fail 'damaged package prompted for Key'
[[ "$(shasum -a 256 "$tmp/home/.codex/config.toml")" == "$config_before" ]] || fail 'damaged package changed config'
[[ "$(shasum -a 256 "$target/dist/image2-mcp")" == "$binary_before" ]] || fail 'damaged package changed old binary'
printf 'PASS: real offline package install, repeat, MCP handshake, and damaged-package refusal\n'
