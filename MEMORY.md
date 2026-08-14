# MEMORY.md

> ClipSlotsApp 项目记忆文件。用于跨会话记录当前版本、关键约定与迭代要点。

## 当前版本

- **当前版本：v2.10.85**
- 平台：macOS（Swift / SwiftUI，SPM 构建，macOS 13+）
- 单一版本号事实来源：`Info.plist` 的 `CFBundleShortVersionString`（`AppVersion.current` 动态读取，`AppVersion.fallback` 为编译期兜底）。CLI 版本号见 `Sources/ClipSlotsCLI/main.swift` 的 `CLI_VERSION`。

## 版本要点（近期）

### v2.10.85 — 悬停预览显示文件图标而非真实图片内容（★当前正式发布版）
- 现象：环形菜单悬停预览窗显示的是 macOS 的 PNG 文档图标，而不是图片像素。
- ★根因（与 v2.10.84 PERF-4 无关）：从 Finder **复制文件**时，剪贴板内容是 `public.file-url` + `com.apple.icns`，后者是 1024px 的**通用文档图标**（本机实测 `default/1/item_0/com.apple.icns.bin` 1.1MB、10 个 rep、最大 1024×1024）。`com.apple.icns` 属于合法图片类型 → `SlotContent.hasImage` 为真 → 所有预览路径优先走「内联图片」分支，把 Finder 图标当内容渲染，真实文件像素没人读。新旧两条解码路径（`decodedInlineImage` / `decodedInlineThumbnail`）都会画出这张图标，所以这是长期存在的行为，不是下采样引入的。
- 修复：
  - Kit 新增 `iconOnlyPasteboardTypes` / `isIconOnlyPasteboardType`（icns 系列）；icns **仍留在** `imagePasteboardTypes`，保证真正粘贴 `.icns` 数据时渲染行为不变。
  - `SlotContent` 新增 `prefersFileContentOverInlineIcon`（内联图片全是图标类型 且 存在 file-url）与 `hasRenderableInlineImage`。
  - 环形悬停预览、网格缩略图、全局搜索预览改用 `hasRenderableInlineImage`：图片文件走磁盘 `ClipSlotsImageIO` 下采样（2048 / 512）显示真实像素；非图片文件（PDF/压缩包等）保留原 Finder 图标渲染（其图标常自带内容缩览），不降级。
- 性能不回退：PERF-4 下采样策略完整保留，只是把「解码哪份数据」从图标换成真实文件，仍不做原图尺寸解码。
- 冷知识：`file:///.file/id=...` 形式的 URL 也能正确解析出 `pathExtension`（实测 png）与真实路径，故 `isImageFile` 判定成立。
- 验证：`swift build` 通过；smoke **通过 33、失败 0**（新增 5 项图标类型判定断言）；DMG 打包校验通过、装机 CLI 版本 2.10.85。
- DMG SHA256：`3bb008fda57caeaf5d928f382c9978b98020bf3363c9975ee06145def307d1fc`（`build/ClipSlots_v2.10.85.dmg`）。

### v2.10.84 — 专项流畅度优化
- 背景：用户反馈「大量直观影响流畅度的卡顿细节」。四维度（SwiftUI 重绘 / 主线程 I/O / 缩略图管线 / 交互动画）全仓扫描后，只落地有真实代码证据且不改功能语义的 7 项。
- **PERF-1（收益最大）切组不再清空缩略图缓存**：`selectSpecialSlotForPreview` / `selectAndActivateSpecialSlot` 的 `loadSlotsAsync(onCommit: invalidateSpecialSlot(oldId))` 与 `activateSpecialSlotForHotkeys` 里的同类调用全部移除。★该清空的原始理由「防旧组 late 异步回调写错 UI」自 v2.10.73 keyed 缓存起已不成立（旧 key 结果只能写回旧 key）；其真实代价是 A→B 丢掉 A 全部已解码图，切回 A 必须整组重解码——**这是切组卡顿主因**。现缓存跨组常驻（仍受 LRU 200 约束），A→B→A 秒回。
- **PERF-2 缩略图通知合并**：`ThumbnailProvider` 单例每张图「开始加载 + 解码完成」各发一次 `objectWillChange`，且回调分散在不同 runloop tick（SwiftUI 只合并同 tick），一屏 10 图 ≈ 20 次全网格重绘。改为 16ms（一帧）窗口合并成 1 次；且缓存写入不再 hop 主线程（本就由 NSLock 保护）。
- **PERF-3 环形菜单 hover 不再全量读盘**：`firstNonEmptySlotSnapshot` 原逐槽 `get().isEmpty`（全 payload + 跨进程 flock），正是仓库自身注释警告的反模式。改为先用 `specialStorage.isEmpty` 廉价探针筛空槽，只对命中槽读全量；探针 UNKNOWN 态保守报非空，故仍以 `get()` 结果终判，语义不变。
- **PERF-4 环形预览内联图下采样**：`RadialInlineImagePreview` 仍用 `decodedInlineImage()` 全尺寸解码（8K 图上百 MB），而预览窗仅 360×480。对齐同文件磁盘图片路径 v2.10.35 已有策略：`decodedInlineThumbnail(maxPixel: 2048) ?? decodedInlineImage()`。★注意 detached 闭包需显式标注 `() -> NSImage?`，否则 `??` 会被推断成 `NSObject?` 编译报错。
- **PERF-7 切组免去无谓索引写盘**：`resetAutoPasteCursor` 在两个游标本就为 nil 时短路跳过 `saveIndex`（整份 index.json 编码 + 原子写）。判断刻意放在 `storageLock` 临界区内，无 TOCTOU。
- **PERF-6 全局搜索去重复排序**：主线程仅在「搜索期间用户真切了页/组」时才按新上下文重排，否则直接复用后台已排好的结果（此前每次搜索都在主线程对全结果集重跑一遍比较器，含较贵的 `localizedStandardCompare`）。
- **PERF-5 动画节奏收紧**：`Anim.transition` response `0.35 → 0.28`；`AttachmentManagerPanel.switchFadeDuration` `0.12 → 0.08`（串行淡出+淡入总等待 240ms → 160ms）。纯观感参数。
- ★**不变量守护（历史最敏感）**：「图片槽位切组立即刷新、绝不串图」由键身份保证——缓存键 `specialSlotId::slot::contentId::updatedAt`，且 CLI 实测确认**任何覆盖写都会同时改变 contentId 与 updatedAt** → 键必变 → 必然 miss 重解码。内容真变的失效点（clearAllSlots、导入覆盖、单槽写入）全部保留，仅移除「因切组」的清空。
- ★**主动放弃的 5 项误报**（避免为改而改）：卡片 `metadataSummary`（早有 NSCache）、环形 hover 判等（早已存在）、启动 `cleanupTrash` 后台化（仅 200 项浅扫描，且会破坏短命 CLI 进程的清理）、`refreshTrigger` 全量摘除（SwiftUI 同 tick 已合并，风险高收益低）、附件列表改 `LazyVStack`（会干扰拖拽重排的 coordinateSpace 几何计算）。
- 验证：`swift build` 通过；smoke **通过 28、失败 0**（新增 5 项断言守护 PERF-7 短路的幂等性 + 索引完整性）；DMG 打包校验通过、装机运行无崩溃、CLI 版本 2.10.84、`clipslots list` 数据完好（`repaired: false`）。
- DMG SHA256：`7aac11d23fe81fa6481283805627c1681d9d08b7932ee5b959a11aab4e918191`（`build/ClipSlots_v2.10.84.dmg`）。

### v2.10.83 — 自动模式一次性开关联动
- **默认值与兼容性**：自动切换对从未保存过该偏好的新用户默认关闭；已有用户的 `UserDefaults` 历史值优先读取并完整保留，升级不会强制覆盖。
- **一次性双向联动**：自动存储或自动粘贴任一发生关→开时，若自动切换为关则同步打开一次；任一发生开→关时，若自动切换为开则同步关闭一次。
- **非持续绑定**：联动完成后允许用户手动修改自动切换，不会被后台轮询、状态重算或视图重建持续纠正；只有自动存储或自动粘贴下一次真实状态变化才再次联动。
- **初始化安全**：初始化、从 `UserDefaults` 加载、`onAppear` 及重建 `LeverClusterView` 均不触发联动。
- **实现位置**：逻辑集中在 `AutoModeState` 的 setter / `setLinkedMode(_:to:)`；先判定真实 transition，且自动切换目标值一致时不重复发布 `@Published`、不重复写盘，也不存在自动切换反向联动自动存储/自动粘贴。
- 功能 commit：`f779e89`；`swift build` 通过，smoke 通过 23、失败 0。
- DMG SHA256：`3176b758158e851e93cc7b550fa26a2b6636b4d0b8f8aba995eb9cf047e25b8a`（`build/ClipSlots_v2.10.83.dmg`）。

### v2.10.82 — 纯附件槽位 `(空)` 占位居中
- 背景：正文为空但有附件（0B 文本 + 附件N）的槽位，`SlotThumbnailView` 文本回退分支把 `(空)` 占位按 `.leading` 左上对齐，观感不居中。
- 根因链：`SlotContent.preview` 空回退返回字符串 `"(空)"`（`ClipboardManager.swift`）；纯附件槽位 `SlotContent.isEmpty`（`items.isEmpty && attachments.isEmpty`）为 false，故不走完全空槽位的 `EmptySlotThumbnailView`，而是落到 `SlotThumbnailView.fallbackView` 的文本分支。
- **改动**：`SlotThumbnailView.swift` 新增私有 `isEmptyBodyPlaceholder`（`multilinePreview == "(空)"`）；文本分支的 `.multilineTextAlignment` 与 `.frame(maxWidth:alignment:)` 在该占位时切为 `.center`，否则保持 `.leading`。仅影响正文空但有附件的 `(空)`，不影响有正文文本、图片/视频缩略图、完全空槽位。
- 验证：`swift build` 通过（仅 WebKit `javaScriptEnabled` 既有 deprecation 警告，无害）；23 项 smoke 全绿（通过 23，失败 0）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION → 2.10.82
- commit：`a2273be`，已推到默认分支 `main`。
- DMG SHA256：`47137d95f54ce135a3bf3f9a74b27fed04d31b5fc26f803d70e4a37a7771ae3b`（`build/ClipSlots_v2.10.82.dmg`）。
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.82（本批 v2.10.75→82 唯一发到 GitHub Release 的版本，自动更新只读 latest，中间版本仅本地打包直装未发 Release）。
- **本机已装**：`/Applications/ClipSlots.app` 与 PATH `clipslots`（→ `.app/Contents/MacOS/clipslots-cli`）均为 2.10.82。

### v2.10.81 — 切主题顶部氛围层卡旧色根治（去静态栅格 + 身份失效）
- 背景：切换深浅色后顶部工具栏区域背景仍停留旧主题颜色（v2.10.76 引入的回归）。
- ★关键经验：v2.10.80 只把 ImageRenderer 栅格缓存 key 并入主题维度**无效**——真因是 ImageRenderer 离屏栅格快照 + `drawingGroup()` / `.regularMaterial` 的 Metal / NSVisualEffectView 纹理会卡在旧 appearance；视图 identity 不变时不随主题刷新，只有 resize 才被动纠正。缓存 key 层面改动治不了纹理层。
- **改动（方案A：去静态化 + 强制身份失效）**：`ContentView.swift` 的 `RetroPosterAmbientBackground` 彻底移除 ImageRenderer 静态栅格缓存（删 `@State raster`/`rasterKey`、`GeometryReader`+`cacheKey`/`quantize`/`rebuildRasterIfNeeded`）；非 resize 常态改为实时 `fullBackground(scheme: effectiveScheme).id(effectiveScheme)`（drawingGroup 保留），resize 期间仍走 `AppTheme.windowBackground(effectiveScheme)` simplified 纯色降级。`headerView` 的 `.background(.regularMaterial)` 改为 `.background(Rectangle().fill(.regularMaterial).id(colorScheme))`，只重建材质层不重建 header 子树。
- 验证：`swift build` 通过；23 项 smoke 全绿。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION → 2.10.81
- commit：`46c8bc4`，已推到 `main`。
- DMG SHA256：`50eb0ccac5d0b7359d8cbae55b2135e169c81faf8175c30e28d57b82381990c7`（本地打包直装，未发 Release）。

### v2.10.80 — 切主题背景卡旧色首次尝试（★缓存 key 并入主题维度，实测无效）
- **改动**：`RetroPosterAmbientBackground` 新增 `@AppStorage("appearanceMode")` 与 `effectiveScheme`，让栅格缓存 key 与栅格配色一致、用捕获配色重建。
- ★结果：用户实测未解决——问题在 Metal/material 纹理层而非缓存 key，故 v2.10.81 改走「去静态化 + 身份失效」根治。
- commit：`b9610d5`，已推到 `main`。
- DMG SHA256：`250036832f34f567b38f986f447aac96aa87f738b1361b34b8c55b72c2e34c5c`（本地打包直装，未发 Release）。

### v2.10.79 — 自动存储/自动粘贴金属摇杆拨动卡顿修复（观察下沉 + 后台化）
- 背景：拨动自动存储/自动粘贴摇杆时卡顿——`ContentView` 巨型视图对高频 `autoMode` 的响应式读取导致整树重求值；`recomputeAutoPreviews()` 在主线程做跨页/跨组磁盘探测。
- **改动A（观察下沉）**：`ContentView` 的 `autoMode` 从 `@ObservedObject` 改为非观察 `private let autoMode = AutoModeState.shared`，只透传给局部观察子视图。新增 `LeverClusterView.swift`：`LeverClusterView(store:autoMode:)` 局部 `@ObservedObject` 承接摇杆/游标控制及 3 个 `.onChange`；`AutoAdvanceToggleView(autoMode:)` 局部观察承接自动切换开关。commit：`bc77b90`。
- **改动B（后台化 + 令牌防错序）**：`main.swift` 新增单调代次令牌 `autoPreviewGeneration`；`recomputeAutoPreviews()` 改为主线程快照状态（pages/specialSlots/config.slots/currentSpecialSlotId/两个游标/pastedChainMembersByGroup）→ 后台执行 `findNextEmptySlot`/`findNextNonEmptySlot` → 回主线程 `guard token == autoPreviewGeneration` 后写 preview，防旧异步结果覆盖新结果。commit：`afb1cf3`。
- 未采用改动C（ToggleLeverView 内部 `@State internalIsOn`）：A+B 已解决重负载，C 有 Binding 状态分叉风险。
- 验证：`swift build` 通过；23 项 smoke 全绿。version bump commit：`fa1acf7`（→ 2.10.79）。均已推到 `main`。
- DMG SHA256：`ecf2dcaacbf9cc622464785a3b165fd072b04842354e9682d6411bed86b9e1a7`（本地打包直装，未发 Release）。

### v2.10.78 — 搜索框整体右移紧挨图标簇
- **改动**：顶部搜索框整体右移，紧贴右侧图标簇布局。
- commit：`656d373`（本地打包直装，未发 Release）。

### v2.10.77 — 切组 tab 交互反馈 + 搜索框收窄
- **改动**：切组 tab 增加交互反馈；顶部搜索框收窄。
- commit：`6a9ec52`（本地打包直装，未发 Release）。

### v2.10.76 — 性能三阶段（★引入背景离屏栅格缓存，后成为切主题卡旧色隐患）
- **Phase1（架构治本）**：交互状态下沉 `TransientUIStore` + `SlotCardView` 实现 `Equatable` + 确认 watcher 已异步。commit：`02f0dda`。
- **Phase2（渲染/体感）**：★海报背景 `RetroPosterAmbientBackground` 引入 ImageRenderer 栅格化静态缓存 + `timeAgo` 分钟粒度缓存。commit：`a3f9e17`。★该静态栅格缓存是后续 v2.10.80/81 切主题顶部卡旧色的根源，v2.10.81 已去除。
- **Phase3（动画体系统一）**：新增 `Anim` 三档 token（interactive/status/transition），全仓散装曲线就近替换，`ToggleLeverView` 加轻量按压反馈。commit：`709d53e`。
- version bump commit：`03d1128`（→ 2.10.76，本地打包直装，未发 Release）。

### v2.10.75 — 拖拽 resize 彻底冻结布局
- **改动**：拖拽 resize 期间锁定量化宽度 + 冻结容器 frame + 关饱和度滤镜，消除每帧重排。
- commit：`c5651b5`（本地打包直装，未发 Release）。

### v2.10.74 — 切组/切页「延迟遮罩（Debounced Veil）」，缓存命中零闪动
- 背景：切组/切页时立即置 `isSwitchingGroup` 会导致即便数据在缓存里瞬时可得也闪一下过渡遮罩（淡化/微模糊），观感不流畅。
- **改动**：`beginGroupSwitchTransition` 不再立即置 `isSwitchingGroup`，改用 `groupSwitchVeilToken` + `asyncAfter(0.08)` 延迟置位。数据 80ms 内就绪（缓存命中）则 token 推进作废延迟闭包 → 遮罩根本不出现，瞬时无闪动切换；仅当真异步等待 > 80ms 才显示过渡遮罩。
- **统一复位入口**：新增 `endGroupSwitchTransition()`，`loadSlotsAsync` / `reloadAllAsync` / 1.2s 兜底三条路径统一走它复位。
- commit：`71f938d`，已推到默认分支 `main`。
- DMG SHA256：`cdd33a7a66285b2a34df4b0f1982671c39af91227bd6d407461299158a8092cd`（`build/ClipSlots_v2.10.74.dmg`）。
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.74（本批唯一发到 GitHub Release 的版本，自动更新读 latest，v2.10.69~73 仅本地打包未发 Release）。

### v2.10.73 — 缩略图渲染解耦最优解（keyed 共享可观察缓存）
- **改动**：`ThumbnailProvider` 升级为 keyed 共享可观察缓存；`SlotThumbnailView` 去掉 per-view `@StateObject`，改为 `currentKey` 纯函数渲染；卡片身份回到 `.id(slot)`（切换复用不重建）。缩略图正确性由 shared provider 保证，而非依赖 cell 重建。
- commit：`56687d7`。
- ★关键经验（v2.10.71→72→73 教训）：**不能靠「移除父级 .id 但保留 per-view @StateObject」赌刷新**（v2.10.71 那样做造成切组卡旧图的缩略图回归）；正确方向是缩略图 = `currentKey` → shared provider 的纯函数渲染，卡片身份保持 `.id(slot)` 稳定复用。

### v2.10.72 — 回滚 v2.10.71 卡片身份改动，修复缩略图回归
- **改动**：回滚 v2.10.71 的卡片身份改动（恢复 `cellIdentity`），修复切组卡旧图的缩略图回归；保留「去掉切换期全网格模糊」的优化。
- commit：`aac74ac`。

### v2.10.71 — 切页/切组卡顿尝试（★造成缩略图回归，后被回滚）
- **改动**：卡片身份 `cellIdentity` 改回 `.id(slot)` + 去掉切换期全网格 `.blur(2)`。
- ★但造成缩略图回归（切组卡旧图），故 v2.10.72 回滚卡片身份改动。
- commit：`e01bef0`。

### v2.10.70 — live-resize 期间背景/卡片降级
- **改动**：live-resize 期间整窗高斯模糊背景降级为纯色（`RetroPosterAmbientBackground` simplified）+ 卡片去软阴影；新增 `LiveResizeMonitor` 监听 `NSWindow` 的 willStart/didEnd LiveResize。
- commit：`aa3cb3d`。

### v2.10.69 — 拖拽缩放窗口流畅度
- **改动**：网格改固定列宽 `makeGridColumns` + 宽度量化（≥8pt 才重算列），消除弹性列逐像素重排。
- commit：`62258b8`。

### v2.10.68 — 界面体验优化 + 滚动/缩放性能改善
- 背景：集中打磨主界面 UI、导航与交互，并针对网格滚动、窗口实时缩放的流畅度做优化。
- 主要改动：
  - 优化页面与槽位组导航：支持展开/收起、多选及批量操作。
  - 优化设置界面、顶部搜索区（`SlotSearchBar`）与插件市场图标（`PluginsView`）。
  - 修复槽位卡片 hover 重复描边与文字预览对齐。
  - 缓存文本预览解码与 HTML 清洗结果，改善网格滚动性能。
  - 稳定 `LazyVGrid` 列配置，改善窗口实时缩放流畅度；收敛动画事务与视频预览启动时机。
- 改动文件：`ContentView.swift`(±590)、`SlotSearchBar.swift`、`SettingsView.swift`、`PluginsView.swift`、`SlotCardView.swift`、`SlotThumbnailView.swift`、`VideoPreviewView.swift`、`ToggleLeverView.swift`、`main.swift`、`ClipboardManager.swift`(+34)、`Info.plist`、`AppVersion.swift`、`CLI_VERSION`（共 13 文件，+761/-438）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.67 → 2.10.68
- commit：`ca5499b`，已推到默认分支 `main`。
- **已发布**：GitHub Release https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.68（asset `ClipSlots_v2.10.68.dmg`，state=uploaded，原生 `digest=sha256:b2afbd1413aad3c94d1d1331844a1fde44a5283ae0c864eba343c28af5d8ebb4`，与本地打包 DMG 实算哈希、正文 SHA-256 三者一致）；`releases/latest` 已返回 tag=v2.10.68。
- **本机已装**：`/Applications/ClipSlots.app` = 2.10.68。DMG：`build/ClipSlots_v2.10.68.dmg`，SHA256=`b2afbd1413aad3c94d1d1331844a1fde44a5283ae0c864eba343c28af5d8ebb4`。
- 遗留：拖动放大窗口时仍有缩放卡顿/不流畅，v2.10.69 继续优化。

### v2.10.67 — 自动更新 SHA-256 完整性校验（方案 A：优先 GitHub asset digest，回退 release body）
- 背景：此前自动更新链路只做「落盘字节数 == asset size」的弱校验（v2.10.9），无法防篡改/中间人替换。GitHub 已原生给该仓库 release 资产返回 `"digest": "sha256:<64位hex>"`，无需改发布流程即可拿到期望哈希，故本版落地加密级完整性校验（方案 A：SHA-256）。
- **改动（enforce-when-present + warn-when-absent，预留 requireChecksum 强制模式）**：
  1. **UpdateChecker.swift（期望哈希解析 + 透传）**：`extractDMGURL(from:body:)` 新增 `body` 入参并把返回值从元组升级为 `struct DMGAsset { url; size; sha256? }`。新增 `extractExpectedSHA256(asset:body:)`：来源优先级 ① asset 的 `digest` 字段（去 `sha256:` 前缀取 64 位 hex，兼容个别无前缀情形）；② 回退 `extractSHA256FromBody`——仅在含 "sha256" 关键字（大小写不敏感）的**行内**、用带非-hex 边界的正则 `(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])` 取独立 64 位 hex（避免误匹配 40 位 commit hash / 128 位 sha512）。`sha256` 一路透传 `presentUpdateAvailable` → `startDownload`。
  2. **UpdateDownloader.swift（下载后比对 + 策略）**：`import CryptoKit`；`startDownload` 增参 `expectedSHA256: String?` 并绑定到本次 `URLSessionDownloadTask`（关联对象 `sha256Key`，与既有 version/expectedSize 绑定一致，回调只认自己 task）。`handleFinished` 在原 size 校验（第一道）之后、交 UpdateInstaller 之前：期望哈希非空 → 用私有静态 `sha256HexOfFile(atPath:)`（FileHandle 1MB/块**流式**计算，避免整包载入）算出小写 hex，与期望值**大小写不敏感**比对，不一致视为致命错误（删文件、走现有 `handleFailure` 中文错误提示、中止安装，NSLog 记期望/实际）；期望哈希为空 → 默认继续安装但 NSLog 告警（兼容无哈希的老 release）。
  3. **requireChecksum 常量（默认 `false`）**：为未来「强制模式」预留——为 `true` 且拿不到期望哈希时直接拒绝更新；默认 `false` 即上面的宽松策略。size 校验保留为第一道，哈希为更强的第二道。
- 改动文件：`Sources/ClipSlots/UpdateChecker.swift`、`Sources/ClipSlots/UpdateDownloader.swift`、`Sources/ClipSlots/AppVersion.swift`、`Sources/ClipSlotsCLI/main.swift`、`Info.plist`、`MEMORY.md`。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.66 → 2.10.67
- commit：`a412af7`（feat+bump 合并），已推到默认分支 `main`（a8c6244 → a412af7，fast-forward，与 Release 对齐）
- 验证：`swift build` 通过（无新增警告）；23 项 smoke 测试全绿（`swift run ClipSlotsKitSmokeTests`：通过 23，失败 0）。
- **已发布**：GitHub Release https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.67（asset `ClipSlots_v2.10.67.dmg`，state=uploaded，GitHub 原生 `digest=sha256:7e1c24e5185dac444ca74b65218815ab3e78d12ebd8ba434c63f532a0257ae99`，即本版校验首选来源）；`repos/.../releases/latest` 已返回 tag=v2.10.67。
- **本机已装**：`/Applications/ClipSlots.app` 与 `/usr/local/bin/clipslots` 均为 2.10.67（旧 2.10.66 已替换，App 已重启）。DMG：`build/ClipSlots_v2.10.67.dmg`，SHA256=`7e1c24e5185dac444ca74b65218815ab3e78d12ebd8ba434c63f532a0257ae99`。
- 备注：强制模式（requireChecksum=true）待线上所有 release 均带 digest / 正文哈希后再开启。

### v2.10.66 — 全量 bug 扫描修复批次（数据不变量 / 滚动回归 / 拖拽竞态 + 3 项 Low）
- 背景：对 v2.10.65 最新代码做了一次全量 bug 扫描，本版落地其中「改动小、无争议、可直接验证」的一批；自动更新加密级完整性校验（方案 A：SHA-256）改动涉及发布流程，另起一版做。
- **关键修复**：
  1. **数据不变量**：`clearAllSlots` 补齐与 `set/clear/setLabel` 一致的 STG-2 护栏——组已从 index 删除时拒绝清空，杜绝 GUI/CLI 并发删组后清空/覆盖导入把已删组目录"复活"成孤儿目录。（`SpecialSlotStorage.swift`）
  2. **回归修复（v2.10.65 引入）**：底部「上次粘贴」跳转不再滚动定位——抽出唯一 `cellIdentity(for:)`，`.id()` 与 `scrollProxy.scrollTo()` 共用同一身份。（`ContentView.swift`）
  3. **并发崩溃**：`handleFileDrop` 多文件拖入对共享数组无锁 append 改为专用串行队列收集，消除偶发丢文件/崩溃的数据竞争。（`SlotCardView.swift`）
- **Low**：CLI 版本号与 App 对齐（此前滞后到 2.10.58）；批量写 stop-on-error 后 `not_executed` 结果补 `group` 字段；导入进度条成功后补发满值推到 100%（`ClipSlotsCLI/main.swift`、`PackImporter.swift`）。
- 验证：`swift build` 通过；23 项 smoke 测试全绿（`swift run ClipSlotsKitSmokeTests`）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.58 → 2.10.66
- commit：`4d4dc90`（fix+bump 合并）
- DMG SHA256：`17cc983311e131ccd23bdd5a7ebb843a9c2dca4354c1fbc7d39836a360dcfcb8`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.66
- 备注：v2.10.59–v2.10.65 为本地打包直装、未上传 GitHub，也未在本文件逐条登记；本版是继 v2.10.58 后下一个正式发到 GitHub Release 的版本。

### v2.10.58 — .clipslotspack 改名后再导入被误判为普通文件（双重加固）
- 背景：导入时靠文件扩展名 `.clipslotspack` 判断走「包导入」还是「普通文件写入槽位」。用户把导出的包改名（扩展名变了），导入就走错路径，把整个 ZIP 当普通文件塞进槽位。
- **修法（两个都做，一起加固）**：
  1. **导入按内容识别，不再只看扩展名**：`startToolbarImport()` 先按扩展名快速命中；未命中时，若为「单个非目录文件」，用新增的 `PackImporter.isValidPack(at:)` 尝试解析内部 `manifest.json`，成功即走包导入。探测只解出 manifest.json，成本极低；失败安全回退普通文件导入。新增私有 `isDirectory(_:)` 排除文件夹选择。
  2. **导出锁定扩展名**：`presentPackSavePanelAndExport` 里 NSSavePanel 取到 URL 后经新增静态方法 `enforcePackExtension(_:)` 收敛为恰好一个 `.clipslotspack`（去重复后缀、大小写不敏感、缺失则补齐），从源头保证导出包后缀正确。
- 改动文件：`Sources/ClipSlots/PackImporter.swift`（新增 `isValidPack`）、`Sources/ClipSlots/main.swift`（`startToolbarImport` 内容探测 + `isDirectory` + `enforcePackExtension` + 导出用 `finalURL`）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.57 → 2.10.58
- commit：`8226fa9`（fix+bump 合并）
- DMG SHA256：`e242688f3db9e8b973edaa0a0291cb15b4f5144571ada94a30ea8edc992cf732`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.58

### v2.10.57 — 打包压缩阶段进度条改不确定态
- 背景：v2.10.55/56 之后，用户反馈打包进度条在槽位写完后立刻跳到 100%，但 zip 压缩还要耗时很久，浮层一直卡在「正在压缩… 100%」不动，直到压缩完成弹成功框才消失，观感像卡死。
- **根因**：`PackExporter` 进入压缩阶段时发的是确定态 `(totalSlots, totalSlots)` = 100%（`PackExporter.swift` L380），而 zip 压缩无法逐字节上报进度、且往往比逐槽位写入更耗时。
- **修法**：压缩阶段改发 `onProgress?(0, 0, "正在压缩…")`，`total = 0` 触发 `ImportProgress.isIndeterminate`，UI（`ContentView.importProgressOverlay`）本就对不确定态渲染来回滚动的线性进度条并隐藏 x/y 与百分比，如实表达「压缩中、耗时未知」。压缩完成（成功/失败/异常）照常 `publishImportProgress(nil)` 收起，与 v2.10.56 的会话代次守卫完全兼容（该不确定态是 zip 前的最后一次非 nil 上报，nil 收起后不会被 stale 更新顶回）。
- 改动文件：`Sources/ClipSlots/PackExporter.swift`（仅压缩阶段那一行进度上报）。UI 与 main.swift 均未改，`ImportProgress` 模型也未动（复用现有 `isIndeterminate`）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.56 → 2.10.57
- commit：`9c6a736`（fix+bump 合并）
- DMG SHA256：`baa7d215970ff595ecb12da954b444fb473bcb041d1087c96a9157021df9546a`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.57

### v2.10.56 — 打包导出进度浮层卡死修复（P0）
- 背景：v2.10.55 给打包导出接进度条后，用户反馈打包完成后进度浮层卡在「正在压缩… 628/628 100%」不消失。
- **根因**：`PackExporter` 在 zip 前发出的最后一次「正在压缩… total/total」100% 进度上报（`PackExporter.swift` L380），与主线程收起浮层的 `publishImportProgress(nil)` 之间存在时序竞态。`publishImportProgress` 后台调用走 `DispatchQueue.main.async`、主线程调用走同步分支，混用下某些时序里这条 stale 100% 非 nil 上报晚于 nil 落到主线程，把刚收起的浮层又顶回去，且此后再无上报来收起它。
- **修法**：给进度浮层引入单调递增的「会话代次」(generation) 令牌，把「收起」变成一道不可逆闸门——
  - 发布 nil（收起）：置空 `importProgress` 并 `importProgressGeneration &+= 1`；
  - 发布非 nil（显示/更新）：在**入队瞬间**（可能在后台线程）快照当前代次并随 block 带到主线程，`applyImportProgressIfCurrent` apply 时若代次已被某次收起推进过则直接丢弃该 stale 更新，绝不把浮层重新顶起来。
  - 关键：非 nil 代次快照必须在入队时抓取，不能在主线程 apply 时抓取（否则 nil 先落地推进代次后，晚到的非 nil 会读到新代次误判为「当前会话」放行）。
  - 导入 / 导出 / 文件夹导入三条路径共用同一 `publishImportProgress`，一并加固。
- 改动文件：`Sources/ClipSlots/main.swift`（`publishImportProgress` 重写 + `importProgressGeneration` + `applyImportProgressIfCurrent`）。UI 与 PackExporter 逻辑未改。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.55 → 2.10.56
- commit：`b4da52f`（fix+bump 合并）
- DMG SHA256：`da9ab672447dd45404015a311f34fc485dc28df6ff6e66e330d9be3a47109e12`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.56

### v2.10.55 — 打包导出加进度条（复用导入同款 UI）
- 背景：打包导出（.clipslotspack）此前无进度显示，大包导出时静默等待、体验差。本次照导入进度条同款样式给导出路径接上进度回调。
- **PackExporter.export 新增 `onProgress(done,total,name)` 回调**：与 `PackImporter.importPack` 同签名，后台线程调用。新增 `countExportableSlots(for:)` 在导出前统计「非空槽位」总数作为分母（判定口径与 export 写入一致：`disk.isEmpty && !hasLabel` 才跳过；仅走磁盘元数据不加载附件字节，绝不 OOM）；写完每个槽位 `doneSlots += 1` 上报一次；写完 manifest 进入压缩阶段上报满格 + detail「正在压缩…」。
- **UI 完全复用**：`presentPackSavePanelAndExport`（main.swift）进入构建阶段先 `publishImportProgress(ImportProgress(title:"正在导出槽位包",detail:"准备打包…"))` 显示不确定态浮层，随后 export 回调经 `publishImportProgress` 切主线程逐槽驱动同一套 `ImportProgress` 模型 + `store.importProgress` + `ContentView.importProgressOverlay`（底部悬浮磨砂玻璃卡片，非模态）。成功/失败/异常三分支均 `publishImportProgress(nil)` 收起浮层。**未改任何 UI 样式**。
- 改动文件：`Sources/ClipSlots/PackExporter.swift`（+countExportableSlots、export 加 onProgress 参数与上报点）、`Sources/ClipSlots/main.swift`（presentPackSavePanelAndExport 接进度）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.54 → 2.10.55
- commit：`34df043`（feat+bump 合并）
- DMG SHA256：`086cb3d08dd179573aa9adb8a26da546d10b14d97bd0caa3f29e877b36f56f4d`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.55

### v2.10.54 — 第七轮扫描 P1×1 + UX 回退 + P2×2
- 背景：修复第七轮扫描报告 https://bytedance.larkoffice.com/docx/J9dzdGacVoDVBhxF1qEcEFr2n2c 标注的问题，并回退 v2.10.48 的编辑 Popover。
- **P1 clearSlotBody 漏刷 contentId/updatedAt**：内容区叉号单独清空槽位主体时只更新 `timestamp`，漏刷身份字段，破坏 v2.10.52 增量 diff（slotsSnapshotEqual 以 contentId+updatedAt 判等）不变量，致跨进程/多实例网格/预览停留旧态、搜索计数陈旧。现补刷 contentId/updatedAt，与 v2.10.53 P1-2 的 updateHTMLSlot/setAttachments 一致（main.swift clearSlotBody）。
- **UX 回退 编辑文本/HTML Popover → Sheet**：v2.10.48 把标签/文本编辑从 Sheet 改 inline Popover 是负优化（点气泡外部无保存 dismiss，编辑内容被静默丢弃）。改回 Sheet（文本 520×320 / HTML 620×360），保留 v2.10.48 新增的 ⌘↩ 保存快捷键；纯展示层改动，@State/编辑缓冲/保存回调不变（SlotCardView textEditorSheet/htmlEditorSheet + 两处按钮 .popover → .sheet）。
- **P2-1 乐观内存更新写盘失败不回滚**：单槽保存（handleCapturedContentForSave）与 setAttachments 的 P0 乐观内存更新写盘失败时未回滚，致内存（新内容）与磁盘（旧内容）长期不一致。现写盘失败时回滚内存到旧快照，带 `contentId` 守卫（仅当内存快照仍是本次写入的值、未被后续写入覆盖时才回滚）+ 失败 toast。
- **P2-2 sweepStaleImportTempDirs 并发误恢复**：启动清扫可能把另一进程进行中导入的 .import_backup_ 备份误恢复回去（其原组目录在 rename 后、writeSlots 前短暂为空），毁掉那场导入。现加 mtime 阈值：仅清扫 mtime 超过 1 小时的陈旧备份，进行中导入的新备份被跳过（PackImporter.swift）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.53 → 2.10.54
- commit：`74c4ebf`（fix+bump 合并）
- DMG SHA256：`d41cd56feaf874efacebd47a3d4476802215e1fdbc202dfd7e271aae37c85444`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.54

### v2.10.53 — 性能优化专项 Bug 扫描修复（1 P0 + 2 P1 + 3 P2）
- 背景：修复扫描报告 https://bytedance.larkoffice.com/docx/XeKndcG2HowLSGxj150cAMCRnZg（覆盖 v2.10.48→v2.10.52 四批性能改动）标注的问题。
- **P0 跨槽并发编辑静默覆盖**：`handleCapturedContentForSave` 派发写盘前补一次同步乐观内存更新（`if loadedSpecialSlotId == activeId { slots[targetSlot] = contentToWrite }`），对齐 v2.10.36 给 `setAttachments` 的补丁。此前内存刷新推迟到后台写盘回调后，窗口内编辑另一槽位触发 `persistCurrentSpecialSlotData` 抓全量旧快照回写，FIFO 让旧值最后落盘覆盖新内容（跨进程锁竞争窗口最长 ~5s）。
- **P1-1 共享 JSONEncoder/Decoder 跨队列 data race**：`SlotStorage` 移除共享 `encoder`/`decoder` 属性，7 个编解码点（meta/附件外置/迁移/manifest 编码 + 3 处解码）改用局部实例，消除 `manifestQueue` 与主 `queue` 并发编码致 `attachments.json`/manifest 错乱。
- **P1-2 增量 diff 判等字段跨进程不更新**：`updateHTMLSlot` / `setAttachments` 复用旧 `SlotContent` 改内容后刷新 `contentId`/`updatedAt`，恢复 v2.10.52 `slotsSnapshotEqual`（以 contentId+updatedAt 判等）不变量，修跨进程/多实例 UI 陈旧、搜索计数不更新。
- **P2-1** `getLabelOnQueue` 去强解包（`labelCacheFingerprint[slot]!`/`labelCache[slot]!` → `if let` 逐个绑定），与公共 `getLabel` 的 v2.10.49 加固对齐，永不 EXC_BREAKPOINT。
- **P2-2** `PackImporter.unzip` 在 `waitUntilExit` 前用后台线程 `readDataToEndOfFile` 抽干 stderr（run() 抛错路径主动关写端制造 EOF 防死锁），防坏包大量输出撑爆 ~64KB 管道缓冲致进程挂起。
- **P2-3** 新增 `sweepStaleImportTempDirs()`，`importPack` 开头（建新备份前）清扫孤儿临时目录：`.rollback_discard_*` 直接删；`.import_backup_<groupId>_<uuid>` 按实况组目录非空→删冗余、缺失/空→rename 回原位恢复数据（绝不删唯一副本）。
- version bump：Info.plist ×2 + AppVersion.swift + CLI_VERSION 2.10.52 → 2.10.53
- commit：`e03d180`(fix) + `59d7f48`(bump)
- DMG SHA256：`25c326f425e10df04db0153551dcd5ae3378ebc923aee9a6dc50bbb71719f0fb`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.53

### v2.10.52 — 性能优化第四批（SwiftUI 渲染重构：瞬态 UI 拆分 + slots 增量 diff）
- 背景：接续 v2.10.49（第一批·低风险清扫）、v2.10.50（第二批·P0 异步化）、v2.10.51（第三批·索引竞态）。本批做研判报告 https://bytedance.larkoffice.com/docx/EyyVdYi8CoBqVjxmQk1ctPaEnUg 标注的 UI 层性能项。约束：不改 UI 样式/布局、不引入拖拽排序、不改游标胶囊位置；自动切换默认开启、自动存储/自动粘贴默认关闭、已有用户设置不覆盖。
- **巨型 @Published Store 拆分**（新增 `TransientUIStore.swift`）：`toastMessage` / `floatingNotice` 从主 `SlotStoreObservable` 剥离到独立 `TransientUIStore`（`let transientUI` 只读引用持有，生命周期随主 store）。原本这两个瞬态状态是 store 的 `@Published`，每次 `showToast`/`showFloatingNotice`（切组/保存/复制几乎都触发）都令 `store.objectWillChange` 发射、波及整棵 `ContentView.body` 与全部槽位卡片重绘。现 Toast/浮层由独立子视图 `TransientOverlayView`（`@ObservedObject var ui`）单独观察渲染，`ContentView.body` 不再读 `toastMessage/floatingNotice`（`store.transientUI` 普通引用读取不建依赖），二者弹出/消失只重绘该覆盖层子视图。toast 进出场动画随状态迁入子视图；`toastView`/`toastIcon`/`floatingNoticeView` 从 ContentView 移除。
- **slots 字典全量替换改增量 diff**（`main.swift` 新增 `applySlotsSnapshot` + `slotsSnapshotEqual`）：此前所有 reload/切组路径无条件 `slots = snapshot.slots`，即便磁盘与内存完全一致（FS watcher 自写回声、无关变更整树 reload、A→A 重复切组）也触发 @Published 全量替换 → didSet 重算签名 + objectWillChange 全树重绘。现按槽位 id（contentId+updatedAt）逐槽对比，快照等价则跳过赋值不重绘；确有变化仍一次性整体赋值（didSet 只重算一次签名）。SlotContent 未实现 Equatable（含 Data 附件），故用 contentId/updatedAt 作稳定判据；即便偶发 id 不稳定也只退化为原「全量赋值」行为，无正确性风险。改造 3 处提交点：`reloadAllAsync`、`loadSlots`（同步）、`loadSlotsAsync`（切组）。
- **组内搜索 matchedSlotCount**：已于 v2.10.49 移出 body 缓存化（`matchedSlotCountCache` + onChange 重算），本批确认无残留 O(N) 渲染路径开销，未再改动。
- 无功能/CLI 契约/UI 样式变更；`swift build -c release --target ClipSlots` 通过（仅历史 warning，本批 0 新增 warning）。
- version bump 2.10.51 → 2.10.52（Info.plist ×2 + AppVersion.swift）；CLI_VERSION 2.10.51 → 2.10.52（同步）
- commit：`c33375b`（fix+bump 合并单提交）
- DMG SHA256：`126c2e658db1ecb5a14a134606d3d892d53b24d1df001dc26ad66c389fee484c`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.52

### v2.10.51 — 性能优化第三批（saveIndex 收编串行队列 + 存储层竞态加固）
- 背景：接续 v2.10.49（第一批·低风险清扫）、v2.10.50（第二批·P0 异步化）。本批做研判报告 https://bytedance.larkoffice.com/docx/EyyVdYi8CoBqVjxmQk1ctPaEnUg 标注的存储层索引竞态项（🔴 高危区），SwiftUI 渲染重构留待第四批。性能扫描报告 https://bytedance.larkoffice.com/docx/YWWFdwcRMoGyKqxfaRhcBkz9n6d 。
- **saveIndex 收进串行队列**（`SpecialSlotStorage.swift`）：原 `loadIndex()` 走 `com.clipslots.specialstorage` 串行 `queue`，而 `saveIndex()`（含 schema 重读 + 原子写盘）在**队列外**裸执行，构成「load 走 queue、save 不走 queue」的队列不一致 data race。现 `saveIndex()` = `queue.sync { saveIndexOnQueue(index) }`，读/写全程串行，**schema 重读一并纳入队列**，写前读到的现有索引不再是并发写中间态。
- **无锁内部版 `saveIndexOnQueue()` / `loadIndexOnQueue()`**：针对 v2.10.40 式重入死锁前科，抽出无锁内部版；任何「已持有 queue」的路径（未来 repair 逻辑等）必须调 OnQueue 版，杜绝二次 `queue.sync`。核查确认当前仅 `loadIndex` 一处 `queue.sync`、无 saveIndex 嵌套，收编本身无死锁。
- **forceRepair 索引读写收编队列 + 消除共享 decoder/encoder 并发**：修复前腐坏判定的读盘+解码、备份恢复的解码+写回均在队列外裸执行，与 `loadIndexOnQueue`/`saveIndexOnQueue` **并发共享同一 `decoder`/`encoder`** 是真实 data race。现全部经 `queue.sync` + 无锁内部版串行执行；恢复写入走 `saveIndexOnQueue()`（restored schema≥2，不触发降级护栏，等价原子写回）。收编后**所有 `index.json` 磁盘读写与 JSON 编解码统一收敛到 `queue`**。`forceRepair` 仅持 `storageLock`（队列外），队列内代码从不反向取 `storageLock`，无锁序环、无死锁。
- 无功能/CLI 契约/UI 变更；`swift build`（Kit + App + CLI）全量通过（仅历史 warning）。
- version bump 2.10.50 → 2.10.51（Info.plist ×2 + AppVersion.swift）；CLI_VERSION 2.10.50 → 2.10.51（同步）
- commit：`d399a9a`（fix+bump 合并单提交）
- DMG SHA256：`8ec1acb6626a68e37fbb7f458cb397d3e2c39b0058e7b627808a8a5bf9baff15`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.51

### v2.10.50 — 性能优化第二批（P0 异步化 + Pack 流式化）
- 背景：接续 v2.10.49（第一批低风险清扫），本批做两处 P0 + 一处 P1，均严守历史加固的安全/时序红线。性能扫描报告 https://bytedance.larkoffice.com/docx/YWWFdwcRMoGyKqxfaRhcBkz9n6d ，风险研判报告 https://bytedance.larkoffice.com/docx/EyyVdYi8CoBqVjxmQk1ctPaEnUg 。saveIndex 串行队列收编与 SwiftUI 渲染重构留待第三、四批单独灰度。
- **P0-1 切组/切页/启动读盘全面异步化**（`main.swift`）：`createSpecialSlot` / `deleteSpecialSlot` / `createPage` / `deletePage` / `createSpecialSlotAndImportFolder` / `init` 启动首帧原走同步 `reloadAll`（主线程逐槽抢跨进程 flock，锁竞争下最长卡死 ~N×5s），统一改走 `reloadAllAsync` / `loadSlotsAsync`；每处切换前 `beginGroupSwitchTransition()` 开 `GroupSwitchVeil` 过渡遮罩（保留旧内容淡化、禁点击、1.2s 兜底关闭）+ generation/activeId 双重陈旧守卫，切组不闪空、旧读晚回不盖新组。`createSpecialSlotAndImportFolder` 的文件夹导入放进 `reloadAllAsync` 完成回调保序。同步版 `reloadAll` 仅保留内部兜底，不再由任何 UI 路径直接调用。
- **P0-2 Pack 导入附件字节全量流式化**（`PackImporter.swift`）：此前仅 >20MB 走 `copyItem` 流式落盘、<20MB 仍 `Data(contentsOf:)` 整块读入内联；统一为无论大小都用内核级 `copyItem` 流式落盘为路径引用（`data` 恒 nil），彻底消除附件字节 Data 中转。删除 `inlineAttachmentThreshold` 阈值常量。三重安全校验（Zip Slip 名字、leaf 软链、中间目录软链越界）全部保留（只换搬运方式）；落盘路径登记 `importedAttachmentPaths`，失败回滚一并清理，绝不残留孤儿。覆盖导入 rename 回滚 + `invalidateContentCaches` 保持不变。Exporter 经核查早已全面 `copyItem` 流式，无需改动。
- **P1 保存前 get 改内存快照**（`main.swift` `handleCapturedContentForSave`）：保存前的 `specialStorage.get()` 同步读盘（锁竞争最长阻塞 ~5s）改为 `contentForSlotOrUnknown`（命中当前组内存即用、无 flock），UNKNOWN 时 ABORT 并提示"存储繁忙"，绝不用空占位覆盖丢已有附件。⚠️ 特意**不**移后台（避免重踩 v2.10.36 lost-update 坑），仅换读源，写盘仍走 slotWriteQueue 串行异步、时序不变。参照 saveHTMLToSlot/updateTextSlot（v2.10.45）现成模式。
- version bump 2.10.49 → 2.10.50（Info.plist ×2 + AppVersion.swift）；CLI_VERSION 2.10.49 → 2.10.50（同步）
- commit：`6edd214`（fix+bump 合并单提交）
- DMG SHA256：`9925635fbde9c0088e6d52205660b7a1c6cb288fff87c62d4c9f4160c4c094a4`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.50

### v2.10.49 — 性能优化第一批（低风险清扫）
- 背景：按四批节奏推进性能优化，本批做第一批低风险、纯增益项；保留所有现有功能与约束不变。性能扫描报告 https://bytedance.larkoffice.com/docx/YWWFdwcRMoGyKqxfaRhcBkz9n6d ，风险研判报告 https://bytedance.larkoffice.com/docx/EyyVdYi8CoBqVjxmQk1ctPaEnUg 。高风险 4 项（保存前同步 get 移后台、saveIndex 串行队列、Pack 流式化、SwiftUI 渲染重构）本批不做。
- **① labelCacheFingerprint 去强解包**（`SlotStorage.swift` getLabel 快/慢路径）：`labelCacheFingerprint[slot]!` / `labelCache[slot]!` 强解包改为 guard/if let（`labelCacheFingerprint:[Int:DirFingerprint?]`、`labelCache:[Int:String?]` 均为可选值字典），缓存与指纹不同步时安全回退慢路径重读，消除潜在崩溃。
- **② 径向悬停预览解码限流**（`RadialPreviewPanel.swift` RadialInlineImagePreview）：内联图解码从裸 `Task.detached` 接入已有全局 `ThumbnailDecodeLimiter`（2–6 并发上限，v2.10.38 引入），与网格/内联缩略图共用配额削峰，不改解码结果。
- **③ 缓存内存压力回收**（`AppDelegate.swift`）：新增 `memoryPressureSource: DispatchSourceMemoryPressure`，`applicationDidFinishLaunching` 调 `setupMemoryPressureMonitor()`，监听 `.warning/.critical`（主队列回调）时清空可重建缓存 `ThumbnailProvider.shared.clearCache()` + `SlotContent.purgeAllInlineImageCaches()`（内联图/缩略图/元数据三缓存）；`applicationWillTerminate` cancel。仅回收内存不触碰磁盘。
- **④ 组内搜索 matchedSlotCount 防抖缓存**（`ContentView.swift`）：新增 `@State matchedSlotCountCache`，`matchedSlotCount` 计算属性改为读缓存；`computeMatchedSlotCount()` 实际遍历、`recomputeMatchedSlotCount()` 写回（非搜索态归零、值变才写）；在 searchText/selectedFilter/searchScope/slotsContentSignature 的 onChange 及 onAppear 触发，避免每次 body 遍历重算。
- 已核查无需再动：inlineImageCache totalCostLimit 已是 512MB（C-3 v2.10.31）；ClipboardManager capture/restore 已用 `if !Thread.isMainThread` 守卫，`main.sync` 不会同线程死锁。
- version bump 2.10.48 → 2.10.49（Info.plist ×2 + AppVersion.swift）；CLI_VERSION 2.10.45 → 2.10.49（同步）
- commit：`33963f4`（fix+bump 合并单提交）
- DMG SHA256：`5db31f0a51739a241d7f5e35ac05f804b5b55608719bf6abf65a59ad32fd2eaa`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.49
- ⚠️ 注意：workspace 沙盒内 `/workspace/.../ClipSlots/` 是一份**过时旧快照**，真实仓库/构建目标在挂载点 `/Users/bytedance/Cursor/ClipSlotsApp`（沙盒 `/mnt/propagation/.../`），务必只改挂载点。

### v2.10.48 — UX 丝滑度改进第二批（搜索 + 就地编辑 3 项）
- 背景：接续 v2.10.46 第一批，做研判报告（https://bytedance.larkoffice.com/docx/XuDEd3WYwoExwqxcoq5cGSjfn7c）第二批中与搜索/编辑相关的 3 项。
- **① 搜索预览滚动闪烁修复**（`GlobalSearchResultsView.swift`）：全局搜索结果行 `onHover` 原本立刻 `selectedResultId = result.id`，滚动/扫视时鼠标连续掠过多行触发右侧预览疯狂重解码闪烁。新增 `hoverDebounce: DispatchWorkItem?`，进入后延迟 ~80ms 才切换选中项，期间离开或掠到别行即 `cancel()`，只有真正停留才更新预览；`onTapGesture` 取消防抖立即选中并跳转（点击是明确意图）。
- **② 标签/文本编辑 Sheet 改 inline Popover**（`SlotCardView.swift`）：标签编辑本就是内联 TextField（未动）；纯文本 / HTML 就地编辑原用 `.sheet`（520×320 / 620×360 巨大遮罩），改为锚定在「编辑」/「编辑HTML」按钮上的 `.popover(arrowEdge: .top)` 气泡（360×220 / 420×260），保持在网格上下文；新增 `textEditorPopover`/`htmlEditorPopover` 两个 `@ViewBuilder`，保存按钮加 `⌘↩` 快捷键。预览大图 `.sheet` 保留不动。
- **③ 搜索结果过渡动画**（`GlobalSearchResultsView.swift`）：新增 `resultsSignature = results.map(\.id)` 作动画驱动键，body 加 `.animation(.easeInOut(duration:0.22), value: resultsSignature)`，空/非空分支与结果行加 `.transition(.opacity)`；换搜索词/切排序时列表与预览面板淡入淡出过渡，消除硬切跳变。
- version bump 2.10.47 → 2.10.48（Info.plist + AppVersion.swift）；CLI_VERSION 保持 2.10.45（GUI-only 未 bump）
- commit：`2c7b29b`（feat+bump 合并单提交）
- DMG SHA256：`06ed209e664f589cef747b55a8baf590b1169262ab4d3d703449de23d8a1656e`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.48
- 约束遵守：不改 UI 样式、不引入拖拽排序、不改游标胶囊位置；附件面板跟随主窗口、切 Finder 拖文件不关闭；自动切换默认开启、自动存储/自动粘贴默认关闭、已有用户设置不覆盖

### v2.10.47 — 回退删页/清空 inline 确认卡（负优化）+ 修复切组内容闪空槽位
- **回退**：v2.10.46 把删页/清空确认改成的底部 inline 确认卡属负优化，本版回退为系统 NSAlert（`confirmDeletePage` 走 `runAlertNonBlocking`；清空组走 `beginSheetModal`，保留「不再提醒」）。彻底删除 `InlineConfirmation` 模型 / `pendingConfirmation` / `requestConfirmation` / `InlineConfirmationBar`。**其余三项 v2.10.46 改进保留**（附件面板 0.12s 淡入淡出、导入进度非模态悬浮条、悬停预览 0.18s）。
- **修复切组主体内容闪空槽位中间态**：根因——v2.10.42 附件外置后切组读盘异步化，而 `selectSpecialSlotForPreview` / `selectAndActivateSpecialSlot` 会先 `slots=[:]` 清空，导致新数据回填前所有槽位闪成「空槽位」占位（顶部已用数/附件角标一直正确，仅主体预览区闪白）。
  - 方案（最优解）：切组时**不清空** slots/labels，保留旧内容 + 叠 `GroupSwitchVeil` 轻微淡化(0.35)/微模糊(2)/高光扫过遮罩表示切换中；新数据在 `loadSlotsAsync(onCommit:)` 后台就绪后整体淡入(0.16s)替换并关闭遮罩。旧组缩略图缓存 `invalidateSpecialSlot` 推迟到 onCommit（切走旧内容后）执行，避免旧内容在遮罩下掉图。
  - 健壮性：新增 `isSwitchingGroup` @Published + `beginGroupSwitchTransition()`（1.2s 兜底关闭防卡死）；`reloadAllAsync` 提交时若 `isSwitchingGroup` 仍开也一并关闭（watcher reload 抢先提交场景）；切组期间 grid `allowsHitTesting(false)` 防误操作。不预加载、不增内存。
  - 新增文件：`Sources/ClipSlots/GroupSwitchVeil.swift`
- version bump 2.10.46 → 2.10.47（Info.plist + AppVersion.swift）；CLI_VERSION 保持 2.10.45（GUI-only，与 v2.10.46 一致未 bump）
- commit：`69ba271`（fix+bump 合并单提交）
- DMG SHA256：`6d02d27b739c1e8519f2b3d0107edc7c8eee87e9bd545a1be87132ede77f8df7`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.47
- 约束遵守：不改 UI 样式、不引入拖拽排序、不改游标胶囊位置；附件面板跟随主窗口、切 Finder 拖文件不关闭；自动切换默认开启、自动存储/自动粘贴默认关闭、已有用户设置不覆盖

### v2.10.46 — UX 丝滑度改进第一批（高感知、低风险 4 项）
- 背景：技术 P0/P1 已全部清理，转做 UX 丝滑度。研判报告 https://bytedance.larkoffice.com/docx/XuDEd3WYwoExwqxcoq5cGSjfn7c 结论：不丝滑主因在 UX（过度模态化 + 过渡动画缺失 + 反馈滞后），非技术架构。本轮做第一批 4 项。
- **① 附件面板切槽位补 0.12s 淡入淡出**（`AttachmentManagerPanel.swift`）：v2.10.29 曾为消卡顿改硬切/瞬切；现性能已 OK，补回极短过渡——切换时旧面板内容 alpha 1→0（0.12s）→ 瞬时 close → 新面板 `animates:false` 定位 + 内容 alpha 0→1（0.12s）。新增 `fadingOutPopover` 记录淡出中的旧 popover，下次 `show` 到来先 `hardCloseFadingOut()` 硬关兜底，杜绝连点叠加两个 popover。首次打开仍走系统淡入动画。淡出完成回调发生在当前 runloop 之后，自然覆盖原 AT-3 的 micro-defer（锚点 NSView 重排已 settle）。面板仍 `.semitransient` 跟随主窗口、切 Finder 拖文件不关闭。
- **② 导入进度改非模态**（`ContentView.swift` `importProgressOverlay`）：去掉 `Color.black.opacity(0.28)` 全屏阻塞遮罩，改为底部悬浮轻量进度卡（`VStack{Spacer();card}` 底部对齐，`.move(edge:.bottom)` 转场），整体 `.allowsHitTesting(false)`，导入期间主网格照常可交互（边导入边整理）。
- **③ 删页/清空组 NSAlert 换轻量 inline 确认**：新增 `InlineConfirmation` 模型（含 `onConfirm(doNotRemind:)` 闭包、`showDoNotRemind`）+ `store.pendingConfirmation` @Published + `requestConfirmation()`（主线程发布）；新增 `InlineConfirmationBar` 视图（底部确认卡，回车确认 / Esc 取消 / 点空白取消，破坏性动作红色 prominent，清空保留「不再提醒」）。`confirmDeletePage`（ContentView）与 `clearAllSlotsInCurrentSpecialSlotWithConfirmation`（main.swift）改用之，移除对应 NSAlert。重命名等其余 NSAlert（`runAlertNonBlocking`/`sheetHostWindow`）保留不动。
- **④ 悬停预览延迟 0.4s→0.18s**（`AttachmentManagerPopover.swift`）：`AttachmentPreviewWindowController` 新增 `isVisible`；hover 时 `delay = isVisible ? 0 : 0.18`，预览窗已开时切换即时响应。
- 约束遵守：未改 UI 样式 / 未引入拖拽排序 / 未改游标胶囊位置；附件面板跟随主窗口、切 Finder 拖文件不关闭；自动切换默认开启、自动存储/粘贴默认关闭、已有用户设置不覆盖。
- commit：`e76ce55`（fix+bump 合并）
- DMG SHA256：`5dee83040198ada1ad30fcb4ba075cb3fa82db9ab23f1fd50d5c43298dbac1bb`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.46

### v2.10.45 — 第八轮 P1×1 + P2×5 全量修复
- 背景：收敛第八轮全量扫描报告（https://bytedance.larkoffice.com/docx/RbpmdrxXRovftnxV4cUcsBFDnJc）发现的 P1×1 + P2×5。未发现 P0。
- **P1-01 读-改-写 UNKNOWN 态丢附件**：`get()`/`contentForSlot()` 在跨进程锁超时且从未缓存时把 UNKNOWN 态坍缩为空占位；`updateTextSlot`/`updateHTMLSlot`/`saveHTMLToSlot` 用它保留 attachments 时会把 attachments 置空，原子 swap 后附件永久丢失。修复：`SlotStorage`/`SpecialSlotStorage` 新增 UNKNOWN-aware 的 `getOrUnknown`（返回 nil = UNKNOWN，不坍缩空占位）；main.swift 新增 `contentForSlotOrUnknown`，三条读-改-写路径在 nil 时**中止本次写入**（弹「存储繁忙」提示），不做 swap。
- **P2-01 判空整读 2× 内存**：`slotContentPayloads` file-like 判空不再 `att.resolveData()` 把整份外置 `.bin` 读进内存，改为廉价谓词 `path != nil || storageFileURL != nil || hasUsableInlineData`（仅 stat/看内存，O(1)）。
- **P2-02 主线程 sleep 掉帧**：`ClipboardManager.resolveData` 换盘重试的 `Thread.sleep(15ms)` 仅在**非主线程**执行；主线程直接判 nil 回退（TOCTOU 重试非正确性所需），消断链附件列表滑动掉帧。
- **P2-03 情形3 陈旧路径丢字节**：`externalizeAttachments` 情形3 清空 `storagePath` 前回探规范路径 `{slotDir}/attachments/{id}.bin`，存在则按情形2克隆进 staging + 回填 `storagePath`（克隆失败抛错回滚），仅规范路径也缺失才判真断链清空。
- **P2-04 损坏守卫漏保字节目录**：损坏守卫（`attachmentDecodeFailedSlots`）在克隆 `attachments.json` 之外，一并克隆 `attachments/` 外置字节目录进 staging，跨原子 swap 保全。
- **P2-05 突发合并漏采尾指纹**：`recordSelfWriteFingerprint` 突发合并（0.08s 窗）内并入后续自写时，新增 `fingerprintRecordCoalesced` 标记，窗口末尾再补采一次尾指纹入环（抽出 `appendSelfWriteFingerprint` 复用），覆盖末尾态，消除最终态落在两次采集之间导致的误判外部写 + 多余 reloadAll。两次采集合计 0.16s，仍 < watcher 0.3s debounce。
- commit：`12b9cf7`（fix+bump 合并）
- DMG SHA256：`b4fbd59a694b7cf4b40f8464191d7555a2b34ba7166eefd09a0eab28cfc1bbe8`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.45

### v2.10.44 — 附件字节外置 P1×3 + P2×6 全量修复
- 背景：收敛 v2.10.41–v2.10.43「附件字节外置三步走」Bug 扫描报告（https://bytedance.larkoffice.com/docx/Fxsid2ifdo5VcnxHxmEchamunOh）发现的全部 P1 与 P2。
- **P1-A 附件字节永久丢失**（`SlotStorage.externalizeAttachments`）：情形 2（克隆现存 `.bin` 进 staging）失败时不再静默置 `storagePath=nil` 后继续写 JSON + 原子 swap（会把旧 `.bin` 随整目录替换掉），改为 `throw SlotStorageError.attachmentExternalizeFailed` → `writeSlotContent` catch 清理 staging、保留原槽目录及其现存字节，整批回滚。
- **P1-B 数据目录不可移植断链**（`SlotStorage.normalizeStoragePaths`，读路径新增）：`storagePath` 存的是写入时绝对路径，迁移/换机/`CLIPSLOTS_DATA_DIR` 变更后 `resolveData` 全量断链。读取时按「当前 slotDir + `attachments/{id}.bin`」约定重建：只要 `.bin` 就在当前 slotDir 下即回填真实绝对路径（仅改内存态，下次 set 自然持久化）。
- **P1-C（v2.10.40 遗留）锁超时空占位覆盖实数据**：`get()` 抽出 `loadContentOrUnknown` 三态（新鲜缓存/锁内读盘/最近缓存 → 真值；锁忙且从未缓存 → nil=未知）。`get()` 把 nil 映射回空占位保持读契约；`isSlotEmpty` 撕裂读回退改用 `loadContentOrUnknown`，遇「未知」保守判为**非空**，杜绝自动模式覆盖仍完好的磁盘数据。
- **P2-A**（`main.swift recordSelfWriteFingerprint`）：自写指纹整树遍历改突发合并（`fingerprintRecordPending` 标志 + 0.08s 延后一次采集，捕获突发最终磁盘态；远小于 watcher 0.3s debounce，自写判定正确性不变）。
- **P2-B**（`SlotStorage.didWriteLiveSlotDir` static hook）：懒迁移写 live 目录后回调，GUI 在 `SlotStoreObservable.init` 注册 `suppressWatcher()`，升级后首次读老库不再触发多余 reloadAll；CLI 侧 hook 为 nil 无副作用。
- **P2-C**（`SlotStorage.writeSlotContent` 改 `@discardableResult` 返回持久化附件；`set()` 缓存该形态）：缓存「已外置」附件（`data=nil` + storagePath），外置省下的内存立即释放，不再等下次 get 重读。
- **P2-D**（`AttachmentManagerPopover` thumbnail/fullImage/previewImage + `SlotAttachment.storageFileURL`）：外置图片按文件 URL 交 ImageIO 增量下采样（`CGImageSourceCreateWithURL`）/`NSImage(contentsOf:)`，不再 `resolveData()` 把整份 `.bin` 读进内存再解码。
- **P2-E**（`SlotAttachment.resolveTextString()` + `AttachmentTextCache` NSCache）：文本附件预览带进程内解码缓存（键 id+storagePath），消除 SwiftUI 重绘时主线程同步读盘；面板 subtitle/bodyText 改用它。
- **P2-F**（`SlotAttachment.resolveData()`）：读 `.bin` 加轻量重试（越过与另一进程原子 swap 交叠时的瞬时 nil），仍失败才当断链返回 nil，最终语义不变。
- 自测：本机 `swift build` 通过（仅历史遗留 warning）；`SKIP_NOTARIZE=1 bash scripts/package_dmg.sh` 打包 + DMG 校验通过。
- commit：`69b7715`（fix+bump 合并）
- DMG SHA256：`2022fabe036027c6c9ac58421367a9ea1a94060d08677d9b2eb84dc9778b3af5`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.44

### v2.10.43 — 附件字节外置架构 Step 3（pack 导出流式打包外置 .bin + CLI/Skill 研判）
- 背景：方案 B「附件字节外置」三步走收官。承接 Step 2（v2.10.42）写盘外置 `{slotDir}/attachments/{id}.bin`，本版让 pack 导出/导入与 CLI/Skill 完成外置字节适配。
- **PackExporter 导出改造（唯一代码改动）**（`PackExporter.swift`）：取字节优先「可流式拷贝的磁盘文件」——先 `storagePath`（外置 .bin），其次本地引用 `path`，均用 `FileManager.copyItem` 内核级流式拷贝进包内 `attachments/` 目录，全程不把文件读进进程内存。**关键：绕过 `att.resolveData()`**——Step 2 后 resolveData() 会按 storagePath 把整个 .bin 读进内存返回，导出含大视频的外置附件即可 OOM（正是 PK-3/D-1 一直规避的问题）；仅当字节只在内存（少见未落盘内联 data）才 `data.write`；声明了 storagePath/path 但文件缺失/为空登记 `failedAttachments`；纯 url/reference 型保留元信息。包内只存字节文件（`file` 相对引用），绝不写 storagePath 绝对路径（换机后无效）。
- **PackImporter 无需改动**：解包后小附件内联字节经 `storage.set → externalizeAttachments`（Step 2）自动落 `.bin`（data 置 nil），大附件保持 path 引用；两类都不内联进 JSON，Step 2 已覆盖导入侧的「字节写成独立文件而非内联 JSON」诉求。
- **CLI 无 breaking change**：`read` 从不输出附件 base64 `data`（仅 `attachmentCount`/`preview`/`text`/`htmlSource`/`types`/`empty` 元数据），任务预设的「read 依赖 base64 data 字段」前提不成立，无需改；`write-attachment` 建 path 引用、`paste` 走 `att.path`，均与外置字节解耦，不受影响。
- **Skill 无需更新（研判结论）**：Step 3 为内部存储/pack 机制改造，对 CLI 命令、参数、输出、行为完全透明；`clipslots-manager` SKILL.md（bundle 版 v1.5.0 + user_skills 草稿）无任何 base64/storagePath/外置字节相关表述，仍准确，本版不改。
- 自测：`swift build -c release` 通过（仅历史遗留 warning）；`SKIP_NOTARIZE=1 bash scripts/package_dmg.sh` 打包 + DMG 校验通过。
- commit：`b910f28`（refactor+bump 合并）
- DMG SHA256：`a9cc4af6be99c640a9000f912c719078dfae6a02dddd9c5b751b629cf9d0dac8`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.43

### v2.10.42 — 附件字节外置架构 Step 2（写盘落独立文件 + 老数据懒迁移）
- 背景：方案 B「附件字节外置」三步走的第二步，承接 v2.10.41 Step 1 的统一读入口 `resolveData()`。Step 2 让字节真正落到独立文件、老数据懒迁移，行为对上层透明。
- **`SlotAttachment` 新增可选字段 `storagePath`**（`ClipboardManager.swift`）：外置字节文件的绝对路径，指向 `{slotDir}/attachments/{id}.bin`；Codable 向后兼容（历史数据缺失即 nil）。
- **`resolveData()` 扩展磁盘懒加载**：内存 `data` 优先（新写入内存态 / 未迁移老数据），否则按 `storagePath` 从磁盘读；文件缺失/断链返回 nil。
- **写盘外置 `externalizeAttachments()`**（`SlotStorage.swift`，`writeSlotContent` 内调用）：把「带字节」附件写成独立 `.bin`，`attachments.json` 只存元数据 + `storagePath`（`data` 置 nil）。字节来源三态：①内联 data 直接写文件；②已外置（内存无 data、仅 storagePath）用 clonefile 把现存 `.bin` 克隆进 staging（否则整槽目录每次 staging→原子 swap 会把旧 `.bin` 一并替换丢失）；③纯 path/url/reference/断链 原样保留元数据不外置。
- **老数据懒迁移 `migrateInlineAttachmentsIfNeeded()`**：读到 `attachments.json` 仍内联 base64 `data`（无 storagePath）时，`readSlotContent` 首次读自动外置落盘并回写 JSON。仅在 get() 慢路径（已持跨进程 StorageLock + 串行 queue）内执行，并发安全；无迁移需求零写盘。
- **崩溃安全（要求 5）**：严格顺序「逐条 临时文件 + rename 落 `.bin` → 全部落盘后才原子改写 JSON」。崩溃在改 JSON 前→旧 JSON（含 data）仍在，下次读幂等重迁；崩溃在后→`.bin`+新 JSON 一致。原始 data 永不丢。
- **`get()` 读后重算 fingerprint**：懒迁移改动了 slotDir，读后重新 stat 指纹再缓存，避免下次 get 无谓整槽重读。
- 自测：CLI（`ClipSlotsCLI` 产物）+ `CLIPSLOTS_DATA_DIR` 隔离验证——老格式内联 data 读时迁移（bin 字节与原始精确一致）、重写槽位后外置 `.bin` 跨原子 swap 存活、JSON 收敛为 data=nil+storagePath、CLI path 引用附件不被误外置。
- 后续：Step 3（v2.10.43）改 pack 导入/导出与 CLI paste 适配外置字节。
- commit：`8648588`（refactor+bump 合并）
- DMG SHA256：`25476cfdf2cb9670737a94afb9433413ffda1af97c41ad62dec3e2b51dd72165`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.42

### v2.10.41 — 附件字节外置架构 Step 1（统一懒加载入口，纯重构）
- 背景：方案 B「附件字节外置（独立文件 + 懒加载）」分三步走。Step 1（本版）加统一懒加载入口，把所有直接读 `att.data` 的地方收敛到一个函数，**此时字节仍在 JSON，行为不变，纯重构**，为后续步骤安全落地铺路。
- **新增 `SlotContent.SlotAttachment.resolveData() -> Data?`**（`ClipboardManager.swift` 扩展内）：Step 1 直接返回 `self.data`（逐字节行为一致）；附完整设计注释说明 Step 2 将扩展为「内联为空则按内容寻址从磁盘懒加载 + 老数据懒迁移」，Step 3 适配 pack/CLI。
- **9 处读取路径改走 `resolveData()`**：`main.swift`（3390 文本附件、3403 图片、3722 多图合并 spill、2938 file-like 分类判存在）、`AttachmentManagerPopover.swift`（697 subtitle、757 缩略图、817 大图、844 悬停预览、958 文本附件预览）、`PackExporter.swift`（242 pack 导出写字节）。全仓已无其他直接 `att.data`/`attachment.data` 读取（仅剩 resolveData 内部与文档注释引用）。
- 后续：Step 2（v2.10.42）改写盘字节落独立文件 + 老数据懒迁移；Step 3（v2.10.43）改 pack 导入/导出 + CLI 适配。
- commit：`b97660a`（refactor+bump 合并）
- DMG SHA256：`66e52ce1e54aeea4d2c7e8a5e9243ab4726df03e5bc567eb50dea25dc698263a`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.41

### v2.10.40 — P0 槽位包导入死锁崩溃修复
- 崩溃：`EXC_BREAKPOINT (SIGTRAP)` / `BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread`，崩溃线程 dispatch queue = `com.clipslots.storage`。
- 根因：`SlotStorage.set()` 在 `queue.sync` 块内调用 `writeSlotContent()`（SlotStorage.swift:359），后者自 v2.10.38 起为保留旧标签调用 `getLabel()`（:739），而 `getLabel()` 内部又对同一串行队列 `queue.sync`（:528）→ 同队列重入 → libdispatch 断言崩溃。`PackImporter.writeSlots()` → `SpecialSlotStorage.set()`（已持 `com.clipslots.storage` flock）→ `SlotStorage.set()` 批量导入时稳定触发。
- 修复：新增 private `getLabelOnQueue(_:)`（no-lock、必须在 `queue` 上调用的内部版），复刻 getLabel 的 cache/disk 逻辑但不再 `queue.sync`、不再重取跨进程锁；`writeSlotContent` 改用它读取旧标签。
- commit：`bc9079e`（fix+bump 合并）
- DMG SHA256：`b985966dbc715bdc08c079b1faee71fd330bf2d1d4cf71298d815c8244873a53`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.40

### v2.10.39 — 导入进度条浮层
- 需求：导入时加进度条，让用户看到导入进度。覆盖三条导入路径：槽位包导入（PackImporter）、批量图片/文件导入（handleBatchSave）、文件夹导入当前组（importFolderIntoCurrentSpecialSlot）。
- **新增 `ImportProgress` 模型 + `SlotStoreObservable.importProgress` @Published 状态**：非空即表示导入进行中；`publishImportProgress()` 统一在主线程发布。ContentView ZStack 内新增 `importProgressOverlay`（半透明遮罩拦截点击 + 居中 `.ultraThickMaterial` 卡片，含 `ProgressView` 进度条、`已处理/总数`、百分比、当前项名称）。`total<=0` 显示不确定进度（.linear 无值），否则确定进度。
- **PackImporter.importPack 新增 `onProgress: (done,total,name)` 回调**：新增 `countTotalSlots(manifest:pagesRoot:)` 预统计总槽位数（遍历各页组 slots 声明，空则扫 slots 目录，口径同 writeSlots）；每写完一组上报一次（组级粒度）。解压/解析阶段先发不确定进度。
- **batch/folder 导入循环内逐条上报**：每处理一个文件刷新 `completed=index+1`，完成/失败分支 `publishImportProgress(nil)` 收起浮层。
- commit：`e3def87`（fix+bump 合并）
- DMG SHA256：`f6b8346fc5ef802da3dad7e2f2a6c8689dea2227d83170b5f67ccbb0b982eeb4`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.39

### v2.10.38 — 大批量图库卡顿 P0 优化（4 项）
- 背景：导入约 1.6GB `.clipslotspack` 图库后「几乎所有操作 3-5s 彩球」。根因分析报告见 https://bytedance.larkoffice.com/docx/BLa5dspXfoGKSnxwUAecKY12nqe
- **P0-1 搜索异步化 + label 内存缓存**：`SlotStorage.getLabel` 加 label.txt 指纹缓存 + 无锁快路径（命中不抢 flock、不读盘）；`SlotStoreObservable.allSearchableSlots` 拆为 `searchableGroupsSnapshot()`（主线程仅捕获轻量分组引用）+ `expandSearchableSlots()`（后台展开逐槽 snapshot/getLabel），ContentView 全局搜索把展开+过滤+排序整体移出主线程。
- **P0-2 导入完成异步刷新 + 跳过重指纹**：导入成功/失败分支的 `reloadAll()` 改 `reloadAllAsync()`；`suppressWatcher` 新增 `recordFingerprint:` 参数，导入收敛时传 `false` 跳过 1.6GB 全树指纹遍历。
- **P0-3 读路径限时**：新增 `SlotStorage.readLockTimeout = 2.0`，`get()`/`getLabel()` 慢路径用短超时，超时回退最近缓存值，杜绝主线程读操作等满 5s。
- **P0-4 缩略图解码全局并发限流**：新增 `ThumbnailDecodeLimiter`（actor，按核数 2–6 上限），网格缩略图（SlotThumbnailView）与内联预览（InlineImageView）解码经其 `run{}` 限流。
- commit：`c39b101`（fix+bump 合并）
- DMG SHA256：`2b725105530aab1974af0614795f5c15a64db3c108427a8c02b413d7430f9827`
- Release：https://github.com/Seven-hub-fanfan/ClipSlots/releases/tag/v2.10.38

### v2.9.29
- **CLI 新增 `--page-name`（与 `--group-name` 对称）**：`list`/`read`/`write`/`paste`/`create-group` 均支持按页面名精确匹配（遍历 `index.pages` 找 `name == pageName` 取其 id）。页面名找不到时显式报错 `找不到名为 '<name>' 的页面` 并非零退出，不再静默回落默认页；`--page`/`--page-name` 互斥（同传报 `只能指定 --page 或 --page-name 其中一个`）。`create-group` 的 `--page` 收敛为严格校验：显式传入不存在的页面 id/名 直接报错，不再静默落到当前页。
- **新增 `CLIPSLOTS_DATA_DIR` 环境变量（env > 默认）**：新增 `Sources/ClipSlotsKit/ClipSlotsPaths.swift` 作为数据目录唯一事实来源；`SpecialSlotStorage`/`SlotStorage`/`StorageLock`/`SlotConnectionStorage`/GUI(`main.swift` 的 watcher 与 undo 快照)/CLI 诊断均改用它。**锁文件随数据目录移动**（`ClipSlotsPaths.lockFile`），保证 GUI+CLI 在重定向数据目录后仍协调同一把锁。`clipslots --help` 输出新增 `env.CLIPSLOTS_DATA_DIR` 说明。配置文件（`~/.config/clipslots/config.toml`）不受影响。

### v2.9.28
- **修复 CLI 安装报错"找不到内置 CLI 二进制 (clipslots-cli)"**（最重要）：v2.9.27 打包脚本重写后遗漏了 CLI 与 Skill 拷贝。`scripts/package_dmg.sh` 现固化：`swift build -c release` 后把 `.build/release/ClipSlotsCLI` 拷贝为 `ClipSlots.app/Contents/MacOS/clipslots-cli` 并 `codesign --force --sign -`；同时把 `skills/clipslots-manager` 拷进 `Contents/Resources/skills/`。`verify_app_bundle` 增加 `test -x .../clipslots-cli` 与 `test -f .../SKILL.md` 硬校验，缺件即 `die`。
- **修复 Skill 市场详情页右上角「安装」按钮点击无反应**：该处原为纯展示徽章（非按钮）。新增 `PluginsView.detailInstallControl` 包成可点击 `Button`，调用新增的 `AgentSkillInstallManager.installToAllDetectedAgents()` —— 遍历所有已检测 Agent 一键安装，复用单 Agent 安全软链逻辑并保留 `lstat` 软链接安全守卫（真实目录/文件跳过不删）。
- **修复 Skill 页「安装到 Agent」刷新按钮无可见反馈**：刷新按钮改为调用新增 `AgentSkillInstallManager.rescan()`，重新扫描 `~/.claude`/`~/.cursor`/`~/.codex`/`~/.gemini` 并通过 `lastMessage` 输出扫描结果反馈。

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
