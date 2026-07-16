# MEMORY.md

> ClipSlotsApp 项目记忆文件。用于跨会话记录当前版本、关键约定与迭代要点。

## 当前版本

- **当前版本：v2.9.19**
- 平台：macOS（Swift / SwiftUI，SPM 构建，macOS 13+）
- 单一版本号事实来源：`Info.plist` 的 `CFBundleShortVersionString`（`AppVersion.current` 动态读取，`AppVersion.fallback` 为编译期兜底）。CLI 版本号见 `Sources/ClipSlotsCLI/main.swift` 的 `CLI_VERSION`。

## 版本要点（近期）

### v2.9.19
- **修复节点画布 hover 交互两个问题**（仅动 hover 相关代码，不改数据层/其他视图）：
  - **Bug1：1-9 号节点 hover 无反应，只有 10 号响应**。根因：`NodeCanvasSheet` 中 `.onHover` 被链在 `.position` 之后，而 `.position` 会让视图占满整块画布，导致 10 个节点的 hover 区域全变成"整张画布"，ZStack 中最后渲染的 10 号在最上层吞掉全部 hover。修复：把 `.onHover` 移到 `.frame` 之后、`.position` 之前，并加 `.contentShape(Rectangle())`，使每个节点 hover 区域严格等于自身卡片、互不干扰。
  - **Bug2：鼠标移走后蓝框/端口不消失、响应迟钝**。根因同上（10 号全画布跟踪区永不触发 onHover(false)）+ `NodePortOverlay` 中 40 个不可见端口恒 `allowsHitTesting(true)`、命中区压在卡片边缘拦截 hover。修复：onHover(false) 立即清空本节点 hover（无动画拖尾）；端口命中区改为 `allowsHitTesting(isVisible)`，隐藏端口让位给卡片 hover（建连目标靠几何判定、拖拽跟随源端口，故建连不受影响）。
  - 顺带修复 `SlotNodeView` 接收 `isHovered` 却未使用的问题：hover 时叠加 `accentColor` 描边（深浅色自适应），补齐每个节点的蓝框视觉反馈。

### v2.9.18
- **UI 全面优化，共修复 28 项视觉/交互问题**（按 UI 代码审查报告 🔴5 / 🟡15 / 🟢8）。两条主线：解除卡片硬高度 + 补齐 AppTheme token。
- **解除 SlotCardView 270px 硬高度**：`SlotCardView` 卡片改 `minHeight: 280` 自适应；`SlotThumbnailView`/视频预览/空槽占位改 `minHeight/idealHeight/maxHeight:.infinity`，预览区随卡片撑高填满灰框、减少留白；文本预览 `lineLimit` 放宽到 14、短文本垂直居中。
- **默认窗口尺寸 540×420 → 1320×820**：`main.swift` `.defaultSize`，开箱一屏 5 列 × 2 行完整显示 10 个槽位无需滚动。
- **卡片精修**：header 顶部加呼吸间距（数字气泡不再贴边）；附件元数据行 `HStack` 改 `.lastTextBaseline` 基线对齐；时间戳去胶囊背景改纯灰文字；有内容时隐藏冗余类型文字；"覆盖"按钮 `.orange`→`AppTheme.warning`。
- **AppTheme 补 token**：新增 `Fonts`（title/headline/subheadline/body/caption/footnote，最小可读 12pt）、间距（spacingTight/Small/Medium/Large、sheetPadding）、弹窗宽度（sheetWidthSmall/Medium/Large）、`onAccentText`、`notice*` 颜色；全项目裸写的 9pt/11pt 极小字、`.white`/`.red`/`.orange`、硬编码圆角/间距向 token 收敛。
- **FloatingNotice 颜色收敛**：不再自实现一套 RGB，改用 `AppTheme.notice*` 与语义色。
- **节点画布**：端口按需显示（有连接/hover 才实心，减少 40 个圆点噪音）；底部按钮精简标签、去冗余小字。
- **其他**：搜索栏对齐、各弹窗操作栏（圆角/间距/危险色）统一、空状态引导优化、预览图放大、版本号对比度微调等。

### v2.9.17
- **附件区支持拖拽/点击上传（批量）**：附件弹窗空状态改为 dropzone（虚线边框 + 上传图标），点击唤起多选文件选择器，支持直接拖入文件；已有附件时在底部工具栏上方保留紧凑拖拽热区。复用底部按钮的加文件逻辑，自动区分图片/文件类型。
- **设置页 + 插件弹窗联动，插件弹窗改为市场风格**：设置页左侧导航新增「插件市场」入口（高级/命令行工具之后），点击打开独立插件弹窗（不内嵌进设置窗口）；插件弹窗改版为 Obsidian 市场风格（顶部搜索框 + 排序 + 「仅显示已安装」开关，分类 Tab：官方 Skill / 官方插件 / 社区插件[即将开放]，卡片网格 + 安装状态徽章，点击卡片进入详情页含完整描述与「安装到 Agent」操作）。市场数据由 `PluginCatalog` 数据驱动，便于后续扩展官方 Skill。
- **去掉主题切换涟漪光效动画**：删除 `WaterRippleThemeTransition` / `WaterRippleRing`，深浅色切换直接生效、无过渡特效。

## 关键文件

- `Sources/ClipSlots/AttachmentManagerPopover.swift`：附件弹窗（含 v2.9.17 dropzone）。
- `Sources/ClipSlots/PluginsView.swift`：插件市场弹窗（v2.9.17 市场风格）。
- `Sources/ClipSlots/PluginMarketModels.swift`：插件市场数据模型与目录（v2.9.17 新增）。
- `Sources/ClipSlots/AgentSkillInstallManager.swift`：Skill 一键安装到 Agent（v2.9.17 新增聚合状态）。
- `Sources/ClipSlots/SettingsView.swift`：设置页（v2.9.17 新增「插件市场」入口）。
- `Sources/ClipSlots/ContentView.swift`：主窗口（v2.9.17 移除主题涟漪动画）。

## 发布流水线

见 `CLAUDE.md`：build / sign / install / launch / commit / push / tag / DMG / GitHub Release。`gh` CLI 路径 `/Users/bytedance/bin/gh`，账号 `Seven-hub-fanfan`。发布前需把 CLI（`clipslots-cli`）与 skill 目录一并 bundle 进 App。
