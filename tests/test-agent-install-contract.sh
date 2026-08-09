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
