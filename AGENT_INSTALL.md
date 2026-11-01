# Image2 MCP Agent Installation

0.4.2 本地 GUI／离线包支持只配置一把密钥；所有在线 Key-only 路径仍使用已发布的 `v0.4.0`，其旧版 `--verify-mcp` 校验要求两把密钥均非空。这包括在线 Agent 安装，以及从源码目录运行 `./install.sh --key-only` 或 `.\install.ps1 -KeyOnly`。只配置一把密钥时，请使用 0.4.2 GUI 或离线包。维护者发布并更新在线版本前，请按所用路径的要求输入。

## Offline package path

When the customer has received a complete `image2-mcp-offline_` package, use its
`OFFLINE_INSTALL.md` and local wrapper instead of the online procedure below.
Verify the archive SHA-256 against the maintainer's trusted delivery record,
extract to a new ordinary directory, and run `bash ./install-offline.sh` or
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-offline.ps1`.
Do not request or download the GitHub helper, query a Release gate, download a
binary, install dependencies, or fall back to the online installer in this path.
The local helper validates its fixed-version/platform payload before any Key
input or target replacement. Keep its process streams attached and follow the
same stdin-only Key rules and completion requirements below. Verification is
local and must never call an image API. The ordinary binary-only Release assets
are not complete offline packages. The self-hosted download source is not deployed.

## Online GitHub path

Follow this procedure to completion. Do not request any customer value except
`OPENAI_IMAGE_API_KEY` and `GEMINI_IMAGE_API_KEY`. Never print either key, store it in an Agent command,
command argument, shell variable, environment variable, temporary file, or
diagnostic, or expose any partial or derived form of it.

Run the helper once. If any download, Release gate, installation, or verification
fails, stop and report the failing stage and its error. Do not retry the helper,
probe alternate GitHub pages or mirrors, reinstall dependencies, change the
network configuration, or launch a second installer automatically. Continue
only after the customer asks to retry or the reported cause has been resolved.

## Fixed contract

- Repository: `https://github.com/Schyler0427/image2-mcp`
- Repository identity: `Schyler0427/image2-mcp`
- Base URL: `https://api.schyler.top`
- Release: public `v0.4.0`
- Release gate:
  `https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.4.0`
- macOS/Linux target: `$HOME/.local/share/image2-mcp`
- Windows target: `%LOCALAPPDATA%\image2-mcp`
- Managed marker: `.image2-mcp-managed`
- Default model: Image2（Image 2.0）。“帮我生成一张图”会由 Agent 调用 `generate_image`，省略 model 或传 `image2`。
  “使用 image2 生成”选择 `model: "image2"`（Image 2.0）；“用 2.5 生图”选择 `model: "image2.5"`（Image 2.5）。
  只有明确说“使用 Gemini 生图”“香蕉生图”或“banana 生图”时才选择 `model: "gemini"`（Gemini 3.1 Flash Image）。参考图编辑使用 `edit_image` 和同样的 model。
- Legacy `generate_image2` and `edit_image2` stay Image2-only; Image 2.5 uses
  `version: "2.5"`. Do not switch providers after an error or repeat image calls
  automatically. A missing selected provider key is an error.
- 0.4.2 本地 GUI／离线包：客户只需提供 Image2 或 Gemini 专用 API Key，至少配置一把，也可同时配置两把。All online Key-only paths, including direct commands from a source checkout, still download the pinned older binary and require nonempty keys for both providers. The fixed gateway is
  `https://api.schyler.top`; model selection follows natural language.
- 永远不要询问客户模型 ID、Base URL 或 endpoint。

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

## Secret input and single-turn execution

Obtain the platform helper as described below and start it once as the current
user with its real standard input, output, and error streams attached. Do not
request elevation or start an administrator process.
If the helper prints `OPENAI_IMAGE_API_KEY:`, ask exactly `请输入 Image2 专用 API Key：`.
When it prints `GEMINI_IMAGE_API_KEY:`, ask exactly `请输入 Gemini 专用 API Key：`.
For a 0.4.2 offline package, before the first prompt explain in Chinese that at least one provider key is required, either field may be left blank, and both may be configured.
For the pinned online path, explain in Chinese that the published older installer requires a nonempty key for each provider; any blank or whitespace-only key fails once with no re-prompt. Do not promise optional-key validation for source downloaded from the immutable older tag.
Wait for each one-line response and keep it only as the pending stdin secret.
Every installation or upgrade requires fresh input for the providers the customer
wants to configure; never reuse an old installation key or an inherited environment key.
In a 0.4.2 offline package, a blank or whitespace-only input leaves that provider unconfigured and clears its
previous key; it must not fall back to an inherited environment key.
If both inputs are blank or whitespace-only, fail once with no re-prompt.
Each nonempty value must be single-line and at most 1024 UTF-8 bytes.

Do not create a forwarding script or a second process to relay stdin.
Keep this download, helper launch, key forwarding, installation, and verification in one Agent turn.

When the attached child prints each named key prompt, send only that provider's
pending secret as one line through that same process's standard input facility.
Send exactly two lines in Image2-then-Gemini order, responding to the prompts. Only
for a 0.4.2 offline package, send an empty line for an unconfigured provider.
Do not inspect `.env.local`, the target, or Codex config while the helper is still running.
Do not restart the helper because an expected file is not present during the
transaction. Only the helper's exit status and final output determine success.

The key must never appear in the command, a command argument, a shell variable,
an environment variable, a temporary file, a diagnostic, or an output stream.

## Obtain the platform helper

On macOS or Linux, download this exact repository-owned helper to a newly
created temporary file:

`https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/scripts/bootstrap-agent-install.sh`

Use `curl -q -fL --retry 0 --connect-timeout 10 --max-time 60 URL -o FILE`, or use
`wget --tries=1 --timeout=60 -O FILE URL` only when curl is unavailable. Do
not retry the helper download. Start the downloaded
`scripts/bootstrap-agent-install.sh` with Bash and no arguments, following the
attached-process rules above.

On Windows, before downloading the helper, add TLS 1.2 to the process protocol
flags without replacing existing flags:

```powershell
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
```

Then download this exact repository-owned helper to a newly created temporary
file with `Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri URL -OutFile FILE`.
Do not retry the helper download:

`https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/scripts/bootstrap-agent-install.ps1`

Start the downloaded `scripts/bootstrap-agent-install.ps1` with Windows
PowerShell 5.1 or later and no arguments, following the attached-process rules
above.

Delete only the downloaded temporary helper after it exits. Never delete a
retained transaction or previous-installation path reported by the helper.

The helper passes that same stdin stream to the platform key-only installer:
`./install.sh --key-only` on macOS/Linux or `.\install.ps1 -KeyOnly` on
Windows. Do not invoke either installer separately.

## Helper-owned safety

The repository-owned helper is the only implementation of the bootstrap
transaction. It owns all of these requirements:

- enforce the fixed public `v0.4.0` gate and all six exact assets;
- make exactly one bounded Release API request; fail on rate limits or network
  errors without probing the Release HTML or expanded-assets pages;
- enforce the fixed platform and architecture, fixed target, exact Git origin
  or byte-exact `.image2-mcp-managed` identity, and validated source archive;
- reject traversal, links, reparse points, duplicates, case ambiguity, and
  file/directory prefix collisions before target mutation;
- stage the source, snapshot the Codex config, perform transactional target
  replacement, invoke the key-only installer, and verify local files/config;
- configure a 20-second MCP startup timeout and a 600-second tool timeout, and
  require a local MCP initialize/tools-list handshake with the installed version
  and all four image tools before reporting success;
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
the helper's installed paths, which providers the customer configured (for example,
`Image2 API Key 已配置（未显示）；Gemini 未配置`), and any
`Previous installation retained at:` path. Never claim a blank provider was configured.
Tell the customer to restart Codex or open a new task. The default remains Image2;
if the selected provider is unconfigured, report the missing key without switching
providers automatically.

Verification is local and must never call an image API. Do not stop after
download, and do not make a billable image request.
