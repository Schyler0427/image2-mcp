# SchylerAI Image2 MCP 通用 Windows 启动器设计

## 目标

交付一个名为 `SchylerAI-Image2-mcp.exe` 的单文件启动器。用户将文件放在任意目录后双击，弹出 Windows 原生密钥窗口，输入 Image2 专用 API Key 后完成安装、更新和 MCP 验证。用户不需要解压 ZIP、安装 Go、运行 PowerShell 或判断 AMD64/ARM64。窗口还提供“检查更新”与“立即更新”操作。

每次执行安装或更新都要求输入 Image2 API Key。再次运行同一个文件会替换活动配置中的密钥；使用更新版本的 EXE 会同时更新 MCP 程序和密钥。旧安装只作为回滚备份保留，不会复制旧 `.env.local` 到新活动目录。检查更新本身不读取或上传 API Key。

## 兼容范围

启动器使用 Windows 386 架构构建，以便在 32 位 Windows、x64 Windows 和支持 x86 模拟的 ARM64 Windows 上启动。EXE 内嵌三种 MCP payload：`windows/386`、`windows/amd64` 和 `windows/arm64`。

启动器通过 Windows 原生系统信息 API 读取真实系统架构，不依赖 32 位进程中的 `PROCESSOR_ARCHITECTURE` 环境变量。它只释放并运行与系统匹配的 payload。目标支持范围为 Windows 10/11 的 x86、x64 和 ARM64；不承诺 Windows 7/8，也不绕过 Codex 本身的系统要求。

## 用户流程

1. 用户双击 `SchylerAI-Image2-mcp.exe`。
2. 启动器显示名称、当前内置版本和密码样式的 Image2 API Key 输入框。
3. 用户点击“检查更新”时，启动器只请求固定的 HTTPS 更新清单，不发送 API Key。清单包含最新版本、发布日期、变更说明、适用 Windows 架构、EXE 下载地址、SHA-256 和维护者签名。
4. 如果有新版，窗口显示版本和变更说明，更新按钮变为“Download new version”。点击后，启动器将新版 EXE 下载到用户缓存目录，检查 HTTPS 地址、文件大小、SHA-256 和嵌入公钥验证的签名。校验失败时删除临时文件并保持当前安装。独立的安装按钮始终可安装当前 EXE 内置版本。
5. 通过校验后，新 EXE 被启动并接管安装流程。新窗口再次要求输入 Image2 API Key；旧进程不把密钥传给新进程。
6. 启动器在后台释放临时 payload，并通过标准输入把密钥传给现有离线安装流程；密钥不出现在命令参数、环境变量、日志或窗口输出中。
7. 安装流程将新版本部署到固定用户目录，写入受 ACL 保护的 `.env.local`，更新 Codex 的 `mcp_servers.image2` 配置，保留其他 MCP 配置，并执行 MCP 握手、版本和工具列表验证。
8. 窗口显示成功、失败或已回滚状态。成功时提示重启 Codex 或开启新会话。
9. 更新失败时恢复完整旧安装和 Codex 配置，并保留事务证据路径。

空密钥、目标目录不可写、更新清单不可达、下载失败、签名或摘要校验失败、payload 校验失败或 MCP 验证失败都不会替换活动安装。取消发生在 PowerShell 安装事务启动前时不会修改旧安装；事务启动后，取消或关闭窗口会等待事务成功完成或执行回滚，不会强制结束安装进程。没有网络时仍可安装当前 EXE 内置版本，但不能检查或下载新版。实际生图仍按现有工具规则访问图片网关；启动器本身只负责本地安装、更新和验证。

## 内部结构

通用启动器是一个 Windows 386 Go 可执行文件，使用 `go:embed` 嵌入：

- `windows/386`、`windows/amd64`、`windows/arm64` 的 `image2-mcp.exe`；
- Windows PowerShell 安装脚本和 runner；
- 离线 manifest、版本标识和必要的安装资源。

启动器还内嵌更新清单的 Ed25519 公钥。更新清单使用固定 HTTPS 地址获取；清单中的版本、下载 URL、SHA-256、架构和签名必须通过验证。更新 URL 只允许 HTTPS，禁止跨主机重定向和用户信息，下载大小有上限，下载与校验过程不携带 API Key 或 Codex 配置。

启动器包含一个最小的原生 Win32 GUI，不依赖 .NET、WebView、Inno Setup 或外部运行时。它负责密钥输入、开始/取消按钮、进度文本和错误摘要。安装细节仍由现有事务安装器完成，避免复制备份、Codex 配置解析、ACL 和 MCP 验证逻辑。

启动器为临时目录创建随机工作区，释放资源后逐项核对 manifest，再启动 PowerShell 安装入口。标准输入管道只发送一行密钥，进程结束后关闭管道并清理临时目录。GUI 不显示密钥，也不把密钥放进子进程环境。

## 版本与发布

更新清单的签名输入是紧凑 UTF-8 JSON，字段顺序固定为
`version`、`published_at`、`notes`、`asset_url`、`sha256`、`size`、
`architectures`；`signature` 字段不参与签名。数组顺序也参与签名，发布时必须
使用 `386`、`amd64`、`arm64` 的固定顺序。维护者可使用
`go run ./scripts/sign-launcher-manifest.go -key <PKCS8-PEM> -input <json> -output <json>`
生成签名清单。签名使用 Go encoding/json 的标准转义规则（包括 HTML 字符转义），无额外空格或行尾。发布工具的 `-public-key` 可校验私钥与启动器内嵌公钥是否匹配。私钥只应保存在发布机或 CI secret 中，不得提交到仓库或嵌入 EXE。

每个通用 EXE 只有一个文件名：`SchylerAI-Image2-mcp.exe`。发布清单同时记录版本、发布日期、变更说明、SHA-256、签名和支持的内部 payload 架构。构建流程在 Windows CI 生成 `windows/386` 启动器，并交叉构建三种 MCP payload 后嵌入。发布新版时，新的 MCP 二进制、模型参数、工具描述和安装器逻辑一起进入 EXE；旧版不会尝试解释未知模型配置。

- 在 Windows x86、x64 和 ARM64（或对应 CI/模拟环境）启动并选择正确 payload；
- 首次安装、再次输入新密钥的更新、取消和空密钥；
- 检查更新、无更新、网络不可达、下载中断、错误摘要和错误签名；
- 新版下载后再次提示输入密钥，并完成版本升级；
- MCP 握手、版本和 `generate_image2` / `edit_image2` 工具列表；
- 损坏 manifest、损坏 payload、权限失败和验证失败时的回滚；
- 密钥不出现在命令行、环境变量、日志、GUI 输出和错误诊断中。

## 非目标

- 不安装或更新 Codex 本身；
- 不把 API Key 写入 Codex 配置；
- 不在启动器中实现图片生成请求；
- 不承诺 Windows 7/8 或未安装 Codex 的机器；
- 不通过网络下载安装依赖或未签名的架构 payload；当前 EXE 必须可自包含离线安装，更新功能只下载经过签名和摘要校验的新 EXE。
- 更新检查只访问固定 HTTPS 更新源，不上传 API Key、图片或本地 Codex 配置；
- 当前 EXE 在没有网络时仍可执行本地安装，自动更新不是唯一安装路径。
