# Direct API Agent Routing Design

## Goal

After a customer configures one API Key, Image2 MCP should be usable by saying
“帮我生成一张图” or explicitly “使用 image2 生成”; the Agent should select
the image tool without asking for Base URL, model, or endpoint details.

## Scope

- Keep the fixed default gateway `https://api.schyler.top`.
- Keep the default model `gpt-image-2.5-sunburst`.
- Preserve the existing key-only installer and local `.env.local` storage.
- Update MCP server instructions, tool descriptions, and customer documentation
  to state automatic and explicit invocation paths.
- Add regression tests for the published routing contract.

## Architecture and data flow

The Agent receives MCP Instructions when it connects. Those instructions state
that natural-language image requests should call `generate_image2` directly and
that explicit “使用 image2” requests use the same tool. The tool descriptions
repeat the routing rule and identify generation versus editing. The runner loads
the locally stored key and the client resolves the gateway and model defaults;
no key or endpoint is passed through tool arguments.

## Error handling and security

If the key is missing, the existing client error remains the only configuration
prompt path. Documentation must never include a real key. The Agent must not
ask customers for Base URL, model, endpoint, Go, Git, or administrator access
as part of normal image generation.

## Testing

- Unit tests assert the server Instructions contain the automatic and explicit
  routing rules and the fixed gateway/model defaults.
- Unit tests assert both tool descriptions identify the correct tool behavior.
- Existing Go, installer contract, bootstrap, and platform build checks remain
  required before release.

## Out of scope

No new status tool, no new API endpoint, no forced single-router tool, and no
real billable image request during verification.
