# Optional provider keys and Chinese launcher UI

The user requests that installing SchylerAI-Image2-mcp no longer require both provider keys and that launcher buttons be Chinese. The existing Windows and Mac launchers, shared installers, and local connection verification all currently enforce both keys.

At least one independent provider key is required. Empty or valid whitespace-only fields represent an unconfigured provider and overwrite any old provider value with an explicit empty value. Keys never come from another provider, inherited environment, or an earlier installation. Provided keys retain their bytes and must be a single line without NUL, at most 1024 UTF-8 bytes. Both credential lines must still be supplied to the installer, even when one line is empty. Missing stdin is a failed input transaction.

Windows and Mac display Chinese buttons and normal status messages. Input labels state that each key is optional and the form requires at least one. Default generation remains Image2; explicit Gemini, banana, or 香蕉 requests select Gemini 3.1 Flash Image. An unconfigured provider reports a missing key without silently switching models.

Release 0.4.1 includes rebuilt universal Windows EXE and Mac app/DMG. Local fixture verification covers both single-provider installations, both-empty refusal, invalid key refusal, replacement clearing the omitted provider, and the real four-tool MCP handshake. No real keys, paid calls, remote publishing, or update-host deployment are required. The published v0.4.0 Agent online gate remains pinned and its older requirements must be documented accurately.
