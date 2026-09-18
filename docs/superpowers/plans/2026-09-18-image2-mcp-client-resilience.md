# Image2 MCP Client Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Image2 MCP resilient to transient image API failures, accept user-facing home-directory paths, and route existing-image edits directly to `edit_image2`.

**Architecture:** Keep the two existing MCP tools and request structures. Add a shared internal HTTP helper in `internal/image2/client.go` that replays reusable request bytes for bounded transient retries, a shared path expansion helper for all filesystem inputs, and stronger routing text in `cmd/image2-mcp/main.go`.

**Tech Stack:** Go, `net/http`, `context`, `httptest`, Model Context Protocol Go SDK.

## Global Constraints

- Preserve tool names `generate_image2` and `edit_image2`.
- Preserve existing request JSON fields and fixed model selection behavior.
- Retry only HTTP `429`, `500`, `502`, `503`, and `504`, with three total attempts.
- Never include API keys or request payloads in errors.
- Use `apply_patch` for source edits and run `go test ./...` after each task.

### Task 1: Add transient API retry behavior

**Files:**
- Modify: `internal/image2/client_test.go`
- Modify: `internal/image2/client.go`

**Interfaces:**
- Add an internal `doImageRequest(ctx context.Context, method, endpoint string, body []byte, contentType string) ([]byte, http.Header, int, int, error)` helper.
- Keep `Generate` and `Edit` responsible for payload construction and response decoding.

- [ ] **Step 1: Write the failing tests**

Add `httptest.Server` tests that count requests for these behaviors:

```go
func TestGenerateRetries429ThenSucceeds(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":"busy"}`)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString([]byte("png"))}},
		})
	}))
	defer server.Close()

	client, err := New("test-key", server.URL, t.TempDir(), server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Generate(context.Background(), GenerateRequest{Prompt: "hello"}); err != nil {
		t.Fatal(err)
	}
	if got := attempts.Load(); got != 2 {
		t.Fatalf("attempts = %d, want 2", got)
	}
}
```

Add equivalent coverage for `503` followed by success, a `400` requested exactly once, and a final `429` with `Retry-After: 30` and `X-Request-ID: req-123` whose error contains `HTTP 429`, `3 attempt(s)`, `req-123`, and no `test-key`.

- [ ] **Step 2: Run the retry tests and verify they fail for the missing behavior**

Run:

```bash
go test ./internal/image2 -run 'TestGenerateRetries|TestGenerateDoesNotRetry|TestGenerateReportsFinalRetryError' -count=1
```

Expected: the retry success test fails because the current client returns on the first `429` or `503`.

- [ ] **Step 3: Implement the shared request helper**

Build each request from `body` on every attempt. Retry only the five transient statuses, wait on a context-aware timer, parse integer-second `Retry-After`, cap it at ten seconds, and otherwise use one second then two seconds. Capture `x-request-id` or `request-id` from the final response and format a bounded error after the last attempt.

- [ ] **Step 4: Route both API methods through the helper**

Pass JSON generation bodies with `application/json` and multipart edit bodies with the writer's content type. Preserve the existing response size limit and `saveImageResponse` behavior.

- [ ] **Step 5: Run focused and package tests**

Run:

```bash
go test ./internal/image2 -run 'TestGenerateRetries|TestGenerateDoesNotRetry|TestGenerateReportsFinalRetryError' -count=1
go test ./internal/image2 -count=1
```

Expected: all focused and package tests pass with no warnings.

- [ ] **Step 6: Commit the retry change**

```bash
git add internal/image2/client.go internal/image2/client_test.go
git commit -m "fix: retry transient image API failures"
```

### Task 2: Accept home-directory shorthand paths

**Files:**
- Modify: `internal/image2/client_test.go`
- Modify: `internal/image2/client.go`

**Interfaces:**
- Add an internal `expandPath(path string) (string, error)` helper.
- Apply it to image paths, mask paths, explicit output directories, and the client default output directory.

- [ ] **Step 1: Write the failing tests**

Set `HOME` to a temporary directory, create `input.png` and `mask.png` below it, call `Edit` with `~/input.png` and `~/mask.png`, and assert the server receives both files. Add a generation test with `OutputDir: "~/generated"` and assert the returned file path is under the expanded directory.

- [ ] **Step 2: Run the path tests and verify they fail**

Run:

```bash
go test ./internal/image2 -run 'TestEditExpandsHomePaths|TestGenerateExpandsHomeOutputDir' -count=1
```

Expected: the tests fail with the current absolute-path validation or write to the literal `~` path.

- [ ] **Step 3: Implement path expansion**

Trim whitespace, expand only `~`, `~/...`, and `~\\...` using `os.UserHomeDir`, then validate the expanded result with the existing absolute-path and regular-file checks. Do not expand `~other` or arbitrary environment variables.

- [ ] **Step 4: Run focused and package tests**

Run:

```bash
go test ./internal/image2 -run 'TestEditExpandsHomePaths|TestGenerateExpandsHomeOutputDir' -count=1
go test ./internal/image2 -count=1
```

Expected: all tests pass and no files are written outside the requested expanded output directory.

- [ ] **Step 5: Commit the path change**

```bash
git add internal/image2/client.go internal/image2/client_test.go
git commit -m "fix: expand home directory paths for image tools"
```

### Task 3: Strengthen MCP edit routing metadata

**Files:**
- Modify: `cmd/image2-mcp/main.go`
- Modify: `cmd/image2-mcp/main_test.go`

**Interfaces:**
- Keep the existing `editParams` schema and `edit_image2` tool name.
- Change only server instructions and the edit tool description.

- [ ] **Step 1: Write the failing metadata test**

Extend `TestServerInstructionsAndToolDescriptions` to require phrases equivalent to `existing image`, `call edit_image2`, `do not use Computer Use`, `preserve`, and `~` path support.

- [ ] **Step 2: Run the metadata test and verify it fails**

Run:

```bash
go test ./cmd/image2-mcp -run TestServerInstructionsAndToolDescriptions -count=1
```

Expected: the test fails because the current descriptions do not contain the direct edit routing rule.

- [ ] **Step 3: Update the MCP instructions and edit description**

State that requests involving existing images, photos, attachments, references, or masks must call `edit_image2`, pass all paths in order, preserve task details, and avoid Computer Use, browser, screenshot, or generic file tools for the transformation. Mention that `~` paths are accepted.

- [ ] **Step 4: Run the metadata and full test suites**

Run:

```bash
go test ./cmd/image2-mcp -run TestServerInstructionsAndToolDescriptions -count=1
go test ./...
```

Expected: all tests pass.

- [ ] **Step 5: Commit the routing metadata change**

```bash
git add cmd/image2-mcp/main.go cmd/image2-mcp/main_test.go
git commit -m "fix: clarify image edit MCP routing"
```

### Task 4: Final verification

**Files:**
- Verify: `internal/image2/client.go`
- Verify: `cmd/image2-mcp/main.go`
- Verify: `internal/image2/client_test.go`
- Verify: `cmd/image2-mcp/main_test.go`

- [ ] **Step 1: Run the complete Go test suite**

```bash
go test ./...
```

Expected: both packages pass.

- [ ] **Step 2: Inspect the final diff and repository status**

```bash
git diff origin/main...HEAD --stat
git diff origin/main...HEAD --check
git status --short --branch
```

Expected: only the design, plan, client, and MCP metadata changes are present; `git diff --check` prints no whitespace errors.

- [ ] **Step 3: Record the final commit range**

```bash
git log --oneline origin/main..HEAD
```

Report the commits and the fresh `go test ./...` result.
