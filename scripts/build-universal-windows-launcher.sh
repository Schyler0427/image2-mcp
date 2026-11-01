#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
output="$root/dist/universal-windows-launcher"
version="$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha256() {
  local result
  if command -v sha256sum >/dev/null 2>&1; then result="$(sha256sum "$1")"
  elif command -v shasum >/dev/null 2>&1; then result="$(shasum -a 256 "$1")"
  else fail 'sha256sum or shasum is required'; fi
  printf '%s\n' "${result%% *}"
}
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'each option requires a value'
  case "$1" in
    --output) output="$2" ;;
    --version) version="$2" ;;
    *) fail "unknown option: $1" ;;
  esac
  shift 2
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'version must be MAJOR.MINOR.PATCH'
[[ "$version" == "$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")" ]] || fail 'version does not match serverVersion'
command -v go >/dev/null 2>&1 || fail 'go is required'
mkdir -p "$output"
output="$(cd "$output" && pwd)"
tmp="$(mktemp -d)"
asset_dir="$root/cmd/windows-launcher/assets"
asset_backup="$tmp/original-assets"
cleanup() {
  rm -rf "$asset_dir"
  if [[ -d "$asset_backup" ]]; then mv "$asset_backup" "$asset_dir"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
if [[ -e "$asset_dir" ]]; then mv "$asset_dir" "$asset_backup"; fi
assets="$tmp/assets"
mkdir -p "$assets/payload/windows" "$assets/payload/scripts" "$assets/scripts"
for path in install.sh install.ps1 go.mod LICENSE scripts/setup.sh scripts/offline-binary.sh scripts/offline-binary.ps1 \
  scripts/run-image2-mcp.sh scripts/run-image2-mcp.ps1 scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1; do
  [[ -f "$root/$path" && ! -L "$root/$path" ]] || fail "required payload file is missing or unsafe: $path"
  mkdir -p "$assets/payload/$(dirname "$path")"
  asset_path="$path"
  # go:embed skips nested modules. Store go.mod as ordinary data until extraction.
  [[ "$path" != go.mod ]] || asset_path=go.mod.txt
  cp "$root/$path" "$assets/payload/$asset_path"
done
cp "$root/install-offline.ps1" "$assets/install-offline.ps1"
cp "$root/scripts/bootstrap-agent-install.ps1" "$assets/scripts/bootstrap-agent-install.ps1"
cp "$root/scripts/offline-binary.ps1" "$assets/scripts/offline-binary.ps1"
printf '%s\n' "$version" > "$assets/version"
for arch in 386 amd64 arm64; do
  binary="$assets/payload/windows/$arch/image2-mcp.exe"
  GOOS=windows GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -o "$binary" ./cmd/image2-mcp
  [[ -s "$binary" && ! -L "$binary" ]] || fail "empty $arch payload"
  metadata="$(go version -m "$binary")" || fail "cannot inspect $arch payload"
  grep -Eq "^[[:space:]]*build[[:space:]]+GOOS=windows$" <<<"$metadata" || fail "$arch payload has wrong GOOS"
  grep -Eq "^[[:space:]]*build[[:space:]]+GOARCH=$arch$" <<<"$metadata" || fail "$arch payload has wrong GOARCH"
  LC_ALL=C grep -aFq "image2-mcp $version offline-v1" "$binary" || fail "$arch payload version marker is missing"
done
manifest="$assets/manifest.json"
{
  printf '{"version":"%s","architectures":{' "$version"
  first=1
  for arch in 386 amd64 arm64; do
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    binary="$assets/payload/windows/$arch/image2-mcp.exe"
    printf '"%s":{"sha256":"%s","size":%s}' "$arch" "$(sha256 "$binary")" "$(wc -c < "$binary" | tr -d '[:space:]')"
  done
  printf '}}\n'
} > "$manifest"
mkdir -p "$asset_dir"
cp -R "$assets/." "$asset_dir/"
launcher="$tmp/SchylerAI-Image2-mcp.exe"
GOOS=windows GOARCH=386 CGO_ENABLED=0 go build -trimpath -ldflags='-H=windowsgui' -o "$launcher" ./cmd/windows-launcher
[[ -s "$launcher" && ! -L "$launcher" ]] || fail 'launcher build produced no executable'
IMAGE2_BUILT_LAUNCHER="$launcher" go test ./cmd/windows-launcher -run '^TestBuiltLauncherIncludesGeneratedPayloads$' -count=1
mv "$launcher" "$output/SchylerAI-Image2-mcp.exe"
cp "$manifest" "$output/SchylerAI-Image2-mcp.manifest.json"
printf 'Universal launcher: %s\n' "$output/SchylerAI-Image2-mcp.exe"
