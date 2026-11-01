#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
os='' arch='' binary='' version='' output=''
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && -n "$2" ]] || fail 'each package option requires a value'
  case "$1" in
    --os) os="$2" ;;
    --arch) arch="$2" ;;
    --binary) binary="$2" ;;
    --version) version="$2" ;;
    --output) output="$2" ;;
    *) fail "unknown package option: $1" ;;
  esac
  shift 2
done
case "$os:$arch" in
  darwin:arm64|darwin:amd64|linux:arm64|linux:amd64|windows:arm64|windows:amd64) ;;
  *) fail 'unsupported offline package platform' ;;
esac
[[ -f "$binary" && ! -L "$binary" && -s "$binary" ]] || fail 'binary must be a nonempty regular file'
[[ -n "$output" ]] || fail 'output directory is required'
expected_version="$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")"
[[ -n "$version" && "$version" == "$expected_version" ]] || fail 'package version must match the server version'
metadata="$(go version -m "$binary")" || fail 'binary is not a readable Go build'
actual_path="$(printf '%s\n' "$metadata" | awk '$1 == "path" { print $2 }')"
[[ "$actual_path" == 'image2-mcp/cmd/image2-mcp' ]] || fail 'binary is not the image2-mcp server'
actual_os="$(printf '%s\n' "$metadata" | awk '$1 == "build" && $2 ~ /^GOOS=/ { sub(/^GOOS=/, "", $2); print $2 }')"
actual_arch="$(printf '%s\n' "$metadata" | awk '$1 == "build" && $2 ~ /^GOARCH=/ { sub(/^GOARCH=/, "", $2); print $2 }')"
[[ "$actual_os" == "$os" && "$actual_arch" == "$arch" ]] || fail 'binary build platform does not match offline package platform'
LC_ALL=C grep -aFq "image2-mcp $version offline-v1" "$binary" || fail 'binary version marker does not match offline package version'
sha256() {
  local result
  if command -v sha256sum >/dev/null 2>&1; then
    result="$(sha256sum "$1")"
  elif command -v shasum >/dev/null 2>&1; then
    result="$(shasum -a 256 "$1")"
  else
    fail 'sha256sum or shasum is required to build offline packages'
  fi
  printf '%s\n' "${result%% *}"
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/package"
mkdir -p "$stage/payload/scripts" "$stage/payload/dist" "$stage/scripts"
for path in install.sh install.ps1 go.mod LICENSE scripts/setup.sh scripts/offline-binary.sh scripts/offline-binary.ps1 \
  scripts/run-image2-mcp.sh scripts/run-image2-mcp.ps1 \
  scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1; do
  [[ -f "$root/$path" && ! -L "$root/$path" ]] || fail "required package file is missing or unsafe: $path"
  cp "$root/$path" "$stage/payload/$path"
done
for path in install-offline.sh install-offline.ps1 OFFLINE_INSTALL.md scripts/offline-binary.sh scripts/offline-binary.ps1 \
  scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1; do
  [[ -f "$root/$path" && ! -L "$root/$path" ]] || fail "required bootstrap file is missing or unsafe: $path"
  cp "$root/$path" "$stage/$path"
done
binary_name='image2-mcp'
[[ "$os" != windows ]] || binary_name='image2-mcp.exe'
cp "$binary" "$stage/payload/dist/$binary_name"
chmod +x "$stage/install-offline.sh" "$stage/scripts/"*.sh "$stage/payload/install.sh" "$stage/payload/scripts/"*.sh "$stage/payload/dist/$binary_name"
printf '%s\n' "$version" > "$stage/OFFLINE_PACKAGE_VERSION"
manifest="$stage/payload/OFFLINE_PACKAGE_MANIFEST"
{
  printf 'IMAGE2_MCP_OFFLINE 1\nversion %s\nplatform %s %s\n' "$version" "$os" "$arch"
  for path in install.sh install.ps1 go.mod LICENSE scripts/setup.sh scripts/offline-binary.sh scripts/offline-binary.ps1 \
    scripts/run-image2-mcp.sh scripts/run-image2-mcp.ps1 \
    scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1 "dist/$binary_name"; do
    bytes="$(wc -c < "$stage/payload/$path" | tr -d '[:space:]')"
    printf 'file %s %s %s\n' "$(sha256 "$stage/payload/$path")" "$bytes" "$path"
  done
} > "$manifest"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
name="image2-mcp-offline_${os}_${arch}"
if [[ "$os" == windows ]]; then
  asset="$output/$name.zip"
  [[ ! -e "$asset" ]] || fail 'refusing to overwrite an existing package'
  (cd "$stage" && zip -q -r "$tmp/$name.zip" .)
  mv "$tmp/$name.zip" "$asset"
else
  asset="$output/$name.tar.gz"
  [[ ! -e "$asset" ]] || fail 'refusing to overwrite an existing package'
  COPYFILE_DISABLE=1 tar -czf "$tmp/$name.tar.gz" -C "$stage" .
  mv "$tmp/$name.tar.gz" "$asset"
fi
printf 'Offline package: %s\n' "$asset"
