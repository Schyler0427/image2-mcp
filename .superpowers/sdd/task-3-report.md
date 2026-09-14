# Task 3 Report

Updated customer documentation and contract assertions for key-only installation,
the fixed gateway, and natural-language Image 2.0/2.5 routing. Image 2.0 is the
documented default; maintainer-only overrides and the prohibition on requesting a
model ID, Base URL, or endpoint are explicit.

Verification:

- `bash tests/test-agent-install-contract.sh` passed.
- `go test ./...` passed.
- `git diff --check` passed.
