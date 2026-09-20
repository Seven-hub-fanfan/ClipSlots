import SwiftUI
import AppKit
import ClipSlotsKit

/// 画布的**连线交互层**（v2.12.0 · 第一档「连线真实化」+ 第二档「节点即执行单元」）。
///
/// 拆成扩展文件而不是继续堆进 `CanvasWorkspaceView.swift`（那个文件已经 1700+ 行）：这一组视图
/// 彼此耦合（端口把手 → 拖线预览 → 落点判定 → 连线渲染），与主文件里的视口 / 拖拽 / 编辑三套
/// 状态机只通过少量 `@State` 相接，是一条干净的缝。
///
/// ## 分层顺序（与 `body` 里的 ZStack 一致）
///
/// ```text
///   …网格 → 空白点击层 → 【连线层】→ 节点层 → 【拖线预览】→ 【出口把手】→ 【操作条】→ 框选…
/// ```
///
/// 连线在节点**下面**（不挡卡片内容），而把手与操作条在节点**上面**（否则它们贴在卡片边缘的那半
/// 会被相邻卡片压住，表现为"这个把手有时候拖得动有时候拖不动"）。
extension CanvasWorkspaceView {

    // MARK: - 屏幕矩形

    /// 每个节点此刻的屏幕矩形（含拖拽中的临时位移）。
    ///
    /// 连线、把手、操作条全部依赖它。之所以一次算好一张表而不是各自现算：拖动一个节点时，
    /// 与它相连的每条线都要问一次同一个位置，各自现算等于把同一个公式抄三遍 —— 而这个公式
    /// （`screen = canvas * zoom + pan`）抄错一次的症状是"线的端点与卡片边缘差一点点"。
    var nodeScreenFrames: [String: CGRect] {
        var out: [String: CGRect] = [:]
        out.reserveCapacity(canvas.nodes.count)
        for node in canvas.nodes {
            out[node.id] = screenFrame(of: node)
        }
        return out
    }

    func screenFrame(of node: CanvasNode) -> CGRect {
        let dragging = draggingIds.contains(node.id)
        let x = (node.x + (dragging ? dragDelta.width : 0)) * zoom + effectivePan.width
        let y = (node.y + (dragging ? dragDelta.height : 0)) * zoom + effectivePan.height
        return CGRect(x: x, y: y, width: node.width * zoom, height: node.height * zoom)
    }

    // MARK: - 连线层

    @ViewBuilder
    var edgeLayer: some View {
        if !canvas.edges.isEmpty {
            CanvasEdgeLayer(edges: canvas.edges,
                            frames: nodeScreenFrames,
                            selectedEdgeId: canvas.selectedEdgeId,
                            isFlowing: { edgeIsFlowing($0) },
                            roleOptions: { roleOptions(for: $0) },
                            onSelect: { id in
                                // 顺序要紧：`clearSelection` 会把连线选中一起清掉（两种选中互斥），
                                // 先点亮再清就等于白点一次。
                                canvas.clearSelection()
                                canvas.selectedEdgeId = id
                            },
                            onSetRole: { id, role in canvas.setEdgeRole(edgeId: id, role: role) },
                            onDisconnect: { id in disconnectEdge(id) })
        }
    }

    /// 这条线此刻是否在"输送"（v2.15.0）：下游节点排队中或生成中。
    ///
    /// 判定放在**下游**而不是上游：一条线的意义是"上游的内容作为下游的输入"，真正在耗时的是下游
    /// 那次生成。上游跑完早已落盘，它自己的忙碌与这条线无关。
    func edgeIsFlowing(_ edge: CanvasEdge) -> Bool {
        switch canvas.node(id: edge.toNodeId)?.state {
        case .queued, .running: return true
        default: return false
        }
    }

    /// 某条线能设哪些角色：下游是视频节点才有首帧 / 尾帧。
    ///
    /// 不把不适用的角色灰掉而是直接不列：灰掉的菜单项要解释"为什么不能选"，而这里的答案
    /// （"因为下游不是视频节点"）只能靠一行提示文字说，成本高于它的价值。
    func roleOptions(for edge: CanvasEdge) -> [CanvasEdgeRole] {
        let downstreamKind = canvas.node(id: edge.toNodeId)?.kind
        var options: [CanvasEdgeRole] = [.auto, .prompt]
        if downstreamKind == .video {
            options.append(.firstFrame)
            options.append(.lastFrame)
        }
        options.append(.reference)
        return options
    }

    func disconnectEdge(_ id: String) {
        guard canvas.disconnect(edgeId: id) else { return }
        store.transientUI.showToast("已断开连接")
    }

    // MARK: - 出口把手

    /// 悬停 / 单选节点右侧的「拖我连线」把手。
    ///
    /// 只给**一个**节点画（hover 优先于选中）：给所有节点都画会让画布变成一片小圆点，而同一时刻
    /// 用户只可能从一个节点开始拖。
    @ViewBuilder
    var outputPortOverlay: some View {
        if let node = interactionNode,
           editingNodeId == nil,
           addMenu == nil,
           draggingNodeId == nil,
           inputFilesNodeId == nil {
            let rect = screenFrame(of: node)
            let anchor = CanvasEdgeGeometry.outputHandle(of: rect)
            CanvasPort(isActive: linkDrag?.fromNodeId == node.id,
                       isConnected: !canvas.outgoingEdges(of: node.id).isEmpty)
                // v2.16.0：圆心推到卡片右缘**外侧 28pt**（实测 TapNow 约 29pt）。
                // 贴边的旧位置（+9pt）有两个毛病：圆压在卡片圆角上分不清是控件还是装饰；
                // 起手那几个像素仍在卡片内，节点拖动手势会把拖线抢走。
                .position(x: anchor.x + TapSkin.portOffset, y: anchor.y)
                .gesture(linkDragGesture(from: node))
                .tapCursor(.crosshair)
                .zIndex(20)
        }
    }

    /// 入口端口层（v2.15.0）。
    ///
    /// 两种时机画：
    /// - **静态**：只给当前交互节点画一枚（与出口把手成对出现）。给所有节点都画会让画布变成一片
    ///   小圆点 —— 这正是 `outputPortOverlay` 当初拒绝全量绘制的理由。
    /// - **拖线中**：给所有**合法落点**都画。这一刻用户要的恰恰是"我能往哪儿落"，一片小圆点在此
    ///   不是噪声而是答案；非法目标（重复 / 成环 / 自己）不画，于是"没圆点的卡就是连不上的卡"。
    @ViewBuilder
    var inputPortOverlay: some View {
        if let drag = linkDrag {
            ForEach(linkCandidates(from: drag.fromNodeId), id: \.id) { node in
                let rect = screenFrame(of: node)
                let anchor = CanvasEdgeGeometry.inputHandle(of: rect)
                CanvasPort(isActive: drag.targetNodeId == node.id,
                           isConnected: !canvas.incomingEdges(of: node.id).isEmpty)
                    .position(x: anchor.x - TapSkin.portOffset, y: anchor.y)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        } else if let node = interactionNode,
                  editingNodeId == nil,
                  addMenu == nil,
                  draggingNodeId == nil,
                  inputFilesNodeId == nil {
            let rect = screenFrame(of: node)
            let anchor = CanvasEdgeGeometry.inputHandle(of: rect)
            CanvasPort(isActive: false,
                       isConnected: !canvas.incomingEdges(of: node.id).isEmpty)
                .position(x: anchor.x - TapSkin.portOffset, y: anchor.y)
                .allowsHitTesting(false)
                .zIndex(20)
        }
    }

    /// 从某个节点出发，此刻能连到哪些节点。
    ///
    /// 复用 `CanvasEdgeGraph.canConnect` 而不是自己判重 / 判环：落点高亮与真正的连接必须同一个
    /// 判据，否则会出现"圆点亮着、松手却弹「连不上」"。
    func linkCandidates(from sourceId: String) -> [CanvasNode] {
        let ids = Set(canvas.nodes.map(\.id))
        return canvas.nodes.filter { node in
            node.id != sourceId
                && CanvasEdgeGraph.canConnect(from: sourceId, to: node.id, edges: canvas.edges, nodeIds: ids) == nil
        }
    }

    /// 拖线手势。
    ///
    /// `minimumDistance: 1`：把手很小，要求更长的起步距离会让"轻拖一下"变成一次点击（而点击在
    /// 这个位置没有任何语义）。与节点拖拽手势不冲突 —— 把手画在节点层之外，事件不会下派到卡片。
    func linkDragGesture(from node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
            .onChanged { value in
                let start = CanvasEdgeGeometry.outputHandle(of: screenFrame(of: node))
                let target = linkTarget(at: value.location, from: node.id)
                if linkDrag?.fromNodeId == node.id {
                    linkDrag?.cursor = value.location
                    linkDrag?.targetNodeId = target
                } else {
                    linkDrag = CanvasWorkspaceView.LinkDrag(fromNodeId: node.id,
                                                            start: start,
                                                            cursor: value.location,
                                                            targetNodeId: target)
                }
            }
            .onEnded { value in
                let drag = linkDrag
                linkDrag = nil
                guard let drag, drag.fromNodeId == node.id else { return }
                finishLinkDrag(from: node, at: value.location, target: drag.targetNodeId)
            }
    }

    /// 光标落在哪个可连节点上。
    ///
    /// 倒序遍历取**最上面**那个：`ForEach` 的绘制顺序是数组顺序，后面的画在上面，所以命中判定
    /// 也必须反着来，否则"点上面那张卡，连到了被它压住的那张"。
    func linkTarget(at screenPoint: CGPoint, from sourceId: String) -> String? {
        let frames = nodeScreenFrames
        for node in canvas.nodes.reversed() {
            guard let rect = frames[node.id], rect.contains(screenPoint) else { continue }
            guard node.id != sourceId else { return nil }
            // 不能连（重复 / 成环）的目标在拖拽中就不该点亮，否则用户松手才知道白拖一趟。
            guard CanvasEdgeGraph.canConnect(from: sourceId,
                                            to: node.id,
                                            edges: canvas.edges,
                                            nodeIds: Set(canvas.nodes.map(\.id))) == nil else { return nil }
            return node.id
        }
        return nil
    }

    /// 松手：落在节点上就连线，落在空白就弹 ADD NODE（新节点建好后自动连上）。
    ///
    /// 落空不是失败而是**创作动作**，这是 TapNow 那类画布最顺手的一招："从这儿拉一条线出来，
    /// 给我一个新节点"。旧版的下游 `+` 也走同一条路（`AddNodeRequest.parentNodeId`），所以这里
    /// 只需要把落点喂给同一个入口。
    func finishLinkDrag(from node: CanvasNode, at screenPoint: CGPoint, target: String?) {
        if let target {
            if let rejection = canvas.connect(from: node.id, to: target) {
                store.transientUI.showToast(rejection.message)
            } else {
                store.transientUI.showToast("已连接")
            }
            return
        }
        // 落在别的节点上但连不了（重复 / 成环）→ 给原因，别默默弹建节点菜单。
        let frames = nodeScreenFrames
        if let blocked = canvas.nodes.reversed().first(where: { frames[$0.id]?.contains(screenPoint) == true }),
           blocked.id != node.id {
            let rejection = CanvasEdgeGraph.canConnect(from: node.id,
                                                       to: blocked.id,
                                                       edges: canvas.edges,
                                                       nodeIds: Set(canvas.nodes.map(\.id)))
            store.transientUI.showToast(rejection?.message ?? "连不上")
            return
        }
        openAddMenu(atScreen: screenPoint, parentNodeId: node.id)
    }

    @ViewBuilder
    var linkDragOverlay: some View {
        if let drag = linkDrag {
            CanvasLinkDragPreview(start: drag.start,
                                  cursor: drag.cursor,
                                  hasTarget: drag.targetNodeId != nil)
                .zIndex(19)
        }
    }

    // MARK: - 节点操作条

    /// 操作条挂给谁：hover 的节点优先，其次是单选的节点。
    ///
    /// hover 优先是刻意的：用户把光标移到某张卡上时，注意力已经在那张卡上了；此时还把操作条留在
    /// 另一张（选中的）卡上，就是"我按的按钮属于另一个节点"这种最难查的误操作。
    var interactionNode: CanvasNode? {
        if let hovered = hoverHoldNodeId, let node = canvas.node(id: hovered) { return node }
        return canvas.soleSelectedNode
    }

    @ViewBuilder
    var actionBarOverlay: some View {
        if let node = interactionNode,
           editingNodeId == nil,
           addMenu == nil,
           draggingNodeId == nil,
           inputFilesNodeId == nil,
           linkDrag == nil {
            let rect = screenFrame(of: node)
            CanvasNodeActionBar(node: node,
                                canvas: canvas,
                                catalog: CrateModelCatalogStore.shared,
                                upstreamCount: canvas.incomingEdges(of: node.id).count,
                                onRun: { startGeneration(node, reusingSeed: false) },
                                onSpawnDownstream: { spawnDownstream(from: node) },
                                onRevealAsset: { revealAsset($0) },
                                canArchive: canArchiveToLibrary(node),
                                onArchive: { archiveNodeToLibrary(node) },
                                onOpenFullscreen: previewableMedia(of: node).map { media in
                                    { openFullscreen(node, attachment: media) }
                                },
                                onCopyText: copyTextAction(for: node))
                .fixedSize()
                // 贴在卡片上边缘外侧。靠上没地方了就翻到下边缘 —— 顶到视口外的操作条等于没有，
                // 而这一条正是"节点即执行单元"的落点，不能因为卡片拖到顶部就消失。
                .position(x: rect.midX, y: actionBarY(for: rect))
                .zIndex(18)
        }
    }

    /// 文本节点的「复制全文」动作；非文本节点或空文本返回 nil（按钮随之消失）。
    ///
    /// 走剪贴板而不是"导出成文件"：文本节点的下游几乎总是另一个输入框（另一个节点的提示词、
    /// 聊天窗口、代码编辑器），而 Cmd+V 是那条路上唯一不需要解释的动作。
    func copyTextAction(for node: CanvasNode) -> (() -> Void)? {
        guard node.kind == .text else { return nil }
        let content = liveText(for: node)
        guard !content.isEmpty else { return nil }
        return {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(content, forType: .string)
            store.transientUI.showToast("已复制全文（\(content.count) 字）")
        }
    }

    /// 操作条的 y（屏幕坐标，胶囊中心）。
    ///
    /// ## 为什么这个数是"堆出来"的而不是拍一个
    ///
    /// v2.16.0 起卡片**上方 20pt 被名签占了**（`tagGap 6 + tagHeight 14`，见 `CanvasTapNodeCard`）。
    /// 旧版 `rect.minY - 20` 正好把操作条压在名签上，于是每次 hover 都会遮住"这是哪个节点"——
    /// 恰恰是操作条最需要用户确认的那条信息。
    ///
    /// 所以高度是逐段累加的：名签带 20 + 呼吸 `toolbarGap` 10 + 胶囊自身半高 22 = 52。
    /// 写成表达式而不是常量 52，是为了改任一段时不用重新做这道算术。
    private func actionBarY(for rect: CGRect) -> CGFloat {
        let tagBand = TapSkin.tagGap + TapSkin.tagHeight
        let above = rect.minY - tagBand - TapSkin.toolbarGap - TapSkin.toolbarHeight / 2
        // 顶到视口外的操作条等于没有，而这一条正是"节点即执行单元"的落点，不能因为卡片拖到
        // 顶部就消失 —— 翻到下边缘。下边缘没有名签，所以只需要让开 `toolbarGap`。
        guard above < TapSkin.toolbarHeight / 2 + 6 else { return above }
        return rect.maxY + TapSkin.toolbarGap + TapSkin.toolbarHeight / 2
    }

    /// 「以它为输入新建下游节点」：等价于旧版卡片下方那个 `+`，但入口挪到了操作条上。
    func spawnDownstream(from node: CanvasNode) {
        let frame = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
        let origin = CanvasSpawnGeometry.downstreamOrigin(of: frame, newSize: CanvasNode.defaultSize)
        let center = CGPoint(x: origin.x + CanvasNode.defaultSize.width / 2,
                             y: origin.y + CanvasNode.defaultSize.height / 2)
        let screen = CanvasGeometry.screenPoint(canvas: center, pan: effectivePan, zoom: zoom)
        openAddMenu(atScreen: screen, parentNodeId: node.id)
    }

    /// 在访达里选中产物文件。
    func revealAsset(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            store.transientUI.showToast("产物文件已不在原处")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
