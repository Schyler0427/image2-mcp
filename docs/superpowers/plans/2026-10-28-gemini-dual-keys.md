# Gemini dual-key image generation implementation plan

> **For agentic workers:** Use subagent-driven-development with disjoint file scopes, test first, independent review, and report the evidence before completion.

**Goal:** One Windows launcher with two dedicated image keys; natural-language Image2, Image2.5 and Gemini selection; default to Image2; select Gemini only for explicit Gemini/banana/香蕉 requests.

**Architecture:** Add a self-contained native Gemini client and generic MCP tools, while retaining existing Image2 tool compatibility. Extend the existing stdin-only installer credential channel to two lines and keep signed updater separate from keys.

**Global constraints:** Never copy real keys from the reference thread, reuse another provider key, make a billed request without an explicit reason, or hide a model substitution. Keep existing response fixes and uncommitted changes. Reuse the attached isolated worktree on codex/gemini-dual-keys.

### Task 1: Gemini native client

Owned files: internal/gemini/*.go and required go.mod/go.sum changes.

Interface: New(apiKey, baseURL, model, outputDir string, httpClient *http.Client) (*Client, error). Request has Prompt, ImagePaths, AspectRatio, ImageSize, OutputDir, OutputName. Result has FilePath, Model, Size. Generate and Edit return Result; Edit requires references. The protocol client requires an explicit model; unified tools default to Image2; explicit Gemini requests use the user-confirmed gemini-3.1-flash-image (Gemini 3.1 Flash Image). Credentials are passed explicitly.

- [x] Write HTTP fixture tests for generate/edit, x-goog-api-key isolation, native payload shape, text-before-image, thought-image skipping, snake_case responses, MIME decoding, JPEG/WebP conversion, invalid/missing images, blocked output, redacted diagnostic, redirect rejection, cancellation and no retry.
- [x] Observe expected initial failure; implement native JSON protocol and bounded image handling with actual image decoding. Use 300s timeout, 64MiB response/aggregate inputs, 32 million pixel limit, maximum 16 references, output_dir absolute or tilde-expanded.
- [x] Run tests and race; commit only task files and write task report.

### Task 2: Two-key install and launcher

Owned files: cmd/windows-launcher credential/GUI/process/extraction code and tests (exclude updater metadata), install.ps1, scripts/setup.sh, runner scripts if needed, bootstrap scripts, installation fixture tests.

Interface: InstallerCredentials{Image2Key string; GeminiKey string}; validate both single-line <=1024 bytes. LauncherCallbacks.Install and InstallEmbedded accept credentials. RunInstaller writes Image2Key + newline + GeminiKey + newline while PowerShell remains suspended, then resumes. Neither key is in args, env or status. Output redaction covers both even across writes. Keep the cancellation transaction boundary.

- [x] Add tests for two-key stdin, validation, multi-secret redaction and failed installs preserving previous configuration.
- [x] Add two password boxes and fresh two-key prompts. Save OPENAI_IMAGE_API_KEY and GEMINI_IMAGE_API_KEY separately to protected .env.local. No key reuse, including inherited provider variables.
- [x] Update Bash and PowerShell fixtures to supply two keys and assert distinct values, redaction, runner loading and rollback. Do not bump version in this task.
- [x] Run focused Go, Windows cross-compile, Bash install tests; commit task files and report.

### Task 3: MCP routing, metadata, docs and version

Owned files: cmd/image2-mcp/*, new internal/image routing helper if useful, README/AGENT_INSTALL/OFFLINE_INSTALL and version marker updates.

- [x] Test four tools through actual MCP sessions; new generate_image/edit_image model=gemini|image2|image2.5 default Image2, explicit Gemini/banana/香蕉 aliases. Test credentials never cross providers and legacy tools retain Image2 semantics.
- [x] Add generic tools using Gemini client and existing Image2 client. Add independent Gemini environment configuration, error for missing selected key, no provider fallback, and explicit unsupported-mask/quality checks.
- [x] Update verification to require four tools and validate both dedicated keys without making remote calls.
- [x] Keep Image2 as the default. Explicit Gemini/banana/香蕉 requests select gemini-3.1-flash-image, labeled Gemini 3.1 Flash Image. Bump release to 0.4.0 and synchronize fixed installers/manifests/fixtures. Update docs and instructions for natural language and dual-key installation.

### Task 4: Full verification and packaging

- [x] Independent review of task changes including key privacy and protocol semantics; fix findings and rerun covering tests.
- [x] go test ./..., go test -race ./..., go vet ./..., git diff --check; all Bash installer/bootstrap/package/contract tests. PowerShell syntax/contracts and Windows test programs cross-compiled; Windows runtime tests remain explicitly unexecuted on macOS.
- [x] Cross-build launcher and native 386/amd64/arm64 MCP; real builder verifies all three payload byte sequences. Deliver versioned EXE under project dist with SHA256SUMS.
- [x] Explicitly report Windows runtime and real Gemini call limitations; do not claim deployed update host.

## Completion evidence (2026-10-28)

Final user choice: default Image2; explicit Gemini/banana/香蕉 routes to Gemini 3.1 Flash Image. Both provider keys are independently configured and required on a fresh installation. Independent reviewers covered MCP routing and installer credential isolation; privacy, diagnostic resource bounds, special-file preflight, and advanced-installer child environment findings were fixed with local regression tests.

Version 0.4.0 artifact: /Users/schyler/Documents/image2-mcp/dist/universal-windows-launcher/SchylerAI-Image2-mcp.exe

Bytes: 45680128. SHA-256: 0b700ac41927af0c70beaeeb4ef779fc93d717789f188515d78f73cfa9ad540b. Builder verified exact byte inclusion of the 386/amd64/arm64 native payloads and GUI subsystem before artifact replacement.

No Windows GUI or PowerShell 5.1 runtime execution, real key reuse, billed image requests, GitHub release publication, or update-host deployment was performed.
