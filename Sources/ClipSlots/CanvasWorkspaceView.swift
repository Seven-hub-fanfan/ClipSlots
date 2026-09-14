import SwiftUI
import ClipSlotsKit

/// 无限画布工作区（v2.11.7 MVP · 版本 C2 极简浮动）。
///
/// 层级自下而上：网格背景 → 节点层 → 框选矩形 → 浮动 UI（左侧槽位库 / 右上生成 / 底部工具栏 /
/// 缩放控件）→ 拖影。
///
/// **视口状态刻意留在本视图的 `@State`**，不放进 `CanvasStore` 的 `@Published`。缩放平移是每帧
/// 事件，若走 `@Published`，一次捏合会让所有节点视图重新求值几十次。节点只关心自己的画布坐标，
/// 视口变换统一由外层一个 `scaleEffect` + `offset` 施加 —— 这样缩放平移的成本与节点数量无关。
/// 停手后才通过 `canvas.updateViewport` 落盘（内部防抖）。
struct CanvasWorkspaceView: View {
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var canvas: CanvasStore

    /// 画布根坐标空间名。槽位库的拖拽手势也用它上报落点，两边共用一个空间才能对齐坐标。
    static let spaceName = "clipslots.canvas.root"

    // MARK: 视口

    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    /// 平移手势进行中的临时量。手势结束才合并进 `pan`，避免逐帧累加带来的漂移。
    @State private var panGestureDelta: CGSize = .zero
    /// 捏合开始时的 pan / zoom 基准。锚点缩放必须基于「手势开始那一刻」的状态反算，
    /// 否则 `MagnificationGesture` 每帧给的是相对初始的累计比例，用当前 zoom 去乘会指数放大。
    @State private var pinchBasePan: CGSize? = nil
    @State private var pinchBaseZoom: CGFloat = 1

    // MARK: 交互

    /// 拖拽中的节点位移（画布空间）。刻意不写进 store，松手才提交。
    @State private var draggingNodeId: String? = nil
    @State private var dragDelta: CGSize = .zero
    /// 框选矩形（屏幕空间）。
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    /// 光标位置，供锚点缩放使用。
    @State private var cursorScreen: CGPoint = .zero
    /// 槽位库拖拽的实时拖影。
    @State private var ghost: (title: String, point: CGPoint)? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGridBackground(pan: effectivePan, zoom: zoom)
                    .allowsHitTesting(false)

                if canvas.nodes.isEmpty {
                    CanvasEmptyHint()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

                nodeLayer

                marqueeOverlay

                floatingLayer(size: proxy.size)

                ghostOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.windowBackground)
            .contentShape(Rectangle())
            // 命名坐标空间：槽位库那边的 DragGesture 也报到这个空间，落点才能直接换算成画布坐标。
            .coordinateSpace(name: CanvasWorkspaceView.spaceName)
            .gesture(canvasDragGesture)
            .simultaneousGesture(pinchGesture)
            .onContinuousHover { phase in
                if case .active(let p) = phase { cursorScreen = p }
            }
            .onAppear {
                pan = canvas.pan
                zoom = canvas.zoom
                // 没有光标事件之前，锚点先取视图中心，避免首次捏合以 (0,0) 为锚点把画面甩到角上。
                cursorScreen = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .onDisappear { canvas.flushSave() }
        }
    }

    private var effectivePan: CGSize {
        CGSize(width: pan.width + panGestureDelta.width, height: pan.height + panGestureDelta.height)
    }

    // MARK: - 节点层

    private var nodeLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(canvas.nodes) { node in
                let isDragging = draggingNodeId == node.id
                CanvasNodeCardView(node: node,
                                   isSelected: canvas.selectedNodeIds.contains(node.id))
                    .offset(x: node.x + (isDragging ? dragDelta.width : 0),
                            y: node.y + (isDragging ? dragDelta.height : 0))
                    .zIndex(isDragging ? 10 : 0)
                    .gesture(nodeDragGesture(node))
                    .onTapGesture {
                        canvas.select(id: node.id, additive: NSEvent.modifierFlags.contains(.shift))
                    }
                    .contextMenu { nodeContextMenu(node) }
            }
        }
        // 统一施加视口变换。锚点固定 `.topLeading` 是刻意的：`CanvasGeometry` 全部公式都建立在
        // `screen = canvas * zoom + pan` 之上，而这个式子只有在缩放锚点为原点时才成立。
        // 用 `.center` 会凭空引入一个「视图尺寸的一半」的偏移，让所有命中判定整体错位。
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(x: effectivePan.width, y: effectivePan.height)
        // 禁掉隐式动画：拖拽时每帧都在改 offset，一旦被动画接管就会有明显的橡皮筋滞后。
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: CanvasNode) -> some View {
        if node.count > 1 {
            Button("展开为 \(node.count) 个节点") { canvas.fanOut(nodeId: node.id) }
            Divider()
        }
        Button("重跑") {
            // MVP：生图未接入，先给明确反馈而不是静默无响应。
            store.transientUI.showToast("生图功能开发中")
        }
        if let taskId = node.taskId {
            Button("复制 taskId") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(taskId, forType: .string)
            }
        }
        Divider()
        Button("删除节点") { canvas.removeNodes(ids: [node.id]) }
    }

    // MARK: - 手势

    /// 节点拖动。位移必须**除以 zoom** 换算回画布空间 —— 否则放大到 2x 时节点会跑得比鼠标快一倍。
    private func nodeDragGesture(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
            .onChanged { value in
                // 抓手/框选模式下不允许拖动节点，否则「想框选却拖歪一个节点」会成为常态。
                guard canvas.activeTool == .select else { return }
                if draggingNodeId != node.id {
                    draggingNodeId = node.id
                    if !canvas.selectedNodeIds.contains(node.id) {
                        canvas.select(id: node.id, additive: false)
                    }
                }
                dragDelta = CGSize(width: value.translation.width / zoom,
                                   height: value.translation.height / zoom)
            }
            .onEnded { value in
                guard draggingNodeId == node.id else { return }
                let dx = value.translation.width / zoom
                let dy = value.translation.height / zoom
                canvas.moveNode(id: node.id, to: CGPoint(x: node.x + dx, y: node.y + dy))
                draggingNodeId = nil
                dragDelta = .zero
            }
    }

    /// 画布空白处拖拽。
    ///
    /// 工具语义：**框选(M) 拉框，其余（选择/抓手）平移**。
    /// 之所以让「选择」也平移而不是像 Figma 那样拉框：这里的平移入口只有手势一条（没有滚轮/空格
    /// 兜底），若默认工具下拖空白是拉框，用户就必须先找到并切到抓手才能挪动视图 —— 一个新界面里
    /// 这一步很容易卡住。框选是明确的次要操作，交给显式的 M 工具。
    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
            .onChanged { value in
                if canvas.activeTool == .marquee {
                    if marqueeStart == nil { marqueeStart = value.startLocation }
                    marqueeCurrent = value.location
                } else {
                    panGestureDelta = value.translation
                }
            }
            .onEnded { value in
                if canvas.activeTool == .marquee {
                    if let start = marqueeStart {
                        commitMarquee(from: start, to: value.location)
                    }
                    marqueeStart = nil
                    marqueeCurrent = nil
                } else {
                    // 位移量本身就是屏幕空间的，直接加到 pan 上，不需要除 zoom。
                    pan.width += value.translation.width
                    pan.height += value.translation.height
                    panGestureDelta = .zero
                    canvas.updateViewport(pan: pan, zoom: zoom)
                }
            }
    }

    /// 框选提交。命中判定换算到**画布空间**再做，这样同一个框在任何缩放下选中的节点集合都一致。
    private func commitMarquee(from start: CGPoint, to end: CGPoint) {
        let topLeftScreen = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let bottomRightScreen = CGPoint(x: max(start.x, end.x), y: max(start.y, end.y))
        let topLeft = CanvasGeometry.canvasPoint(screen: topLeftScreen, pan: pan, zoom: zoom)
        let bottomRight = CanvasGeometry.canvasPoint(screen: bottomRightScreen, pan: pan, zoom: zoom)
        let rect = CGRect(x: topLeft.x,
                          y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)
        canvas.selectNodes(inCanvasRect: rect, additive: NSEvent.modifierFlags.contains(.shift))
    }

    /// 捏合缩放。锚点跟光标 —— 缩放必须让光标下的内容保持不动，否则放大到 3x 时用户想看的区域会
    /// 直接飞出屏幕。
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchBasePan == nil {
                    pinchBasePan = pan
                    pinchBaseZoom = zoom
                }
                guard let basePan = pinchBasePan else { return }
                let target = CanvasGeometry.clampZoom(pinchBaseZoom * scale)
                pan = CanvasGeometry.panForAnchoredZoom(anchorScreen: cursorScreen,
                                                        pan: basePan,
                                                        oldZoom: pinchBaseZoom,
                                                        newZoom: target)
                zoom = target
            }
            .onEnded { _ in
                pinchBasePan = nil
                canvas.updateViewport(pan: pan, zoom: zoom)
            }
    }

    // MARK: - 框选矩形

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            Rectangle()
                .fill(AppTheme.chromeAccentInk.opacity(0.08))
                .overlay(Rectangle().stroke(AppTheme.chromeAccentInk.opacity(0.5), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 拖影

    @ViewBuilder
    private var ghostOverlay: some View {
        if let ghost {
            CanvasDragGhost(title: ghost.title)
                // 用 offset 而非 position：拖影本身有自适应宽度，position 会把它的中心钉在光标上，
                // 让文字压住光标；offset 从左上角起算，观感上是「挂在光标右下」。
                .offset(x: ghost.point.x + 10, y: ghost.point.y + 10)
                .transaction { $0.animation = nil }
        }
    }

    // MARK: - 浮动层

    private func floatingLayer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // 左上：槽位库
            CanvasSlotLibraryPanel(store: store,
                                   canvas: canvas,
                                   onDragChanged: handleSlotDragChanged,
                                   onDropSlot: handleSlotDrop)
                .padding(.leading, 14)
                .padding(.top, 14)

            // 右上：生成按钮
            VStack {
                HStack {
                    Spacer()
                    CanvasGenerateButton {
                        store.transientUI.showToast("生图功能开发中")
                    }
                }
                Spacer()
            }
            .padding(.trailing, 16)
            .padding(.top, 14)

            // 底部居中：工具栏
            VStack {
                Spacer()
                CanvasFloatingToolbar(canvas: canvas) {
                    // 新建落在视图中心，而不是 (0,0)：用户平移到远处后按 ＋，节点该出现在他眼前。
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    canvas.addBlankNode(at: CanvasGeometry.canvasPoint(screen: center, pan: pan, zoom: zoom))
                }
            }
            .frame(width: size.width)
            .padding(.bottom, 16)

            // 左下：缩放控件
            VStack {
                Spacer()
                HStack {
                    CanvasZoomControl(zoom: zoom,
                                      onZoomOut: { applyZoomStep(0.8, size: size) },
                                      onZoomIn: { applyZoomStep(1.25, size: size) },
                                      onReset: { resetZoom(size: size) },
                                      onFit: { fitToContent(size: size) })
                    Spacer()
                }
            }
            .padding(.leading, 14)
            .padding(.bottom, 16)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - 动作

    /// 按钮缩放以**视图中心**为锚点（没有正在移动的光标可依据时，中心是唯一合理选择）。
    private func applyZoomStep(_ factor: CGFloat, size: CGSize) {
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let target = CanvasGeometry.clampZoom(zoom * factor)
        let newPan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan, oldZoom: zoom, newZoom: target)
        withAnimation(Anim.interactive) {
            pan = newPan
            zoom = target
        }
        canvas.updateViewport(pan: newPan, zoom: target)
    }

    /// 重置为 100%，同样以视图中心为锚点 —— 直接把 pan 归零会让用户丢失当前所看的位置。
    private func resetZoom(size: CGSize) {
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let newPan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan, oldZoom: zoom, newZoom: 1)
        withAnimation(Anim.transition) {
            pan = newPan
            zoom = 1
        }
        canvas.updateViewport(pan: newPan, zoom: 1)
    }

    private func fitToContent(size: CGSize) {
        guard !canvas.nodes.isEmpty else {
            withAnimation(Anim.transition) { pan = .zero; zoom = 1 }
            canvas.updateViewport(pan: .zero, zoom: 1)
            return
        }
        let bounds = CanvasGeometry.bounds(of: canvas.nodes.map(\.frame))
        let fit = CanvasGeometry.fitTransform(contentBounds: bounds, viewSize: size)
        withAnimation(Anim.transition) {
            pan = fit.pan
            zoom = fit.zoom
        }
        canvas.updateViewport(pan: fit.pan, zoom: fit.zoom)
    }

    private func handleSlotDragChanged(_ payload: CanvasSlotDragPayload?, at point: CGPoint) {
        if let payload {
            let title = payload.label ?? "槽位 \(payload.slot)"
            ghost = (title, point)
        } else {
            ghost = nil
        }
    }

    /// 槽位库拖拽落到画布：把落点换算成画布坐标后建节点。
    private func handleSlotDrop(_ payload: CanvasSlotDragPayload, screenPoint: CGPoint) {
        ghost = nil
        let canvasPoint = CanvasGeometry.canvasPoint(screen: screenPoint, pan: pan, zoom: zoom)
        canvas.addNodeFromSlot(pageId: payload.pageId,
                               groupId: payload.groupId,
                               slot: payload.slot,
                               label: payload.label,
                               prompt: payload.prompt,
                               at: canvasPoint)
    }
}

// MARK: - 网格背景

/// 细网格。用 `Canvas`（Core Graphics 直绘）而不是成百上千个 `Divider` —— 后者在缩小时会瞬间
/// 创建几千个视图节点把主线程打满。
struct CanvasGridBackground: View {
    let pan: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let step = CanvasGeometry.gridScreenStep(base: CanvasStore.gridBase, zoom: zoom)
            let xs = CanvasGeometry.gridLineOffsets(viewLength: canvasSize.width,
                                                    panComponent: pan.width, step: step)
            let ys = CanvasGeometry.gridLineOffsets(viewLength: canvasSize.height,
                                                    panComponent: pan.height, step: step)
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }
            for y in ys {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }
            context.stroke(path, with: .color(AppTheme.subtleBorder.opacity(0.45)), lineWidth: 0.5)
        }
    }
}
