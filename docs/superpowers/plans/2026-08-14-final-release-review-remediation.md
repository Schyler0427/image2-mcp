# Final Release Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every Critical/Important whole-branch finding before publishing `v0.2.1`, then obtain fresh local, native Windows PowerShell 5.1, and whole-branch review evidence.

**Architecture:** Keep the installers dependency-free and conservative. Bash and PowerShell reject ambiguous TOML/Git ownership before persistent mutation, Git-free parsing accepts only a provable standard worktree root, usable Git adds an independent top-level check, and PowerShell 5.1 web calls use basic parsing plus additive TLS 1.2. Documentation remains the exact implemented helper-owned transaction contract.

**Tech Stack:** Bash 3.2, awk, Windows PowerShell 5.1, Git config text format, GitHub Actions, Go.

## Global Constraints

- Fixed repository: `https://github.com/Schyler0427/image2-mcp`.
- Fixed public Release: non-draft/non-prerelease `v0.2.1` with all six exact assets.
- The only customer input is `OPENAI_IMAGE_API_KEY`, read once through child stdin and never printed or derived in diagnostics.
- Reject ambiguous TOML or Git ownership before target/config/key persistent writes; never print customer config values.
- Customer machines must not require Git, Go, Python, jq, or a new TOML library.
- Bash must remain compatible with Bash 3.2 and Windows code with Windows PowerShell 5.1.
- Do not update `main`, create a tag, or publish a Release.

---

### Task 1: Reject conflicting dotted and inline TOML definitions

**Files:**
- Modify: `tests/test-install-key-only.sh`
- Modify: `tests/test-install-key-only.ps1`
- Modify: `scripts/setup.sh`
- Modify: `install.ps1`

**Interfaces:**
- Consumes: existing header validation and atomic config replacement.
- Produces: context-aware assignment validation invoked before key input or any persistent write.

- [ ] **Step 1: Add Bash RED fixtures**

Create untouched-refusal cases for each conflicting shape, including quoted equivalents:

```toml
mcp_servers.image2.command = "old"
"mcp_servers" . "image2" . command = "old"
mcp_servers = { image2 = { command = "old" } }
[mcp_servers]
image2.command = "old"
[mcp_servers]
'image2' = { command = "old" }
```

Require non-zero status and fixed message `unsupported conflicting Image2 TOML assignment`, assert output omits `old`, compare the original config hash, and prove `.env.local`/binary remain absent or unchanged.

- [ ] **Step 2: Verify Bash RED**

Run `bash tests/test-install-key-only.sh`.
Expected: FAIL because the current installer appends `[mcp_servers.image2]` and reports success.

- [ ] **Step 3: Add and verify PowerShell RED fixtures**

Add equivalent configs to `tests/test-install-key-only.ps1`. Run them in the Task 5 native workflow and require non-zero status, fixed redacted diagnostic, byte-identical config, and no persistent key/binary/config mutation.

- [ ] **Step 4: Implement context-aware conservative validation**

Reuse each installer's existing quoted-key decoder. Track the current table and parse only assignment LHS up to an unquoted `=`. Reject these effective paths without reading or printing RHS:

```text
root + mcp_servers
root + mcp_servers.image2[...]
[mcp_servers] + image2[...]
```

Call validation before `read_key_once` / `Read-KeyOnlyApiKey` and before `.env.local`, binary, or config writes.

- [ ] **Step 5: Verify GREEN and commit**

Run Bash locally and PowerShell natively; existing root/descendant replacement and unrelated/quoted sibling fixtures must still pass.

```bash
git add scripts/setup.sh install.ps1 tests/test-install-key-only.sh tests/test-install-key-only.ps1
git commit -m "fix: reject conflicting Image2 TOML assignments"
```

### Task 2: Prove Git worktree ownership before replacement

**Files:**
- Modify: `tests/test-agent-bootstrap.sh`
- Modify: `tests/test-agent-bootstrap.ps1`
- Modify: `scripts/bootstrap-agent-install.sh`
- Modify: `scripts/bootstrap-agent-install.ps1`

**Interfaces:**
- Consumes: exact `.git/config` origin parsing and fixed target path.
- Produces: strict no-Git structural proof plus usable-Git top-level proof.

- [ ] **Step 1: Add Bash and PowerShell RED fixtures**

Starting from valid targets, create separate cases for `core.bare=true`, `core.worktree=../elsewhere`, `[include]`, `[includeIf]`, `.git/config.worktree`, and `extensions.worktreeConfig=true`. Add an available-Git fixture whose `rev-parse --show-toplevel` differs from target. Require refusal before source download/key input/target mutation and preserve a sentinel hash.

- [ ] **Step 2: Verify RED**

Run `bash tests/test-agent-bootstrap.sh` and native `.\tests\test-agent-bootstrap.ps1`.
Expected: at least `core.worktree` is accepted before the fix.

- [ ] **Step 3: Implement strict config proof**

Both helpers must:

- require plain `.git` directory and config file;
- reject include/includeIf sections, any `core.worktree`, `core.bare=true` or ambiguous duplicate, `extensions.worktreeConfig=true`, and `.git/config.worktree`;
- retain exactly one byte-exact fixed origin URL;
- avoid resolving include paths or printing values.

When Git is usable, select one executable deterministically and require `rev-parse --show-toplevel` to equal the target after full-path normalization. A missing/nonfunctional executable uses strict config proof; a usable Git whose check fails is a refusal.

- [ ] **Step 4: Verify GREEN and commit**

Keep the Bash blocked-Git fixture (nonfunctional wrapper is unavailable), standard exact-origin repeat, and native deterministic `Get-Command ... | Select-Object -First 1` coverage.

```bash
git add scripts/bootstrap-agent-install.sh scripts/bootstrap-agent-install.ps1 tests/test-agent-bootstrap.sh tests/test-agent-bootstrap.ps1
git commit -m "fix: prove bootstrap Git worktree ownership"
```

### Task 3: Make every Windows PowerShell 5.1 GitHub hop compatible

**Files:**
- Modify: `install.ps1`
- Modify: `scripts/bootstrap-agent-install.ps1`
- Modify: `tests/test-install-key-only.ps1`
- Modify: `tests/test-agent-bootstrap.ps1`
- Modify: `AGENT_INSTALL.md`

**Interfaces:**
- Produces: additive TLS 1.2 helpers and `-UseBasicParsing` on every GitHub web cmdlet call, including the Agent's initial helper download.

- [ ] **Step 1: Add RED mock assertions**

Mocks accept `[switch]$UseBasicParsing` and fail if absent or if TLS1.2 is not enabled. Start with another protocol flag where supported and assert it remains enabled.

- [ ] **Step 2: Verify native RED**

Run both PowerShell suites. Expected: missing basic-parsing/TLS assertion.

- [ ] **Step 3: Implement additive TLS and basic parsing**

Use this pattern in both production scripts:

```powershell
function Enable-Image2Tls12 {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
```

Call it before GitHub access and add `-UseBasicParsing` to every production `Invoke-RestMethod` / `Invoke-WebRequest`. Never replace the flags with TLS1.2 alone.

- [ ] **Step 4: Fix the Agent's first Windows hop**

`AGENT_INSTALL.md` must instruct the Agent, before any helper exists, to OR TLS1.2 and run:

```powershell
Invoke-WebRequest -UseBasicParsing -Uri URL -OutFile FILE
```

- [ ] **Step 5: Run real native probe and commit**

The temporary workflow applies the production additive helper and requests public GitHub repository metadata under Windows PowerShell 5.1. Assert HTTP success, TLS1.2 present, and prior flags retained.

```bash
git add install.ps1 scripts/bootstrap-agent-install.ps1 tests/test-install-key-only.ps1 tests/test-agent-bootstrap.ps1 AGENT_INSTALL.md
git commit -m "fix: support PowerShell 5.1 GitHub downloads"
```

### Task 4: Align README and contract tests

**Files:**
- Modify: `README.md`
- Modify: `tests/test-agent-install-contract.sh`
- Verify: `docs/superpowers/specs/2026-08-07-agent-key-only-install-design.md`

- [ ] **Step 1: Add README RED contract**

Require exact `v0.2.1` trigger wording and reject literal `` `v*` tag ``.

- [ ] **Step 2: Verify RED**

Run `bash tests/test-agent-install-contract.sh`.
Expected: `FAIL: README release trigger is not pinned to v0.2.1`.

- [ ] **Step 3: Fix README, verify GREEN, and commit**

Replace only the stale trigger sentence and scan the approved design for pending implementation, default-branch archives, in-place update, selective preservation, or temporary previous-target cleanup.

```bash
bash tests/test-agent-install-contract.sh
git diff --check
git add README.md tests/test-agent-install-contract.sh
git commit -m "docs: pin README release trigger to v0.2.1"
```

### Task 5: Native verification, cleanup, and fresh review

**Files:**
- Temporarily create/delete: `.github/workflows/windows-bootstrap-review.yml`
- Update ignored: `.superpowers/sdd/final-review-fix-report.md`
- Regenerate ignored: `.superpowers/sdd/review-b5eb615..<HEAD>.diff`

- [ ] **Step 1: Add temporary Windows workflow**

Target only `codex/agent-key-only-install`; parse PowerShell files; run the real TLS/basic-parsing probe; run both PowerShell suites with bounded timeout and no key/test stream in workflow commands/logs.

- [ ] **Step 2: Record native GREEN**

Push, wait for completion, and record run/job IDs plus parser, TLS probe, installer, and bootstrap conclusions. Diagnose failures from exact redacted logs.

- [ ] **Step 3: Remove the workflow separately**

```bash
git add .github/workflows/windows-bootstrap-review.yml
git commit -m "ci: remove temporary Windows remediation validation"
git push fork codex/agent-key-only-install
```

- [ ] **Step 4: Run fresh complete local verification**

```bash
for file in $(rg --files -g '*.sh' scripts tests); do bash -n "$file"; done
bash tests/test-agent-bootstrap.sh
bash tests/test-agent-install-contract.sh
bash tests/test-install-key-only.sh
go test ./...
go build ./...
git diff --check
git status --short
```

- [ ] **Step 5: Regenerate evidence and request review**

Append focused RED/GREEN evidence and corrected final SHA to the ignored report. Generate a full binary diff from `fork/main` to final HEAD. Dispatch a fresh read-only reviewer with no prior session history.

- [ ] **Step 6: Resolve review findings**

Fix every Critical/Important finding with a focused regression, rerun affected local/native suites, regenerate the package, and request another fresh review until no Critical or Important issues remain.

