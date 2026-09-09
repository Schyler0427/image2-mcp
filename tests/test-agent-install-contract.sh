#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doc="$root/AGENT_INSTALL.md"
workflow="$root/.github/workflows/release.yml"
windows_installer="$root/install.ps1"
[[ -f "$doc" ]] || { echo 'FAIL: AGENT_INSTALL.md missing' >&2; exit 1; }
[[ -f "$windows_installer" ]] || { echo 'FAIL: install.ps1 missing' >&2; exit 1; }
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
  'scripts/bootstrap-agent-install.sh' \
  'scripts/bootstrap-agent-install.ps1' \
  'Previous installation retained at:' \
  'not active in the refreshed target'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: missing helper contract: $required" >&2; exit 1; }
done
for required in \
  'ask exactly `请输入 API Key：`' \
  'request elevation or start an administrator process.' \
  'Do not create a forwarding script or a second process to relay stdin.' \
  'Keep this download, helper launch, key forwarding, installation, and verification in one Agent turn.' \
  'Do not inspect `.env.local`, the target, or Codex config while the helper is still running.'; do
  grep -Fq "$required" "$doc" || {
    echo "FAIL: missing single-turn Agent contract: $required" >&2
    exit 1
  }
done
for required in \
  'curl -fL --connect-timeout 10 --max-time 60 URL -o FILE' \
  'wget --tries=1 --timeout=60 -O FILE URL' \
  'Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri URL -OutFile FILE'; do
  grep -Fq "$required" "$doc" || {
    echo "FAIL: missing bounded helper download contract: $required" >&2
    exit 1
  }
done
if grep -Fq 'Start the selected helper and wait until it requests stdin. Then ask exactly' "$doc"; then
  echo 'FAIL: Agent guide still starts a long-running helper before asking for the key' >&2
  exit 1
fi
if grep -Fq '.image2-mcp-source-manifest' "$doc"; then
  echo 'FAIL: Agent guide still delegates a prose manifest algorithm' >&2
  exit 1
fi
if grep -Fq '$Security.SetAccessRuleProtection($true, $false)' "$windows_installer"; then
  echo 'FAIL: Windows key-only installer still requires protected ACL elevation' >&2
  exit 1
fi
grep -Fq '$Security = Get-Acl -Path $Path' "$windows_installer" || {
  echo 'FAIL: Windows key-only installer does not preserve the existing ACL' >&2
  exit 1
}
for required in \
  'https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.3.1' \
  'v0.3.1' \
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
  'tar -xzf' \
  'Invoke-WebRequest' \
  'A blank or whitespace-only key fails once with no re-prompt.' \
  'must never call an image API'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: missing $required" >&2; exit 1; }
done
for test_path in 'tests/test-agent-bootstrap.sh' 'tests/test-agent-bootstrap.ps1'; do
  grep -Fq "$test_path" "$workflow" || {
    echo "FAIL: release workflow does not gate on $test_path" >&2
    exit 1
  }
done
grep -Fq -- '- "v0.3.1"' "$workflow" || {
  echo 'FAIL: release workflow is not pinned to v0.3.1' >&2
  exit 1
}
grep -Fq 'git tag v0.3.1' "$root/README.md" || {
  echo 'FAIL: README release instructions are not pinned to v0.3.1' >&2
  exit 1
}
grep -Fq '仓库包含 GitHub Actions Release workflow。推送 `v0.3.1` tag 后会自动构建：' "$root/README.md" || {
  echo 'FAIL: README release trigger is not pinned to v0.3.1' >&2
  exit 1
}
if grep -Fq '`v*` tag' "$root/README.md"; then
  echo 'FAIL: README release trigger still accepts a wildcard tag' >&2
  exit 1
fi
asset_count="$(grep -Ec 'goos: (darwin|linux|windows)|goarch: (arm64|amd64)' "$workflow")"
[[ "$asset_count" -eq 12 ]] || {
  echo 'FAIL: release workflow six-asset matrix changed' >&2
  exit 1
}
if grep -Fq 'move the complete accepted target' "$doc"; then
  echo 'FAIL: Agent guide still swaps every accepted target' >&2
  exit 1
fi
if grep -Fxq '.image2-mcp-source-manifest' "$root/.gitignore"; then
  echo 'FAIL: obsolete source manifest remains ignored' >&2
  exit 1
fi
if grep -Eiq 'ask (for|the user for).*(url|path|repo|branch|go)|T[B]D|TO[D]O|<yo[u]r' "$doc"; then
  echo 'FAIL: Agent guide contains a forbidden prompt or placeholder' >&2
  exit 1
fi
echo 'PASS: Agent install contract'
