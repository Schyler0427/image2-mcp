# SchylerAI-Image2-mcp · macOS

当前本地版本：**0.4.3**。通用应用同时包含 Apple 芯片与 Intel 启动器及离线 MCP，最低系统版本为 macOS 12。

## 使用

将 DMG 内的 `SchylerAI-Image2-mcp.app` 拖入“应用程序”，退出旧应用后打开新版本。窗口和“显示简介”的版本都应为 0.4.3。

Each app launch starts with empty password fields. Installation accepts an Image2 key, a Gemini key, or both; at least one provider key is required. Each installation collects fresh input and writes two lines through stdin, including an empty line for an unconfigured provider. A blank field clears that provider's previous key and cannot fall back to an inherited environment key. The installer validates the local installed MCP and preserves the existing bootstrap backup/rollback transaction. Once installation starts the UI waits for commit/rollback before closing or quitting. Update checking does not read the credentials.

All launcher buttons and messages are Chinese, including “安装 / 更新密钥”, “检查更新” and “取消”. The default remains Image2 even when only Gemini is configured. Explicit Gemini, banana or 香蕉 requests select Gemini 3.1 Flash Image (`gemini-3.1-flash-image`); a missing selected provider key reports an error without automatically switching providers.

本地 0.4.3 的普通 PNG 仍默认 Image2 2.0。“用2.6生图”选择 Image2.6 Sunburst，“用2.6快速版生图”选择 Image2.6 Flare。“生成动图”“做个GIF”“循环动图”自动选择 Flare 生成 GIF，除非已明确指定模型；指定模型不因不支持或上游错误而改换。GIF 只支持文生图，不支持参考图编辑成动图。默认自动尺寸、9 帧、每帧 200 ms；文件保留动画帧并报告实际尺寸、帧数与总时长。在线 Key-only 路径使用 v0.4.4，支持这些功能。

安装成功后重启 Codex，并打开新对话。安装和本地连接验证不会调用收费生图 API。

## 0.4.2 修复

修复优化构建中 `mkdtemp` 指针超出借用生命周期后被读取的问题。暂存目录路径在借用闭包内转换为独立字符串，清理前验证绝对路径、固定父目录、随机名称、用户及文件系统身份，拒绝误删工作目录或替换后的目录。

普通构建和 `-O` 优化构建均运行安装器与目录保护回归测试。发布前还直接运行已打包启动器的 `--verify-resources`，不需要密钥、不修改用户配置。

## 构建与验证

```sh
bash tests/test-macos-launcher.sh
bash scripts/build-macos-launcher.sh
bash tests/test-macos-packaged-install.sh dist/macos-launcher/SchylerAI-Image2-mcp.app
```

签名更新服务需要维护者单独部署；本地构建使用临时签名，未经过 Apple 公证。历史设计和实施计划位于 `docs/superpowers/`。
