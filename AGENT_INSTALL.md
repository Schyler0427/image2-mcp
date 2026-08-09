# Image2 MCP Agent Installation

Follow this procedure to completion. Do not ask the customer for any value
except `OPENAI_IMAGE_API_KEY`. Never print the key or place it in a command.

## Fixed values

- Repository: `https://github.com/Schyler0427/image2-mcp`
- Base URL: `https://api.schyler.top`
- macOS/Linux target: `$HOME/.local/share/image2-mcp`
- Windows target: `%LOCALAPPDATA%\image2-mcp`

## Platform detection

Detect the platform before downloading anything. Support only these Release
targets and stop with an error for every other operating system or architecture:

- macOS arm64: `darwin/arm64`
- macOS x86_64: `darwin/amd64`
- Linux aarch64 or arm64: `linux/arm64`
- Linux x86_64 or amd64: `linux/amd64`
- Windows ARM64: `windows/arm64`
- Windows AMD64: `windows/amd64`

Do not select a fallback target. macOS and Linux use the macOS/Linux target;
Windows uses the Windows target.

## Required release gate

Before changing a target or asking for the key, query only this fixed GitHub
Release endpoint:

`https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.2.1`

Accept the response only when it describes the public `v0.2.1` Release with
`draft` set to `false` and `prerelease` set to `false`, and when its assets
contain every one of these exact names:

- `image2-mcp_darwin_arm64.tar.gz`
- `image2-mcp_darwin_amd64.tar.gz`
- `image2-mcp_linux_arm64.tar.gz`
- `image2-mcp_linux_amd64.tar.gz`
- `image2-mcp_windows_arm64.zip`
- `image2-mcp_windows_amd64.zip`

Do not use a latest-release endpoint or substitute a tag or asset. A missing,
private, draft, prerelease, malformed, or mismatched Release is a hard failure
before any target change or key prompt.

On macOS/Linux, save the endpoint response in the staging parent with
`curl -fL -sS URL -o FILE`, or, when curl is unavailable, with
`wget -O FILE URL`. If neither downloader exists, stop. Parse the saved JSON
and enforce the tag, `draft`, `prerelease`, and all six asset-name checks above;
if no local JSON parser is available, stop. On Windows, use native PowerShell
`Invoke-RestMethod` against the same endpoint and compare the parsed properties
and asset-name collection to those exact values.

## Existing target acceptance

The guide's Git bootstrap always clones
`https://github.com/Schyler0427/image2-mcp.git`. For an existing Git target,
run `git -C TARGET remote get-url origin` and accept it only when its output is
exactly `https://github.com/Schyler0427/image2-mcp.git`. Do not trim, normalize,
or accept SSH, alternate-host, trailing-path, or alternate-scheme forms.

For an existing non-Git target, read `.image2-mcp-managed` as bytes and accept
it only when it is byte-for-byte the UTF-8 bytes of
`Schyler0427/image2-mcp`, with no newline or other bytes. A Git target with a
different remote and a non-Git target with a missing or different marker are
unrecognized; leave them unchanged. When writing a marker, write exactly that
slug and no newline.

## macOS and Linux bootstrap

1. Complete the required release gate. Define the target as
   `$HOME/.local/share/image2-mcp`, create its parent, and create unique sibling
   staging and backup directories under that parent. If the target exists,
   apply the existing-target acceptance rules before changing it.
2. When Git exists, run
   `git clone --depth 1 https://github.com/Schyler0427/image2-mcp.git STAGED_REPOSITORY`.
   Without Git, require `curl` or `wget` and `tar`; download
   `https://github.com/Schyler0427/image2-mcp/archive/refs/heads/main.tar.gz`
   with `curl -fL -sS URL -o ARCHIVE` or `wget -O ARCHIVE URL`, extract it with
   `tar -xzf ARCHIVE -C STAGING_PARENT`, and use the extracted
   `image2-mcp-main` directory as `STAGED_REPOSITORY`. If a downloader or
   extractor is unavailable, or extraction does not yield that directory, stop.
3. Before moving anything, validate that `STAGED_REPOSITORY` contains
   `install.sh`, `install.ps1`, `scripts/`, and `go.mod`. Write its marker with
   `printf %s 'Schyler0427/image2-mcp' > STAGED_REPOSITORY/.image2-mcp-managed`.
   A bootstrap failure leaves an existing target unchanged.
4. For a repeat install, move the complete accepted target to the sibling
   backup, then move `STAGED_REPOSITORY` to the fixed target. Copy, never move,
   the prior `.env.local` from the backup into the replacement before prompting
   for the key, so it is staged before the installer performs its new atomic
   key-only write. Copy the prior `output/` from the backup into the replacement
   before prompting for the key. Leave the backup untouched until successful
   verification, so it remains a complete rollback target. For a first install,
   there is no prior content to copy.
5. Start `./install.sh --key-only` from the fixed target. For an archive
   bootstrap, set `IMAGE2_MCP_REPO=Schyler0427/image2-mcp` only in this child
   installer process. Do not use any other installer mode or option.
6. On bootstrap or installer failure, move the replacement to a failed sibling
   directory and restore the complete old target from the untouched backup. This
   restores the prior `.env.local` and `output/`. With no old target, leave no
   partially installed target. Do not delete staging, failed, or backup
   directories on failure. Delete temporary and backup directories only after
   successful verification.

## Windows bootstrap

1. Complete the required release gate. Define the target as
   `%LOCALAPPDATA%\image2-mcp`, create its parent, and create unique sibling
   staging and backup directories under that parent. If the target exists,
   apply the existing-target acceptance rules before changing it.
2. When Git exists, run
   `git clone --depth 1 https://github.com/Schyler0427/image2-mcp.git STAGED_REPOSITORY`.
   Without Git, download
   `https://github.com/Schyler0427/image2-mcp/archive/refs/heads/main.zip`
   with `Invoke-WebRequest -Uri URL -OutFile ARCHIVE`, extract it with
   `Expand-Archive -LiteralPath ARCHIVE -DestinationPath STAGING_PARENT`, and
   use the extracted `image2-mcp-main` directory as `STAGED_REPOSITORY`. Stop
   when `Invoke-WebRequest` or `Expand-Archive` is unavailable, or extraction
   does not yield that directory.
3. Before moving anything, validate that `STAGED_REPOSITORY` contains
   `install.sh`, `install.ps1`, `scripts/`, and `go.mod`. Write
   `.image2-mcp-managed` as UTF-8 without a byte-order mark or newline, with
   only `Schyler0427/image2-mcp`. A bootstrap failure leaves an existing target
   unchanged.
4. For a repeat install, move the complete accepted target to the sibling
   backup, then move `STAGED_REPOSITORY` to the fixed target. Copy, never move,
   the prior `.env.local` from the backup into the replacement before prompting
   for the key, so it is staged before the installer performs its new atomic
   key-only write. Copy the prior `output/` from the backup into the replacement
   before prompting for the key. Leave the backup untouched until successful
   verification, so it remains a complete rollback target. For a first install,
   there is no prior content to copy.
5. Start `.\install.ps1 -KeyOnly` from the fixed target. For an archive
   bootstrap, set `IMAGE2_MCP_REPO=Schyler0427/image2-mcp` only in this child
   installer process. Do not use any other installer mode or option.
6. On bootstrap or installer failure, move the replacement to a failed sibling
   directory and restore the complete old target from the untouched backup. This
   restores the prior `.env.local` and `output/`. With no old target, leave no
   partially installed target. Do not delete staging, failed, or backup
   directories on failure. Delete temporary and backup directories only after
   successful verification.

## Secret input

Start the platform key-only installer and let it read one line from standard
input. If chat collection is required, ask exactly `请输入 API Key：`, then feed
the response to the already-running process through standard input. Never use a
command argument or printed environment assignment.

A blank or whitespace-only key fails once with no re-prompt.

## Completion

Do not stop after download. Require `Verification: OK`, report installed paths
and `API Key 已配置（未显示）`, then tell the customer to restart Codex or open a
new task. Verification is local and must never call an image API.
