# Direct API Agent Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Image2 MCP default to Image 2.0 while letting the Agent select Image 2.5 from a natural-language “2.5” request, with the customer providing only an API Key.

**Architecture:** Keep the fixed `https://api.schyler.top` gateway and local key-only runner. Add a public `version` selector (`2.0` or `2.5`) to generation and edit tool inputs; the client maps it to internal model IDs, while an empty selector uses the configured default (`gpt-image-2.0` unless a maintainer explicitly sets `OPENAI_IMAGE_MODEL`). MCP Instructions and tool descriptions teach automatic natural-language routing and explicit “使用 image2” routing.

**Tech Stack:** Go, modelcontextprotocol/go-sdk, Bash/PowerShell installers, Markdown documentation, Go unit tests.

## Global Constraints

- Default model is `gpt-image-2.0` when `OPENAI_IMAGE_MODEL` is not explicitly set.
- Image 2.5 maps internally to `gpt-image-2.5-sunburst`; customers never enter a model ID.
- Fixed default gateway is `https://api.schyler.top`.
- Installation asks only for `OPENAI_IMAGE_API_KEY`, stores it in local `.env.local`, and does not request elevation.
- Do not make a billable image API request during verification.
- Preserve existing `OPENAI_IMAGE_MODEL` support for maintainer-level overrides.

### Task 1: Add version mapping and request overrides

**Files:**
- Modify: `internal/image2/client.go:22-120,132-290`
- Test: `internal/image2/client_test.go:55-155,285-380`

**Interfaces:**
- `GenerateRequest.Version` and `EditRequest.Version` are optional public request fields containing only `"2.0"` or `"2.5"`.
- `resolveRequestedModel(version string, configured string) (string, error)` maps an empty version to `configured`, `2.0` to `gpt-image-2.0`, and `2.5` to `gpt-image-2.5-sunburst`; other values return `image version must be 2.0 or 2.5`.

- [ ] **Step 1: Write failing tests**

Add tests that clear `OPENAI_IMAGE_MODEL` and assert generation sends `gpt-image-2.0`, generation with `Version: "2.5"` sends `gpt-image-2.5-sunburst`, and edit with `Version: "2.5"` sends the same model in multipart form. Add an invalid-version test asserting the exact validation error.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `go test ./internal/image2 -run 'TestGenerateUsesImage20DefaultModel|TestGenerateVersion25|TestEditVersion25|TestRejectsInvalidImageVersion'`

Expected: FAIL because the default constant and `Version` fields/mapping do not yet exist.

- [ ] **Step 3: Implement the minimal mapping**

Define:

```go
const (
    DefaultBaseURL = "https://api.schyler.top"
    DefaultModel = "gpt-image-2.0"
    Image25Model = "gpt-image-2.5-sunburst"
)
```

Add `Version string` to both request structs. Resolve the model at the beginning of `Generate` and `Edit`, use the resolved value in the request payload/form and returned result, and preserve `OPENAI_IMAGE_MODEL` as the empty-version fallback.

- [ ] **Step 4: Run focused and package tests**

Run: `go test ./internal/image2`

Expected: PASS with all client tests, including the existing configured-model tests.

- [ ] **Step 5: Commit**

```bash
git add internal/image2/client.go internal/image2/client_test.go
git commit -m "feat: default to image 2.0 with friendly version selection"
```

### Task 2: Teach MCP automatic and explicit routing

**Files:**
- Modify: `cmd/image2-mcp/main.go:15-100`
- Test: `cmd/image2-mcp/main_test.go:10-70`

**Interfaces:**
- `generateParams.Version` and `editParams.Version` expose the friendly selector to MCP as an optional field.
- Tool handlers pass `params.Version` into the corresponding internal request.

- [ ] **Step 1: Write failing metadata tests**

Add a test that connects to `newServer`, reads `Implementation.Instructions` and both tool descriptions, and asserts they mention automatic generation for “帮我生成一张图”, explicit “使用 image2”, default Image 2.0, and selecting Image 2.5 by saying “用 2.5 生图”, while asserting the internal model ID is absent from customer-facing text.

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `go test ./cmd/image2-mcp -run 'TestServerInstructions|TestToolDescriptions'`

Expected: FAIL because the current metadata advertises Image 2.5 as the default and has no routing guidance.

- [ ] **Step 3: Implement metadata and handler wiring**

Update Instructions and descriptions to state: natural-language image requests automatically call `generate_image2`; “使用 image2” is an explicit option; no Base URL, model ID, endpoint, Go, Git, or admin permission should be requested; no version means Image 2.0; “2.5” selects Image 2.5. Add `Version` fields and pass them to client requests.

- [ ] **Step 4: Run package tests**

Run: `go test ./cmd/image2-mcp`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/image2-mcp/main.go cmd/image2-mcp/main_test.go
git commit -m "feat: route image requests by friendly version"
```

### Task 3: Update customer documentation and contract tests

**Files:**
- Modify: `README.md:1-25,130-145,330-430`
- Modify: `AGENT_INSTALL.md:1-85`
- Test: `tests/test-agent-install-contract.sh`

**Interfaces:**
- Customer-facing docs describe only the friendly `2.0`/`2.5` terms and the fixed gateway; installation remains key-only.

- [ ] **Step 1: Extend the contract test with failing assertions**

Require the README and AGENT_INSTALL content to contain `用 2.5 生图`, `gpt-image-2.0`, automatic `generate_image2` routing, and the fixed gateway, and to omit instructions asking customers to enter a model ID.

- [ ] **Step 2: Run the contract test and verify it fails**

Run: `bash tests/test-agent-install-contract.sh`

Expected: FAIL on the old Image 2.5 default documentation.

- [ ] **Step 3: Update docs and contract assertions**

Rewrite examples and response samples to show Image 2.0 as the default. Add concise examples for “帮我生成一张图”, “使用 image2 生成”, and “用 2.5 生图”. State that the customer supplies only the Key and never a model ID, Base URL, or endpoint.

- [ ] **Step 4: Run documentation and full baseline tests**

Run: `bash tests/test-agent-install-contract.sh && go test ./... && git diff --check`

Expected: PASS with no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENT_INSTALL.md tests/test-agent-install-contract.sh
git commit -m "docs: document key-only image version routing"
```

### Task 4: Run release-grade verification and prepare handoff

**Files:**
- Inspect: `.github/workflows/release.yml`
- Inspect: `tests/test-agent-bootstrap.sh`, `tests/test-agent-bootstrap.ps1`, `tests/test-install-key-only.sh`, `tests/test-install-key-only.ps1`

- [ ] **Step 1: Run all local checks**

Run: `go test ./...`, `bash tests/test-agent-bootstrap.sh`, `bash tests/test-install-key-only.sh`, and the available PowerShell test scripts.

- [ ] **Step 2: Build all six release targets**

Run the workflow-equivalent builds for darwin/arm64, darwin/amd64, linux/arm64, linux/amd64, windows/arm64, and windows/amd64, writing outputs under a temporary directory.

- [ ] **Step 3: Inspect the final diff**

Run: `git diff fork/main...HEAD --stat` and `git status --short`; confirm no key, temporary helper, or generated binary is tracked.

- [ ] **Step 4: Commit any verification-only fixes**

Only if a test exposes a regression, add the smallest fix and rerun the affected check before committing it.
