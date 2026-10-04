# Codex 桌面联动实施范围

用户已选择方案 2：Agent 保留在 ClipSlots 内，参照所提供桌面截图调整界面，通过官方接口联动本机数据；不承诺官方未来的 UI/功能自动完整复制。

## 本机证据

- 官方桌面位于 `/Applications/ChatGPT.app`，bundle ID `com.openai.codex`，签名 OpenAI OpCo。
- 桌面版本 `26.930.21537`，内核 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`：`0.159.0-alpha.12.1`。
- ClipSlots 217807 内置 Codex `0.160.0`，当前优先使用内置程序。
- 已通过官方桌面内核生成精确 schema：`/tmp/clipslots-codex-desktop-schema/`。
- 只读 RPC 探测：`project/list`、`thread/list`、`config/read` 均成功。当前项目列表为空，有真实会话。
- 当前有效 provider 是 `custom`，默认模型 `deepseek-flash`，推理强度 `medium`；OpenAI 账户为空。不能因没有 OpenAI 账户阻止用户自己的 provider。
- 未读取或输出凭据；未发起推理或修改官方会话。

## 实施内容

1. **本机引擎跟随**：识别 ChatGPT.app/Codex.app 和用户指定路径；异步检查版本与协议兼容性，失败回退内置程序并显示原因。更新只作用于下一连接，不中断运行任务。
2. **桌面式页面**：窄图标栏、会话侧栏、简洁居中欢迎页、底部项目选择与输入区；保持顶部“编辑｜画布｜Agent”，保留独立侧栏助手和主题模式。
3. **真实数据联动**：分页读取官方项目和会话，支持历史搜索/刷新/选项目/读历史/继续会话，保留本地草稿和旧会话。打开历史只读，发送才恢复线程。
4. **模型与配置**：读取实际模型/provider/推理配置，输入区直接选择模型和强度；不把用户的自定义 provider 强制改成 OpenAI。
5. **Skills/MCP**：读取本机目录与状态，提供 Skill 选择/启停和 MCP 刷新/授权入口。遵循已有配置，不输出认证信息。
6. **安全的任务交接**：识别运行中的会话，避免同时从两个客户端发送；迟到刷新不能覆盖新选中的会话或未发送草稿。不承诺跨客户端实时共同编辑。
7. **槽位联动**：原有动态工具继续兼容。桌面历史线程没有 ClipSlots 动态工具，不能假装恢复后自动拥有工具；需提供可用于恢复线程的 MCP 适配或等效的、明确可验证的工具连接。

## 协议注意点

- `project/list` 返回 `data/nextCursor`，项目 `roots` 是 `[{path}]`；旧内核可降级为从会话 cwd 推导项目。
- `thread/list` 支持 cursor、modelProviders、sourceKinds、searchTerm、projectId、cwd、sortKey；线程带 name/preview/model/modelProvider/reasoningEffort/projectId/cwd/status/historyMode。
- `thread/read(includeTurns:true)` 对分页历史已弃用全量加载；实现应兼容 `thread/turns/list(itemsView:"full")` 与 `thread/items/list` 分页。
- `thread/resume` 不支持临时注入新的 `dynamicTools`，不能把已有桌面线程当作自建线程处理。
- `skills/list` 返回 `data:[{cwd,skills,errors}]`；skill 包含 name/path/description/enabled。
- `skills/config/write` 支持 path + enabled。
- `mcpServerStatus/list` 返回 data/nextCursor，各项包含 name/authStatus/tools/resources/runtimeStatus。
- 只展示公开推理摘要，不暴露原始推理内容。

## 验证与交付

- 协议模拟：运行程序选择/失效回退、分页、历史转换、任务状态、provider 认证分支、工具桥接与刷新竞争。
- 真实官方内核：无付费推理的兼容探测，真实会话只读验证。
- 原生隔离 bundle/数据：主题、会话、项目、模型、搜索与中文输入；最终点击验收要求桌面解锁。
- Debug/Release 构建后，备份安装 217808；保护旧槽位、画布、会话、CLI 软链接及官方运行程序签名。

## 已实现

- `CodexWorkspace.swift`：安全配置子集、游标分页、项目目录推导、只读历史转换、稳定消息 ID，以及连接失败时的内置引擎回退。
- `CodexWorkspaceModel`：页面打开/应用激活/任务结束时刷新；手动刷新；会话选择版本号防止迟到覆盖；读取实际模型、Skills 和 MCP 状态。
- `AgentChatModel.CodexContext`：按会话保存目录、provider、模型、推理强度和本地覆盖选择。更新远端历史保留草稿和附件；失败的本地消息保留以供重试。
- 原生 Agent 页面：窄工具栏、会话导航、居中欢迎页、底部项目栏、模型/强度菜单、终端只读/可编辑项目权限菜单、Skills/MCP 页面。
- `clipslots-cli agent-mcp`：复用现有工具注册表和 CLI 跨进程写锁。每次发送将 MCP 配置传给该线程，支持桌面已有线程；不改写全局 Codex MCP 配置。
- 自定义 provider 复用其本机认证配置；仅 OpenAI 或声明需要 OpenAI 认证的 provider 检查 OpenAI 登录。取消原先强制 `keyring` 的配置覆盖。
- 更新引擎在下一次连接生效；运行中的回答保持其原进程。配置协议不兼容或启动失败时，自动模式回退内置引擎并提示。用户指定程序路径失败会如实报错。

## 同步边界

- 共用本机 Codex 数据，刷新后显示双方已保存的历史；不提供跨客户端逐 token 镜像或并发协同编辑。
- 发送前检查服务端可见的 active 状态并拒绝重入。不同 Codex 进程的状态可见性由官方引擎决定，不能把这当成跨应用原子锁。
- 项目列表优先读取官方 project/list，兼容从会话 cwd 推导；选择本地文件夹设置新会话目录，不自动创建官方项目记录。
- 本机 Skills 启停写回官方配置，下一轮任务生效；“使用”将 Skill 名称插入草稿。MCP 显示实际目录/授权状态并提供官方 OAuth 入口。
- 未支持的历史记录类型标记为“暂不支持展开”，不静默丢弃；只展示公开推理摘要。
- 官方引擎的兼容升级可以自动跟随。官方页面设计、新权限/新交互/新功能需要 ClipSlots 后续适配，不能保证全功能永久自动同步。

## 本轮验证进度

- Debug 与 Release（App、CLI）构建通过，`git diff --check` 通过。
- 63 项协议/工具检查通过（官方桌面 `0.159.0-alpha.12.1`）；包含只读读取真实桌面 32 条会话、32 个推导项目和所选历史。
- 官方引擎实际发现 ClipSlots MCP 工具；MCP 与动态工具均通过临时数据目录写入/读回检查。未发起付费推理。
- 内置回退引擎 `0.160.0` 的 60 项协议检查通过；Release CLI 的 MCP 握手及隔离写入/读回通过。
- 核心回归 32,715 项通过。
- 两轮原生回归均有 80 项通过；唯一未通过项是 `native desktop focus`，报告显示 `sessionLocked: true`。布局、中文输入、历史搜索、草稿/附件、模型元数据恢复等检查通过。已核对原生截图并修正 macOS 菜单的占宽及项目栏背景。最终前台验收需解锁。
- 已安装并启动 `/Applications/ClipSlots.app`，build **217808**；安装校验记录 `.dbg/codex-desktop-install.json`。安装前后槽位索引及三份 Agent 会话哈希一致，两个 CLI 软链接保留，官方内置 Codex 二进制哈希未变。
- 旧应用备份：`build/backup/ClipSlots-217807-before-codex-desktop-20261003-044043.app`。
- 画布及全部 Agent 会话备份：`build/local-codex-desktop-20261003-044013/data-before-update/`。
