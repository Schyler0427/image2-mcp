Universal Windows launcher implementation

- Task 1: complete (commits 7949f174..89de69e, review approved)
- Task 2: complete (commits 1995461..35bbc0e, review approved for integrated launcher path; callback blocking remains documented API risk)
- Task 3: complete (4738565 and cee4190; nested-module embed exclusion fixed, all three real PE payloads verified inside final EXE)
- Task 4: complete (389268b and 8d19280; signed updates, dedicated offline installation button, signing-key matching, publisher documentation and CI)
- Task 5: local verification complete; final independent review found no remaining P0/P1. Windows runtime acceptance remains unexecuted in this macOS environment.

Final hardening:

- 30288d0: cancellation before PowerShell resume aborts safely; cancellation after resume waits for commit or rollback.
- 49c59bd: native and WOW64 PowerShell architecture regression tests, configured in Windows CI.
- 8d19280: Win32 OS-thread affinity, safe busy-window close, update result visibility, publisher golden vectors and trusted-key matching.

Final verification passed:

- go test ./...
- go test -race ./...
- go vet ./...
- git diff --check
- tests/test-universal-launcher.sh
- tests/test-agent-install-contract.sh
- tests/test-offline-package.sh
- tests/test-offline-install.sh
- tests/test-install-key-only.sh
- tests/test-agent-bootstrap.sh
- Universal builder with real Windows 386/amd64/arm64 MCP payloads and Windows 386 GUI launcher; final payload byte inclusion, PE metadata and hashes verified.
- Windows 386 test executable compiled; PowerShell transaction and architecture tests require Windows execution.
- CI workflow YAML syntax parsed successfully.

Artifact: /Users/schyler/Documents/image2-mcp/dist/universal-windows-launcher/SchylerAI-Image2-mcp.exe
Version: 0.3.5
Bytes: 44872192
SHA-256: 4f9fe98b272823497ea62701342ec296b904ae9b5b2da2d27a9ad3c59d9fefac

External prerequisites: deploy the signed manifest and identical EXE bytes to the fixed api.schyler.top update paths; provision CI signing secret. No remote publication or update-host deployment was performed. The signing private key is outside the repository.


Gemini and Image2 dual-key integration — 2026-10-28

- Task 1: complete (54f788d native Gemini client; b440a5f bounded diagnostics; 563655e applies the same diagnostic protections to the prior Image2 response fix).
- Task 2: complete (edeb5d2 and d278e1f dual-key install/launcher; b9b84b1 advanced installer child environment isolation).
- Task 3: complete (e218ed1 generic MCP tools, default Image2 with explicit Gemini/banana/香蕉 aliases; confirmed Gemini model gemini-3.1-flash-image; version0.4.0).
- Task 4: local verification and packaging complete; independent review findings fixed with red-green regression evidence. Windows runtime acceptance and real paid API checks remain unexecuted.

Fresh verification: go test -count=1 ./...; go test -race -count=1 ./...; go vet ./...; git diff --check; Bash key-only (including interactive download/build isolation and Image2-only smoke), bootstrap, agent contract, offline packaging, real offline install/repeat/rollback, universal launcher extraction; Windows386 MCP/launcher test cross-compilation; final real universal builder with exact embedded payload checks. PowerShell source parsed statically; native runtime fixtures are present for Windows CI.

Final artifact: /Users/schyler/Documents/image2-mcp/dist/universal-windows-launcher/SchylerAI-Image2-mcp.exe
Version: 0.4.0
Bytes: 45680128
SHA-256: 0b700ac41927af0c70beaeeb4ef779fc93d717789f188515d78f73cfa9ad540b
Companion SHA256SUMS.txt and 使用说明.txt written. The signed online update service has not been deployed; the embedded offline installer works independently of it.
