#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/dist/macos-launcher"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'each option requires a value'
  case "$1" in --output) output="$2" ;; *) fail "unknown option: $1" ;; esac
  shift 2
done
[[ "$(uname -s)" == Darwin ]] || fail 'Mac app packaging requires macOS and Xcode command line tools'
for tool in go xcrun hdiutil codesign python3 ditto; do command -v "$tool" >/dev/null || fail "required build tool missing: $tool"; done
version="$(sed -n 's/^const serverVersion = "\([^"]*\)"/\1/p' "$root/cmd/image2-mcp/main.go")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid backend version'
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
python3 - "$output" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
allowed={'SchylerAI-Image2-mcp.app','SchylerAI-Image2-mcp-macOS.dmg','使用说明.txt','SHA256SUMS.txt'}
if p.is_symlink() or (p.exists() and not p.is_dir()): raise SystemExit('unsafe output directory')
if p.exists():
    for entry in p.iterdir():
        if entry.name not in allowed or entry.is_symlink(): raise SystemExit('output contains unrelated or unsafe content')
        expected_directory=entry.name.endswith('.app')
        if (expected_directory and not entry.is_dir()) or (not expected_directory and not entry.is_file()): raise SystemExit('invalid existing artifact type')
PY
stage="$(mktemp -d "$(dirname "$output")/.macos-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/SchylerAI-Image2-mcp.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/packages" "$stage/packages"
cd "$root"
identity="${MACOS_SIGN_IDENTITY:--}"
if [[ "$identity" == - ]]; then
  sign_args=(--force --sign -)
else
  sign_args=(--force --options runtime --timestamp --sign "$identity")
fi
for arch in arm64 amd64; do
  binary="$stage/image2-mcp-$arch"
  GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -o "$binary" ./cmd/image2-mcp
  codesign "${sign_args[@]}" "$binary"
  codesign --verify --strict "$binary"
  bash scripts/build-offline-package.sh --os darwin --arch "$arch" --binary "$binary" --version "$version" --output "$stage/packages"
  mkdir -p "$resources/packages/$arch"
  COPYFILE_DISABLE=1 tar -xzf "$stage/packages/image2-mcp-offline_darwin_$arch.tar.gz" -C "$resources/packages/$arch"
done
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx12.0" \
    macos/LauncherCore.swift macos/LauncherUpdate.swift macos/Launcher.swift -o "$stage/launcher-$arch"
done
xcrun lipo -create "$stage/launcher-arm64" "$stage/launcher-x86_64" -output "$app/Contents/MacOS/SchylerAI-Image2-mcp"
xcrun lipo "$app/Contents/MacOS/SchylerAI-Image2-mcp" -verify_arch arm64 x86_64
python3 - "$app" "$version" <<'PY'
from pathlib import Path
import hashlib,json,plistlib,sys
app=Path(sys.argv[1]); version=sys.argv[2]
info={'CFBundleName':'SchylerAI-Image2-mcp','CFBundleDisplayName':'SchylerAI-Image2-mcp','CFBundleIdentifier':'top.schyler.image2-mcp.launcher','CFBundleExecutable':'SchylerAI-Image2-mcp','CFBundlePackageType':'APPL','CFBundleShortVersionString':version,'CFBundleVersion':version,'LSMinimumSystemVersion':'12.0','NSHighResolutionCapable':True,'LSApplicationCategoryType':'public.app-category.developer-tools'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
# Native payloads are signed before their offline manifests are generated.
# Record final resource bytes before sealing the enclosing app bundle.
python3 - "$resources" "$version" <<'PY'
from pathlib import Path
import hashlib,json,sys
r=Path(sys.argv[1]); records=[]
for p in sorted((r/'packages').rglob('*')):
    if p.is_symlink(): raise SystemExit('symlinks are forbidden in packaged installer resources')
    if p.is_file():
        data=p.read_bytes(); records.append({'path':p.relative_to(r).as_posix(),'sha256':hashlib.sha256(data).hexdigest(),'size':len(data)})
(r/'resource-manifest.json').write_text(json.dumps({'version':sys.argv[2],'files':records},separators=(',',':')),encoding='utf-8')
PY
codesign "${sign_args[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"
[[ "$("$app/Contents/MacOS/SchylerAI-Image2-mcp" --version)" == "$version" ]] || fail 'packaged launcher version check failed'
[[ "$("$app/Contents/MacOS/SchylerAI-Image2-mcp" --verify-resources)" == 'Offline resources: OK' ]] || fail 'optimized packaged launcher resource check failed'
mkdir -p "$stage/dmg-root"
ditto "$app" "$stage/dmg-root/SchylerAI-Image2-mcp.app"
ln -s /Applications "$stage/dmg-root/Applications"
cat > "$stage/dmg-root/使用说明.txt" <<'NOTES'
把 SchylerAI-Image2-mcp 拖到 Applications，再打开应用。
Image2 和 Gemini 专用 Key 至少填写一项，另一项可留空，点击“安装 / 更新密钥”。安装成功后重启 Codex 或开启新会话。
默认“帮我生图”使用 Image2；“用 2.5 生图”使用 Image2.5；只有明确说 Gemini / 香蕉 / banana 生图才使用 Gemini 3.1 Flash Image。
每次安装或换钥都重新输入需要启用的密钥；留空的服务保持未配置并清除旧密钥，不读取或复用其他密钥。安装和连接验证不会发起收费生图。
本地构建未使用 Developer ID 证书、未经过 Apple 公证；macOS 可能阻止首次打开，请按系统安全提示处理。不要关闭 Gatekeeper 或删除隔离属性。
在线更新功能需要维护者部署签名更新清单；未部署前，当前内置版本仍可离线安装。
NOTES
hdiutil create -quiet -volname SchylerAI-Image2-mcp -srcfolder "$stage/dmg-root" -format UDZO -ov "$stage/SchylerAI-Image2-mcp-macOS.dmg"
hdiutil verify "$stage/SchylerAI-Image2-mcp-macOS.dmg" >/dev/null
if [[ -n "${MACOS_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  [[ "$identity" != - ]] || fail 'notarization requires MACOS_SIGN_IDENTITY'
  xcrun notarytool submit "$stage/SchylerAI-Image2-mcp-macOS.dmg" --keychain-profile "$MACOS_NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$stage/SchylerAI-Image2-mcp-macOS.dmg"
fi
release="$stage/release"
mkdir "$release"
mv "$app" "$release/SchylerAI-Image2-mcp.app"
mv "$stage/SchylerAI-Image2-mcp-macOS.dmg" "$release/SchylerAI-Image2-mcp-macOS.dmg"
cp "$stage/dmg-root/使用说明.txt" "$release/使用说明.txt"
(cd "$release" && shasum -a 256 SchylerAI-Image2-mcp-macOS.dmg > SHA256SUMS.txt)
# Publish the complete output set in one atomic directory operation. A failure
# leaves the old directory intact; after success cleanup can remove the old set.
python3 - "$release" "$output" <<'PY'
import ctypes,os,sys
source,destination=map(os.fsencode,sys.argv[1:])
if os.path.exists(destination):
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    swap=libc.renamex_np
    swap.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
    swap.restype=ctypes.c_int
    if swap(source,destination,2)!=0:
        error=ctypes.get_errno(); raise OSError(error,os.strerror(error))
else:
    os.rename(source,destination)
PY
printf 'Mac app: %s\nMac disk image: %s\n' "$output/SchylerAI-Image2-mcp.app" "$output/SchylerAI-Image2-mcp-macOS.dmg"
