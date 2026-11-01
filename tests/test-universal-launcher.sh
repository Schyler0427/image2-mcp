#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bash -n "$root/scripts/build-universal-windows-launcher.sh" || fail 'universal launcher builder has shell syntax errors'
go test ./cmd/windows-launcher -run 'TestCompiledEmbeddedPayloadsAreComplete|TestExtractEmbeddedPayload|TestEmbeddedPath|TestInstallEmbeddedWorkspaceCleanup' || fail 'embedded payload tests failed'
grep -Fq 'for arch in 386 amd64 arm64' "$root/scripts/build-universal-windows-launcher.sh" || fail 'builder does not compile all native payloads'
grep -Fq 'sha256' "$root/scripts/build-universal-windows-launcher.sh" || fail 'builder does not generate SHA-256 manifest'
printf 'PASS: universal launcher extraction fixtures and build contract\n'
