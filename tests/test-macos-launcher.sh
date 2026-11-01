#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$root/scripts/build-macos-launcher.sh" ]] || fail 'Mac app builder is missing'
bash -n "$root/scripts/build-macos-launcher.sh"
[[ "$(uname -s)" == Darwin ]] || { printf 'SKIP: native macOS launcher tests require macOS\n'; exit 0; }
for source in LauncherCore.swift LauncherUpdate.swift Launcher.swift; do
  [[ -f "$root/macos/$source" ]] || fail "native source missing: $source"
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for target in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -parse-as-library -O -target "$target-apple-macosx12.0" \
    "$root/macos/LauncherCore.swift" "$root/macos/LauncherUpdate.swift" "$root/macos/Launcher.swift" \
    -o "$tmp/launcher-$target"
done
xcrun lipo -create "$tmp/launcher-arm64" "$tmp/launcher-x86_64" -output "$tmp/launcher"
xcrun lipo "$tmp/launcher" -verify_arch arm64 x86_64
[[ "$("$tmp/launcher" --version)" == unknown ]] || fail 'bare native version entry point failed'
if "$tmp/launcher" --verify-resources >"$tmp/resource-check.log" 2>&1; then fail 'bare launcher accepted missing resources'; fi
[[ "$(cat "$tmp/resource-check.log")" == INSTALL_RESOURCES ]] || fail 'resource preflight must expose only its safe failure code'
mkdir "$tmp/working"
printf 'keep\n' > "$tmp/working/sentinel"
for optimization in -Onone -O; do
  xcrun swiftc -swift-version 5 -parse-as-library "$optimization" "$root/macos/LauncherCore.swift" "$root/macos/tests/InstallerCoreTests.swift" -o "$tmp/core-tests"
  (cd "$tmp/working" && "$tmp/core-tests")
  [[ "$(cat "$tmp/working/sentinel")" == keep ]] || fail 'installer touched its working directory'
  xcrun swiftc -swift-version 5 -parse-as-library "$optimization" "$root/macos/LauncherCore.swift" "$root/macos/tests/TemporaryDirectoryTests.swift" -o "$tmp/temporary-tests"
  (cd "$tmp/working" && "$tmp/temporary-tests")
done
xcrun swiftc -swift-version 5 -parse-as-library "$root/macos/LauncherUpdate.swift" "$root/macos/tests/LauncherUpdateTests.swift" -o "$tmp/update-tests"
"$tmp/update-tests"
xcrun swiftc -swift-version 5 -parse-as-library -D LAUNCHER_GUI_TESTING \
  "$root/macos/Launcher.swift" "$root/macos/LauncherCore.swift" "$root/macos/LauncherUpdate.swift" \
  "$root/macos/tests/GUIContractTests.swift" -o "$tmp/gui-tests"
"$tmp/gui-tests"
printf 'PASS: universal native macOS launcher and core/update tests\n'
