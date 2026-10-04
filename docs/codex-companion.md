# 官方 Codex + ClipSlots 联动（217810 历史记录，已回退）

**最新决定（2026-10-03）：用户要求“回退上一版”。已恢复 217809，撤回本轮联动源代码，并移除新增的 `clipslots-canvas` MCP 配置。素材、会话、任务和其它 MCP 配置保留当前数据。以下内容仅记录此前 217810 的实施情况，不代表当前版本。**

217810 程序与回退前源码已归档到 `build/rollback-217809-20261003-112007/`；回退记录 `.dbg/companion-rollback.json`。当前 Agent 主入口恢复为 `AgentWorkspaceView`。

用户已接受放弃复刻（2026-10-03）：“可以，我现在觉得可以不用复刻了”。
本轮转向官方 App 承担 Agent，ClipSlots 专注画布/素材操作。既有会话、定时任务数据保留，不擅自删除；不提交/推送 Git，不自动派子 Agent。

## 实施时的事实

- 本轮基线 217809，现已安装 **217810**；工作树 `ClipSlots-agent-perf`，不能误用默认 cwd `ClipSlots`。
- 官方 `/Applications/ChatGPT.app`，CLI `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。
- 内置 MCP 已有槽位/页面/组工具：`AgentMCPServer.swift` → `AgentToolRegistry.swift` → CLI。原路径直接写磁盘，不能保证画布撤销。
- `CanvasCommandBridge` 仅为全局热键桥，不能用于跨进程。
- `CanvasStore` 持有真实节点和历史；`ContentView` 以 StateObject 持有它。
- `CanvasWorkspaceView` onAppear 安装槽位文本/附件撤销回调，onDisappear 清除。因此第一版画布联动要求 ClipSlots 处于画布页；切换到官方 App 前先让 ClipSlots 进入画布，后台保留此页。
- 节点正文通过 `store.canvasSlotText` 读取，`store.writeCanvasSlotText` 写入；成功后 `canvas.recordSlotTextEdit`、`canvas.noteSlotDataChanged`。`CanvasStore.history.undoTarget.id` 可防止工具撤销用户后来做的其它操作。

## 已实现

1. Agent 主入口改为简洁的官方 Codex 联动页，显示连接、选中素材和打开官方 App 动作；原内置页保留为历史/旧版入口，不再默认伪装官方。保留现有侧栏助手和存量任务。
2. 新增受限的本机桥：Network.framework 绑定 **127.0.0.1**，仅处理 JSON 的明确操作，不提供通用命令执行。随机运行期令牌保存在 ClipSlots 数据目录、权限 0600；协议不向模型返回令牌。Kit 客户端由 MCP 调用，GUI 主线程执行真实编辑。
3. 第一组工具：读取当前画布选择与上下文、写回指定节点正文、撤销指定写回。传 project/node/session 标识及文本 revision；拒绝旧会话、项目已切换、原内容已变；变更 request_id 去重缓存、重试不重复写；撤销必须匹配历史栈顶 change_id，不能误撤用户后续操作。正文写回保留附件。
4. 官方 MCP 使用独立的 `clipslots-canvas` 配置，指向 `/Applications/ClipSlots.app/Contents/MacOS/clipslots-cli canvas-mcp`，仅暴露上述三项工具，防止通用 `write_slot` 绕过画布事务。配置前读取现有项，拒绝覆盖不同的同名项，备份 `config.toml` 并设 0600；使用 `codex mcp add` 写入实际 CLIPSLOTS_DATA_DIR，保留既有其它 MCP。
5. 原生隔离验证：MCP 真进程调用 → 画布正文/slotRevision 更新 → 历史可撤销 → 磁盘读回旧内容。覆盖 stale revision、重复 request、错误 change_id、项目切换、App 不可达。官方引擎只验证工具发现和配置，无付费推理；不能宣称已跑真实模型对话。
6. Debug、针对性回归、Release、备份安装 217810 均完成；正式 App 入口、配置按钮与实时画布读取通过。

### 代码与数据边界

- `CanvasCompanionBridge.swift`：随机端口的 127.0.0.1 TCP/NDJSON 通道；目录 0700，endpoint 0600，运行期随机令牌；单请求最大 2 MB，连接数和超时有界。令牌不进入工具输出。
- `CanvasCompanionTools.swift` / CLI `canvas-mcp`：标准 MCP stdio；旧 `agent-mcp` 保留供已有会话使用。
- `CodexCompanionModel.swift`：GUI 主线程串行处理；项目切换刷新会话标识；正文和节点出生时间及画布版本组成 revision；512 个请求的摘要去重，不缓存正文副本，淘汰前更换会话 ID 防止重放。
- `writeCanvasSlotText`：与 GUI 写队列保序，在同一跨进程锁内读取最新槽位、比较旧正文并持久化，锁失败或已变化时拒绝写入。保留附件、标签和手动缩略图；只更新正文并清除不匹配的旧 HTML 源。
- `CanvasStore.undoSlotTextChange`：先持久化原正文，成功才推进真实历史栈；仅撤销栈顶且由本联动创建的指定条目。
- `CodexCompanionView`：Agent 默认联动页；显示当前选择、连接配置、复制示例请求、打开官方 App、返回画布；“历史会话与本机任务”保留原页面。侧栏助手及调度器保留。
- 第一版支持**节点正文读写**和**附件元信息读取**；不传送附件字节给模型，不自动创建图片/视频，不同步官方云任务。画布需保持打开，App 重启/换项目后必须重新读取上下文。

## 验收与交付

- 联动原生专项 **80/80**：真实 CLI MCP 进程 → GUI 选择/读写/刷新 → 磁盘读回 → 工具撤销与原生重做；附件字节不丢、重复请求、错误 change_id、后续用户移动、编辑中保护、项目往返、无效凭据、离开画布、窗口重建、另一进程写入与持锁导致的写入/撤销失败均覆盖。真实 AX 点击了历史/任务/返回入口，深浅色截图已核对。
- 官方协议 **80/80**：官方 CLI 在独立无凭据目录启动，发现 `clipslots-canvas` 三项工具；不发起模型回合。
- 旧页面原生回归 **102/102**，核心回归 **32715/32715**；Debug/Release App 与 CLI 均构建成功，`git diff --check` 通过。
- 报告和截图：`build/validation/codex-companion/`；日志 `.dbg/companion-{build,native,protocol,legacy-native,core,release,release-cli}.log`。
- 复现：`swift build -j 4` 后运行 `CLIPSLOTS_CODEX_COMPANION_PROBE=1 python3 scripts/canvas_regression.py --skip-build`。测试仅在独立 bundle 和 `/tmp/clipslots-v2174-*` 数据目录执行。

### 正式安装

- `/Applications/ClipSlots.app` **217810** 已启动；签名、App/CLI 指纹、CLI 软链接和内置官方 Codex 程序哈希核对通过。未提交/推送 Git。
- 旧版备份：`build/backup/ClipSlots-217809-before-codex-companion-20261003-111633.app`。
- 画布/会话/本机任务备份：`build/local-codex-companion-20261003-111608/data-before-update`。安装期间槽位索引及三份会话文件哈希不变。
- 正式版 AX 实点 Agent → 连接 Codex → 打开官方 Codex 成功；ClipSlots 自动进入画布、前台 App 为 `/Applications/ChatGPT.app`。正式 CLI MCP 可读取实际画布，未向用户素材写测试内容。
- 官方 MCP 配置已添加 `clipslots-canvas`；既有 **5 项**配置逐项哈希一致。配置备份 `~/.codex/config.toml.before-clipslots-53FA92D3-429E-4AB6-B007-6BBC5E5F2AEB`，权限 0600。
- 安装记录 `.dbg/codex-companion-install.json`；正式验证 `.dbg/companion-installed-verification.json`。
- **没有付费推理验收，也没有重启/终止官方 App 的正在进行的任务。**首次使用请在官方 Codex 新建会话加载工具。
