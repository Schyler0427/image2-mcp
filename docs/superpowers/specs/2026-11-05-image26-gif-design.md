# Image2.6 and animated GIF support

Approved scope: the user chose to retain the original Image2 default, then approved the update after a local GIF capability test on 2026-11-05.

## Routing and compatibility

- Ordinary image generation and editing continue to use Image2 2.0. Explicit Image2.5 and Gemini / banana / 香蕉 routing stays unchanged.
- Explicit `image2.6` / `2.6` selects Sunburst (`gpt-image-2.6-sunburst`). Explicit `image2.6-flare` / `2.6快速版` selects Flare (`gpt-image-2.6-flare`). Both support PNG generation and editing through the existing Image2 credential and gateway.
- Do not switch model or provider after an error. Sunburst returned HTTP 503 during the live test; Flare returned a verified nine-frame, 1.8-second GIF. Advertising a model does not establish account availability.
- User clarification: natural-language “生成动图”, “GIF”, and “循环动图” automatically select GIF generation with Image2.6 Flare when no model was specified. Runtime GIF generation with a blank model/version also selects Flare; an explicitly selected model is never changed. Ordinary PNG requests retain Image2 2.0. Gemini and edit tools reject GIF output.

## Request and output contract

- Generation gains `output_format` (`png` by default, or `gif`), optional `quality`, `frame_count`, and `frame_duration_ms`.
- GIF defaults: size `auto`, nine frames, 200 ms per frame. Frame count must be 2–64; duration must be 20–2000 ms (the service rounds to 10 ms). Explicit GIF size must be `auto` or positive dimensions divisible by 16. Reject animation fields for PNG and reject GIF with older models before sending a request.
- Preserve ordinary PNG payloads/defaults when the new fields are omitted. No SVG, markup editing, or animation editing is included.
- For both Base64 and URL GIF responses, validate GIF structure and preserve its original bytes. Never flatten to PNG, rename static PNG bytes as GIF, or expose download URLs/credentials in diagnostics.
- Bound the encoded response to the existing 64 MiB limit, frames to 64, and cumulative logical-canvas pixels to 32 million before full GIF decoding. Reject corrupt and single-frame GIF responses.
- GIF results report actual dimensions, `output_format`, `frame_count`, and total `duration_ms`; ordinary PNG results remain compatible. Normalize output suffix to `.gif` for GIF.

## Release and verification

- Version 0.4.3 throughout runtime/offline checks and current documentation. Preserve published online v0.4.0 pins and historical incident/spec records.
- Keep optional independent keys, Chinese installer controls, update signature validation, architecture detection, and the fixed macOS staging safeguards unchanged.
- Use test-first changes for request routing, rejection, byte preservation, URL downloads, and animation bounds. Run Go race/vet, installation contracts, native Mac tests, and packaged isolated installation checks.
- Build universal Mac app/DMG and universal Windows executable in a new versioned directory. Do not publish remotely, change actual credentials, or replace the user's running app as part of this task.
