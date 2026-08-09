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
for required in \
  'https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.2.1' \
  'v0.2.1' \
  'image2-mcp_darwin_arm64.tar.gz' \
  'image2-mcp_darwin_amd64.tar.gz' \
  'image2-mcp_linux_arm64.tar.gz' \
  'image2-mcp_linux_amd64.tar.gz' \
  'image2-mcp_windows_arm64.zip' \
  'image2-mcp_windows_amd64.zip' \
  'draft' \
  'prerelease' \
  'git clone --depth 1 https://github.com/Schyler0427/image2-mcp.git' \
  'curl -fL' \
  'wget -O' \
  'tar -xzf' \
  'Invoke-WebRequest' \
  'Expand-Archive' \
  'byte-for-byte' \
  '.image2-mcp-source-manifest' \
  'git -C TARGET status --porcelain=v1 --untracked-files=all' \
  'git -C TARGET fetch origin main' \
  'git -C TARGET merge --ff-only FETCH_HEAD' \
  'Never move, replace, reset, clean, or delete an existing Git target.' \
  'local commits' \
  'every customer-owned path' \
  'repository-owned relative path' \
  'path collision' \
  'leave the target unchanged' \
  'A blank or whitespace-only key fails once with no re-prompt.' \
  'must never call an image API'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: missing $required" >&2; exit 1; }
done
for required in \
  'prior `.env.local` from the backup into the replacement' \
  'before prompting for the key' \
  'new atomic' \
  'prior `output/` from the backup into the replacement' \
  'backup untouched until successful' \
  'complete old target from the untouched backup'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: missing preservation rule: $required" >&2; exit 1; }
done
grep -Fxq '.image2-mcp-source-manifest' "$root/.gitignore" || {
  echo 'FAIL: source ownership manifest is not ignored' >&2
  exit 1
}
if grep -Fq 'move the complete accepted target' "$doc"; then
  echo 'FAIL: Agent guide still swaps every accepted target' >&2
  exit 1
fi
if grep -Eiq 'ask (for|the user for).*(url|path|repo|branch|go)|T[B]D|TO[D]O|<yo[u]r' "$doc"; then
  echo 'FAIL: Agent guide contains a forbidden prompt or placeholder' >&2
  exit 1
fi
echo 'PASS: Agent install contract'
