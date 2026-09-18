# Image2 MCP Client Resilience Design

## Problem

The customer conversation exposed three related failure modes:

- A transient `429 Too Many Requests` response surfaced as an exhausted retry failure without useful recovery information.
- Image editing requests contained user-facing paths such as `~/Documents/...`, while the client only accepted absolute paths.
- The model routed an edit request to Computer Use instead of the dedicated `edit_image2` MCP tool because the tool metadata did not state the routing rule strongly enough.

The current MCP server already exposes `generate_image2` and `edit_image2`. The change should preserve those tool names and request fields so existing installations remain compatible.

## Goals

- Retry transient image API responses locally with a bounded policy.
- Respect a server-provided `Retry-After` delay when it is usable, while keeping the delay bounded by the request context.
- Return a concise final error containing the HTTP status and available request identifier without exposing the API key or request body.
- Accept `~` and `~/...` paths for input images, masks, and output directories, then validate the expanded path.
- Make the MCP instructions and `edit_image2` description explicitly route existing-image edits to `edit_image2` and away from Computer Use, browser, and screenshot tools.
- Add regression tests for retry behavior, path expansion, and routing metadata.

## Non-goals

- Do not add a second editing tool or change existing tool names and JSON fields.
- Do not change the fixed gateway, model selection semantics, output format, or installation flow.
- Do not retry non-transient client errors such as `400`, `401`, `403`, or `404`.
- Do not add unbounded retries or hide a permanent API failure.

## Design

### HTTP request policy

Refactor the duplicated generation and edit request paths to use one internal request helper that receives a reusable request body and content type. The helper creates a fresh `http.Request` for every attempt so request bodies can be replayed safely.

The retry policy uses a maximum of three total attempts. It retries only `429`, `500`, `502`, `503`, and `504`. For each retry:

1. Parse `Retry-After` as a non-negative integer number of seconds when present.
2. If it is absent or invalid, use short exponential backoff: 1 second before attempt 2 and 2 seconds before attempt 3.
3. Cap any server-provided delay at 10 seconds.
4. Wait with a context-aware timer so cancellation ends the operation immediately.

The helper captures `Retry-After` and common request ID headers (`x-request-id`, `request-id`) from the final response. A final error has the form `image API returned HTTP <status> after <attempts> attempt(s): <summary>` and appends request ID and retry delay metadata only when available. The key is never included.

The existing 180-second HTTP client timeout remains unchanged. A transport error is returned directly because there is no response status to classify and automatic replay could duplicate an unknown request state.

### Path normalization

Add one internal `expandPath` helper:

- Trim surrounding whitespace.
- Expand exactly `~` or a path beginning with `~/` or `~\\` to `os.UserHomeDir()`.
- Leave other paths unchanged.
- Return an error when the home directory cannot be resolved.

Apply it to `image_paths`, `mask_path`, `output_dir`, and the client default output directory before validation or file creation. After expansion, image and mask paths must be absolute regular files; an explicitly supplied output directory must be absolute. The returned file path remains the actual expanded absolute path used for writing.

### MCP routing metadata

Update server instructions and the `edit_image2` description with direct routing language:

- Existing image, photo, attachment, reference image, or mask edit requests must call `edit_image2`.
- Pass all provided image paths in their original order; the first image is the primary input unless the user specifies otherwise.
- Preserve the user's requested subject, task details, style, pose, and composition in the prompt.
- Do not use Computer Use, browser navigation, screenshots, or generic file tools for the image transformation itself.
- Paths beginning with `~` are supported.

The tool schema remains unchanged. This metadata is intended to reduce model routing ambiguity without requiring a host-specific integration.

## Error handling

A retryable status that succeeds returns the normal image result and does not expose intermediate responses. A retryable status that exhausts its attempts returns one stable tool error with the final status, bounded attempt count, response summary, and request ID if the gateway provides one. A non-retryable status returns after one attempt with the same error format.

Response bodies continue to be limited before summarization. API keys and request payloads are never included in error messages.

## Testing

Add tests in `internal/image2/client_test.go` for:

- `429` followed by success, verifying the request is replayed and the result is saved.
- `503` followed by success, verifying bounded retry behavior.
- `400`, verifying no retry occurs.
- A final `429` with `Retry-After` and `X-Request-ID`, verifying the error contains status, attempt count, bounded metadata, and request ID but not the key.
- `~/...` image and mask paths, verifying the edit request succeeds with expanded paths.
- `~/...` output directory, verifying the output is written beneath the expanded directory.

Add or update tests in `cmd/image2-mcp/main_test.go` to assert that server instructions and the edit tool description contain the direct `edit_image2` routing guidance and the prohibition on Computer Use for the transformation.

Run `go test ./...` after each red-green cycle and once again as the final verification.
