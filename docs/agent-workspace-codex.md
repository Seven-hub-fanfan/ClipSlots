# Agent 工作区与 Codex

当前实施构建：2.17.8（217808）。桌面联动范围与验证详见 [Codex 桌面联动](codex-desktop-sync-implementation.md)。

## 使用

1. 点击顶部「Agent」，进入独立聊天页。
2. 自动读取本机 Codex 的模型服务配置。使用自定义服务时无需额外登录 OpenAI；需要连接 ChatGPT 时打开左下设置完成官方授权。
3. 回到应用发送消息；模型留空时使用 Codex 默认模型，也可以从账户提供的模型目录中选择。

左侧提供新建、官方历史和搜索。官方历史分页读取；ClipSlots 本地最近会话保留 30 条。草稿、附件与模型选择按会话保存。打开历史只读，发送时才恢复线程。应用激活、任务结束和手动刷新会更新已保存的桌面历史。运行中的会话不能直接切到另一条官方历史；新建会停止当前回答并保留已收到的内容。

输入框提供附件、Skill、模型和停止按钮。Codex 支持图片输入；其他文件以本地文件引用提供给 Agent，具体读取能力取决于文件格式。每条消息最多 8 个附件，每个不超过 20 MB。选择的文件先复制到应用数据目录，原文件移动后不会使已保存附件失效。

工具行可以展开查看返回内容。槽位操作通过 ClipSlots 现有工具完成；终端默认只读，也可在输入框下方选择允许编辑项目文件。Skills/MCP 页面展示本机配置，可启停 Skill、插入 Skill 名称、刷新 MCP 和打开官方授权。

编辑和画布的右侧助手仍保留独立会话。新 Agent 页默认使用 Codex，后端选择与原有侧栏分开保存；DeepSeek 和 Tika 继续可用。

## 接入方式

- 优先使用本机 ChatGPT.app/Codex.app 的 App Server，自动模式失败时回退内置 0.160.0；stdio JSONL 双向 JSON-RPC。每次新连接重新检查安装，更新不打断当前任务。
- `initialize` / `initialized` 握手；启用 `experimentalApi` 以使用动态工具。
- 新会话用 `thread/start`，已有会话用 `thread/resume`，每轮通过 `turn/start` 发送。
- 处理正文增量、公开推理摘要、工具状态、token 用量、完成和错误事件。
- 动态工具 `clipslots_tool` 将调用路由到 `AgentToolRegistry`，执行前检查当轮工具白名单。工具目录随每轮更新，因此更改 Skill 不必丢弃历史线程。
- 桌面已有线程通过 `clipslots-cli agent-mcp` 接入同一注册表；MCP 配置仅作为当前线程覆盖传入，不改写用户全局配置。
- 停止发送 `turn/interrupt`，连接关闭负责兜底回收进程。RPC 有独立超时，回答有 10 分钟上限。
- 未支持的服务端请求返回结构化拒绝，避免等待无响应。命令与文件审批不扩大只读终端权限。
- 登录使用官方 `account/login/start`；认证存储遵循本机 Codex 配置。应用不读取认证文件，不记录原始 RPC 或 stderr，界面只提取模型/provider 等展示字段。
- 每次运行使用独立后端实例，迟到事件由本地 run ID 丢弃，防止旧会话串入新会话。
- 同一会话使用其他后端新增对话后，下一次 Codex 会重建线程并导入完整本地历史，包含过去附件的引用。

## 数据与构建

- 新会话：`~/.local/share/clipslots/agent-sessions/workspace.json`，权限 0600。
- 附件：同一数据根下 `agent-attachments/`，目录权限 0700，文件权限 0600。
- 现有 `edit.json` / `canvas.json` 无需迁移；新增字段可选，旧历史仍可解码。
- 新页后端：`agent.workspace.backend`。Codex 设置：`agent.codex.cliPath` / `agent.codex.model` / `agent.codex.effort`。
- `scripts/bundle_codex_runtime.py` 打包固定版本的官方 npm 运行程序，校验固定 SHA-512，包含 Apache 许可证及上游依赖许可证。支持 arm64 / x64。
- `scripts/package_dmg.sh` 已接入运行程序打包并按应用大小分配 DMG 容量；可通过 `CODEX_RUNTIME_ARCHIVE` 使用已有归档。
- 保留 Codex 官方签名，不随 ClipSlots 的 ad-hoc 更新重新签名，以维持其钥匙串身份。

## 验证命令

```sh
swift build
CODEX_TEST_EXECUTABLE=/path/to/codex .build/debug/CodexProtocolRegression
CLIPSLOTS_AGENT_WORKSPACE_PROBE=1 python3 scripts/canvas_regression.py --skip-build
.build/debug/ClipSlotsKitSmokeTests
swift build -c release
```

协议测试包含分片 Unicode、双向请求、乱序回复、工具拒绝、线程恢复、取消、超时、错误透传、真实 CLI 的隔离槽位写入和读取；官方程序测试仅握手、模型目录和建线程，不发送推理请求。

原生回归使用独立 bundle 和临时数据目录，覆盖三页路由、会话与附件恢复、历史搜索、新建对话、中文输入法、深浅与简洁/多彩外观，以及原有侧栏回归。

真实账户授权需要用户在官方网页完成；未自动发起付费模型请求。

### 217807 历史验证与安装记录

- Debug 与 Release 构建通过。
- 37 项 Codex 协议/工具检查、32,715 项核心检查通过。
- 解锁桌面后原生检查 74 项全部通过，包含窗口焦点、历史搜索真实点击与键盘输入、中文输入、会话恢复及页面截图核对。
- 已安装并启动 `/Applications/ClipSlots.app`，build 217807。旧应用和画布已备份；槽位索引、编辑/画布会话的哈希未变化，两处 CLI 软链接保留。
- 安装明细及校验摘要：`.dbg/agent-workspace-install.json`。

协议参考：

- https://developers.openai.com/codex/app-server
- https://developers.openai.com/codex/auth
- 本次使用官方 0.160.0 的 `app-server generate-json-schema --experimental` 输出核对请求与事件形状。
