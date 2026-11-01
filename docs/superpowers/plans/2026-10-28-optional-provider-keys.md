# Optional Provider Keys Implementation Plan

> **For agentic workers:** Execute independent Windows, Mac and documentation changes in parallel, then verify the complete packaged installation.

**Goal:** Accept one or both independent image keys and present Chinese launcher controls.

**Architecture:** Preserve the fixed two-line credential protocol and existing atomic installation/rollback. Normalize only valid whitespace-only fields to empty, require at least one provider, and verify only configured providers before the local MCP handshake.

**Tech Stack:** Go, Win32, Swift/AppKit, Bash, Windows PowerShell 5.1.

## Global constraints

- Default Image2 and explicit Gemini routing remain unchanged.
- No cross-provider, ambient, or old-key fallback.
- No real image API calls or changes to the developer's installed configuration.
- New local artifacts use 0.4.1; the already published online Agent gate remains v0.4.0.

## Tasks

- [ ] Add failing single-provider credential, GUI, installer, and packaged-install regressions.
- [ ] Update Windows credential validation and Chinese UI; run Go tests and compile all Windows targets.
- [ ] Update Mac credential normalization, form copy and regressions; run native Swift and GUI action tests.
- [ ] Update shared Bash/PowerShell input validation and environment verification; require two lines but only one nonempty value.
- [ ] Update local MCP verification to validate configured providers only; keep all four-tool handshake.
- [ ] Update current docs and version to 0.4.1, preserving truthful published-gate limitations.
- [ ] Build universal EXE and universal Mac app/DMG, test actual packaged installation in isolated homes, review changes, and deliver verified files.
