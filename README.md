# SchylerAI-Image2-mcp

SchylerAI-Image2-mcp 是一个给 Codex 使用的本地 STDIO MCP 服务，支持 Image2 和 Gemini 独立密钥，至少配置一把即可，也可同时配置两把。默认使用 **Image2（Image 2.0）**；明确说 Gemini、香蕉或 banana 生图时才使用 Gemini 3.1 Flash Image。它提供四个工具：

- `generate_image`：统一文生图，`model=image2`（普通 PNG 默认）、`image2.5`、`image2.6`、`image2.6-flare` 或 `gemini`（也接受 `banana` / `香蕉`）；支持 Image2.6 动态 GIF 生成
- `edit_image`：统一参考图编辑，支持同样的模型选择
- `generate_image2`：调用固定网关的 Image 2.0 / Image 2.5 / Image 2.6 生图接口
- `edit_image2`：图生图编辑（支持 Image 2.0 / Image 2.5 / Image 2.6、多图输入和可选蒙版）

后两个工具保留旧版 Image2 调用行为。以下 Image2.6 与 GIF 说明适用于本地 0.4.3 构建，固定在线 `v0.4.0` 安装尚不包含这些功能。新调用使用统一工具，用户直接说模型名称即可。Gemini 原生接口使用自己的专用密钥，读取 `candidates[].content.parts[]` 的图片数据；支持文字在图片前、camelCase/snake_case 字段，并将有效 PNG/JPEG/WebP 图片保存为 PNG。

Image2 支持接口返回的 `data[0].b64_json` 和 `data[0].url`，优先使用 Base64，
否则下载图片并保存到本地。普通 PNG 请求中链接返回的 JPEG / GIF 会转为 PNG；明确请求动态 GIF 时，
Base64 或链接返回的 GIF 会原样保存为 `.gif`，不丢失动画帧。下载不会携带生图 API Key；响应上限为 64 MiB，动态 GIF 最多 64 帧、累计逻辑画布像素不超过 3200 万。

如果响应缺少图片、无法解析或下载失败，工具会在图片输出目录保存
`image2-response-*.json`，并在错误里给出路径。诊断保留已知协议字段的结构、
HTTP 状态和清理后的请求 ID；未知字段名隐藏，响应字符串替换为长度说明，避免泄漏密钥、签名链接、
提示词和图片编码。结构深度、节点数和文件大小有独立上限，超过时记录截断标记。非 JSON 响应只记录长度，不保存正文。失败不会重新提交生图。

## 安装

### Mac 通用应用

Mac 用户使用 `SchylerAI-Image2-mcp-macOS.dmg`：打开后把应用拖到 Applications，再双击 `SchylerAI-Image2-mcp.app`。同一个应用包含 Apple Silicon 与 Intel 程序，最低 macOS 12，不需要安装 Go 或选择架构。

在窗口中输入 Image2 或 Gemini 专用 Key，至少配置一把，也可同时配置两把，然后点击“安装 / 更新密钥”。安装成功后重启 Codex 或开启新会话。再次打开应用可更新密钥；每次重新输入本次要配置的 Key，不读取或复用旧 Key。留空表示该服务未配置，并清除该服务原有配置；不会从环境变量或其他服务借用密钥。普通生图默认 Image2，明确说 Gemini／香蕉／banana 生图才使用 Gemini 3.1 Flash Image；所选服务未配置时会报错，不会自动切换服务。

Mac 应用复用离线安装事务，检查本地 MCP 握手并保留旧安装备份，不在安装验证时调用收费接口。“检查更新”使用独立的 Mac 签名清单；维护者尚需部署更新服务。

本地交付采用 ad-hoc 签名，尚未使用 Developer ID 证书或经过 Apple 公证，其他 Mac 的系统安全策略可能阻止首次打开。发布正式版时使用有效证书与 Apple 公证；不通过关闭 Gatekeeper 或移除隔离属性处理。维护者构建步骤见 [Mac 构建和发布说明](macos/README.md)。

### Windows 通用启动器

Windows 用户可直接下载维护者提供的 `SchylerAI-Image2-mcp.exe`，无需解压 ZIP、安装 Go
或判断电脑架构。双击后在窗口中输入 **Image2 专用 API Key** 或 **Gemini 专用 API Key**，至少配置一把，也可同时配置两把，再点击“安装 / 更新密钥”；程序会自动
选择 Windows x86、x64 或 ARM64 对应的内置 MCP。每次重新安装、替换密钥或升级版本都重新
输入本次要配置的 Key。留空表示该服务未配置，并清除该服务原有配置；不会复用其他服务、环境变量或旧安装的密钥。

窗口中的“检查更新”只访问固定的 HTTPS 更新服务，不上传 API Key、图片或 Codex 配置。
发现新版后点击“下载新版”会自动下载并校验签名和 SHA-256，启动新版窗口；新版会
再次要求输入本次要配置的密钥，至少配置一把。新版 EXE 会同时带上新的模型、工具描述和 MCP 逻辑。没有网络时，当前
EXE 仍可安装它内置的版本，只是不能检查或下载更新。支持 Windows 10/11 的 x86、x64 和
ARM64；不承诺 Windows 7/8。
“安装 / 更新密钥”始终安装当前内置版本，随时可用它更新专用密钥。点击“取消”会立即停止下载；
本地安装事务一旦开始，取消或关闭会等待它完成或回滚，避免留下半完成配置。
自动更新依赖维护者在 `https://api.schyler.top/image2/releases/latest/launcher.json` 提供签名清单，
并在清单中的固定路径提供 EXE；发布工作流会生成并签名这些资产，服务未部署前检查更新会失败，
但当前 EXE 的离线安装不受影响。

GitHub 无法访问时，使用维护者通过可访问渠道提供的完整离线安装包，名称以
`image2-mcp-offline_` 开头。先核对可信渠道提供的 SHA-256，再解压到新目录运行：

```bash
bash ./install-offline.sh
```

Windows 使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-offline.ps1`。
完整步骤见 [离线安装说明](OFFLINE_INSTALL.md)。离线安装和验证不访问 GitHub，
不下载依赖，也不调用生图 API；升级会重新询问本次要配置的专用 Key，至少配置一把，并保留旧版备份。
完整离线包需要本分支构建；尚未发布，自有下载服务也尚未部署。

0.4.3 本地 GUI／离线包支持只配置一把密钥，并提供 Image2.6 与动态 GIF 生图；所有在线 Key-only 路径仍使用已发布的 `v0.4.0`，其旧版 `--verify-mcp` 校验要求两把密钥均非空，也没有本地 0.4.3 的新功能。这包括在线 Agent 安装，以及从源码目录运行 `./install.sh --key-only` 或 `.\install.ps1 -KeyOnly`。只配置一把密钥或使用 Image2.6／GIF 时，请使用 0.4.3 本地 GUI 或离线包。维护者发布并更新在线版本前，请按所用路径的要求输入。

能够访问 GitHub 且已准备好 Image2 和 Gemini 密钥时，也可使用原有在线安装指令：

```text
请安装并配置 Image2 MCP：读取并严格执行 https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/AGENT_INSTALL.md，按当前固定在线版本的要求输入 Image2 和 Gemini 专用 API Key，除密钥外不要向我询问其他配置，完成安装和验证后再结束。
```

对于 0.4.3 本地 GUI／离线包，客户只需提供 Image2 或 Gemini 专用 API Key，至少配置一把，也可同时配置两把；每次安装或升级都会分别询问。留空表示该服务未配置，并清除该服务原有配置；不会复用其他服务、环境变量或旧安装的 Key。两个输入均为空或仅含空白时，安装会直接失败，不会反复询问。
安装失败时会报告失败阶段，不会自动反复安装或切换下载地址。Release 检查只请求一次 API。
安装成功必须通过本地 MCP 握手、版本和四个工具的检查，验证过程不会调用生图接口。

默认使用 Image2。Agent 会根据自然语言自动调用
`generate_image` 或 `edit_image`；客户不需要填写模型 ID、Base URL 或 endpoint。说“使用 image2 生成”选择 Image 2.0，说“用 2.5 生图”选择 Image 2.5，说“用2.6生图”选择 Image2.6 Sunburst，说“用2.6快速版生图”选择 Image2.6 Flare，说“使用 Gemini 生图”“香蕉生图”或“banana 生图”选择 Gemini 3.1 Flash Image。0.4.3 本地版本中，“生成动图”“做个GIF”“循环动图”会自动选择 Flare 生成 GIF，除非明确指定模型；已指定的模型不因不支持 GIF 或上游报错而改换。

## 维护者和高级安装

默认图片网关：

```text
https://api.schyler.top
```

最终调用接口：

```text
{OPENAI_IMAGE_BASE_URL}/v1/images/generations
{OPENAI_IMAGE_BASE_URL}/v1/images/edits
{GEMINI_IMAGE_BASE_URL}/v1beta/models/{GEMINI_IMAGE_MODEL}:generateContent
```

Key-only 安装无需配置或修改 Base URL；程序默认使用上述网关和对应图片端点。

### 前置条件

- 已安装 Codex
- 当前在线 Key-only 安装需同时准备独立可用的 `OPENAI_IMAGE_API_KEY` 和 `GEMINI_IMAGE_API_KEY`；0.4.3 GUI／离线包至少配置一把即可
- 推荐仓库已经发布 GitHub Release；这样使用者不需要安装 Go
- 如果仓库还没有 Release，则需要本机安装 Go，让脚本从源码编译

仓库里只需要提交源码和脚本，不需要提交编译后的 `dist/`。

安装脚本有两种模式：

- 本机有 Go：普通模式运行测试并从源码编译；Key-only 模式仍下载固定 Release
- 本机没有 Go：从 GitHub Releases 下载当前系统的预编译二进制；当前固定版本仍为 `v0.4.0`

### 从 GitHub 拉取后安装

以下命令使用在线 Key-only 安装，即使从 0.4.3 源码目录运行，也会下载固定的 `v0.4.0` 二进制。该旧版的 MCP 验证要求 Image2 和 Gemini 密钥均非空，留空任意一项不能完成安装。只配置一把密钥或使用 Image2.6／GIF 时，请使用 0.4.3 本地 GUI 或离线包。输入的密钥保存到本地 `.env.local`，不会写入 Codex 配置，也不会提交到 GitHub。

### macOS / Linux

```bash
git clone <your-repo-url>
cd image2-mcp
./install.sh --key-only
```

### Windows PowerShell

```powershell
git clone <your-repo-url>
cd image2-mcp
powershell -ExecutionPolicy Bypass -File .\install.ps1 -KeyOnly
```

安装脚本会做这些事：

1. 依次交互式输入 `OPENAI_IMAGE_API_KEY` 和 `GEMINI_IMAGE_API_KEY`；当前在线 Key-only 路径需两项均非空，供旧版验证使用
2. 写入本地 `.env.local`
3. Key-only 模式直接下载固定 `v0.4.0` Release 的预编译二进制，不安装 Go，也不运行源码测试
4. 写入 Codex MCP 配置，启动超时为 20 秒，工具执行超时为 600 秒
5. 检查实际 MCP 握手、版本和工具列表，通过后输出 `Verification: OK`

`.env.local`、`dist/`、`output/` 都已加入 `.gitignore`，不要提交到 GitHub。

如果你想强制使用 GitHub Release 里的预编译二进制，即使本机安装了 Go，也可运行以下命令；它们仍下载 `v0.4.0`，需要两项密钥均非空：

macOS / Linux：

```bash
./install.sh --key-only
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -KeyOnly
```

维护者如需自定义 URL 或模型，可使用高级交互模式；客户不需要使用该模式：

macOS / Linux：

```bash
./install.sh --interactive
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Interactive
```

如果已经配置过 `.env.local`，后续只想重新构建：

macOS / Linux：

```bash
./install.sh
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

### 本地配置

交互式安装会生成 `.env.local`：

```dotenv
OPENAI_IMAGE_BASE_URL="https://api.schyler.top"
GEMINI_IMAGE_BASE_URL="https://api.schyler.top"
GEMINI_IMAGE_MODEL="gemini-3.1-flash-image"
```

本次输入的 API Key 会分别保存在本地 `.env.local`，不在文档示例中展示。0.4.3 程序支持将未配置的服务保存为空值，清除该服务原有配置，runner 不会改用环境变量里的 Key；在线 Key-only 下载的旧版二进制仍要求两项密钥均非空才能通过验证。`GEMINI_IMAGE_MODEL` 是维护者高级配置，客户不需要填写。

Agent 根据自然语言选择工具参数：普通 PNG 未提模型使用 Image2 2.0，说“使用 image2 生成”选择 Image 2.0，说“用 2.5 生图”选择 Image 2.5，说“用2.6生图”选择 Image2.6 Sunburst，说“用2.6快速版生图”选择 Image2.6 Flare。0.4.3 本地版本中，“生成动图”“做个GIF”“循环动图”自动使用 GIF 与 Flare，除非明确指定模型。只有明确说 Gemini、香蕉或 banana 生图才选择 Gemini 3.1 Flash Image。所选服务未配置时会报错，不会自动切换服务；仅配置 Gemini 也不会改变默认模型。客户不填写模型 ID。

Codex 配置里不会直接保存 key。启动 MCP 时，runner 脚本会读取本地
`.env.local`。

如果要换 key，重新运行交互式安装即可。网关和 endpoint 固定，不需要客户输入：

```bash
./install.sh --interactive
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Interactive
```

### Codex MCP 配置

安装脚本会自动写入 `~/.codex/config.toml`。

macOS / Linux 写入示例：

```toml
[mcp_servers.image2]
command = "/path/to/image2-mcp/scripts/run-image2-mcp.sh"
startup_timeout_sec = 20
tool_timeout_sec = 600
```

Windows 写入示例：

```toml
[mcp_servers.image2]
command = "powershell.exe"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\image2-mcp\\scripts\\run-image2-mcp.ps1"]
startup_timeout_sec = 20
tool_timeout_sec = 600
```

安装完成后，重启 Codex 或开启新会话，让 Codex 重新加载 MCP 配置。

### 自然语言调用

直接描述任务即可，系统会自动路由到 `generate_image` 或 `edit_image`：

- “帮我生成一张图”使用默认的 Image2（Image 2.0）
- “用 Gemini 生图，画一只戴帽子的猫”“香蕉生图”或“banana 生图”使用 Gemini 3.1 Flash Image
- “使用 image2 生成一张海边日落”使用 Image 2.0，传入 `model=image2`
- “用 2.5 生图，画一只戴帽子的猫”使用 Image 2.5，传入 `model=image2.5`
- “用2.6生图，画一只戴帽子的猫”使用 Image2.6 Sunburst，传入 `model=image2.6`
- “用2.6快速版生图，画一只戴帽子的猫”使用 Image2.6 Flare，传入 `model=image2.6-flare`
- “生成动图：挥手的小猫”“做个GIF”或“循环动图”自动传入 `output_format=gif` 并选择 Flare，除非明确指定模型
- “用2.6快速版生成一个挥手的 GIF”明确选择 Flare 与 GIF
- “参考这两张图改成水彩风”默认用 Image2 的参考图编辑，保留图片顺序；明确说 Gemini / 香蕉 / banana 时使用 Gemini

Gemini 支持 `aspect_ratio`（默认 `1:1`）和 `image_size`（`1K`、`2K`、`4K`）。Image2 使用 `size`；`quality` 可用于 Image2 生成与编辑，蒙版只用于 Image2 编辑。GIF 仅支持 Image2.6 生图，不能把参考图或编辑请求变成动图；提供参考图时不会丢弃它们改走文生图。GIF 默认 `size=auto`、9 帧、每帧 200 ms；`frame_count` 为 2–64，`frame_duration_ms` 为 20–2000（服务按 10 ms 取整），明确尺寸须为正数且宽高均为 16 的倍数。PNG 不能带动画参数。返回的 GIF 保留原始字节，结果报告实际宽高、帧数和总时长。混用参数会在发请求前报错，工具不会忽略蒙版，也不会自动切换模型或借用另一把 Key。

客户永远不需要提供模型 ID、Base URL 或 endpoint。除非维护者明确覆盖默认配置，
固定网关始终是 `https://api.schyler.top`。

如果 `~/.codex/config.toml` 已经存在 `[mcp_servers.image2]`，安装脚本不会覆盖它。
这种情况下如果你移动了项目目录，需要手动更新里面的 runner 路径。

如果你想让脚本覆盖已有的 `[mcp_servers.image2]` 配置：

macOS / Linux：

```bash
./install.sh --configure-codex --force-config
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ForceConfig
```

`--force-config` / `-ForceConfig` 会删除旧的 `[mcp_servers.image2]` 配置块，
再写入当前项目路径对应的新配置。

### 手动构建

macOS / Linux：

```bash
go build -o ./dist/image2-mcp ./cmd/image2-mcp
```

Windows：

```powershell
go build -o .\dist\image2-mcp.exe .\cmd\image2-mcp
```

### 发布 GitHub Release

仓库包含 GitHub Actions Release workflow。推送 `v*` tag 后会核对服务版本并自动构建：

```text
darwin/arm64
darwin/amd64
linux/arm64
linux/amd64
windows/arm64
windows/amd64
```

发布方式：

```bash
git tag v0.4.3
git push origin v0.4.3
```

Release 产物命名：

```text
image2-mcp_darwin_arm64.tar.gz
image2-mcp_darwin_amd64.tar.gz
image2-mcp_linux_arm64.tar.gz
image2-mcp_linux_amd64.tar.gz
image2-mcp_windows_arm64.zip
image2-mcp_windows_amd64.zip
```

如果用户本机没有 Go，安装脚本会根据系统自动下载这些产物。

同时发布六个完整离线包，使用 `image2-mcp-offline_<os>_<arch>` 命名及相同
平台扩展名，并生成 `SHA256SUMS.txt`。六个普通二进制包继续保留兼容旧安装器。
离线包内含固定平台程序、安装入口、runner、许可证及每个文件的 SHA-256 清单。

本地构建某个平台的离线包（维护者需要 Go；客户不需要）：

```bash
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o dist/image2-mcp ./cmd/image2-mcp
bash scripts/build-offline-package.sh --os darwin --arch arm64 --binary dist/image2-mcp --version 0.4.3 --output dist/offline
```

### 真实生图测试

macOS / Linux：

```bash
./install.sh --interactive --configure-codex --smoke
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Interactive -ConfigureCodex -Smoke
```

真实 smoke test 会调用一次接口，并生成：

```text
output/imagegen/mcp-smoke-test.png
```

注意：`--smoke` 会真实调用一次图片接口，可能消耗额度。

要单独验证图生图接口，需要指定一张本地参考图的绝对路径：

```bash
RUN_IMAGE2_EDIT_SMOKE=1 \
IMAGE2_EDIT_INPUT="/Users/you/Desktop/reference.png" \
go test ./internal/image2 -run TestRealEditImage2Smoke -count=1 -v
```

该测试会生成：

```text
output/imagegen/mcp-edit-smoke-test.png
```

多图真实测试使用系统路径分隔符连接两张或更多图片。macOS / Linux 示例：

```bash
RUN_IMAGE2_EDIT_MULTI_SMOKE=1 \
IMAGE2_EDIT_INPUTS="/Users/you/Desktop/subject.png:/Users/you/Desktop/style.png" \
go test ./internal/image2 -run TestRealEditImage2MultiSmoke -count=1 -v
```

该测试会生成：

```text
output/imagegen/mcp-edit-multi-smoke-test.png
```

## Codex 里怎么调用

统一文生图默认示例（Image2）：

```json
{
  "prompt": "一只戴帽子的猫，水彩风",
  "model": "image2",
  "size": "1024x1024",
  "output_name": "cat.png"
}
```

统一参考图编辑工具 `edit_image` 额外接收有序的 `image_paths` 数组。Gemini 调用将 `model` 改为 `gemini`，使用 `aspect_ratio` 和 `image_size` 替代 `size`。以下旧工具示例继续保留用于兼容已有调用。

本地 0.4.3 的动态 GIF 示例（`generate_image`；未指定模型时也会自动选择 Flare）：

```json
{
  "prompt": "一只挥手的小猫，做成循环动图",
  "model": "image2.6-flare",
  "output_format": "gif",
  "frame_count": 9,
  "frame_duration_ms": 200,
  "output_name": "waving-cat.gif"
}
```

`output_format` 可选 `png`（默认）或 `gif`；`quality` 是 Image2 生成的可选参数。GIF 省略 `size` 时使用 `auto`，省略帧数或每帧时长时使用 9 帧和 200 ms。返回 `file_path`、实际 `size`、`output_format=gif`、实际 `frame_count` 与总 `duration_ms`；文件扩展名为 `.gif`。只支持文生图生成动画，不支持用参考图编辑或生成动画，也不支持 SVG 或复杂度／标记编辑。

### 文生图

MCP 工具名：

```text
generate_image2
```

入参示例：

```json
{
  "prompt": "A realistic studio desk setup",
  "size": "1024x1024",
  "output_dir": "/Users/you/Desktop/images",
  "output_name": "desk.png"
}
```

字段说明：

```text
prompt       必填，生图提示词
version      可选；省略时普通 PNG 使用维护者默认版本（通常为 Image 2.0），GIF 使用 Image2.6 Flare；Image 2.5 传 "2.5"，Image2.6 Sunburst 传 "2.6"，Flare 传 "2.6-flare"
size         可选；PNG 默认 1024x1024，GIF 默认 auto，明确 GIF 尺寸的宽高须为正数且均为 16 的倍数
output_format 可选，png（默认）或 gif；GIF 只支持 Image2.6 生图
quality      可选，Image2 生图质量
frame_count  GIF 可选，2–64 帧，默认 9；PNG 不可传
frame_duration_ms GIF 可选，每帧 20–2000 ms，默认 200 ms，服务按 10 ms 取整；PNG 不可传
output_dir   可选，图片保存目录；如果传入，必须是绝对路径
output_name  可选，图片文件名；不传则按格式自动生成 image2-时间戳.png 或 .gif
```

`output_dir` 规则：

- 不传：保存到默认目录 `output/imagegen/`
- 传绝对路径：保存到该目录
- 支持 `~/` 开头的用户目录路径
- 传其他相对路径：直接报错，不会调用生图接口

macOS 绝对路径示例：

```text
/Users/you/Desktop/images
```

Windows 绝对路径示例：

```text
C:\Users\you\Desktop\images
```

返回示例：

```json
{
  "file_path": "/Users/you/Desktop/images/desk.png",
  "size": "1024x1024"
}
```

### 图生图

调用接口：

```text
POST {OPENAI_IMAGE_BASE_URL}/v1/images/edits
Content-Type: multipart/form-data
```

入参示例：

```json
{
  "prompt": "Add a cat sitting on the desk",
  "image_paths": ["/Users/you/Desktop/images/desk.png"],
  "size": "1024x1024",
  "quality": "auto",
  "mask_path": "/Users/you/Desktop/images/mask.png",
  "output_dir": "/Users/you/Desktop/images",
  "output_name": "desk-with-cat.png"
}
```

多图输入时，数组顺序会原样保留：

```json
{
  "prompt": "以第一张图为主体，以第二张图为服装和配色参考",
  "image_paths": [
    "/Users/you/Desktop/images/subject.png",
    "/Users/you/Desktop/images/style.jpg"
  ],
  "output_name": "combined.png"
}
```

字段说明：

```text
prompt       必填，编辑提示词
version      可选；省略使用默认版本，Image 2.5 传 "2.5"，Image2.6 Sunburst 传 "2.6"，Flare 传 "2.6-flare"；编辑仅输出 PNG
image_paths  必填，源图片绝对路径列表，至少一个
size         可选，默认 1024x1024
quality      可选，默认 auto
mask_path    可选，蒙版图片绝对路径
output_dir   可选，图片保存目录；如果传入，必须是绝对路径
output_name  可选，图片文件名；不传则自动生成 image2-时间戳.png
```

`image_paths` 规则：

- 至少传一个路径
- 每个路径必须是绝对路径或 `~/` 路径，文件存在且为普通文件
- 多图会按数组顺序上传

`mask_path` 规则：

- 不传或为空：不使用蒙版
- 传绝对路径：文件必须存在

`output_dir` 规则与 `generate_image2` 相同。

返回示例与 `generate_image2` 相同：

```json
{
  "file_path": "/Users/you/Desktop/images/desk-with-cat.png",
  "size": "1024x1024"
}
```

## 脚本参数

macOS / Linux：

```bash
./install.sh --help
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Help
```

常用参数：

```text
--interactive / -Interactive        交互式输入 URL 和 key（高级维护者模式）
--configure-codex / -ConfigureCodex 写入 Codex MCP 配置
--force-config / -ForceConfig       覆盖已有 image2 MCP 配置
--base-url / -BaseUrl               指定图片网关地址
--prebuilt / -Prebuilt              强制下载 GitHub Release 二进制
--skip-tests / -SkipTests           跳过测试，只构建
--smoke / -Smoke                    调用真实接口做生图测试
```

## 常见问题

### 需要提前打包吗？

不需要提交打包产物。别人从 GitHub 拉取源码后，直接运行安装脚本即可。

如果你已经发布 GitHub Release，用户不需要安装 Go；脚本会下载预编译二进制。
如果还没有发布 Release，用户需要安装 Go，让脚本在本机编译。

GitHub 仓库里不要提交 `dist/`。不同系统需要在本机编译自己的二进制。

### 为什么 key 不写进 Codex config？

为了避免泄漏。Codex config 只保存 runner 路径，真实 key 放在本地
`.env.local`，并且 `.env.local` 不提交。

### Codex 看不到 generate_image2 或 edit_image2 怎么办？

确认 `~/.codex/config.toml` 里有 `[mcp_servers.image2]`，然后重启 Codex 或开启新会话。

如果你已经配置过但后来移动了项目目录，检查 config 里的 runner 路径是否还是旧路径。

可以运行本地连接检查，确认 MCP 能启动并提供四个工具，且至少配置一把专用 Key；此命令不会生成图片：

```bash
~/.local/share/image2-mcp/scripts/run-image2-mcp.sh --verify-mcp
```

Windows PowerShell：

```powershell
& "$env:LOCALAPPDATA\image2-mcp\scripts\run-image2-mcp.ps1" --verify-mcp
```

成功时输出 `MCP verification: OK`。若失败，保留错误并排查对应阶段，避免反复重装。

### 生图失败怎么办？

MCP 连接正常并不代表客户的 Key 已获得对应模型权限。统一工具使用 2.5 时传入
`model: "image2.5"`；旧工具使用 `version: "2.5"`。Image2.6 Sunburst／Flare 也需要对应账号和网关权限；模型被列为可选项不代表请求一定可用。网关权限或模型不可用需要按接口错误排查，工具不会自动降级或切换服务。
Gemini 请求最多等待 300 秒且不自动重试；Image2 的 429 和临时 5xx 最多尝试 3 次，其他 HTTP 错误不重试，单次最多等待 180 秒。
Codex 工具超时设为 600 秒；失败后不应由 Agent 再发起重复生图。Gemini 无图片或异常响应会保存不含字符串内容的结构诊断；不保存提示词、密钥或图片编码。

检查：

- 使用 Image2 时，`OPENAI_IMAGE_API_KEY` 是否已配置且正确
- 使用 Gemini 时，`GEMINI_IMAGE_API_KEY` 是否已配置、正确且属于 Gemini 图片服务
- 固定网关是否可访问：`https://api.schyler.top`
- `image_paths` 是否全部为本地绝对路径，且文件存在
- `output_dir` 是否是绝对路径
- 目标保存目录是否有写入权限
