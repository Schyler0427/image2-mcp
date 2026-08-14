# Image2 MCP Agent Installation

Follow this procedure to completion. Do not request any customer value except
`OPENAI_IMAGE_API_KEY`. Never print the key, store it in an Agent command,
command argument, shell variable, environment variable, temporary file, or
diagnostic, or expose any partial or derived form of it.

## Fixed contract

- Repository: `https://github.com/Schyler0427/image2-mcp`
- Repository identity: `Schyler0427/image2-mcp`
- Base URL: `https://api.schyler.top`
- Release: public `v0.2.1`
- Release gate:
  `https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.2.1`
- macOS/Linux target: `$HOME/.local/share/image2-mcp`
- Windows target: `%LOCALAPPDATA%\image2-mcp`
- Managed marker: `.image2-mcp-managed`

The public Release must have `draft` and `prerelease` set to `false` and must
contain all six assets before the helper changes the target or reads the key:

- `image2-mcp_darwin_arm64.tar.gz`
- `image2-mcp_darwin_amd64.tar.gz`
- `image2-mcp_linux_arm64.tar.gz`
- `image2-mcp_linux_amd64.tar.gz`
- `image2-mcp_windows_arm64.zip`
- `image2-mcp_windows_amd64.zip`

Do not substitute another repository, ref, Release, base URL, target, installer
mode, or helper. The customer does not need Git or Go.

## Obtain the platform helper

Detect the platform. On macOS or Linux, download this exact repository-owned
helper to a newly created temporary file:

`https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/scripts/bootstrap-agent-install.sh`

Use `curl -fL URL -o FILE`, or use `wget -O FILE URL` only when curl is
unavailable. Then start the downloaded `scripts/bootstrap-agent-install.sh`
with Bash. Do not add arguments.

On Windows, before downloading the helper, add TLS 1.2 to the process protocol
flags without replacing existing flags:

```powershell
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
```

Then download this exact repository-owned helper to a newly created temporary
file with `Invoke-WebRequest -UseBasicParsing -Uri URL -OutFile FILE`:

`https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/scripts/bootstrap-agent-install.ps1`

Start the downloaded `scripts/bootstrap-agent-install.ps1` with Windows
PowerShell 5.1 or later. Do not add arguments.

Delete only the downloaded temporary helper after it exits. Never delete a
retained transaction or previous-installation path reported by the helper.

## Secret input

Start the selected helper and wait until it requests stdin. Then ask exactly
`请输入 API Key：` and send the response as one line through that process's
standard input facility. The key must never appear in the command or an output
stream. Do not send a second line.

A blank or whitespace-only key fails once with no re-prompt.

The helper passes that same stdin stream to the platform key-only installer:
`./install.sh --key-only` on macOS/Linux or `.\install.ps1 -KeyOnly` on
Windows. Do not invoke either installer separately.

## Helper-owned safety

The repository-owned helper is the only implementation of the bootstrap
transaction. It owns all of these requirements:

- enforce the fixed public `v0.2.1` gate and all six exact assets;
- enforce the fixed platform and architecture, fixed target, exact Git origin
  or byte-exact `.image2-mcp-managed` identity, and validated source archive;
- reject traversal, links, reparse points, duplicates, case ambiguity, and
  file/directory prefix collisions before target mutation;
- stage the source, snapshot the Codex config, perform transactional target
  replacement, invoke the key-only installer, and verify local files/config;
- on failure, restore the complete prior target and Codex config, or retain and
  report all transaction evidence when automatic recovery is incomplete;
- on a successful repeat, keep the complete prior target in a unique sibling
  backup and print `Previous installation retained at:` followed by its path;
- report that previous local and customer content is `not active in the refreshed target`.

The retained previous directory is untouched recovery material. Its old
customer/local content is not copied, merged, or active in the refreshed fixed
target. Do not remove it automatically.

Existing targets originally created with
`git clone --depth 1 https://github.com/Schyler0427/image2-mcp.git` are accepted
only when the helper proves the exact origin and worktree root; the helper still
uses the same complete-backup transaction. The Agent must not run that clone or
perform an in-place Git update. Archive retrieval and extraction details such as
`tar -xzf` are likewise owned by the helper, not reimplemented by the Agent.

## Completion

Require an exit status of zero and the exact line `Verification: OK`. Report
the helper's installed paths, `API Key 已配置（未显示）`, and any
`Previous installation retained at:` path. Tell the customer to restart Codex
or open a new task.

Verification is local and must never call an image API. Do not stop after
download, and do not make a billable image request.
