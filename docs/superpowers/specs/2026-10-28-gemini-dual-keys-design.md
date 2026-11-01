# Gemini 与 Image2 双密钥生图

用户已授权在现有 SchylerAI-Image2-mcp 单文件程序中增加独立 Gemini 图片密钥、自然语言模型选择，未指定模型时使用 Image2，只有明确说 Gemini、香蕉或 banana 生图才选择 Gemini。参考资料是会话《编写Java图生图调用文档》及其本地 docs/gemini-image-generation-api.md。

## 行为

- 安装器提供 Image2 API Key 和 Gemini API Key 两个密码输入框，终端安装也依次询问两把新密钥。分别保存为 OPENAI_IMAGE_API_KEY 和 GEMINI_IMAGE_API_KEY，不从其他服务或旧安装复用。两把都必填，每把仅允许单行且最多 1024 字节。
- 新增 generate_image 与 edit_image 两个统一工具。model 参数接受 gemini、image2、image2.5，省略时使用 Image2；Gemini 同时接受 banana / 香蕉 别名；自然语言元数据明确三者映射。原 generate_image2/edit_image2 保持 Image2 行为供已有调用使用。
- Image2 使用现有 Images API 与自己的密钥；Gemini 使用同一固定网关的原生 /v1beta/models/{model}:generateContent，与自己的密钥。两边密钥绝不互为回退。缺少所选服务密钥时清晰报错，不自动改用另一模型。
- Gemini 文生图和参考图编辑共用 contents/parts 接口。参考图顺序保留，先读取实际格式，再编码 inlineData。支持 aspect_ratio 与 image_size=1K/2K/4K；不向 Gemini 发送 Image2 的 size/quality/mask 字段。请求蒙版编辑时须选用 Image2。
- 遍历 candidates/content/parts 找图片，兼容 inlineData 与 inline_data，忽略文字和思考图片，验证 Base64、MIME、真实图片格式与像素上限后保存。输出应是实际有效图片。无图片、封锁或格式异常时不重复提交请求，保存不含密钥/提示词/图片编码的脱敏结构诊断。
- Gemini 客户端不从全局 OpenAI Key 读取凭据；请求使用 x-goog-api-key，不跟随重定向。新图片请求只发送一次，取消和 300 秒超时有效。64 MiB 响应与 3200 万像素限制。
- 更新检查不读取任何图片密钥；新版 EXE 提示输入两把密钥。保持离线安装、事务回滚、WOW64 识别、最终三架构嵌入验证。

## 模型核对

参考文档列出 gemini-3.1-flash-image、gemini-3-pro-image、gemini-nano-banana-2.1；实测的是 3.1 Flash，未列出 3.1 Pro。用户已明确选择 Gemini 3.1 Flash Image，Gemini 实际模型 ID 为 gemini-3.1-flash-image；随后明确更正全局默认仍为 Image2。工具描述、安装说明和界面须准确使用 Flash 名称，不能标作 Pro。协议客户端接受显式模型 ID，统一工具仅在明确选用 Gemini 时设置这个模型值。

## 验证

本地 HTTP 夹具验证请求协议、选择对应密钥、输入顺序、图片落盘、异常诊断、取消、无重试、重定向阻断。MCP 内存会话验证四个工具、自然语言元数据、默认 Image2 与显式 Gemini/香蕉/banana/Image2.5 的路由。安装夹具验证两把新密钥、未复用旧配置、不进入参数/子进程环境/日志、失败回滚和换钥。运行全部 Go/race/vet、离线/安装脚本与 Windows 三架构构建，再产出新版单文件。Windows 实机与真实网关调用均不得用本地夹具冒充。
