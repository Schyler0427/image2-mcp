#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 && -d "$1/Contents/Resources" ]] || { echo 'usage: test-macos-packaged-install.sh APP_PATH' >&2; exit 1; }
app="$(cd "$1" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -O "$root/macos/LauncherCore.swift" "$root/macos/tests/PackagedInstallTests.swift" -o "$tmp/packaged-tests"
mkdir "$tmp/working"
printf 'keep\n' > "$tmp/working/sentinel"
(cd "$tmp/working" && "$tmp/packaged-tests" "$app/Contents/Resources" "$tmp/home")
[[ "$(cat "$tmp/working/sentinel")" == keep ]] || { echo 'FAIL: packaged install modified cwd' >&2; exit 1; }
