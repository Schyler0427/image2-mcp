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

## macOS and Linux bootstrap

1. Define the target as `$HOME/.local/share/image2-mcp`. Create its parent
   directory and create unique sibling staging and backup directories. Keep all
   staging and backup paths under that parent.
2. If the target exists, accept it only when its `origin` remote normalizes to
   `https://github.com/Schyler0427/image2-mcp`, or when
   `.image2-mcp-managed` contains only `Schyler0427/image2-mcp`. Refuse to
   change an unrecognized target.
3. When Git is available, shallow-clone
   `https://github.com/Schyler0427/image2-mcp` into the staging directory.
   When Git is unavailable, download the default-branch archive from
   `https://github.com/Schyler0427/image2-mcp/archive/refs/heads/main.tar.gz`
   with `curl` or `wget`, extract it into staging, and use the extracted
   repository directory as the staged repository.
4. Before moving anything, validate that the staged repository contains
   `install.sh`, `install.ps1`, `scripts/`, and `go.mod`. Write
   `.image2-mcp-managed` with exactly `Schyler0427/image2-mcp` and no other
   content. On a bootstrap failure, leave the existing target unchanged.
5. Move an accepted existing target to its sibling backup directory. This
   preserves its `.env.local` and `output/`. Move the staged repository to the
   fixed target.
6. Start `./install.sh --key-only` from the fixed target. For an archive
   bootstrap, set `IMAGE2_MCP_REPO=Schyler0427/image2-mcp` only for that child
   installer process. Do not use any other installer mode or option.
7. If bootstrap or installer verification fails, move the new target aside and
   restore the old target from its sibling backup. If there was no old target,
   leave no partially installed target. Do not delete staging or backup
   directories on failure. Delete temporary and backup directories only after
   successful verification.

## Windows bootstrap

1. Define the target as `%LOCALAPPDATA%\image2-mcp`. Create its parent
   directory and create unique sibling staging and backup directories. Keep all
   staging and backup paths under that parent.
2. If the target exists, accept it only when its `origin` remote normalizes to
   `https://github.com/Schyler0427/image2-mcp`, or when
   `.image2-mcp-managed` contains only `Schyler0427/image2-mcp`. Refuse to
   change an unrecognized target.
3. When Git is available, shallow-clone
   `https://github.com/Schyler0427/image2-mcp` into the staging directory.
   When Git is unavailable, download the default-branch archive from
   `https://github.com/Schyler0427/image2-mcp/archive/refs/heads/main.zip`
   with `Invoke-WebRequest`, expand it into staging, and use the extracted
   repository directory as the staged repository.
4. Before moving anything, validate that the staged repository contains
   `install.sh`, `install.ps1`, `scripts/`, and `go.mod`. Write
   `.image2-mcp-managed` with exactly `Schyler0427/image2-mcp` and no other
   content. On a bootstrap failure, leave the existing target unchanged.
5. Move an accepted existing target to its sibling backup directory. This
   preserves its `.env.local` and `output/`. Move the staged repository to the
   fixed target.
6. Start `.\install.ps1 -KeyOnly` from the fixed target. For an archive
   bootstrap, set `IMAGE2_MCP_REPO=Schyler0427/image2-mcp` only for that child
   installer process. Do not use any other installer mode or option.
7. If bootstrap or installer verification fails, move the new target aside and
   restore the old target from its sibling backup. If there was no old target,
   leave no partially installed target. Do not delete staging or backup
   directories on failure. Delete temporary and backup directories only after
   successful verification.

## Secret input

Start the platform key-only installer and let it read one line from standard
input. If chat collection is required, ask exactly `请输入 API Key：`, then feed
the response to the already-running process through standard input. Never use a
command argument or printed environment assignment.

## Completion

Do not stop after download. Require `Verification: OK`, report installed paths
and `API Key 已配置（未显示）`, then tell the customer to restart Codex or open a
new task.
