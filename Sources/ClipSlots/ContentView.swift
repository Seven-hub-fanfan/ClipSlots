import SwiftUI
import ClipSlotsKit
import AppKit

/// v2.10.70: 监测 macOS 窗口的 live-resize（拖拽边缘缩放 / 标题栏缩放）。拖拽过程中窗口尺寸每帧变化，
/// 整窗的环境背景（radius 50~58 的超大高斯模糊 + 多层 .screen 混合）与每张卡片的软阴影都会按新尺寸
/// 逐帧重新离屏栅格化/重合成，是拖拽卡顿的主因。此单例把 willStartLiveResize / didEndLiveResize 通知
/// 转成一个 @Published 开关，供背景与卡片在拖拽期间降级渲染（去模糊 / 去阴影），拖拽结束立即恢复。
final class LiveResizeMonitor: ObservableObject {
    static let shared = LiveResizeMonitor()
    @Published private(set) var isResizing = false
    private init() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if self?.isResizing == false { self?.isResizing = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if self?.isResizing == true { self?.isResizing = false }
        }
    }
}

/// v2.10.9 (P2-27): 承载搜索防抖 DispatchWorkItem 的小型持有者。放在视图 @StateObject
/// 里而不是 @State，可通过引用语义在 body 之外命令式地取消/替换，不再触发无意义的 body
/// 失效（避免 @State 反模式）。deinit 兜底取消，onDisappear 亦会主动取消（P2-26）。
final class SearchDebounceHolder: ObservableObject {
    var workItem: DispatchWorkItem?
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
    deinit { workItem?.cancel() }
}

struct ContentView: View {
    // v2.10.69: 网格列由「量化后的容器宽度」推导为 .fixed 列宽（原来是 .flexible + 逐像素弹性解算）。
    // 拖拽实时缩放窗口时，弹性列会在每一像素都重解算列宽并重排全部可见卡片，造成明显卡顿；
    // 改为固定列宽后，卡片尺寸在两个宽度台阶之间保持不变，无需逐帧重排。列宽由此工具方法计算，
    // 结果缓存进 @State（gridColumnsState），保证台阶之间数组身份稳定、不触发 LazyVGrid 重新布局。
    static let gridColumnSpacing: CGFloat = 14
    private static func makeGridColumns(for totalWidth: CGFloat) -> [GridItem] {
        let spacing = gridColumnSpacing
        let availableWidth = max(0, totalWidth - AppTheme.pagePadding * 2)
        let columnCount = max(1, Int((availableWidth + spacing) / 254))
        let columnWidth = max(1, (availableWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
        return Array(repeating: GridItem(.fixed(columnWidth), spacing: spacing), count: columnCount)
    }

    // P2-31 (v2.10.9): 已确认 store 的所有权正确——真正的持有者是 @main `ClipSlotsApp`
    // 里的 `@StateObject private var store = SlotStoreObservable()`（main.swift），并以
    // `ContentView(store: store)` 注入。@StateObject 保证其生命周期跨视图重建存活，因此
    // 这里用 @ObservedObject 只是「观察而不持有」是正确用法，无需改动所有权。
    @ObservedObject var store: SlotStoreObservable
    // v2.10.0: 三档金属拨杆共享状态（自动存储 / 自动粘贴 / 自动切换）。
    // v2.10.79 (改动A 观察下沉): 改为非观察的 `let` 引用——ContentView 自身不再订阅 autoMode，
    // 仅把该引用透传给局部观察它的子视图（LeverClusterView / AutoAdvanceToggleView）以及既有的
    // CursorBadgesView / CrossGroupCursorHintView。拨杆翻动只重绘这些小簇，不再触发整棵
    // ContentView.body 重新求值。（全量 grep 已确认 ContentView 内对 autoMode 的响应式读取只在
    // 摇杆簇与自动切换按钮，其余仅透传，故撤订阅安全、不破坏开关联动。）
    private let autoMode = AutoModeState.shared
    // v2.10.70: 观察 live-resize 状态，拖拽缩放窗口期间把整窗环境背景降级为纯色填充。
    @ObservedObject private var liveResize = LiveResizeMonitor.shared
    @State private var showingSettings = false
    @State private var showingSpecialSlotManagement = false
    @State private var showingHotkeyTemplatePopover = false
    // v2.9.8: plugins page popover.
    @State private var showingPlugins = false
    @State private var showingPageSelector = false
    @State private var expandedPageId: String?
    @State private var isPageMultiSelecting = false
    // v2.10.69: 量化后的网格容器宽度 + 缓存的列数组。拖拽 resize 时仅当宽度跨过 8pt 台阶才更新，
    // 其余帧沿用同一 [GridItem] 实例（身份稳定），避免逐像素重排。
    @State private var quantizedGridWidth: CGFloat = 0
    @State private var gridColumnsState: [GridItem] = []
    @State private var selectedPageIds: Set<String> = []
    // v2.9.8: update checker.
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var showingConnectionFullscreen = false
    // v2.9.37: hover state for the footer "上次粘贴" button (subtle hover highlight).
    @State private var lastPasteHovering = false
    @Environment(\.colorScheme) private var colorScheme

    // v2.7.47: new installs should open in dark mode by default.
// AppStorage's default only applies when UserDefaults has no value, so existing
// users who already selected system/light/dark are not overwritten.
@AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.dark.rawValue

    // v2.5: Search state
    @State private var searchText: String = ""
    @State private var selectedFilter: SlotFilterType = .all
    // v2.7.23: global search is the default. Users can still switch back to group scope.
@State private var searchScope: SlotSearchScope = .global
    @State private var globalSearchSortRule: SlotSearchSortRule = .smart
    // v2.8.0 (perf M1/M2): debounced + cached global search. `searchText` changes on
    // every keystroke, but the expensive cross-page/group scan should only run after
    // the user pauses typing (debounce), and its result is cached in state so that
    // unrelated view re-renders (e.g. thumbnails finishing load) no longer re-run the
    // whole scan+sort on the main thread.
    @State private var globalSearchResultsCache: [SlotGlobalSearchResult] = []
    // v2.10.49 (perf 第一批 P1「组内搜索 matchedSlotCount 防抖缓存」): 此前 matchedSlotCount 是
    // 每次 body 求值都遍历本组槽位重算的计算属性（无结果提示与匹配计数文案各触发一次遍历）。
    // 改为把结果缓存到此 @State，仅在搜索输入（searchText/selectedFilter/searchScope）或底层槽位
    // 内容签名（slotsContentSignature）变化时重算一次，避免无关重绘（缩略图加载完成等）反复遍历。
    @State private var matchedSlotCountCache: Int = 0
    // P2-27 (v2.10.9): 防抖 work item 从 @State 迁到视图持有的 holder（引用语义，body 外可安全 mutate）。
    @StateObject private var searchDebounce = SearchDebounceHolder()

    // v2.7.1: stable connection sheet replaces broken node-canvas UI.
    @State private var showingConnectionManagement = false
    // v2.7.2: Independent node canvas (does NOT draw lines on the main grid).
    @State private var showingNodeCanvas = false

    // v2.9.17: theme switch now takes effect instantly with no transition effect.
    // The previous water-ripple overlay (v2.7.45) was removed per product request.
    private func cycleAppearanceMode() {
        let current = ThemeMode(rawValue: appearanceModeRaw) ?? .system
        switch current {
        // v2.7.41: toolbar theme switch only toggles light/dark.
        // Keep "follow system" only in Settings to avoid confusing three-state cycling.
        case .system: appearanceModeRaw = ThemeMode.dark.rawValue
        case .light:  appearanceModeRaw = ThemeMode.dark.rawValue
        case .dark:   appearanceModeRaw = ThemeMode.light.rawValue
        }
    }

    // v2.9.12: Obsidian-style in-app settings overlay. Dimmed backdrop + centered
    // two-pane panel. Lives inside the main window ZStack, so it follows the window.
    private var settingsOverlay: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeSettings() }

                SettingsView(
                    config: store.config,
                    onSave: { newConfig in
                        store.updateConfig(newConfig)
                        closeSettings()
                    },
                    onClose: { closeSettings() },
                    // v2.9.17: sidebar「插件市场」→ close settings, open the
                    // independent plugin marketplace popover (anchored on toolbar).
                    onOpenPlugins: {
                        showingSettings = false
                        store.isSettingsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            showingPlugins = true
                        }
                    }
                )
                // Fill the main window with small insets so it reads as an in-app
                // panel (like Obsidian), while staying usable in small windows.
                .frame(
                    width: min(max(geo.size.width - 32, 480), 880),
                    height: min(max(geo.size.height - 32, 380), 660)
                )
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func closeSettings() {
        withAnimation(Anim.status) { showingSettings = false }
    }

    // v2.10.73（方案③：缩略图渲染解耦）：卡片身份改回 `.id(slot)`——切页/切组时卡片被复用而非
    // 整格重建（流畅）。缩略图刷新不再依赖卡片身份携带内容版本，而是由 SlotThumbnailView 观察
    // ThumbnailProvider（以 key 为维度的共享缓存单一数据源）驱动：currentKey 一变即读新 key，
    // 命中秒出、未命中异步填充，彻底消除「切到含主体图片的组、缩略图卡旧图需切走切回」的回归。
    // 注：原 v2.10.72 的 cellIdentity(for:) 已删除（全仓再无引用）。v2.10.87 起 slotRenderTokens
    // 基础设施也已一并删除——它自 v2.10.73 就再无读取点，却仍作为主 store 的 @Published 被写 16 次，
    // 每次都白白触发整棵 ContentView.body 重算（详见 main.swift 该字段原声明处的注释）。

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                headerView

                // Hotkey error banner
                // v2.10.87（动画打磨）: 原为硬切——横幅出现/消失会瞬间把下方网格顶下去/弹上来。
                // 用与搜索结果区同一套「淡入 + 自顶部展开」过渡，两处纵向插入的节奏保持一致。
                Group {
                    if !store.hotkeyRegistrationErrors.isEmpty {
                        hotkeyErrorBanner
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(Anim.reveal, value: store.hotkeyRegistrationErrors.isEmpty)

                // Search results remain in the content area; the controls themselves live in titleBar.
                //
                // v2.10.87（动画打磨）: 原实现是裸 `if isSearchActive { ... }`，无任何过渡——敲下第一个
                // 搜索字符的瞬间，这一整块（组内计数提示 / 全局搜索结果面板）凭空出现，把下方槽位网格
                // 硬生生往下顶一大截；清空搜索时又整块消失、网格「弹」回原位。这是搜索路径上观感最突兀
                // 的一处跳变。
                //
                // 改为「淡入 + 自顶部展开」，并把 `.animation` 紧贴这个 Group 作用域：
                // - 动画只由 isSearchActive 这一个布尔驱动，输入过程中逐字符改 searchText 不会反复触发；
                // - 作用域限定在本 Group，父 VStack 的其它子项（标题栏 / 网格 / 底栏）不会被顺带纳入
                //   隐式动画，只是跟着本块被动画的高度平滑让位，因此网格是「被推开」而不是「跳一下」；
                // - 用 Anim.reveal（0.13s easeOut）而不是更长的 Anim.transition：这一下会带动 10 张卡片
                //   所在容器的纵向布局，时长必须压短，既读得出动作又不拖慢连续输入的节奏。
                //   v2.10.88：原为 Anim.status(0.2s easeInOut)，实测偏慢——大面积纵向位移的感知时长
                //   天然比小控件更长，0.2s 在连续输入搜索词时会明显拖住节奏，故收紧到专用的 reveal 档。
                Group {
                    if isSearchActive {
                        searchResultsSection
                            .padding(.horizontal, AppTheme.pagePadding)
                            .padding(.vertical, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(Anim.reveal, value: isSearchActive)

                GeometryReader { gridGeometry in
                    let rawWidth = gridGeometry.size.width
                    // v2.10.75: resize 期间锁定「上次量化台阶宽度」作为有效布局宽度，逐像素 Diff 归零；
                    // 非 resize 时用真实 rawWidth 自适应。quantizedGridWidth 尚未初始化(0)时兜底用 rawWidth。
                    let layoutWidth = liveResize.isResizing && quantizedGridWidth > 0 ? quantizedGridWidth : rawWidth
                    // v2.10.69: 首帧（state 尚空）用当前宽度直接算一份兜底；之后一律读 @State 缓存的
                    // 列数组，保证拖拽 resize 台阶之间数组身份稳定，不触发 LazyVGrid 逐帧重排。
                    let columns = gridColumnsState.isEmpty ? Self.makeGridColumns(for: layoutWidth) : gridColumnsState

                    ScrollViewReader { scrollProxy in
                        ScrollView {
                        // v2.5: No results hint
                        if searchScope == .currentGroup && isSearchActive && matchedSlotCount == 0 {
                            noResultsView
                                .padding(.top, 32)
                        }

                        LazyVGrid(
                            columns: columns,
                            spacing: 14
                        ) {
                            ForEach(Array(stride(from: 1, through: store.config.slots, by: 1)), id: \.self) { slot in
                                // v2.10.73（方案③）：卡片身份改回 `.id(slot)`——切组/切页时复用卡片、不整格
                                // 重建（流畅）；缩略图正确性由 SlotThumbnailView 观察 ThumbnailProvider 保证。
                                slotCardView(slot: slot)
                                    .id(slot)
                            }
                        }
                        .padding(AppTheme.pagePadding)
                        // v2.10.47: 切组过渡——保留旧内容但轻微淡化，作为「切换中」骨架的底衬；期间禁用点击。
                        // v2.10.76 (Phase 1 交互状态下沉): 淡化/禁点击/淡入动画迁入 GroupSwitchDimModifier，
                        // 只观察 store.transientUI.isSwitchingGroup——切组状态变更不再触发整棵 ContentView.body
                        // 重新求值。视觉与 v2.10.71 完全一致（0.35 透明度 + 0.16s easeInOut，无全网格模糊）。
                        .modifier(GroupSwitchDimModifier(ui: store.transientUI))
                    }
                    // v2.10.75: resize 期间给 ScrollView 显式固定宽度=锁定的 layoutWidth，让 AppKit 窗口
                    // 拉伸而 SwiftUI 内容尺寸不动（宁可露底色也保帧率）；非 resize 时 width=nil 恢复自适应。
                    .frame(width: liveResize.isResizing ? layoutWidth : nil)
                    .background(AppTheme.windowBackground(colorScheme))
                    .transaction { $0.animation = nil }
                    // v2.10.47: 切组过渡遮罩——柔和高光扫过淡化后的旧内容，表示「正在切换/加载」。
                    // v2.10.76 (Phase 1): 遮罩显隐迁入 GroupSwitchVeilOverlay，只观察 store.transientUI。
                    .overlay {
                        GroupSwitchVeilOverlay(ui: store.transientUI)
                    }
                    // v2.9.37: when the footer "上次粘贴" button flashes a slot, scroll it
                    // into view so the highlighted card is always visible after the jump.
                    // v2.10.73（方案③）：卡片 .id 已改回 slot，scrollTo 目标同步用 slot 保持一致。
                    .onChange(of: store.flashHighlightSlot) { target in
                        guard let target else { return }
                        withAnimation(Anim.status) {
                            scrollProxy.scrollTo(target.slot, anchor: .center)
                        }
                    }
                    // v2.10.69: 网格宽度量化——仅当容器宽度相对上次缓存变化 ≥ 8pt（或首次）时，
                    // 才重算并提交固定列宽到 @State。这样把拖拽 resize 的「逐像素重排」降为「每 8pt 一次」，
                    // 其余帧沿用同一 [GridItem] 实例，卡片尺寸固定、不再逐帧重解算布局。
                    .onChange(of: rawWidth) { newWidth in
                        if quantizedGridWidth == 0 || abs(newWidth - quantizedGridWidth) >= 8 {
                            quantizedGridWidth = newWidth
                            gridColumnsState = Self.makeGridColumns(for: newWidth)
                        }
                    }
                    // v2.10.75: resize 结束时强制把量化宽度对齐到真实宽度并重算列，避免停在
                    // 1-7pt 偏差处（< 8pt 阈值未触发）导致网格没贴齐窗口边缘的量化边界回归。
                    .onChange(of: liveResize.isResizing) { resizing in
                        if resizing == false {
                            quantizedGridWidth = rawWidth
                            gridColumnsState = Self.makeGridColumns(for: rawWidth)
                        }
                    }
                }
                }

                bottomBar
            }
            .background(
                RetroPosterAmbientBackground(simplified: liveResize.isResizing)
                    .ignoresSafeArea()
            )

            // v2.10.52 (perf 第四批 · 巨型 @Published Store 拆分): Toast / 浮层提示改由独立子视图
            // TransientOverlayView 观察 store.transientUI 渲染。ContentView.body 不再读取
            // toastMessage/floatingNotice（store.transientUI 是普通引用读取，不建立 @Published 依赖），
            // 因此二者高频弹出/消失不再触发整棵 body 重新求值，只重绘该覆盖层子视图。
            // 层级用 zIndex(101) 与原 toast(100)/floatingNotice(101) 对齐，位于设置(200)与进度(150)之下。
            TransientOverlayView(ui: store.transientUI)
                .zIndex(101)

            // v2.10.46: 导入进度浮层（槽位包 / 批量文件 / 文件夹导入共用）。非模态：底部悬浮、不阻塞交互。
            // v2.10.87 (perf): 改由独立子视图 ImportProgressOverlayView 观察 store.transientUI 渲染。
            // ContentView.body 不再读取 importProgress（store.transientUI 是普通引用读取，不建立
            // @Published 依赖），因此几百次进度上报不再逐次触发整棵 body 重新求值，只重绘该浮层。
            ImportProgressOverlayView(ui: store.transientUI)
                .zIndex(150)

            // v2.9.12: in-app settings overlay (Obsidian-style two-pane).
            // Rendered inside the main window's ZStack so it stays attached to the
            // window and moves together when the window is dragged.
            if showingSettings {
                settingsOverlay
                    .transition(.opacity)
                    .zIndex(200)
            }

        }
        .onAppear {
            AppearanceDefaults.ensureDefaultDarkIfNeeded()
        }
        // v2.9.12: settings overlay is a modal hotkey-editing safe zone; keep the
        // store flag in sync so business hotkeys don't fire while it is open.
        .onChange(of: showingSettings) { store.isSettingsPresented = $0 }
        // v2.9.12: Cmd+, / "设置…" menu opens the in-app overlay.
        .onReceive(NotificationCenter.default.publisher(for: .openInAppSettings)) { _ in
            withAnimation(Anim.status) { showingSettings = true }
        }
        // v2.6.7: Import options sheet
        .sheet(item: $store.pendingImportSelection) { selection in
            ImportOptionsSheet(
                selection: selection,
                onCancel: {
                    store.pendingImportSelection = nil
                },
                onConfirm: { choice in
                    store.pendingImportSelection = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        store.executeImportSelection(selection, choice: choice)
                    }
                }
            )
        }
        // v2.10.14: 打包导出选择 sheet
        .sheet(isPresented: $store.showingPackExport) {
            PackExportView(
                store: store,
                onCancel: { store.showingPackExport = false },
                onExport: { selection in
                    store.performPackExport(selection)
                }
            )
        }
        // v2.7.1: stable connection manager replaces broken node-canvas UI.
        .sheet(isPresented: $showingConnectionManagement) {
            ConnectionManagementSheet(store: store)
                .frame(width: 540, height: 620)
        }
        // v2.7.2: Independent node canvas. Do NOT draw connection lines on the main slot grid.
        .sheet(isPresented: $showingNodeCanvas) {
            NodeCanvasSheet(store: store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .sheet(isPresented: $showingConnectionFullscreen) {
            ConnectionFullscreenView(
                store: store,
                onClose: { showingConnectionFullscreen = false },
                onOpenNodeCanvas: { showingNodeCanvas = true; showingConnectionFullscreen = false },
                onOpenManager: { showingConnectionManagement = true; showingConnectionFullscreen = false }
            )
                .frame(minWidth: 720, minHeight: 560)
        }
    }

    private var hotkeyErrorBanner: some View {
        VStack(spacing: 4) {
            ForEach(store.hotkeyRegistrationErrors, id: \.self) { error in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                    Spacer()
                }
            }
            HStack(spacing: 4) {
                Text("💡 建议在设置中尝试 Cmd+Option+数字 以避免冲突")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // v2.10.87 (perf): 导入进度浮层的渲染已迁至 ImportProgressOverlayView（见 TransientUIStore.swift），
    // 与 v2.10.52 的 Toast/浮层拆分同构——ContentView 不再读取 store.importProgress，因此高频进度
    // 上报不再触发整棵 body 重新求值。视觉（底部悬浮 340pt 胶囊、非模态不拦点击、进出场动画）不变。

    // v2.10.52 (perf 第四批): Toast / 浮层提示的渲染已迁至 TransientOverlayView（见 TransientUIStore.swift），
    // ContentView 内不再保留 toastView / toastIcon / floatingNoticeView。

    // MARK: - Header Layers

    private var headerView: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 12)

            Divider()

            actionBar
                // v2.10.24: 跨组游标提示胶囊移到「第二行」——即自动存储 / 自动粘贴 拨杆所在的
                // actionBar 这一行，水平居中显示。用 overlay 叠加不占额外垂直空间
                // （仅在游标位于其他组时才有内容），保持 .thickMaterial 磨砂玻璃样式。
                .overlay(crossGroupCursorHint)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, 6)
                .padding(.bottom, 4)

            specialSlotTagBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 4)

            // v2.7.37: remove the upper shortcut hint completely.
            // It duplicated the bottom bar and consumed vertical space for slots.
            // activeHotkeyLayerNotice intentionally not rendered here.

            Divider()
        }
        // v2.10.81: 用独立矩形承载 .regularMaterial 并加 .id(colorScheme)，切主题时强制重建这层
        // NSVisualEffectView——修复 AppKit 材质 appearance 滞后（顶部磨砂玻璃切主题后卡旧色）。
        // .id 只作用于材质层，不波及 header 内容子树（搜索框文本/焦点、popover 状态不受影响）。
        .background(
            Rectangle()
                .fill(.regularMaterial)
                .id(colorScheme)
        )
        .popover(isPresented: $showingSpecialSlotManagement) {
            SpecialSlotManagementView(store: store)
        }
        // v2.8.0 (perf M1/M2): drive the cached global-search results from explicit
        // input changes instead of recomputing inside the view body on every render.
        .onChange(of: searchText) { _ in
            scheduleGlobalSearchRecompute(debounced: true)
            recomputeMatchedSlotCount()  // v2.10.49: 组内匹配计数即时刷新（本组遍历 ≤10 槽极廉价）
        }
        .onChange(of: selectedFilter) { _ in
            scheduleGlobalSearchRecompute(debounced: false)
            recomputeMatchedSlotCount()  // v2.10.49
        }
        .onChange(of: searchScope) { _ in
            scheduleGlobalSearchRecompute(debounced: false)
            recomputeMatchedSlotCount()  // v2.10.49
        }
        .onChange(of: globalSearchSortRule) { _ in scheduleGlobalSearchRecompute(debounced: false) }
        // P2-5 (v2.10.6) + P2-28 (v2.10.9): 全局搜索缓存此前只在搜索输入变化时失效，底层
        // 槽位内容（热键/后台同步改动）变化时结果保持陈旧。原实现用
        // `store.slots.mapValues { ... }` 在每次 body 求值都新建 [Int:String]，开销随槽位数增长。
        // 现改为观察 store 上预先计算好的 @Published 派生签名（slotsContentSignature），
        // 仅在 slots 真正变化时重算一次。
        .onChange(of: store.slotsContentSignature) { _ in
            scheduleGlobalSearchRecompute(debounced: false)
            recomputeMatchedSlotCount()  // v2.10.49: 槽位内容变化时同步刷新匹配计数缓存
        }
        // v2.10.49: 首次出现时初始化匹配计数缓存，避免进入即处于搜索态时读到 0 的短暂错值。
        .onAppear {
            recomputeMatchedSlotCount()
        }
        // P2-26 (v2.10.9): 视图消失时取消尚未触发的搜索防抖 work item，避免其在视图销毁后再触发。
        .onDisappear {
            searchDebounce.cancel()
        }
    }

    // Layer 1: Title + Stats + Settings
    private var titleBar: some View {
        HStack(spacing: 14) {
            // The edge clusters keep their intrinsic sizes and stay pinned to the title-bar edges.
            HStack(spacing: 14) {
                ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.brandGradient(colorScheme))
                    .frame(width: 44, height: 44)
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)

                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ClipSlots")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Button {
                    updateChecker.checkForUpdates()
                    } label: {
                        HStack(spacing: 5) {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(updateChecker.isChecking ? "检查中…" : "检查更新")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.borderless)
                    .disabled(updateChecker.isChecking)
                    .help("检查是否有新版本")
            }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            LeverClusterView(store: store, autoMode: autoMode)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            // v2.10.78: 唯一撑开用 Spacer 前移到搜索框之前，把 400pt 搜索框推到右侧、
            // 紧挨右侧图标簇；左侧（logo/拨杆簇与搜索框之间）留白。
            Spacer(minLength: 0)

            SlotSearchBar(
                searchText: $searchText,
                selectedFilter: $selectedFilter,
                searchScope: $searchScope
            )
            // v2.10.77: 搜索框此前 maxWidth: .infinity 会横向铺满整行，观感过长。改为
            // 固定上限宽度 400pt。用固定上限而非随窗口宽度变化的比例值，配合 v2.10.75
            // resize 冻结，resize 时宽度稳定。
            .frame(minWidth: 0, idealWidth: 400, maxWidth: 400)
            .layoutPriority(0)

            HStack(spacing: 8) {
                Button {
                cycleAppearanceMode()
            } label: {
                Image(systemName: (ThemeMode(rawValue: appearanceModeRaw) ?? .system).icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("外观：\((ThemeMode(rawValue: appearanceModeRaw) ?? .system).title)，点击切换")

            // v2.9.8: 插件入口（月亮与键盘图标之间）
            Button {
                showingPlugins = true
            } label: {
                // v2.9.23: 干净简洁的主题色拼图图标（去掉层次渲染灰色锯齿与红点通知），
                // 与相邻工具栏图标（外观/键盘）保持一致的样式。
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("插件")
            .popover(isPresented: $showingPlugins) {
                PluginsView {
                    showingPlugins = false
                }
            }

            Button {
                showingHotkeyTemplatePopover = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("快捷键模板：\(store.config.hotkeyTemplate.kind.title)")
            .popover(isPresented: $showingHotkeyTemplatePopover) {
                HotkeyTemplatePopover(
                    config: store.config,
                    onSave: { newConfig in
                        store.updateConfig(newConfig)
                        showingHotkeyTemplatePopover = false
                    }
                )
                .frame(width: 360)
            }

            // v2.9.12: settings now open as an in-app overlay (Obsidian-style),
            // embedded in the main window so it follows the window when dragged.
            Button {
                withAnimation(Anim.status) { showingSettings = true }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("设置")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .frame(maxWidth: .infinity)
    }

    // Layer 2: Page Selector + Actions
    private var actionBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                showingPageSelector.toggle()
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(width: 25, height: 25)
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    Text(store.currentPage?.name ?? "默认页面")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(store.currentPageSlotGroups.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.primary)
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.13), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $showingPageSelector, arrowEdge: .bottom) {
                pageSelectorPopover
            }

            Spacer(minLength: 8)

            AutoAdvanceToggleView(autoMode: autoMode)

            toolbarActions
        }
        .frame(minHeight: 36, alignment: .center)
    }

    private var pageSelectorPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.88))
                        .frame(width: 30, height: 30)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                }
                Text("页面导航")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    showingPageSelector = false
                    promptCreatePage()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("新建页面")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.pages) { page in
                        let isCurrentPage = page.id == store.currentPageId
                        let isExpanded = expandedPageId == page.id || (expandedPageId == nil && isCurrentPage)
                        let isSelected = selectedPageIds.contains(page.id)
                        let pageGroups = store.specialSlots.filter { $0.pageId == page.id }

                        Button {
                            if isPageMultiSelecting {
                                if isSelected {
                                    selectedPageIds.remove(page.id)
                                } else {
                                    selectedPageIds.insert(page.id)
                                }
                            } else if isExpanded {
                                withAnimation(Anim.status) {
                                    expandedPageId = ""
                                }
                            } else {
                                store.switchToPage(id: page.id)
                                withAnimation(Anim.status) {
                                    expandedPageId = page.id
                                }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: isCurrentPage ? "folder.fill" : "folder")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 18)
                                Text(page.name)
                                    .font(.system(size: 12, weight: isCurrentPage ? .semibold : .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(pageGroups.count)")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                                if isPageMultiSelecting {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                } else {
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isCurrentPage ? Color.primary.opacity(0.075) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PageNavigationButtonStyle())

                        if isExpanded && !isPageMultiSelecting {
                            VStack(spacing: 2) {
                                ForEach(pageGroups) { group in
                                    let isCurrentGroup = group.id == store.currentSpecialSlotId
                                    Button {
                                        store.switchSpecialSlot(id: group.id)
                                        showingPageSelector = false
                                    } label: {
                                        HStack(spacing: 8) {
                                            Rectangle()
                                                .fill(isCurrentGroup ? Color.accentColor : Color.primary.opacity(0.10))
                                                .frame(width: 1, height: 24)
                                            Text(group.name)
                                                .font(.system(size: 11, weight: isCurrentGroup ? .semibold : .regular))
                                                .lineLimit(1)
                                            Spacer()
                                            if isCurrentGroup {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 8, weight: .bold))
                                            }
                                        }
                                        .foregroundColor(isCurrentGroup ? .primary : .secondary)
                                        .padding(.leading, 23)
                                        .padding(.trailing, 11)
                                        .frame(height: 31)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(isCurrentGroup ? Color.primary.opacity(0.07) : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 300)

            Divider()

            HStack(spacing: 10) {
                if isPageMultiSelecting {
                    Button(role: .destructive) {
                        let pageIds = selectedPageIds
                        for pageId in pageIds {
                            store.deletePage(id: pageId)
                        }
                        selectedPageIds.removeAll()
                        withAnimation(Anim.interactive) {
                            isPageMultiSelecting = false
                        }
                    } label: {
                        Label("删除 \(selectedPageIds.count)", systemImage: "trash")
                    }
                    .disabled(selectedPageIds.isEmpty)

                    Button {
                        selectedPageIds.removeAll()
                        withAnimation(Anim.interactive) {
                            isPageMultiSelecting = false
                        }
                    } label: {
                        Text("取消")
                    }
                } else {
                    if store.pages.count > 1, let page = store.currentPage {
                        Button {
                            showingPageSelector = false
                            promptRenamePage(id: page.id, currentName: page.name)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showingPageSelector = false
                            confirmDeletePage(id: page.id, name: page.name)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }

                    Button {
                        selectedPageIds.removeAll()
                        withAnimation(Anim.interactive) {
                            isPageMultiSelecting = true
                        }
                    } label: {
                        Label("多选", systemImage: "checkmark.circle")
                    }
                }

                Spacer()

                Button {
                    showingPageSelector = false
                    isPageMultiSelecting = false
                    selectedPageIds.removeAll()
                } label: {
                    Text("完成")
                        .fontWeight(.semibold)
                }
            }
            .font(.system(size: 10.5))
            .buttonStyle(.borderless)
            .padding(.horizontal, 11)
            .padding(.bottom, 9)
        }
        .frame(width: 252)
    }

    // v2.10.79 (改动A 观察下沉): 原 `autoAdvanceToggle` / `leverCluster` 及其私有辅助
    // `leverWithCursorControls` / `cursorControlButton` 已迁至独立子视图
    // AutoAdvanceToggleView / LeverClusterView（见 LeverClusterView.swift），由它们各自
    // @ObservedObject 局部观察 autoMode，使拨杆翻动不再触发整棵 ContentView.body 重求值。

    // v2.7.39: keep the top-right action group vertically centered and easier to hit.
    // The previous system Button styles had inconsistent intrinsic heights, making the
    // group look stuck to the top of the row.
    private var toolbarActions: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolbarActionButton(
                title: "打包",
                icon: "shippingbox",
                role: .normal,
                prominent: false,
                action: { store.startPackExport() }
            )
            .help("把选中的页面/槽位组打包导出为 .clipslotspack")

            ToolbarActionButton(
                title: "导入",
                icon: "folder.badge.plus",
                role: .normal,
                prominent: false,
                action: { store.startToolbarImport() }
            )
            .help("导入图片/文件夹，或导入槽位包（.clipslotspack）")

            ToolbarActionButton(
                title: "清空",
                icon: "trash",
                role: .destructive,
                prominent: true,
                action: { store.clearAllSlotsInCurrentSpecialSlotWithConfirmation() }
            )
            .help("清空当前槽位组中的全部槽位")
        }
        .frame(height: 36, alignment: .center)
        .padding(.horizontal, 2)
    }

    // v2.9.31: "自动切换" toggle moved to the filter row (see SlotSearchBar, v2.9.33).

    // v2.4: renamed from specialSlotTagBar — shows only current page's slot groups
    private var specialSlotTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.currentPageSlotGroups) { group in
                    let isCurrent = group.id == store.currentSpecialSlotId

                    // v2.10.77: 组切换 tab 加入按压微缩 / hover 高亮 / 选中态平滑过渡，
                    // 交互反馈由 GroupTabButton 内部承载，点击切组语义（switchSpecialSlot）保持不变。
                    GroupTabButton(name: group.name, isCurrent: isCurrent) {
                        store.switchSpecialSlot(id: group.id)
                    }
                    .contextMenu {
                        Button {
                            renameSlotGroup(id: group.id, currentName: group.name)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        if store.currentPageSlotGroups.count > 1 {
                            Button(role: .destructive) {
                                store.deleteSpecialSlotWithConfirmation(id: group.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    store.createQuickSpecialSlot()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(store.currentPageSlotGroups.count >= store.specialSlotSettings.maxSpecialSlots)
                .help(store.currentPageSlotGroups.count >= store.specialSlotSettings.maxSpecialSlots
                      ? "当前页面的槽位组数量已达到上限" : "新建槽位组")

                Button {
                    showingSpecialSlotManagement = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .help("管理槽位组")
            }
        }
    }

    private var activeHotkeyLayerNotice: some View {
        let pageName = store.currentPage?.name ?? "默认页面"
        let groupName = store.currentSpecialSlot?.name ?? "默认槽位组"
        return HStack(spacing: 8) {
            Label("\(pageName) / \(groupName)", systemImage: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            ShortcutBadge(title: "粘贴", shortcut: shortcutDisplay(store.config.pasteKey, slotToken: "数字"), icon: "square.and.arrow.up")
            ShortcutBadge(title: "保存", shortcut: shortcutDisplay(store.config.saveKey, slotToken: "数字"), icon: "square.and.arrow.down")
            ShortcutBadge(title: "圆盘", shortcut: shortcutDisplay(store.config.radialKey), icon: "circle.grid.cross")
            ShortcutBadge(title: "切组", shortcut: "⌘ ← / ⌘ →", icon: "arrow.left.arrow.right")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .id("\(store.config.saveKey)|\(store.config.pasteKey)|\(store.config.radialKey)|\(store.config.hotkeyTemplate.kind.rawValue)")
    }

    // P2-4: run NSAlert without blocking the SwiftUI runloop; sheet on the key window, modal fallback.
    private func runAlertNonBlocking(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // P2 (v2.10.13): 全程使用 beginSheetModal 异步展示，去除同步 runModal 回退——同步
        // runModal 会进入嵌套 runloop，与自动更新/自动模式等其它 modal 叠加时造成卡顿/重入。
        // 宿主窗口若已有 sheet，改把新 alert 挂到该 sheet 窗口上（sheet 可再挂 sheet），
        // 而不是退回 runModal。极端情况下进程内无任何窗口时，创建一个临时不可见宿主窗口承载
        // sheet，仍以异步方式呈现，绝不进入同步 runModal。
        func focusAccessory() {
            if let field = alert.accessoryView {
                alert.layout()
                alert.window.makeFirstResponder(field)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            // 若窗口已有 sheet，挂到该 sheet 窗口上，避免与其冲突或回退到 runModal。
            let target = window.attachedSheet ?? window
            alert.beginSheetModal(for: target) { completion($0) }
            focusAccessory()
        } else {
            // 进程内无任何可用窗口：创建临时不可见宿主窗口承载 sheet，异步呈现后释放。
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.alphaValue = 0
            host.center()
            host.orderFront(nil)
            focusAccessory()
            alert.beginSheetModal(for: host) { resp in
                completion(resp)
                host.orderOut(nil)
            }
        }
    }

    // v2.4: renamed from renameSpecialSlot
    private func renameSlotGroup(id: String, currentName: String) {
        let alert = NSAlert()
        alert.messageText = "重命名槽位组"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        textField.placeholderString = "输入新名称"
        alert.accessoryView = textField

        // P2-4: non-blocking sheet instead of runModal.
        runAlertNonBlocking(alert) { response in
            if response == .alertFirstButtonReturn {
                let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    store.renameSpecialSlot(id: id, name: newName)
                }
            }
        }
    }

    // MARK: - Page Dialog Helpers (v2.4)

    private func promptCreatePage() {
        let alert = NSAlert()
        alert.messageText = "新建页面"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "输入页面名称"
        alert.accessoryView = textField

        // P2-4: non-blocking sheet instead of runModal.
        runAlertNonBlocking(alert) { response in
            if response == .alertFirstButtonReturn {
                let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    store.createPage(name: name)
                }
            }
        }
    }

    private func promptRenamePage(id: String, currentName: String) {
        let alert = NSAlert()
        alert.messageText = "重命名页面"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        textField.placeholderString = "输入新名称"
        alert.accessoryView = textField

        // P2-4: non-blocking sheet instead of runModal.
        runAlertNonBlocking(alert) { response in
            if response == .alertFirstButtonReturn {
                let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    store.renamePage(id: id, name: newName)
                }
            }
        }
    }

    private func confirmDeletePage(id: String, name: String) {
        // v2.10.47: 回退 v2.10.46 的 inline 确认卡（负优化）——恢复系统 NSAlert（非阻塞 sheet）。
        let alert = NSAlert()
        alert.messageText = "删除页面？"
        alert.informativeText = "将删除页面「\(name)」及其下所有槽位组和槽位内容。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        // P2-4: non-blocking sheet instead of runModal.
        runAlertNonBlocking(alert) { response in
            if response == .alertFirstButtonReturn {
                store.deletePage(id: id)
            }
        }
    }

    private func humanReadableShortcut(_ template: String) -> String {
        shortcutDisplay(template, slotToken: "数字")
    }

    private func shortcutDisplay(_ template: String, slotToken: String = "") -> String {
        let rawParts = template
            .replacingOccurrences(of: "{n}", with: slotToken)
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let mapped = rawParts.map { part -> String in
            switch part {
            case "cmd", "command", "⌘": return "⌘"
            case "ctrl", "control", "⌃": return "⌃"
            case "option", "opt", "alt", "⌥": return "⌥"
            case "shift", "⇧": return "⇧"
            case "space", "spacebar": return "Space"
            case "left", "arrowleft", "←": return "←"
            case "right", "arrowright", "→": return "→"
            case "up", "arrowup", "↑": return "↑"
            case "down", "arrowdown", "↓": return "↓"
            default: return part.uppercased()
            }
        }
        return mapped.joined(separator: " ")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // v2.7.37: keep the shortcut hint only in the bottom bar, because it is compact
            // and leaves the top content area to the slot grid.
            ShortcutBadge(title: "保存", shortcut: shortcutDisplay(store.config.saveKey, slotToken: "数字"), icon: "square.and.arrow.down")
            ShortcutBadge(title: "粘贴", shortcut: shortcutDisplay(store.config.pasteKey, slotToken: "数字"), icon: "square.and.arrow.up")
            ShortcutBadge(title: "圆盘", shortcut: shortcutDisplay(store.config.radialKey), icon: "circle.grid.cross")
            ShortcutBadge(title: "切组", shortcut: "⌘ ← / ⌘ →", icon: "arrow.left.arrow.right")

            // v2.9.36: persistent "上次粘贴" status, styled subtly so it never
            // competes with the shortcut chips for attention.
            lastPasteStatusView

            Spacer()

            Text("v\(AppVersion.current)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundColor(Color.secondary.opacity(0.55))
                .fixedSize()
                .help("当前版本 v\(AppVersion.current)\n首次打开 ClipSlots.app 时，macOS 可能提示“无法验证开发者”，请右键点击 App → 选择「打开」→ 点击「打开」确认即可。")

            // Connection stays as a separate tool and is moved to the right side.
            // v2.9.24: 当「槽位连接」开关关闭时，底部「连接」入口按钮彻底隐藏（不占位）。
            if store.isSlotConnectionEnabled {
                connectionToolButton
            }
            // v2.9.22: 版本号已迁移到左上角「检查更新」按钮右侧，底部不再重复展示。
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // v2.9.37: footer "上次粘贴" status, redesigned to be low-key (small icon +
    // secondary text, no coloured capsule) so it blends into the footer text.
    // It is now a button: hover gives a subtle highlight, click jumps + scrolls to
    // the last-paste group and flashes the corresponding card for 2s.
    private var lastPasteStatusView: some View {
        Button {
            store.jumpToLastPaste()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.forward.circle")
                    .font(.system(size: 11, weight: .semibold))
                if let desc = store.lastPasteDescription {
                    Text("上次粘贴 ")
                    + Text(desc)
                        .foregroundColor(lastPasteHovering ? .primary : .secondary)
                } else {
                    Text("上次粘贴 —")
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundColor(lastPasteHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lastPasteHovering ? AppTheme.chipBackground(colorScheme) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.lastPasteDescription == nil)
        .onHover { hovering in
            // Only highlight when the button is actionable (there is a location).
            lastPasteHovering = hovering && store.lastPasteDescription != nil
        }
        .animation(Anim.interactive, value: lastPasteHovering)
        .help(store.lastPasteDescription.map { "点击跳转到上次粘贴位置：\($0)" } ?? "尚未粘贴过任何槽位")
    }

    // v2.7.9: prominent connection button with current-group state.
    // v2.7.36: standalone connection button, not mixed with shortcut chips.
    private var connectionToolButton: some View {
        Button {
            showingConnectionFullscreen = true
        } label: {
            connectionMenuLabel
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var connectionMenuLabel: some View {
        let edgeCount = store.currentConnectionMap.edges.count
        let hasConnections = edgeCount > 0
        // v2.9.22: 「连接」按钮升级——更贴切的节点连线图标 + 渐变胶囊 + 描边/投影，
        // 提升质感并与整体设计语言统一；有连接时用强调色渐变，无连接时用中性玻璃底。
        return HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .bold))
                .symbolRenderingMode(.hierarchical)
            Text(hasConnections ? "连接 · \(edgeCount)" : "连接")
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(hasConnections ? .white : .accentColor)
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(
                    hasConnections
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.accentColor.opacity(0.10))
                )
        )
        .overlay(
            Capsule().stroke(
                hasConnections ? Color.white.opacity(0.35) : Color.accentColor.opacity(0.35),
                lineWidth: 1)
        )
        .shadow(
            color: hasConnections ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.06),
            radius: hasConnections ? 6 : 2, x: 0, y: hasConnections ? 2 : 1)
        .scaleEffect(hasConnections ? 1.02 : 1.0)
        .animation(Anim.transition, value: edgeCount)
        .help(hasConnections ? "当前槽位组已有 \(edgeCount) 条连接" : "打开节点连接工具")
    }

    private func keyChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
    }

    private func shortcutPreview(_ template: String, slot: Int) -> String {
        let token = store.config.hotkeyTemplate.keyToken(for: slot) ?? "\(slot)"
        return template.replacingOccurrences(of: "{n}", with: token)
    }

    // MARK: - v2.7.0 Connection Mode Bar

    // v2.7.1: connection mode bar disabled — use ConnectionManagementSheet instead.
    private var connectionModeBar: some View {
        EmptyView()
    }

    // MARK: - v2.7.0 Slot Card Helper

    @ViewBuilder
    private func slotCardView(slot: Int) -> some View {
        let content = store.slots[slot] ?? SlotContent()
        let label = store.labels[slot] ?? ""
        let isMatched = slotMatched(slot)

        SlotCardView(
            slot: slot,
            content: content,
            specialSlotId: store.currentSpecialSlotId,
            label: label,
            saveShortcut: shortcutPreview(store.config.saveKey, slot: slot),
            pasteShortcut: shortcutPreview(store.config.pasteKey, slot: slot),
            onPaste: { store.pasteSlotFromUI(slot) },
            onCopy: { store.copySlot(slot) },
            onSave: { store.saveToSlot(slot) },
            onClear: { store.clearSlotWithConfirmation(slot) },
            onSetLabel: { newLabel in store.setLabel(slot, label: newLabel.isEmpty ? nil : newLabel) },
            onEditText: { newText in store.updateTextSlot(slot, text: newText) },
            onEditHTML: { html in store.updateHTMLSlot(slot, html: html) },
            onDropFiles: { urls in store.importDroppedFiles(urls, toSlot: slot) },
            onClearBody: { store.clearSlotBody(slot) },
            isLastPasted: store.isLastPasted(slot: slot, groupId: store.currentSpecialSlotId),
            isFlashHighlighted: store.flashHighlightSlot == FlashHighlightTarget(groupId: store.currentSpecialSlotId, slot: slot),
            store: store,
            connectionDotColor: store.portColor(for: slot),
            isConnectionMode: false,
            connectedPorts: [],
            highlightedPort: nil,
            isPortVisible: false,
            onBeginDrag: nil,
            onUpdateDrag: nil,
            onEndDrag: nil
        )
        // v2.10.76 (Phase 1.2): 让 SwiftUI 用 SlotCardView 的 Equatable 判定跳过未变卡片的 body 求值。
        // 只有 thumbnailKey/label/快捷键/上次粘贴/高亮/连线等视觉输入变化的那张卡片才重算 body。
        .equatable()
        // v2.10.3 (P2): 放左上角，避开右上角的「上次粘贴」角标，避免两者堆叠遮挡。
        .overlay(alignment: .topLeading) { cursorBadges(slot: slot) }
        .opacity(!isSearchActive || isMatched ? 1.0 : 0.22)
        // v2.10.75: resize 期间强制 saturation=1.0，避免 .saturation 滤镜每帧离屏合成拖累帧率；
        // 非 resize 时保持原有搜索未命中降饱和度效果。
        .saturation(liveResize.isResizing ? 1.0 : (!isSearchActive || isMatched ? 1.0 : 0.35))
        .allowsHitTesting(!isSearchActive || isMatched)
    }

    // v2.10.1: 槽位格子右上角叠加游标角标——绿色 = 下一次自动存储写入点，蓝色 = 下一次自动粘贴读取点。
    // 仅在对应拨杆开启且预览命中该槽位时显示；两者可同时出现（并排避免重叠）。
    // v2.10.76 (Phase 1 交互状态下沉): 改为独立的 CursorBadgesView（只观察 store.transientUI + autoMode），
    // 使游标预览变更（recomputeAutoPreviews）只重绘这 10 个极小的角标视图，不再触发整棵 ContentView.body。
    private func cursorBadges(slot: Int) -> some View {
        CursorBadgesView(slot: slot, groupId: store.currentSpecialSlotId, ui: store.transientUI, autoMode: autoMode)
    }

    // MARK: - P2-25 (v2.10.9) 跨组游标提示
    //
    // 写/读游标角标（🟢 写 / 🔵 读）只画在「当前查看组」的槽位格子上。当自动存储/粘贴游标
    // 已推进到别的组/页（跨组推进场景），当前视图看不到任何角标，用户会困惑。这里在搜索区
    // 下方给出一条轻量的胶囊提示，指明写/读游标实际所在的页/组/槽位。

    // v2.10.76 (Phase 1 交互状态下沉): 跨组游标提示改为独立的 CrossGroupCursorHintView。
    // 它同时观察 store（specialSlots/pages/currentSpecialSlotId 供文案与跳转）与 store.transientUI
    // （游标预览）——预览变更只重绘这条胶囊提示，不再触发整棵 ContentView.body。
    @ViewBuilder
    private var crossGroupCursorHint: some View {
        CrossGroupCursorHintView(store: store, ui: store.transientUI, autoMode: autoMode)
    }

    // MARK: - Search (v2.5.1)

    private var searchResultsSection: some View {
        VStack(spacing: 4) {
            if searchScope == .currentGroup {
                Text(matchedSlotCount == 0
                     ? "组内未找到匹配槽位"
                     : "组内找到 \(matchedSlotCount) 个匹配槽位")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else {
                GlobalSearchResultsView(
                    results: globalSearchResultsCache,
                    currentPageId: store.currentPageId,
                    currentGroupId: store.currentSpecialSlotId,
                    onJump: jumpToSearchResult,
                    sortRule: $globalSearchSortRule
                )
                .padding(.top, 2)
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text("未找到匹配槽位")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("清除搜索") {
                // P2-29 (v2.10.9): 这是显式的「清除搜索」整体动作，语义上清空全部搜索条件，
                // 因此仍同时清文本 + 重置筛选。搜索栏的 × 按钮（SlotSearchBar）才需保留筛选。
                searchText = ""
                selectedFilter = .all
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var isSearchActive: Bool {
        SlotSearchMatcher.isActive(query: searchText, filter: selectedFilter)
    }

    // v2.10.49: 读缓存值，不再在 body 求值时遍历重算。缓存由 recomputeMatchedSlotCount() 维护。
    private var matchedSlotCount: Int {
        matchedSlotCountCache
    }

    // v2.10.49: 实际遍历本组槽位计算匹配数；仅由输入/内容变化的 onChange 与 onAppear 触发。
    private func computeMatchedSlotCount() -> Int {
        stride(from: 1, through: store.config.slots, by: 1).filter { slotMatched($0) }.count
    }

    // v2.10.49: 重算并写回缓存。非搜索激活态直接归零，省去无谓遍历。仅在值变化时写 @State。
    private func recomputeMatchedSlotCount() {
        let newValue = isSearchActive ? computeMatchedSlotCount() : 0
        if matchedSlotCountCache != newValue {
            matchedSlotCountCache = newValue
        }
    }

    private func slotMatched(_ slot: Int) -> Bool {
        let content = store.slots[slot] ?? SlotContent()
        let label = store.labels[slot] ?? ""
        return SlotSearchMatcher.matches(
            slot: slot,
            content: content,
            label: label,
            query: searchText,
            filter: selectedFilter
        )
    }

    // MARK: - Global Search (v2.5.1)

    /// v2.8.0 (perf M1/M2): recompute the debounced/cached global search results.
    /// Called only when a search input actually changes (text, filter, scope, sort),
    /// not on every view re-render. Text changes are debounced by the caller.
    /// v2.8.7 (F): the cross-page scan (`allSearchableSlots()` reads every group's disk
    /// snapshot) used to run synchronously on the main thread, causing typing lag on
    /// large libraries. It now runs off the main thread; results are applied back on the
    /// main thread and only if the search inputs are still current (stale-query guard).
    private func recomputeGlobalSearchResults(overrideQuery: String? = nil, overrideFilter: SlotFilterType? = nil) {
        // Capture the current inputs on the main thread.
        // P2-8 (v2.10.6): 优先使用调度时刻显式捕获并传入的值（overrideQuery/overrideFilter），
        // 避免防抖 work item 通过被捕获的 ContentView struct 拷贝读到陈旧的 searchText/selectedFilter。
        let query = overrideQuery ?? searchText
        let filter = overrideFilter ?? selectedFilter
        let scope = searchScope
        let sortRule = globalSearchSortRule

        let store = self.store
        // P2-4 (v2.10.6): 将 generation 自增与令牌捕获上移到最前（早返回之前）。
        // 此前搜索失活（清空搜索框）走下面 guard 的早返回，不自增 generation，
        // 已派发的后台搜索完成后会通过陈旧校验、把旧结果写回已清空的缓存（“回魂”）。
        // 现在任何一次重算入口都会作废在途搜索。
        store.globalSearchGeneration += 1
        let searchToken = store.globalSearchGeneration

        guard scope == .global, SlotSearchMatcher.isActive(query: query, filter: filter) else {
            globalSearchResultsCache = []
            return
        }

        let currentPageId = store.currentPageId
        let currentSpecialSlotId = store.currentSpecialSlotId

        // P2-9 (v2.10.5): 在主线程先快照可搜索槽位集合。`pages` / `specialSlots` 只在主线程被
        // 修改，直接在后台遍历是真实数据竞争。
        // P0-1 (v2.10.38): 只在主线程捕获「轻量的分组引用」（页/组元数据 + 各组 SlotStorage 句柄），
        // 把真正繁重的逐槽展开（snapshot + getLabel，此前会逐槽抢 flock 同步读 label.txt 钉死主线程）
        // 连同 filter + sort 一起移到后台队列。大库全局搜索不再卡主线程。
        let groupRefs = store.searchableGroupsSnapshot()

        DispatchQueue.global(qos: .userInitiated).async {
            // Heavy per-slot expansion + cross-page filter + sort all run off the main thread.
            let all = SlotStoreObservable.expandSearchableSlots(groupRefs)
            let results = ContentView.filterAndSortGlobalSearch(
                all: all,
                query: query,
                filter: filter,
                sortRule: sortRule,
                currentPageId: currentPageId,
                currentSpecialSlotId: currentSpecialSlotId
            )
            DispatchQueue.main.async {
                // Stale-query guard: only apply if no newer recompute was scheduled.
                guard store.globalSearchGeneration == searchToken else { return }   // P1-4
                // P2-7 (v2.10.6): 智能排序在后台搜索开始时捕获了当时的当前页/组，
                // 搜索运行期间若用户切页/切组，排序上下文已过时。此处在主线程完成回调里
                // 重新捕获最新的当前页/组并按新上下文重排，保证渲染顺序正确。
                let freshPageId = store.currentPageId
                let freshSpecialSlotId = store.currentSpecialSlotId
                // PERF-6 (v2.10.84): 仅在「排序上下文真的变了」时才在主线程重排。
                // 后台已按 (currentPageId, currentSpecialSlotId) 排好序；只有当用户在搜索运行期间
                // 切了页/组，那份顺序才会过时。而这是**罕见**情况——绝大多数搜索里用户只是打字，
                // 上下文自始至终没变，此时主线程那次 sortGlobalSearch 是纯粹重复劳动：它会对整个
                // 结果集再跑一遍比较器（nameAscending/nameDescending 用的还是相对昂贵的
                // localizedStandardCompare），大库下正是「输入最后一个字符后界面顿一下」的来源。
                // 上下文未变时直接复用后台结果，语义完全等价（同输入、同比较器 → 同顺序）。
                let contextChanged = freshPageId != currentPageId
                    || freshSpecialSlotId != currentSpecialSlotId
                // P2 (#9, v2.10.7): 只重排、不重复过滤（results 已在后台过滤完毕），
                // 避免大结果集在主线程再跑一遍 filter 造成卡顿。
                let reordered = contextChanged
                    ? ContentView.sortGlobalSearch(
                        results,
                        sortRule: sortRule,
                        currentPageId: freshPageId,
                        currentSpecialSlotId: freshSpecialSlotId
                    )
                    : results
                self.globalSearchResultsCache = reordered
            }
        }
    }

    /// Schedule a global-search recompute. Keystroke-driven changes are debounced so
    /// the cross-page scan runs once after the user pauses typing; structural changes
    /// (filter/scope/sort) recompute immediately.
    private func scheduleGlobalSearchRecompute(debounced: Bool) {
        searchDebounce.cancel()

        guard searchScope == .global, isSearchActive else {
            store.globalSearchGeneration += 1   // P1-4 (v2.10.7): 作废在途后台搜索，防止清空后旧结果回魂
            globalSearchResultsCache = []
            return
        }

        if debounced {
            // P2 (v2.10.13): 去抖闭包不再在「调度时刻」冻结 searchText/selectedFilter 快照。
            // 此前显式捕获局部值会把输入定格在调度瞬间——用户在 0.2s 去抖窗口内切换范围/筛选/
            // 排序后，实际执行仍用旧快照，结果与当前筛选不符。@State 读取会穿透到底层持久存储，
            // 故让闭包在「触发时刻」调用无参 recomputeGlobalSearchResults()，由它重新读取当前
            // query/scope/filter/sortRule。
            let work = DispatchWorkItem {
                recomputeGlobalSearchResults()
            }
            searchDebounce.workItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            recomputeGlobalSearchResults()
        }
    }

    /// Pure filter + sort over an already-collected slot list. Static so it can run on a
    /// background thread without touching `@State`/view state (v2.8.7 F).
    private static func filterAndSortGlobalSearch(
        all: [SlotGlobalSearchResult],
        query: String,
        filter: SlotFilterType,
        sortRule: SlotSearchSortRule,
        currentPageId: String,
        currentSpecialSlotId: String
    ) -> [SlotGlobalSearchResult] {
        let filtered = all
            .filter { result in
                SlotSearchMatcher.matches(
                    slot: result.slot,
                    content: result.content,
                    label: result.label,
                    query: query,
                    filter: filter
                )
            }
        // P2 (#9, v2.10.7): 过滤后交给 sortGlobalSearch 排序；主线程完成回调可直接复用
        // sortGlobalSearch 重排而无需重复过滤，避免大结果集在主线程二次过滤造成卡顿。
        return ContentView.sortGlobalSearch(
            filtered,
            sortRule: sortRule,
            currentPageId: currentPageId,
            currentSpecialSlotId: currentSpecialSlotId
        )
    }

    /// P2 (#9, v2.10.7): 仅排序（不重复过滤）。后台队列已完成过滤，主线程完成回调只需
    /// 按最新的当前页/组上下文重排即可，避免对大结果集在主线程重复执行 filter。
    private static func sortGlobalSearch(
        _ filtered: [SlotGlobalSearchResult],
        sortRule: SlotSearchSortRule,
        currentPageId: String,
        currentSpecialSlotId: String
    ) -> [SlotGlobalSearchResult] {
        switch sortRule {
        case .smart:
            return filtered.sorted { lhs, rhs in
                let lhsCurrentPage = lhs.pageId == currentPageId
                let rhsCurrentPage = rhs.pageId == currentPageId
                if lhsCurrentPage != rhsCurrentPage { return lhsCurrentPage }
                let lhsCurrentGroup = lhs.groupId == currentSpecialSlotId
                let rhsCurrentGroup = rhs.groupId == currentSpecialSlotId
                if lhsCurrentGroup != rhsCurrentGroup { return lhsCurrentGroup }
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.slot < rhs.slot
            }
        case .slotOrder:
            return filtered.sorted { lhs, rhs in
                if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                return lhs.groupOrder < rhs.groupOrder
            }
        case .nameAscending:
            return filtered.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
        case .nameDescending:
            return filtered.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedDescending
            }
        case .typeOrder:
            return filtered.sorted { lhs, rhs in
                if lhs.contentTypeOrder != rhs.contentTypeOrder {
                    return lhs.contentTypeOrder < rhs.contentTypeOrder
                }
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.slot < rhs.slot
            }
        case .pageGroupSlot:
            return filtered.sorted { lhs, rhs in
                if lhs.pageOrder != rhs.pageOrder { return lhs.pageOrder < rhs.pageOrder }
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.slot < rhs.slot
            }
        }
    }

    private func jumpToSearchResult(_ result: SlotGlobalSearchResult) {
        store.switchToPage(id: result.pageId)
        store.switchSpecialSlot(id: result.groupId)
        searchScope = .currentGroup
    }
}

// MARK: - v2.7.21 Shortcut Badge

private struct ShortcutBadge: View {
    let title: String
    let shortcut: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(shortcut)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.14), lineWidth: 0.7))
    }
}

// MARK: - v2.7.39 Toolbar Action Button

private struct ToolbarActionButton: View {
    enum Role {
        case normal
        case accent
        case destructive
    }

    let title: String
    let icon: String
    let role: Role
    let prominent: Bool
    let action: () -> Void
    @State private var isHovering = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(minWidth: minWidth, minHeight: 30)
            .padding(.horizontal, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(foregroundColor)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: shadowColor, radius: prominent ? 4 : 0, x: 0, y: prominent ? 1 : 0)
        .scaleEffect(isHovering ? 1.035 : 1.0)
        .animation(Anim.interactive, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var minWidth: CGFloat {
        switch role {
        case .normal: return 70
        case .accent: return 92
        case .destructive: return 66
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .normal:
            return .primary
        case .accent, .destructive:
            return .white
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .normal:
            return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)
        case .accent:
            return Color.accentColor
        case .destructive:
            return Color.red
        }
    }

    private var borderColor: Color {
        switch role {
        case .normal:
            return Color.secondary.opacity(0.16)
        case .accent:
            return Color.white.opacity(0.22)
        case .destructive:
            return Color.white.opacity(0.20)
        }
    }

    private var shadowColor: Color {
        switch role {
        case .normal:
            return .clear
        case .accent:
            return Color.accentColor.opacity(0.20)
        case .destructive:
            return Color.red.opacity(0.18)
        }
    }
}

// MARK: - Hotkey Template Popover

struct HotkeyTemplatePopover: View {
    let config: AppConfig
    var onSave: (AppConfig) -> Void

    @State private var kind: HotkeyTemplateKind
    @State private var customKeys: [String]

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _kind = State(initialValue: config.hotkeyTemplate.kind)
        _customKeys = State(initialValue: config.hotkeyTemplate.customKeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷键模板")
                .font(.headline)

            Picker("模板", selection: $kind) {
                ForEach(HotkeyTemplateKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }
            .pickerStyle(.segmented)

            templatePreview

            if kind == .custom {
                customKeyGrid
            }

            Divider()

            HStack {
                Spacer()
                Button("应用") {
                    var newConfig = config
                    newConfig.hotkeyTemplate.kind = kind
                    newConfig.hotkeyTemplate.customKeys = customKeys
                    newConfig.save()
                    onSave(newConfig)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var templatePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("槽位映射")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(1...10, id: \.self) { slot in
                    let key = currentTemplate.keyToken(for: slot) ?? "-"
                    VStack(spacing: 2) {
                        Text("槽 \(slot)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(key.uppercased())
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private var currentTemplate: HotkeyTemplate {
        HotkeyTemplate(kind: kind, customKeys: customKeys)
    }

    private var customKeyGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
            ForEach(0..<10, id: \.self) { index in
                HStack {
                    Text("槽 \(index + 1)")
                        .font(.caption)
                    TextField("", text: Binding(
                        get: { customKeys.indices.contains(index) ? customKeys[index] : "" },
                        set: { v in
                            let trimmed = String(v.prefix(1)).lowercased()
                            guard customKeys.indices.contains(index) else { return }
                            customKeys[index] = trimmed
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                }
            }
        }
    }
}

// MARK: - v2.7.0 Slot Frame Preference Key

struct SlotFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - v2.10.76 (Phase 1 交互状态下沉) 只观察 TransientUIStore 的游标提示子视图
//
// 这两个视图承接原先写在 ContentView.body 里、直接读取主 store 游标预览的两处 UI。迁到独立视图后，
// 它们各自持有 @ObservedObject 观察 store.transientUI（游标预览）+ autoMode（拨杆开关）；游标预览的
// 高频重算（recomputeAutoPreviews）只重绘这些小视图，不再触发整棵 ContentView.body 与 10 张卡片重算。
// 视觉与交互（角标颜色/位置/help、跨组胶囊文案/跳转/磨砂玻璃样式）与迁移前逐像素一致。

/// 槽位格子右上角的写/读游标角标（🟢 写 / 🔵 读）。
private struct CursorBadgesView: View {
    let slot: Int
    let groupId: String
    @ObservedObject var ui: TransientUIStore
    @ObservedObject var autoMode: AutoModeState

    var body: some View {
        let addr = SlotAddress(groupId: groupId, slot: slot)
        let showWrite = autoMode.autoStoreEnabled && ui.autoStorePreview == addr
        let showRead = autoMode.autoPasteEnabled && ui.autoPastePreview == addr
        if showWrite || showRead {
            HStack(spacing: 3) {
                if showWrite {
                    cursorDot(color: .green)
                        .help("下一次 Opt+1 自动存储会写这里")
                }
                if showRead {
                    cursorDot(color: .blue)
                        .help("下一次 Cmd+1 自动粘贴会读这里")
                }
            }
            .padding(7)
        }
    }

    private func cursorDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: color.opacity(0.55), radius: 2)
    }
}

/// 标题栏第二行的「写/读游标在其他组」跨组提示胶囊。
private struct CrossGroupCursorHintView: View {
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var ui: TransientUIStore
    @ObservedObject var autoMode: AutoModeState

    /// 若地址指向的组不是当前查看组，返回「页 / 组 · 槽位 N」描述；否则返回 nil（当前组已有角标）。
    private func crossGroupCursorLabel(_ addr: SlotAddress?) -> String? {
        guard let addr,
              addr.groupId != store.currentSpecialSlotId,
              let group = store.specialSlots.first(where: { $0.id == addr.groupId }) else {
            return nil
        }
        let pageName = store.pages.first(where: { $0.id == group.pageId })?.name
        let pagePart = pageName.map { "\($0) / " } ?? ""
        return "\(pagePart)\(group.name) · 槽位 \(addr.slot)"
    }

    @ViewBuilder
    var body: some View {
        let writeHint = autoMode.autoStoreEnabled ? crossGroupCursorLabel(ui.autoStorePreview) : nil
        let readHint = autoMode.autoPasteEnabled ? crossGroupCursorLabel(ui.autoPastePreview) : nil
        if writeHint != nil || readHint != nil {
            HStack(spacing: 12) {
                if let writeHint, let addr = ui.autoStorePreview {
                    Button {
                        store.jumpToCursorAddress(addr)
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text("写游标在其他组：\(writeHint)")
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击跳转到写游标所在槽位")
                }
                if let readHint, let addr = ui.autoPastePreview {
                    Button {
                        store.jumpToCursorAddress(addr)
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color.blue).frame(width: 7, height: 7)
                            Text("读游标在其他组：\(readHint)")
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击跳转到读游标所在槽位")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // v2.10.22: 胶囊改用中高强度磨砂玻璃（.thickMaterial），背景半透明但内容不可辨认、
            // 只透出色彩基调，观感对齐系统 Popover / 「快捷键模板」弹窗的毛玻璃质感。
            .background(
                Capsule()
                    .fill(.thickMaterial)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }
}

// MARK: - v2.7.43 Always-on Poster Ambient Background

private struct RetroPosterAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    // v2.10.80: 直接观察 App 自有主题（顶部太阳/月亮切换写入的 @AppStorage("appearanceMode")）。
    // 背景配色的真实驱动是它（经 App 根部 .preferredColorScheme 生效），而非派生的
    // @Environment(\.colorScheme)——后者在 .background 内嵌子视图里传播到本视图可能滞后，
    // 正是 v2.10.76 栅格缓存切主题不刷新的根因之一。
    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.dark.rawValue
    // v2.10.70: 拖拽 live-resize 期间为 true——只画纯色底，跳过 4 层超大高斯模糊 + grain + drawingGroup，
    // 避免整窗离屏缓冲每帧按新尺寸重新栅格化造成掉帧；拖拽结束恢复完整海报背景。
    var simplified: Bool = false

    // v2.10.81: 彻底移除 v2.10.76 的 ImageRenderer 静态栅格快照（raster/@State + cacheKey/quantize +
    // rebuildRasterIfNeeded 全部删除）。根因：ImageRenderer 离屏位图 + drawingGroup 的 Metal 纹理会
    // 卡在旧 appearance，视图 identity 不变就不刷新——切主题时缓存键虽已含新 scheme，但快照/纹理不重建，
    // 背景卡旧色直到 resize 被动纠正。改回「非 resize 常态实时渲染 fullBackground + drawingGroup 维持
    // 低开销」，并对该层加 .id(effectiveScheme) 破除身份缓存，切主题即时重建拿到新配色。
    // resize 期间仍保留 v2.10.75/70 的 simplified 纯色降级（不画多层模糊、不触发离屏）。

    // v2.10.80: 真实驱动背景配色的主题。显式模式(dark/light)直接取用——与太阳/月亮切换、Settings
    // Picker 同步，不依赖 @Environment(\.colorScheme) 在本子视图里的延迟传播；system 模式回落到环境
    // colorScheme（跟随系统外观）。口径与 FloatingNoticeWindowController 的 effectiveColorScheme 一致。
    private var effectiveScheme: ColorScheme {
        (ThemeMode(rawValue: appearanceModeRaw) ?? .system).preferredColorScheme ?? colorScheme
    }

    var body: some View {
        if simplified {
            // v2.10.75/70: live-resize 期间只画纯色底，跳过 4 层超大高斯模糊 + grain + drawingGroup，
            // 避免整窗离屏缓冲每帧按新尺寸重合成造成掉帧。
            AppTheme.windowBackground(effectiveScheme)
        } else {
            // v2.10.81: 实时海报渲染（drawingGroup 仍在，维持非 resize 常态低开销）。.id(effectiveScheme)
            // 使切主题时该子树获得新身份、强制重建 drawingGroup 的 GPU 纹理，即时呈现新主题配色。
            fullBackground(scheme: effectiveScheme)
                .id(effectiveScheme)
        }
    }

    /// 海报层叠内容（不含 drawingGroup）。按显式 scheme 参数取色，避免依赖可能滞后的 self.colorScheme。
    private func posterLayers(scheme: ColorScheme) -> some View {
        ZStack {
            AppTheme.windowBackground(scheme)

            Circle()
                .fill(scheme == .dark ? Color(red: 0.22, green: 0.27, blue: 0.48).opacity(0.24) : Color(red: 0.70, green: 0.75, blue: 0.88).opacity(0.46))
                .frame(width: 820, height: 820)
                .offset(x: 130, y: -40)
                .blur(radius: 1.5)

            RadialGradient(colors: [Color.red.opacity(scheme == .dark ? 0.28 : 0.22), Color.red.opacity(scheme == .dark ? 0.12 : 0.08), .clear], center: .center, startRadius: 0, endRadius: 460)
                .frame(width: 720, height: 580)
                .offset(x: -470, y: -230)
                .blur(radius: 50)
                .blendMode(.screen)

            RadialGradient(colors: [Color.white.opacity(scheme == .dark ? 0.18 : 0.48), Color.orange.opacity(scheme == .dark ? 0.18 : 0.16), .clear], center: .center, startRadius: 0, endRadius: 520)
                .frame(width: 760, height: 580)
                .offset(x: 560, y: -250)
                .blur(radius: 58)
                .blendMode(.screen)

            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.white.opacity(scheme == .dark ? 0.055 : 0.26), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 130)
                .rotationEffect(.degrees(-2.5))
                .offset(y: -210)
                .blur(radius: 32)
                .blendMode(.screen)

            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.red.opacity(scheme == .dark ? 0.08 : 0.06), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 220)
                .rotationEffect(.degrees(5))
                .offset(y: 110)
                .blur(radius: 58)
                .blendMode(.screen)

            RetroPosterGrain(opacity: scheme == .dark ? 0.060 : 0.050)
        }
    }

    private func fullBackground(scheme: ColorScheme) -> some View {
        // v2.8.4 (perf): flatten the whole poster background (base fill + 4 large
        // blur/`.screen` gradient layers + grain) into ONE offscreen GPU texture.
        // Previously CoreAnimation had to composite ~7 blurred/blended layers every
        // frame while the window resized/zoomed, which contributed to the dropped-frame
        // feel. drawingGroup keeps the identical look (screen blends still composite
        // against the base fill inside the group) but collapses the overdraw into a
        // single Metal pass, off the main thread.
        posterLayers(scheme: scheme)
            .drawingGroup()
    }
}

private struct RetroPosterGrain: View {
    let opacity: Double

    // v2.8.4 (perf): the grain used to be a full-window `Canvas` that ran a nested
    // per-pixel loop (step=3) over the ENTIRE window on EVERY redraw. During live
    // window resize / title-bar double-click zoom this fired dozens of times per
    // second on the main thread (a maximized window = 200k+ fill() calls per frame),
    // stalling the run loop so the frame lagged behind the mouse and dropped frames.
    // The grain is a purely decorative, static noise texture, so we now rasterize a
    // single tile ONCE (cached) and tile it across the window — resize/zoom becomes a
    // near-free bitmap stretch/tile instead of a main-thread pixel loop.
    var body: some View {
        Image(nsImage: RetroPosterGrain.tileImage)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }

    /// Deterministic noise tile, generated exactly once on first access and reused
    /// for the lifetime of the process. Alpha per pixel matches the old formula
    /// (0.35 + value*0.65); the per-theme `opacity` is applied on the Image so one
    /// tile serves both light and dark modes.
    private static let tileImage: NSImage = makeTile(side: 240, step: 3)

    private static func makeTile(side: CGFloat, step: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        var x: CGFloat = 0
        while x <= side {
            var y: CGFloat = 0
            while y <= side {
                let value = abs(sin(Double(x * 12.9898 + y * 78.233)))
                let alpha = 0.35 + value * 0.65
                NSColor(white: 1, alpha: alpha).setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: 1)).fill()
                y += step
            }
            x += step
        }
        image.unlockFocus()
        return image
    }
}

// MARK: - v2.7.40 Fullscreen Connection Mode

private struct ConnectionFullscreenView: View {
    @ObservedObject var store: SlotStoreObservable
    var onClose: () -> Void
    var onOpenNodeCanvas: () -> Void
    var onOpenManager: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.windowBackground(colorScheme),
                    Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.08),
                    AppTheme.windowBackground(colorScheme)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 54, height: 54)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接模式")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("为当前槽位组规划串联路径、模板与批量粘贴顺序")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("完成") { onClose() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 34)
                .padding(.top, 28)

                HStack(spacing: 14) {
                    ConnectionMetricCard(title: "当前连接", value: "\(store.currentConnectionMap.edges.count)", icon: "link.circle.fill")
                    ConnectionMetricCard(title: "槽位数量", value: "\(store.config.slots)", icon: "rectangle.grid.2x2.fill")
                    ConnectionMetricCard(title: "当前组", value: store.currentSpecialSlot?.name ?? "默认", icon: "folder.fill")
                }
                .padding(.horizontal, 34)

                HStack(spacing: 16) {
                    ConnectionFullscreenAction(title: "打开节点画布", subtitle: "可视化拖拽连接槽位", icon: "point.3.connected.trianglepath.dotted", tint: .accentColor, action: onOpenNodeCanvas)
                    ConnectionFullscreenAction(title: "应用全串联模板", subtitle: "一键生成 1→2→3…", icon: "list.number", tint: .orange, action: { store.applyBuiltInFullChainTemplate() })
                }
                .padding(.horizontal, 34)

                Spacer()
            }
        }
    }
}

private struct ConnectionMetricCard: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

private struct ConnectionFullscreenAction: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(tint)
                Text(title).font(.system(size: 17, weight: .bold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(hovering ? 0.45 : 0.18), lineWidth: 1))
            .scaleEffect(hovering ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.interactive, value: hovering)
    }
}

private struct PageNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(Anim.interactive, value: configuration.isPressed)
    }
}
