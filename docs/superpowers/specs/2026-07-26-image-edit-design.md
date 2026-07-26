# Image Edit MCP Design

## Goal

Add image-to-image support without changing the existing `generate_image2`
tool. The new tool must accept one or more local reference images, call the
OpenAI-compatible image edits endpoint, and save the returned PNG locally.

## Chosen Approach

Add a separate MCP tool named `edit_image2`. Keeping generation and editing as
separate tools makes their schemas and HTTP contracts explicit and preserves
backward compatibility for existing `generate_image2` callers.

The alternatives were rejected for these reasons:

- Adding optional image inputs to `generate_image2` would make one tool switch
  endpoints and request formats implicitly.
- Sending base64 images through MCP arguments would make calls large and less
  reliable than passing local paths in this local STDIO workflow.

## Tool Contract

`edit_image2` accepts:

- `prompt` (required string): instructions for the edit.
- `image_paths` (required string array): one or more absolute local image
  paths, preserved in request order.
- `size` (optional string): defaults to `1024x1024`.
- `quality` (optional string): defaults to `auto`.
- `output_dir` (optional string): absolute output directory.
- `output_name` (optional string): PNG file name.

The result uses the existing result shape:

- `file_path`
- `model`
- `size`

## Components

### MCP Server

Register `edit_image2` alongside `generate_image2`. The handler maps MCP
arguments into an image client edit request and returns the structured result
plus the existing JSON text representation.

### Image Client

Add an edit endpoint derived from `OPENAI_IMAGE_BASE_URL`. The endpoint builder
must accept base URLs ending in the host root, `/v1`, `/images/edits`, or
`/v1/images/edits` without duplicating path segments.

The edit request validates inputs, builds a `multipart/form-data` body, and
adds these fields:

- `model=gpt-image-2`
- `prompt=<prompt>`
- `size=<size>`
- `quality=<quality>`
- one repeated `image` part per `image_paths` entry

Each image part uses the base file name and detected content type. The client
parses `data[0].b64_json` and reuses the current output directory, file-name
sanitization, and PNG writing behavior.

## Validation And Errors

- Reject an empty prompt.
- Reject an empty `image_paths` array.
- Require every image path to be absolute, exist, and refer to a regular file.
- Return errors that identify the failing image path without exposing the API
  key.
- Reject a relative `output_dir` using the existing behavior.
- Preserve non-2xx response summaries and missing `b64_json` checks.
- Keep the existing 180-second HTTP timeout.

## Testing

Use test-driven development for each behavior:

1. Endpoint construction for supported base URL shapes.
2. Input validation for prompt, image list, absolute paths, and missing files.
3. Multipart request fields and repeated ordered image parts against an
   `httptest` server.
4. Successful base64 response decoding and PNG output.
5. MCP tool registration and parameter mapping.
6. Full regression run with `go test ./...`.
7. One live smoke test using a local reference image and the configured image
   gateway, without printing or committing credentials.

## Documentation

Update the README with the `edit_image2` schema and a single-image and
multi-image example. Explain that reference images must be local absolute
paths and that image order is preserved.

## Non-Goals

- Masks and pixel-precise inpainting.
- Remote image URLs.
- Base64 image arguments.
- Changing the existing `generate_image2` interface.
- Asynchronous image tasks or retries.
