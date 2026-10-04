# Agent 输入与技能引用修复

本地隔离候选构建：21781102，基于 217811。适用于画布侧栏和独立 Agent 输入框。

## 本次变化

- Enter / 小键盘 Enter 发送，Shift+Enter 换行，保留 ⌘Enter。输入法正在组词时交给原生输入法处理，不发送；长按重复事件、空白输入和运行中的重复发送均被拦截。
- 输入 `/` 显示可执行的快捷操作：`/skills`、`/model`、`/new`；独立 Codex 页面另有 `/mcp`、`/attach`。方向键选择，Enter/Tab 确认，Esc 关闭；选中菜单项不会顺带发送消息。
- 两个页面均有可见“技能”入口，也可输入 `$` 搜索，支持 `/技能名称` 筛选。中文、emoji、光标前后的文字在替换时保留。
- 技能选择变成每条消息的引用标签，可移除，随会话草稿保存。后台读取完整 SKILL.md 后冻结快照；发送、重试和重启恢复都使用该快照。最多 4 个，每个 64 KB，超限或无法读取会明确报错。
- DeepSeek、Tika、Codex 均接收规范快照。Codex 的“Skills 与 MCP”页“使用”按钮复用同一引用路径。Codex 项目技能列表后台刷新，本地技能目录使用缓存，输入时不扫描目录。
- 引用技能规范不修改全局启用状态。原来的可执行技能管理仍可从技能按钮右键菜单或 Skills 与 MCP 页面进入。画布仅参考规范生成文字，继续使用预览、确认回填和撤销流程。
- 候选包补入内置 `clipslots-manager` 技能资源。

## 验证

基础库 **32,743/32,743**、Codex 本地协议 **128/128**、原生窗口回归 **247/247** 全部通过，`sessionLocked=false`。新原生测试覆盖真实 NSWindow 按键派发、可见技能按钮点击、菜单键盘操作、中文输入法、草稿恢复、切换会话时的异步加载隔离，以及实际请求中的技能快照。最终原生报告为 `build/validation/agent-workspace/report.json`。

中间一轮 246 项通过、窗口焦点一项失败；系统未锁屏。测试入口增加等待 AppKit 激活完成后再检查真实焦点，最终整轮通过。中间报告保留于 `.dbg/composer-intermediate-evidence/`，未覆写为通过。

DeepSeek 验证捕获真实构造的 HTTP 请求体；Codex 验证本地模拟 app-server 的 `turn/start` 参数；Tika 验证本地模拟 CLI 实际收到的参数。没有调用付费模型，未验证真实模型对规范的遵循效果。

截图：`canvas-agent-menu-canvas.png`、`canvas-agent-menu-agent.png`、`canvas-agent-composer-canvas.png`、`canvas-agent-composer-agent.png`，均在 `build/validation/agent-workspace/`。

## 使用

打开 `build/agent-loop-candidate/ClipSlots Agent Loop.app`。输入要求后按 Enter 发送，或先输入 `/` 选择操作、输入 `$` 引用技能。

这是独立候选，不替换 `/Applications/ClipSlots.app`。保留已有 `CandidateData`，数据与配置仍由原生启动器固定到候选同级目录。原开发树、主应用、真实素材不在本轮修改范围，没有提交或推送。

这是 ClipSlots 内部的输入功能补齐，并非官方 Codex 全量 UI 同步。技能引用传递完整 SKILL.md；未自动读取其中提到的关联文件，也不因此增加脚本执行权限。
