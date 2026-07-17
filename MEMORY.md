# MEMORY.md

> ClipSlotsApp 项目记忆文件。用于跨会话记录当前版本、关键约定与迭代要点。

## 当前版本

- **当前版本：v2.9.27**
- 平台：macOS（Swift / SwiftUI，SPM 构建，macOS 13+）
- 单一版本号事实来源：`Info.plist` 的 `CFBundleShortVersionString`（`AppVersion.current` 动态读取，`AppVersion.fallback` 为编译期兜底）。CLI 版本号见 `Sources/ClipSlotsCLI/main.swift` 的 `CLI_VERSION`。

## 版本要点（近期）

### v2.9.27
- **修复 DMG 缺少 Applications 拖拽软链**：将 Applications 快捷方式固化进打包脚本 `scripts/package_dmg.sh`（`ensure_applications_symlink` 在 staging / 挂载卷 / 最终校验三处强制存在 `Applications -> /Applications`），确保每次发版打开 DMG 都能直接拖入 Applications 安装，不再随手动流程丢失。DMG 输出改为版本化命名 `ClipSlots_v<version>.dmg`。

### v2.9.26
- **路径统一**：CLI 固定安装到 `/usr/local/bin/clipslots`（软链到应用内 `clipslots-cli`）；清理历史遗留的手动旧二进制 `~/bin/clipslots`；`docs/clipslots-cli-skill-draft.md` 与 `skills/clipslots-manager/SKILL.md`（含 frontmatter/requires）中所有 `~/bin/clipslots` 替换为 `/usr/local/bin/clipslots`，并同步刷新已安装 App bundle 内 SKILL.md。
- **Gatekeeper 首次打开提示**：新增 `RELEASE_NOTES_v2.9.26.md` 中文提示；App 内版本号（`ContentView` 左上角 `v…`）悬停 `.help` 补充"右键→打开"引导。
- **安装后 PATH 检测**：`CLIInstallManager.install()` 成功后若 `/usr/local/bin` 不在 `PATH`，在成功提示后追加终端找不到命令的提醒（复用现有 `lastMessage` 机制）。
- **Skill 卸载软链安全防护**：`AgentSkillInstallManager` 安装/更新前增加软链接守卫（`lstat` 语义），仅当目标为软链接或不存在时才 `rm -rf`/`removeItem` 重建软链；真实目录/文件不删除并提示，防止误删用户数据。

### v2.9.25
- **辅助权限弹窗视觉重做**：由 `NSAlert` 换为自定义 SwiftUI 磁玻璃面板（`AccessibilityPermissionGuide.swift` 的 `AccessibilityGuideCard` + 自定义 `NSPanel` 模态）。顶部 52pt `lock.shield.fill` 主题色大图标、21pt 加粗标题、宽松行距副文本、数字圆圈（1/2）步骤列表；底部「打开设置」为蓝色填充主按钮、「本次已知晓」为文字次要按钮（不再两个并排实心按钮）；整体圆角 18pt、内边距充裕、`.ultraThinMaterial` 磨砂背景 + 描边/投影。
- **实时预览窗空状态删除**：`RadialPreviewPanel.swift` 的 `RadialLivePreviewContent` 空态分支（眼睛图标 +「悬停槽位查看预览」+ 灰色毛玻璃容器）改为 `EmptyView()`。无悬停时只显示顶部工具栏那一行，工具栏下方不再有内容区；悬停时正常展开预览，不影响圆盘菜单预览。
- **槽位卡片预览区扩充到约 4 行**：`SlotThumbnailView` 文本预览框 `minHeight 96→108 / idealHeight 132→116`，`lineLimit 28→4`，让长文本清晰稳定显示约 4 行；短文本（≤60 字符）仍 `.center` 居中。（注：`SlotCardView.contentPreview` 为未使用的死代码，实际渲染走 `SlotThumbnailView`。）

### v2.9.24
- **Toast/FloatingNotice 视觉重做**：图标改为按语义类型（success→checkmark.circle.fill 绿 / warning→exclamationmark.triangle.fill 黄 / error→xmark.circle.fill 红 / info→info.circle.fill 蓝）统一渲染，移除此前看似"三横线/汉堡"的 text.alignleft 图标；标题加粗、副标题层次更清晰；内边距 12–16pt、圆角 12pt、统一背景材质与描边/轻投影。
- **清除调试文本**：全仓检查确认用户可见字符串中不再出现调试占位「在代码里是圆盘」。
- **统一槽位卡片预览 lineLimit=28**：`SlotThumbnailView` 文本分支与 `SlotCardView` 内容预览统一为 28，避免部分卡片过早省略（标题/文件名保持单行）。
- **设置「槽位连接」Toggle 关闭时彻底隐藏连接入口**：主界面底部「连接」按钮（`connectionToolButton`）按 `enableSlotConnection`（`store.isSlotConnectionEnabled`）门控，关闭时完全隐藏（不占位）。

### v2.9.23
- **实时预览面板默认折叠 / 悬停展开**：圆盘菜单的浮动实时预览（`RadialPreviewPanel` + `RadialMenuWindowController`）默认只显示顶部工具栏（约 60pt），悬停圆盘槽位才展开完整内容区，离开重新折叠，带高度动画且保持顶边固定，不干扰任何主界面布局。
- **统一槽位卡片文本预览行数**：`SlotCardView` 文本预览 `lineLimit` 由 3 统一为 28，与 `SlotThumbnailView` 一致，避免部分卡片过早省略。
- **修复插件图标**：去掉 v2.9.22 的层次渲染灰色锯齿与右上角红点，改回干净的主题色（accentColor）填充拼图，与相邻工具栏图标样式一致。
- **新增窗口最小尺寸**：`main.swift` WindowGroup 最小尺寸由 460×360 增大到 720×560，防止标题栏/应用图标在缩到最小时被挤压变形。

### v2.9.22
- **UI 全面优化**（主界面 + 节点画布 + 圆盘预览 + 插件中心 + 权限弹窗）：
  - 槽位卡片高度过高：空槽图标缩小、说明并为一行；有内容卡片按钮区改 `.small` 控件、高度 66→52；卡片 `minHeight` 280→216，缩略图 minHeight 120→96，让 10 个槽位尽量不滚动看全。
  - 槽位文本预览 `lineLimit` 14→28，减少过早省略与空白。
  - 节点画布按钮精简合并：顶部只剩「串联 / 模板 / 清除 / 完成」4 个（串联=本组/本页/批量应用菜单；模板=导出/导入；清除=本组/本页/全部菜单），底部操作栏整行删除（`footer` 已移除）。
  - 圆盘预览面板不透明背景修复：头部 `windowBackgroundColor(0.96)` 与空态浅色底改为 `.ultraThinMaterial` 半透明毛玻璃，消除"大块不透明色块遮屏"。
  - 「连接」按钮升级：节点连线图标 + 强调色渐变胶囊 + 描边/投影，更有质感。
  - 版本号从右下角迁移到左上角「检查更新」按钮右侧。
  - 辅助权限弹窗：改用 `accessoryView` 富文本，精简文案、加大字号（13pt）与行距（lineSpacing 6）。
  - 插件中心补「社区 Skill」分类（即将开放，与「社区插件」并列）。
  - 插件图标改 `puzzlepiece.extension.fill` + 层次渲染 + 右上角红点通知。
  - 节点画布「导出连接模板」弹窗重做：头部图标+标题、卡片式范围选项（主要/次要层次）、圆角/间距统一、底部主次按钮分区。

### v2.9.21
- **修复节点画布端口消失 bug**（仅动 `NodeCanvasSheet.swift`，不改数据层）：
  - **四边 hover 命中区外扩**：端口圆点位于卡片上/下/左/右四边外侧，此前 hover 命中区仅为卡片本体，鼠标从卡片移向任一边端口时会离开 hover 区，端口从就绪态缩回/消失（"刚要点就找不到"）。给卡片加 `.padding(12)`（在 `.contentShape`/`.onHover` 之前），四向外扩 12px hover 命中区，完整覆盖四个方向的端口圆点。
  - **拖拽期间端口恒就绪**：进入拖拽连线模式（`activeDrag != nil`）后，`visibleSlots` 传入 `Set(1...10)`，所有节点端口保持就绪态，无论 hover 与否，直到连线完成或取消——避免拖拽途中目标端口缩回/消失。
- **节点画布界面精简 + 布局居中**（`NodeCanvasSheet.swift`）：
  - 移除标题栏下方说明小字「独立画布内编辑连接；主界面继续保持干净，只显示色点提醒。」。
  - 移除底部「当前链路：1→6 …」文字行——连线关系从画布本身即可看清，无需文字重复。
  - 节点网格在画布内水平 + 垂直居中（`position(for:)` 由画布/节点尺寸推导居中原点），不再紧贴左上角。

### v2.9.20
- **节点画布连接交互全面优化**（仅动节点画布相关文件，不改槽位数据层/其他功能；连线数据结构不变；深浅色自适应）：
  - **端口三级常显模型**（`NodePortOverlay`）：从"隐藏/显示二态"改为静默（8px、opacity 0.35 低调常驻）/ 就绪（所属节点 hover 放大到 12px + 高亮描边）/ 高亮（拖拽吸附目标 16px 填色 + 外发光）。从根源消除"看不清连接点在哪"的死循环。
  - **命中区与可见性彻底解耦**：端口恒 `allowsHitTesting(true)`，不再随状态翻转；命中区从 28×28 收窄到 18×18，减少对卡片中心 hover 的拦截，根治鼠标在卡片边缘时端口忽隐忽现的边界抖动。
  - **消灭重绘抖动**（`NodeCanvasSheet`）：`nodeFrames` 从计算属性改为 `@State` 缓存，仅在 `onAppear` 计算一次，不再每帧重建视图身份，端口/连线不再"跳一下"。
  - **"连得上"体验**（`NodeCanvasSheet` + `NodeConnectionCanvas`）：吸附半径 `nearestNodePortTarget` 从 32 扩大到 44px；拖拽吸附命中时预览线加粗为实线 + 方向箭头，未吸附时为细虚线。
  - **连线可读性**（`NodeConnectionCanvas`）：连线终点补方向箭头（output→input）；连线中点 hover 显示红色 × 删除入口（`EdgeConnectionDeleteHandle`），hover 时整条连线变红，点击断开（新增 store 方法 `disconnectEdge(id:)`）。

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
