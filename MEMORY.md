# MEMORY.md

> ClipSlotsApp 项目记忆文件。用于跨会话记录当前版本、关键约定与迭代要点。

## 当前版本

- **当前版本：v2.9.17**
- 平台：macOS（Swift / SwiftUI，SPM 构建，macOS 13+）
- 单一版本号事实来源：`Info.plist` 的 `CFBundleShortVersionString`（`AppVersion.current` 动态读取，`AppVersion.fallback` 为编译期兜底）。CLI 版本号见 `Sources/ClipSlotsCLI/main.swift` 的 `CLI_VERSION`。

## 版本要点（近期）

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
