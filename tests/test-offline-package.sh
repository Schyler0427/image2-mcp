#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
builder="$root/scripts/build-offline-package.sh"
[[ -x "$builder" ]] || fail 'offline package builder is missing or not executable'
version="$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")"
cat > "$tmp/fixture.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("MCP verification: OK") }
GO
mkdir -p "$tmp/out"
for pair in linux:amd64 windows:arm64; do
  os="${pair%:*}" arch="${pair#*:}"
  binary="$tmp/binary-$os-$arch"
  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -o "$binary" "$root/cmd/image2-mcp"
  "$builder" --os "$os" --arch "$arch" --binary "$binary" --version "$version" --output "$tmp/out"
done
unix_archive="$tmp/out/image2-mcp-offline_linux_amd64.tar.gz"
windows_archive="$tmp/out/image2-mcp-offline_windows_arm64.zip"
[[ -s "$unix_archive" && -s "$windows_archive" ]] || fail 'expected offline assets were not created'
mkdir "$tmp/unix" "$tmp/windows"
tar -xzf "$unix_archive" -C "$tmp/unix"
unzip -q "$windows_archive" -d "$tmp/windows"
for package in "$tmp/unix" "$tmp/windows"; do
  for path in install-offline.sh install-offline.ps1 OFFLINE_INSTALL.md OFFLINE_PACKAGE_VERSION \
    scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1 scripts/offline-binary.sh scripts/offline-binary.ps1 \
    payload/install.sh payload/install.ps1 payload/go.mod payload/LICENSE \
    payload/scripts/setup.sh payload/scripts/offline-binary.sh payload/scripts/offline-binary.ps1 payload/scripts/run-image2-mcp.sh payload/scripts/run-image2-mcp.ps1 \
    payload/scripts/bootstrap-agent-install.sh payload/scripts/bootstrap-agent-install.ps1 \
    payload/OFFLINE_PACKAGE_MANIFEST; do
    [[ -f "$package/$path" && ! -L "$package/$path" ]] || fail "package missing regular $path"
  done
  [[ "$(cat "$package/OFFLINE_PACKAGE_VERSION")" == "$version" ]] || fail 'version marker mismatch'
  [[ ! -e "$package/payload/.env.local" && ! -e "$package/payload/.git" ]] || fail 'package includes local state'
  [[ "$(find "$package" -type l | wc -l | tr -d ' ')" == 0 ]] || fail 'package contains a symlink'
done
cmp "$tmp/binary-linux-amd64" "$tmp/unix/payload/dist/image2-mcp" || fail 'Unix binary changed'
cmp "$tmp/binary-windows-arm64" "$tmp/windows/payload/dist/image2-mcp.exe" || fail 'Windows binary changed'
grep -Fxq 'IMAGE2_MCP_OFFLINE 1' "$tmp/unix/payload/OFFLINE_PACKAGE_MANIFEST" || fail 'manifest format missing'
grep -Fxq 'platform linux amd64' "$tmp/unix/payload/OFFLINE_PACKAGE_MANIFEST" || fail 'manifest platform mismatch'
grep -Fxq 'platform windows arm64' "$tmp/windows/payload/OFFLINE_PACKAGE_MANIFEST" || fail 'Windows manifest platform mismatch'
[[ "$(wc -l < "$tmp/unix/payload/OFFLINE_PACKAGE_MANIFEST" | tr -d ' ')" == 15 ]] || fail 'manifest does not cover twelve payload files'
while read -r record digest bytes path; do
  [[ "$record" == file ]] || continue
  actual="$(shasum -a 256 "$tmp/unix/payload/$path")"
  [[ "${actual%% *}" == "$digest" ]] || fail "manifest digest mismatch: $path"
  [[ "$(wc -c < "$tmp/unix/payload/$path" | tr -d ' ')" == "$bytes" ]] || fail "manifest length mismatch: $path"
done < "$tmp/unix/payload/OFFLINE_PACKAGE_MANIFEST"
if "$builder" --os windows --arch amd64 --binary "$tmp/binary-linux-amd64" --version "$version" --output "$tmp/bad-platform" >"$tmp/bad-platform.log" 2>&1; then
  fail 'builder accepted a binary for a different platform'
fi
if "$builder" --os linux --arch amd64 --binary "$tmp/binary-linux-amd64" --version 999.0.0 --output "$tmp/bad-version" >"$tmp/bad-version.log" 2>&1; then
  fail 'builder accepted a mismatched server version'
fi
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$tmp/non-image-binary" "$tmp/fixture.go"
if "$builder" --os linux --arch amd64 --binary "$tmp/non-image-binary" --version "$version" --output "$tmp/bad-identity" >"$tmp/bad-identity.log" 2>&1; then
  fail 'builder accepted an unrelated Go executable'
fi
printf 'PASS: offline package contents, platform, version, and checksums\n'
