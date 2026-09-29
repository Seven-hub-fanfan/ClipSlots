# V2.17.4 修订：Agent 与槽位交互参考

## 已交付基线

V2.17.4 build 217401 已安装在 `/Applications/ClipSlots.app`。
安装记录 `build/validation/installation.json`；本次是其后续修订，目标 build 217402。
不动 main、v2.17.1/v2.17.2/v2.17.3 工作树。

## 录屏观察

原始路径和假设见 `debug-agent-slot-interactions.md`。
抽帧在 `/tmp/clipslots-agent-reference/`，每段 14–18 帧及同名前缀 `-sheet.jpg`。
工具 `/tmp/clipslots-recording-frames.swift` 使用 AVFoundation；环境没有 ffmpeg。

- `20260924214806` (52.77s)：ClipSlots 问题演示。0–18s 在编辑页切主题；20–32s 浅色画布槽位卡和添加菜单有明显黑色光晕；44–50s 深色槽位卡内嵌白色空槽卡，点击/拖动不响应。
- `20260924214956` (14s)：TapNow 暗色画布和添加菜单。右侧 Agent 为平整面板。
- `20260924215034` (23.23s)：TapNow Agent。欢迎区两张建议卡，点击建议后欢迎区消失，草稿进入底部输入框，卡片下方小刷新按钮切换建议。

第三段原始分辨率 2872×1760（约 1436×880 点）；1440×882 抽帧接近原生点数。
关键参考：

- `20260924215034_rec_-004-5.2.jpg`：空会话、欢迎区。
- `20260924215034_rec_-016-20.7.jpg`：填入建议后的底部草稿。

## Agent 落地方向

- 侧栏约 480pt（现有仅320pt）；同步 `WindowLayoutMetrics.agentSidebarWidth` 预算和引用处。
- 顶部紧凑会话标题「新建对话」，左侧列表入口，右侧设置/新会话/收起等实际可用操作；不放无法工作的仿制按钮。
- 面板暗色约 #111，输入表面约 #1a1a；浅色走动态统一 token。不要大阴影。
- 空会话欢迎区垂直居中，次级问候和约26pt「今天一起创作点什么？」。
- 两列建议卡，各约217×140pt；细边、轻微错位/旋转，图标/类别/标题/两行说明/右箭头，整张卡可点。
- 建议使用 ClipSlots 实际能力：优化生图提示词、视频分镜、整理槽位、检查画布等；点卡只填草稿，不自动提交或付费生成；可换一组。
- 底部一体输入框，约120pt起、文字多时增高；左侧加号/Skill，右侧模型/配置入口、圆形发送/停止，⌘Return发送。保留现有模型和工具能力。
- 回答排版移除左右成对气泡的厚重底色，保留流式输出、折叠思考、复制、工具状态和错误重试。
- 流式时避免强制把正在翻阅历史的用户每个 token 拉到底部。

## 槽位/主题

- 明暗分段、两张主题卡、顶层外观按钮内部 label 必须有明确完整 `contentShape`。测试 padding/corner 命中，不能只点文字中心。
- `CanvasNodeCardView` 的强黑影需移除，浅色用边界/表面分层。
- `CanvasSlotFanStack.cardView` 当前固定 white fill + white 2.6pt border + black shadows，空内容不应画成嵌套白色缩略卡；正常附件堆叠保留。
- 当前 native pointer 在 `.slot` 上直接返回false，依赖父层 SwiftUI drag/tap；fan区域自己的 highPriority DragGesture 移动后只return，不能拖父节点。修复需要同时覆盖：卡片空白、缩略预览、正文编辑、底部入参按钮、多选拖动、撤销、扇形翻页/展开。不要只让其中一块区域能拖。
- `CanvasAddNodeMenu` 当前 black 0.42、radius22、y12；改为无黑色光晕的薄边/轻影，并检查其他画布浮层。

## 当前验证入口

`CLIPSLOTS_TEST_SKIN=minimal CLIPSLOTS_TEST_APPEARANCE=light CLIPSLOTS_SLOT_AGENT_PROBE=1 CANVAS_DEBUG_RUN=pre-fix python3 scripts/canvas_regression.py`

新增 `CanvasSlotAgentRegression.swift`，HTTP日志7783，结果 `build/validation/slot-agent-*.json`。
前两轮槽位body点击、拖动和外观popover均失败，但window.isKeyWindow=false，需先解决原生测试焦点再确定产品原因。
## 已落地（build 217402）

- Agent：480pt、会话菜单/新建/配置/收起、两列旋转建议卡和换一组、一体输入框。建议只填草稿。回答为连续排版，保留思考、复制、工具状态、重试。用户上翻时停止自动跟随，提供回到最新。
- Agent 草稿跟随会话存活，皮肤切换或收起不会丢失；原生编辑器去掉常驻滚动槽，保留中文输入与 ⌘Return。新会话隔离旧流回调，停止生成保存部分回答。
- 主题按钮：顶层、明暗分段、两张皮肤卡都把完整 label 设为点击区域。
- 槽位：外壳、空预览、正文预览走统一原生路由；正文点击编辑、拖动移动。有内容的扇形预览传递屏幕拖动给同一移动/撤销实现，输入/编辑/翻页保留独立事件。
- 视觉：空槽位直接显示图标和说明；移除整卡、添加菜单、生成面板黑影；文字卡和边框跟随外观。

验证记录见 `debug-agent-slot-interactions.md`。锁屏期间使用直接路由与离屏截图，不能替代解锁后的真实点击回归。
