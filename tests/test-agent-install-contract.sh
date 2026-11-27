#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doc="$root/AGENT_INSTALL.md"
readme="$root/README.md"
workflow="$root/.github/workflows/release.yml"
windows_installer="$root/install.ps1"
expected_release="v$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")"
published_release='v0.4.5'
for versioned_path in AGENT_INSTALL.md scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1; do
  actual_releases="$(grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' "$root/$versioned_path" | sort -u)"
  [[ "$actual_releases" == "$published_release" ]] || {
    echo "FAIL: $versioned_path does not preserve published release $published_release consistently" >&2
    exit 1
  }
done
[[ -f "$doc" ]] || { echo 'FAIL: AGENT_INSTALL.md missing' >&2; exit 1; }
[[ -f "$windows_installer" ]] || { echo 'FAIL: install.ps1 missing' >&2; exit 1; }
for required in \
  '用 2.5 生图' \
  'Image 2.0' \
  'Agent 会根据自然语言自动调用' \
  'https://api.schyler.top' \
  '只需提供 Image2 或 Gemini 专用 API Key，至少配置一把，也可同时配置两把' \
  '帮我生成一张图' \
  '使用 image2 生成'; do
  grep -Fq "$required" "$readme" || { echo "FAIL: README missing image version contract: $required" >&2; exit 1; }
done
for required in \
  '用 2.5 生图' \
  'Image 2.0' \
  '会由 Agent 调用 `generate_image`' \
  '只需提供 Image2 或 Gemini 专用 API Key，至少配置一把，也可同时配置两把' \
  '永远不要询问客户模型 ID、Base URL 或 endpoint'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: Agent guide missing image version contract: $required" >&2; exit 1; }
done
for customer_doc in README.md OFFLINE_INSTALL.md docs/launcher-release.md; do
  for required in \
    '至少配置一把，也可同时配置两把' \
    '留空表示该服务未配置，并清除该服务原有配置' \
    '环境变量' \
    '不会自动切换服务' \
    '安装 / 更新密钥' \
    '检查更新' \
    '取消'; do
    grep -Fq "$required" "$root/$customer_doc" || {
      echo "FAIL: $customer_doc missing optional-provider contract: $required" >&2
      exit 1
    }
  done
done
for required in \
  'at least one provider key is required' \
  'A blank field clears that provider' \
  'cannot fall back to an inherited environment key' \
  'The default remains Image2 even when only Gemini is configured' \
  'without automatically switching providers' \
  '安装 / 更新密钥' \
  '检查更新' \
  '取消'; do
  grep -Fq "$required" "$root/macos/README.md" || {
    echo "FAIL: macOS guide missing optional-provider contract: $required" >&2
    exit 1
  }
done
for required in \
  'Blank or whitespace-only input leaves that provider unconfigured and clears its previous key;' \
  'it must not fall back to an inherited environment key.' \
  'If both inputs are blank or whitespace-only, fail once with no re-prompt.' \
  'an empty line for an unconfigured provider.' \
  'Never claim a blank provider was configured.' \
  'providers automatically.'; do
  grep -Fq "$required" "$doc" || {
    echo "FAIL: Agent guide missing optional-provider contract: $required" >&2
    exit 1
  }
done
for scope_doc in "$readme" "$doc"; do
  grep -Fq '0.4.3 本地 GUI／离线包' "$scope_doc" || {
    echo "FAIL: $scope_doc does not distinguish current offline keys from the published online gate" >&2
    exit 1
  }
  for required in \
    'v0.4.5' \
    '完整离线包'; do
    grep -Fq "$required" "$scope_doc" || {
      echo "FAIL: $scope_doc does not explain source-checkout Key-only limitations: $required" >&2
      exit 1
    }
  done
done
for required in \
  'Key-only 模式直接下载固定 `v0.4.5` Release 的预编译二进制'; do
  grep -Fq "$required" "$readme" || {
    echo "FAIL: README source-checkout Key-only instructions promise unsupported one-key installation: $required" >&2
    exit 1
  }
done
if grep -Eiq 'requires both fresh keys|A blank or whitespace-only key fails once|重新输入两把|必须.*两把|只需提供 Image2 和 Gemini 两把|Download new version|Install / Change keys' \
  "$readme" "$doc" "$root/OFFLINE_INSTALL.md" "$root/macos/README.md" "$root/docs/launcher-release.md"; then
  echo 'FAIL: current installation docs still require both keys or show English launcher buttons' >&2
  exit 1
fi
if grep -Eiq 'ask (for|the user for).*(model id|base url|endpoint)|请输入.*(模型 ID|Base URL|endpoint)' "$readme" "$doc"; then
  echo 'FAIL: customer docs ask for model ID, Base URL, or endpoint' >&2
  exit 1
fi
if grep -Eiq '((please|让客户|请客户|要求客户).*(provide|enter|填写|提供|输入).*(model ?id|base ?url|endpoint|模型 ?ID|Base ?URL))|((model ?id|base ?url|endpoint|模型 ?ID|Base ?URL).*(required|必填|请输入|请提供))' "$readme" "$doc"; then
  echo 'FAIL: customer docs request model ID, Base URL, or endpoint' >&2
  exit 1
fi
if grep -Eiq 'gpt-image-2\.[056](-sunburst|-flare)?' "$readme" "$doc" "$root/OFFLINE_INSTALL.md" "$root/macos/README.md" "$root/docs/launcher-release.md"; then
  echo 'FAIL: customer docs expose provider model IDs' >&2
  exit 1
fi
for customer_doc in README.md AGENT_INSTALL.md OFFLINE_INSTALL.md macos/README.md docs/launcher-release.md; do
  for required in '0.4.3' '用2.6生图' '用2.6快速版生图' '生成动图' '做个GIF' '循环动图' 'v0.4.5'; do
    grep -Fq "$required" "$root/$customer_doc" || {
      echo "FAIL: $customer_doc missing local Image2.6/GIF or pinned online scope: $required" >&2
      exit 1
    }
  done
done
for required in 'output_format=gif' 'frame_count' 'frame_duration_ms' 'duration_ms' '参考图'; do
  grep -Fq "$required" "$readme" || {
    echo "FAIL: README missing GIF request/result contract: $required" >&2
    exit 1
  }
done
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
  'ask exactly `请输入 Image2 专用 API Key：`' \
  'ask exactly `请输入 Gemini 专用 API Key：`' \
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
  'curl -q -fL --retry 0 --connect-timeout 10 --max-time 60 URL -o FILE' \
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
  'https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.4.5' \
  'v0.4.5' \
  'image2-mcp_darwin_arm64.tar.gz' \
  'image2-mcp_darwin_amd64.tar.gz' \
  'image2-mcp_linux_arm64.tar.gz' \
  'image2-mcp_linux_amd64.tar.gz' \
  'image2-mcp_windows_arm64.zip' \
  'image2-mcp_windows_amd64.zip' \
  'draft' \
  'prerelease' \
  'git clone --depth 1 https://github.com/Schyler0427/image2-mcp.git' \
  'curl -q -fL --retry 0' \
  'tar -xzf' \
  'Invoke-WebRequest' \
  'must never call an image API'; do
  grep -Fq "$required" "$doc" || { echo "FAIL: missing $required" >&2; exit 1; }
done
for test_path in 'tests/test-agent-bootstrap.sh' 'tests/test-agent-bootstrap.ps1'; do
  grep -Fq "$test_path" "$workflow" || {
    echo "FAIL: release workflow does not gate on $test_path" >&2
    exit 1
  }
done
for test_path in tests/test-offline-package.sh tests/test-offline-install.sh tests/test-offline-install.ps1; do
  grep -Fq "$test_path" "$workflow" || {
    echo "FAIL: release workflow does not gate on $test_path" >&2
    exit 1
  }
done
for required in install-offline.sh install-offline.ps1 OFFLINE_INSTALL.md 'SHA256SUMS.txt'; do
  grep -Fq "$required" "$readme" || {
    echo "FAIL: README missing offline contract: $required" >&2
    exit 1
  }
done
grep -Fq 'scripts/build-offline-package.sh' "$workflow" || {
  echo 'FAIL: release workflow does not build complete offline packages' >&2
  exit 1
}
grep -Fq 'sha256sum image2-mcp-offline_' "$workflow" || {
  echo 'FAIL: release workflow does not checksum complete offline packages' >&2
  exit 1
}
grep -Fq -- '- "v*"' "$workflow" || {
  echo 'FAIL: release workflow does not accept version tags' >&2
  exit 1
}
grep -Fq 'test "$GITHUB_REF_NAME" = "v$version"' "$workflow" || {
  echo 'FAIL: release workflow does not check the tag against the server version' >&2
  exit 1
}
for release_command in "git tag $expected_release" "git push origin $expected_release" "--version ${expected_release#v} --output dist/offline"; do
  grep -Fq -- "$release_command" "$root/README.md" || {
    echo "FAIL: README release instructions do not match server release $expected_release: $release_command" >&2
    exit 1
  }
done
grep -Fq '仓库包含 GitHub Actions Release workflow。推送 `v*` tag 后会核对服务版本并自动构建：' "$root/README.md" || {
  echo 'FAIL: README release trigger does not describe the version check' >&2
  exit 1
}
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
