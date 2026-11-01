# Task 2 — dual-provider install and launcher

Implemented in `/Users/schyler/.codex/worktrees/image-response-fix/image2-mcp`, branch `codex/gemini-dual-keys`.

## Changes
- Added `InstallerCredentials{Image2Key, GeminiKey}` with separate mandatory, nonblank, single-line, NUL-free values limited to 1024 bytes. The suspended Windows installer receives exactly two newline-terminated values through stdin before it resumes. Existing cancellation and commit/rollback boundaries are preserved.
- Added two Windows password fields and propagated the credential object through GUI callbacks, embedded extraction and installer execution. Both fields clear when installation starts. No credential is included in process arguments or child environment.
- Extended output redaction to both credentials, including split write boundaries and overlapping credential values. Added focused regression tests.
- Bash and PowerShell key-only and interactive installation request fresh provider-specific credentials every time, validate both before writing, and atomically store both in protected `.env.local`. No inherited or saved-key reuse prompt remains. `.env.local` takes precedence over legacy `.env`.
- Bash reads each key byte-by-byte to detect NUL and avoid buffered readers consuming the second line. Prompts are emitted sequentially, allowing one input line after each prompt. Bash keeps credentials unexported during key-only installation so download/build subprocesses do not inherit them.
- Bootstrap, offline version preflight and verification subprocesses clear inherited provider credentials. Runtime runners clear both inherited keys, then load local `.env.local` or the legacy `.env` fallback, preventing a missing local provider key from using an unrelated ambient key.
- Expanded Bash and PowerShell fixtures for two-key input, replacement, invalid/missing Gemini input, redaction, ambient-key isolation, runner loading, backup and rollback behavior.
- Preserved previous authorized dirty changes in owned installer files. Version strings remain 0.3.5 for root to synchronize to 0.4.0. No GUI copy promises a Gemini default; latest user correction makes Image2 the default.

## Verification
- Red phase: new credential API tests failed before `InstallerCredentials` existed; Bash dual-key fixture failed because GEMINI_IMAGE_API_KEY was absent. Additional regressions failed for legacy `.env` overwriting fresh interactive credentials, partially redacted overlapping credentials, and ambient Gemini values reaching offline version preflight. Each passed after its fix.
- `go test ./cmd/windows-launcher` — passed.
- `go test -race ./cmd/windows-launcher` — passed.
- `GOOS=windows GOARCH=386 CGO_ENABLED=0 go test -c -o /tmp/image2-windows-launcher-test-386.exe ./cmd/windows-launcher` — passed. Windows test executable compiled; not run on macOS.
- `GOOS=windows GOARCH=386 CGO_ENABLED=0 go build -o /tmp/image2-windows-launcher-386.exe ./cmd/windows-launcher` — passed.
- `bash tests/test-install-key-only.sh` — passed, including latest sequential reader, invalid Gemini input, fresh interactive precedence and download environment isolation.
- `bash tests/test-offline-install.sh` — passed with actual locally built MCP binary; covers two-key first install, replacement, failed repeat rollback, MCP handshake and damaged package refusal.
- `env OPENAI_IMAGE_API_KEY=ambient-image-key GEMINI_IMAGE_API_KEY=ambient-gemini-key bash tests/test-agent-bootstrap.sh` — passed, including child environment isolation.
- `bash -n` for changed Bash production/test scripts — passed.
- PowerShell child commit `edeb5d27fc5d8a226a4d660b9945679ad2babe43`: 8 static contracts and runner isolation check passed; six changed PowerShell scripts parsed without syntax errors via tree-sitter. Parent reran that parser successfully. Details are in `/tmp/gemini-dual-key-powershell-report.md`.
- `git diff --check` — passed.

## Limits
This macOS host has no powershell.exe/pwsh or Windows GUI runtime. Windows PowerShell 5.1 integration tests and actual GUI interaction have not run here. Cross-compilation and static syntax checks do not substitute for those runtime tests. No real credentials were used and no billed image request was made. Root still owns independent review, release version synchronization, complete suite and final packaging.

## Independent review follow-up — advanced install credential isolation
- Reproduced the review finding with a child Bash process after `write_interactive_env` and `load_legacy_environment`: it inherited both fresh keys because dotenv loading used `set -a`.
- Added that regression first; it failed with `interactive configuration exported credentials to child processes`. Added real `--interactive --prebuilt`, interactive source, existing local config with explicit smoke, and ambient-only source cases using fake curl and fake go subprocesses. All now pass.
- Bash removes the export attribute from both provider keys after local dotenv loading and explicitly supplies only the Image2 key to the authorized Image2 smoke subprocess. Fresh input helper values are also explicitly unexported.
- PowerShell wraps the full download/test/build stage in `Invoke-WithoutImageCredentials` with try/finally restoration. Explicit Image2 smoke receives only Image2 credentials, restores the previous smoke flag/Gemini environment afterward, and normal runners continue to load local config as before.
- Added PowerShell native fake `go.exe` integration cases for the same four advanced paths, a download guard requiring absent provider keys, and a failure-path restoration assertion. These Windows fixtures are authored but not executed on macOS. Before implementation, a static boundary assertion failed; after implementation six PowerShell files parse and the existing eight key contracts pass.
- Fresh verification: `bash tests/test-install-key-only.sh`, `bash tests/test-offline-install.sh`, Bash syntax check, `git diff --check`, six-file PowerShell tree-sitter parser and eight static key contracts all pass. No real API request was made. Retained root's 0.4.0 synchronization in the four touched tracked files.
