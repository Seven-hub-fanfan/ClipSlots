# Agent 消息可读性（217811 待安装）

2026-10-03，用户反馈 217809 的正文和思考区域难读，要求参考 Codex 的设计。此轮修改位于 `ClipSlots-agent-perf`，仅涉及聊天呈现；不改 Codex 协议、会话记录、模型配置、画布和工具执行逻辑。

## 呈现调整

- 独立 Agent 页正文 12 → 15pt，行距 6pt，段落间距 12pt；内容列最大 760pt（含左右各 24pt 留白）。侧栏正文 13pt。
- 独立页去掉逐消息的 ClipSlots 署名，避免思考条目和正文各重复一遍名称。
- 思考默认折叠为 13pt 的单行按钮，移除字数和脑图标。展开使用 13pt Markdown、独立段落与左侧细线，取消大块灰底；展开时保留阅读位置。
- 流式阶段复用正文和思考组件，不再截取末尾 220 字作为微小的实时预览。
- Markdown 按段落、标题、有序/无序/任务列表、引用、分隔线、代码块呈现；列表续行对齐，围栏代码支持语言标记、横向滚动和复制。保留未闭合的流式围栏内容。未覆盖的 Markdown 语法继续按文本显示。
- 行内代码有等宽字体及底色；Skill 引用显示可读链接名称，原始消息与复制内容保持原样。
- 工具行字号增至 12pt。全部沿用动态深浅色，不引入第三方渲染依赖。
- “回到最新”仅在末尾不在可视区时显示，避免折叠思考后仍悬浮遮挡正文。

## 验证

- Debug / Release 构建通过，`git diff --check` 通过。
- 原生界面回归 **134/134**，桌面未锁定；覆盖原有 Agent 工作区、草稿、中文输入以及本轮 Markdown、深浅色、简洁/多彩、窄窗口、思考展开/折叠和阅读位置。
- 流式交互回归 **53/53**；DeepSeek/Tika 均为本地模拟流。完整回答、最终定位、上滚查看历史、生成时继续输入、停止保留尾片段、恢复记录通过；未调用付费模型。
- 截图和原生报告：`build/validation/agent-workspace/agent-readability-*.png`、`report.json`。
- 性能/交互报告：`build/validation/agent-perf-readability.json`。
- 日志：`.dbg/readability-{build,native,perf,release}.log`。

复现：

```sh
swift build -j 4 --product ClipSlots
CLIPSLOTS_AGENT_WORKSPACE_PROBE=1 python3 scripts/canvas_regression.py --skip-build
CLIPSLOTS_AGENT_PERF=1 CLIPSLOTS_AGENT_INTERACTION=1 CANVAS_DEBUG_RUN=readability python3 scripts/canvas_regression.py --skip-build
```

## 交付状态

- 签名包：`build/local-agent-readability-20261003-143758/ClipSlots.app`，2.17.8 / 217811。
- `codesign --verify --deep --strict` 通过；CLI、官方内置 Codex 运行程序与 217809 的哈希一致。
- 准备记录：`.dbg/agent-readability-prepared.json`；准备脚本 `.dbg/prepare-agent-readability.py`。
- 用户确认后已于 2026-10-03 一次性替换 `/Applications/ClipSlots.app`，当前为 217811。旧应用、数据、配置和 UserDefaults 备份在 `/Users/bytedance/ClipSlots Backups/20261003-144055-before-217811`。
- 安装后签名深度校验通过，应用正常启动；CLI 读取默认页/组 10 个槽位成功，CLI 与官方内置 Codex 的哈希仍与 217809 一致。
- 未提交或推送 Git；本轮开始前的已有修改均保留，相关源文件备份 `.dbg/readability-baseline-20261003-112525/`。
