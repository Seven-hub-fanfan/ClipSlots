# Codex 完整桌面功能对齐（217808 后续）

用户反馈：缺少工作模式/页面切换；时钟入口无法打开定时任务；要求继续按本机 Codex App 对齐，询问能否做到 1:1 内置。不能再次把聊天页的视觉模仿当作完整 App。

## 本轮截图证据

用户图片（全部已查看）：
- `89b878fc-6645-4750-a43a-0707f53152a2_image.png`：ClipSlots 左上 Codex 下拉只提供“连接与模型设置 / Skills 与 MCP”。
- `e1d30cf6-9ec1-4384-98f5-0b826dbf8822_image.png`：官方同位置是“ChatGPT Work（创建、学习和探索） / Codex（构建、调试和发布）”模式选择。
- `dfa34016-6023-4be7-a1cf-2d0c0cae0494_image.png`：ClipSlots 时钟按钮被标出；目前实现错误地执行刷新历史。
- `f0c445cf-035f-48f0-a04e-918be07fb5fd_image.png`：官方时钟打开“定时任务”，有新建、即将执行、搜索；更多菜单含“项目 / 代码审查”。

路径共同前缀：
`/Users/bytedance/Library/Application Support/Trae CN/User/workspaceStorage/c5b591ce1812f03ea5da2adf714f9806/paste-files/`

本机真实窗口截图也已读取：
`/var/folders/j2/y9ng5chs6dqd665ryhl4p00m0000gn/T/codex-shot-2026-10-03_09-24-48.png`。
Screen Recording 已授权；官方窗口 ID 25423，1280×820，标题 ChatGPT，截图显示定时任务页。

## 技术事实

- 正确工程：`/Users/bytedance/Trae Clipslots/ClipSlots-agent-perf`。当前已装 build 217808；上轮历史、项目目录、模型、Skills/MCP、工具桥接与引擎跟随均在此工作树。
- 官方应用 `/Applications/ChatGPT.app` 是 Electron，资源 `/Contents/Resources/app.asar`，约 547MB。
- 未修改官方应用，未读取/输出认证文件或凭据，未发起推理。
- 当前精确 schema `/tmp/clipslots-codex-desktop-schema/` 有 project CRUD、review/start，没有 automation/schedule/cron 类方法。
- 只读检查应用包发现：
  - `/.vite/build/main-C3nRcJ3D.js` 中 `Bge` AutomationsService 通过私有宿主处理 `list-automations`、`automation-create/update/delete/run-now`。
  - 该服务依赖 globalState、appServerConnectionRegistry、habitatAutomationsService；创建时校验项目目录/执行环境，删除时还处理运行记录和通知。
  - `/.vite/build/preload.js` 提供 `electronBridge`，通过 `codex_desktop:connect-app-host` 等 IPC 连接宿主；单独 WKWebView 加载前端不能获得此宿主。
  - `/webview/assets/automations-page-5dec60eac265.js` 包含本地与云任务、个人/团队、定时频率、历史结果、暂停、立即运行、归档、插件模板与本地任务云同步等功能。
  - `/.vite/build/bootstrap-yYZ8rgHq.js`：本地任务有 `automations/<id>/automation.toml`，SQLite `sqlite/codex.db`（开发版 codex-dev.db），同时有 automations / automation_runs 表和较复杂的迁移。不能只写几条 SQL 就声称与官方调度等价。
  - 本机 `~/.codex/sqlite` 下检查时未命中 `*.sqlite`；官方实际扩展名是 `.db`，下一步若必要只读检查表结构/数量，勿输出用户内容或凭据。
- ASAR 只读方法：前16字节4个小端uint；JSON头长第4个uint，读取JSON；内容起始=8+第2个uint；树中file.offset加内容起始得到文件数据。主要字符串使用反引号，不是双引号。

## 已向用户说明的边界

完整原版 1:1 内嵌且自动继承所有未来功能，目前没有已确认可用的官方支持路径。App Server 的引擎接入不等于完整 Electron App 的嵌入。后续必须区分本机实现和官方服务，不能为没有接通的能力放同名空按钮。

## 后续实施要求

1. 按完整导航建立路由：主页、定时任务、Skills/扩展、更多（项目、代码审查）、设置；时钟必须进入定时任务。
2. 项目与代码审查优先使用已存在的官方协议，完成真实操作与结果呈现。
3. 定时任务继续做窄范围接口/存储调查，确定可靠可运行的路径；如采用独立本机调度，必须明确显示执行宿主与同步限制，不能冒称 ChatGPT 云任务。
4. ChatGPT Work 不能通过切换为 DeepSeek/Tika 假冒。如采用官方网页嵌入，需明确独立登录与网页能力边界；不复制桌面凭据，不篡改官方 bundle。
5. 逐入口验收：打开页面、创建/配置、运行或执行对应操作、读回结果、恢复与错误处理。无付费自动验收。
6. 沿既有授权完成本机备份安装，保留原有画布/槽位/会话。不要 Git 提交/推送，不自动派子 Agent。

## 已实现（217809）

- `AgentWorkspaceView.swift`：主页、定时任务、Skills/MCP、项目、代码审查和 Work 能力说明路由；时钟不再刷新历史；更多菜单含项目/审查；离开聊天保留草稿，回到主页不新建会话。非聊天页有对应左栏；定时任务空状态按用户截图重做。
- `CodexPages.swift`：定时任务新建/编辑/搜索/暂停/恢复/删除/立即运行/停止/执行记录/查看会话；一次、每日、每周计划；显示项目、时间及本机执行边界。项目创建、重命名、删除、Finder 定位、选择项目开始聊天。审查支持未提交变更、相对分支、指定提交，显示流式结果、停止、打开审查会话。
- `CodexAutomation.swift`：独立 JSON 持久化，位于 ClipSlots 数据根目录 `automations/tasks.json`，不触碰官方自动化数据库。认领执行先原子落盘；串行执行；休眠/退出后的多次到期合并一次；按任务时区计算每日/每周及 DST；一次任务先禁用；异常退出标记中断、不自动重放；删除保留执行记录，最多保存最近 200 条，单条输出最多 100,000 字符。
- `CodexTaskModel.swift`：应用启动即加载调度，15 秒检查一次，页面关闭仍可执行；使用 Codex 的 read-only sandbox，不注入 ClipSlots 写入桥。定时任务和审查使用独立会话，不挤占正在编辑的聊天。创建任务/点击执行会使用用户的 Codex 配置和模型额度。
- `CodexWorkspace.swift` / `CodexWorkspaceModel.swift`：通过 `project/create`、`project/update`、`project/delete` 管理官方项目，并重新读取确认。兼容旧引擎时明确显示不支持。
- `CodexAgentService.swift`：代码审查使用官方 `review/start`，不是把提示词伪装成审查；支持 `exitedReviewMode` 的结果展示，沿用中断和超时控制。
- `CodexToolsView.swift`：Skills/MCP 现在可在主区域打开，保留原有真实配置操作；使用 Skill 后回到聊天输入框。

### 明确没有实现的官方能力

- **不是完整原版 App 的 1:1 内嵌，也不能自动获得官方所有后续页面和功能。**
- ChatGPT Work：菜单有对应入口，但进入后明确显示官方没有提供 Work 内嵌接口及不可用原因；没有接入替代模型、没有复制桌面认证状态、没有将网页冒充 Work。
- 官方本地/云定时任务、团队任务、模板市场及云端通知：不共享。此版本实现的是 ClipSlots 本机调度，需要 App 运行；退出后不在后台执行，恢复后补一次。
- 代码审查不包含官方云端 PR/GitHub 审查服务；实现本机项目的官方引擎审查。
- Skills/MCP 不等于官方所有 Apps/连接器市场。

### 验收

- Debug 构建成功；`git diff --check` 通过。
- 原生回归 **102/102**，未锁屏：真实时钟导航、新建任务 sheet、项目/审查/Skills 页面、返回聊天及草稿/IME 保留，定时执行本地模拟端到端、结果和线程保存、暂停不运行、删除保留结果。
- 官方桌面协议 **82/82**：项目 CRUD 在临时独立 `CODEX_HOME` 真机执行并读回；review/start 及流式结果使用本地协议模拟；定时存储、重复触发、中断恢复、DST、磁盘写失败均覆盖。只读验证现有桌面会话/项目/Skills；没有付费推理。
- 截图及原生报告：`build/validation/agent-workspace/`；测试日志 `.dbg/codex-pages-{native,protocol,bundled-protocol,core}.log`。
- 内置引擎兼容回归 **79/79**，原有核心回归 **32715/32715**，均无失败。
- Release App / CLI 构建成功，打包签名及代码指纹核对通过。

### 备份安装及正式 App 验证

- 已安装并启动 `/Applications/ClipSlots.app`，build **217809**；记录 `.dbg/codex-pages-install.json`。
- 旧版备份：`build/backup/ClipSlots-217808-before-codex-pages-20261003-093619.app`。
- 数据备份：`build/local-codex-pages-20261003-093605/data-before-update`。
- 安装前后槽位索引、Agent 三份会话文件哈希一致；CLI 软链接、内置官方 Codex 运行程序哈希保留，未修改官方 ChatGPT.app。
- 正式安装 App（非测试窗口）完成原生 AX 点击：Agent → 时钟 → 定时任务；新建任务 → 保存按钮出现 → 取消；主页模式菜单 → ChatGPT Work 说明；更多 → 项目。最终留在定时任务页，没有创建真实任务或调用付费模型。
- 实际浅色截图：`/var/folders/j2/y9ng5chs6dqd665ryhl4p00m0000gn/T/codex-shot-2026-10-03_09-36-51-w26060.png`；同次捕获的 `...-w26071.png` 为“更多”提示浮层。
- 本轮未提交或推送 Git。
