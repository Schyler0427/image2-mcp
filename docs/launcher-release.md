# Windows 启动器发布

客户只需要一个文件：`SchylerAI-Image2-mcp.exe`。更新模型、工具描述、MCP 逻辑或安装器时，
提升 MCP 版本、同步安装器中的固定版本并重新构建 EXE。启动器版本读取内嵌版本文件。

本地 Windows 0.4.4 修复安装暂存目录切换时的短暂拒绝访问：目录移动遇到 Win32 错误 5（拒绝访问）、32（共享冲突）或 33（锁冲突）时，最多尝试 6 次，每次间隔 1 秒。正式目录切换、旧版备份和失败回滚使用同一个重试入口；永久失败保留原始异常，其他错误不重试。模型、工具、密钥输入方式和原有事务顺序保持不变。`tests/test-bootstrap-directory-move.ps1` 覆盖重试、失败上限、原始异常、真实目录移动及事务入口；Windows PowerShell 5.1 CI 会运行此测试。PowerShell 7/macOS 的本地测试不能替代 Windows GUI 实机验收。

本地 0.4.3 构建新增 Image2.6 Sunburst／Flare 和动态 GIF 文生图，v0.4.5 在线版同步提供这些功能，并在安装时自动写入 `[features]` 的 `image_generation = false` 避免新版 Codex 内置生图抢占路由。普通 PNG 仍默认 Image2 2.0。“用2.6生图”选择 Sunburst，“用2.6快速版生图”选择 Flare；“生成动图”“做个GIF”“循环动图”在没有明确指定模型时自动选择 Flare 并设置 `output_format=gif`。明确指定的模型不因不支持 GIF 或上游错误而改换。GIF 不支持参考图编辑，不能丢弃参考图改走文生图；生成可选 `quality`，GIF 默认自动尺寸、9 帧、每帧 200 ms，输出保留原始 `.gif` 字节并报告实际尺寸、帧数及总时长。固定在线 Key-only 路径使用 v0.4.5；更新服务需维护者另外部署。

## 构建与校验

```bash
bash scripts/build-universal-windows-launcher.sh
```

Windows 维护者也可运行 `scripts/build-universal-windows-launcher.ps1`。构建器生成三种原生
MCP 程序，再打包为 Windows 386 GUI 启动器。构建后测试会核对真实 PE 架构、版本、摘要，
并确认最终 EXE 包含三种完整二进制；校验通过前不会替换输出文件。默认输出目录是
`dist/universal-windows-launcher`。直接 `go build ./cmd/windows-launcher` 只会打包仓库测试
资源，不能作为客户安装包分发。

## 签名

维护者私钥使用 PKCS#8 Ed25519 PEM，保存在仓库外，不能放进 EXE、离线包或 Git。
图片服务 API Key 与发布签名私钥是两种独立凭据。客户只输入 Image2 或 Gemini 专用 API Key，至少配置一把，也可同时配置两把。留空表示该服务未配置，并清除该服务原有配置；不能复用旧安装或环境变量里的 Key。默认仍使用 Image2；只有明确说 Gemini、banana 或香蕉时才使用 Gemini 3.1 Flash Image（`gemini-3.1-flash-image`）。所选服务未配置时报告错误，不会自动切换服务。

启动器全部按钮和提示使用中文，包括“安装 / 更新密钥”“检查更新”“下载新版”和“取消”。

按 `scripts/update-manifest.example.json` 填写实际版本、UTC 发布时间、说明、下载地址、
EXE 字节数及 SHA-256，再签名：

```bash
go run ./scripts/sign-launcher-manifest.go \
  -key /path/outside/repository/update-signing-key.pem \
  -public-key '启动器的 UpdatePublicKeyBase64' \
  -input /path/launcher-unsigned.json \
  -output /path/launcher.json
```

签名输入格式见启动器设计文档。CI 使用 secret
`IMAGE2_LAUNCHER_UPDATE_PRIVATE_KEY_B64`（整个 PEM 文件的 Base64），并核对它与启动器内嵌
公钥是否匹配。更新清单签名用于客户端验证更新，与 Windows Authenticode 代码签名不同。

## 更新服务

发布工作流会生成 GitHub Release 资产；还需由维护者将相同字节部署到自有 HTTPS 服务。
更新服务不会由本地构建器自动部署。必须提供以下地址，且不能通过重定向跳到其他主机：

```text
https://api.schyler.top/image2/releases/<version>/SchylerAI-Image2-mcp.exe
https://api.schyler.top/image2/releases/latest/launcher.json
```

先上传不可变版本 EXE，确认字节数与 SHA-256 匹配，再原子替换 `latest/launcher.json`。
只修改 JSON 中的空格或字段顺序不会改变签名语义；修改说明、数组顺序、版本或其他签名
字段后必须重新签名。发布错误内容时递增补丁版本修复，不降低清单版本。

未部署更新服务时，窗口检查更新会报告失败，当前 EXE 的离线安装和换密钥仍可使用。
轮换签名公钥时，先用旧私钥签发包含新公钥的新版 EXE，再切换后续清单的签名私钥。

## Windows 验收

本地 macOS/Linux 可测试协议、打包、哈希和签名，但不能代替 Windows 实机验收。发布前需在
Windows 10/11 的可用架构上验证弹窗、首次安装、换密钥、下载更新与新版启动、MCP 握手、
失败回滚，以及安装中取消或关闭会等待事务完成。CI 已加入 Windows 原生/WOW64 架构回归
与 PowerShell 事务取消测试；最终 GUI 仍需 Windows 实机确认。
