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
    var renderedCanvasEdges: [CanvasEdge] {
        canvas.interactionEdges.filter { edge in
            guard let source = canvas.pile(containing: edge.fromNodeId) else { return true }
            return canvas.pile(containing: edge.toNodeId)?.id != source.id
        }
    }
    @ViewBuilder var selectedEdgeToolbar: some View {
        if let id = canvas.selectedEdgeId, let edge = canvas.edges.first(where: { $0.id == id }),
           let a = nodeScreenFrames[edge.fromNodeId], let b = nodeScreenFrames[edge.toNodeId],
           addMenu == nil, draggingNodeId == nil, linkDrag == nil {
            let start = edgeEndpoint(id: edge.fromNodeId, rect: a, output: true)
            let end = edgeEndpoint(id: edge.toNodeId, rect: b, output: false)
            let controls = CanvasEdgeGeometry.controlPoints(start: start, end: end, outSide: .right, inSide: .left,
                                                            coordinateScale: zoom)
            let point = CanvasEdgeGeometry.point(start: start, c1: controls.0, c2: controls.1, end: end, t: 0.5)
            HStack(spacing: 10) {
                Menu {
                    ForEach(roleOptions(for: edge), id: \.self) { role in
                        Button(role.displayName) { canvas.setEdgeRole(edgeId: id, role: role) }
                    }
                    Divider()
                    Toggle("流光动画", isOn: Binding(get: { edge.animated }, set: {
                        canvas.setEdgeAnimated(edgeId: id, animated: $0)
                    }))
                } label: {
                    Label(edge.role.displayName, systemImage: edge.role.symbolName).font(.system(size: 11))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Rectangle().fill(TapSkin.border).frame(width: 1, height: 16)
                Button { disconnectEdge(id) } label: {
                    Image(systemName: "scissors").frame(width: 26, height: 26)
                }.buttonStyle(.plain).help("断开连接 · 可撤销")
                    .canvasControlRegion("edge-disconnect")
            }
            .padding(.horizontal, 11).frame(height: 36)
            .foregroundColor(TapSkin.ink)
            .background(Capsule().fill(TapSkin.chromeFill))
            .overlay(Capsule().stroke(TapSkin.border, lineWidth: 1))
            .canvasControlRegion("edge-toolbar")
            .position(x: min(max(point.x, canvasContentViewport.minX + 90), canvasContentViewport.maxX - 90),
                      y: min(max(point.y - 30, canvasContentViewport.minY + 22), canvasContentViewport.maxY - 22))
            .zIndex(42)
        }
    }

    // MARK: - 屏幕矩形

    func nodeLayerOrder(_ node: CanvasNode) -> Double {
        if draggingNodeId == node.id { return 10 }
        if draggingIds.contains(node.id) { return 9 }
        if editingNodeId == node.id { return 8 }
        if canvas.selectedGroupID == nil && canvas.selectedNodeIds.contains(node.id) { return 4 }
        return 0
    }

    /// Match SwiftUI zIndex before using the document's stable array order.
    /// Selection must never make the displayed front card differ from the hit.
    var nodesInPaintOrder: [CanvasNode] {
        let hidden = canvas.piledMemberIDs.union(nodeMountQueue.pendingIDs)
        let dragged = draggingNodeId, draggedIDs = draggingIds, edited = editingNodeId
        let selected = canvas.selectedGroupID == nil ? canvas.selectedNodeIds : []
        var ranked: [(Int, CanvasNode, Int)] = []
        for (index, node) in canvas.nodes.enumerated() where !hidden.contains(node.id) {
            var priority = 0
            if selected.contains(node.id) { priority = 4 }
            if node.id == edited { priority = 8 }
            if draggedIDs.contains(node.id) { priority = 9 }
            if node.id == dragged { priority = 10 }
            ranked.append((index, node, priority))
        }
        ranked.sort { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }
        return ranked.map { $0.1 }
    }

    func nodeBody(at point: CGPoint) -> CanvasNode? {
        // The native Pile surface owns its preview. Members have no independent
        // canvas pointer target until extracted or unstacked.
        guard pileBody(at: point) == nil else { return nil }
        return nodesInPaintOrder.last { screenFrame(of: $0).contains(point) }
    }

    /// The foreground panel owns its full rectangle; underlying cards cannot
    /// acquire a press through the visible prompt or its controls.
    func composerContains(_ point: CGPoint) -> Bool {
        composerFrame?.contains(point) == true
    }

    /// 每个节点此刻的屏幕矩形（含拖拽中的临时位移）。
    ///
    /// 连线、把手、操作条全部依赖它。之所以一次算好一张表而不是各自现算：拖动一个节点时，
    /// 与它相连的每条线都要问一次同一个位置，各自现算等于把同一个公式抄三遍 —— 而这个公式
    /// （`screen = canvas * zoom + pan`）抄错一次的症状是"线的端点与卡片边缘差一点点"。
    var nodeScreenFrames: [String: CGRect] {
        var out: [String: CGRect] = [:]
        let nodes = canvas.nodes, piles = canvas.piles, selected = draggingIds, delta = dragDelta
        let scale = zoom, origin = effectivePan
        let pileFrames = Dictionary(piles.flatMap { pile in
            let frame = pileScreenFrame(pile)
            return pile.memberIDs.map { ($0, frame) }
        }, uniquingKeysWith: { first, _ in first })
        out.reserveCapacity(nodes.count)
        for node in nodes {
            let offset = selected.contains(node.id) ? delta : .zero
            out[node.id] = pileFrames[node.id] ?? CGRect(x: (node.x + offset.width) * scale + origin.width,
                y: (node.y + offset.height) * scale + origin.height, width: node.width * scale, height: node.height * scale)
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

    func visiblePortIDs(output: Bool) -> Set<String> {
        var nodes = staticPortNodes
        if let drag = linkDrag {
            nodes = output == drag.fromInput ? linkCandidates(from: drag.fromNodeId, reverse: drag.fromInput)
                : [canvas.node(id: drag.fromNodeId)].compactMap { $0 }
        }
        return exposedPortIDs(nodes: nodes, output: output)
    }

    /// Compute stacking and controls once for the entire port layer. A port
    /// must never rebuild the workspace's geometry for every neighbouring card.
    func exposedPortIDs(nodes: [CanvasNode], output: Bool) -> Set<String> {
        let viewport = canvasContentViewport, composer = composerFrame
        let controls = Array(activeControlRegions.values)
        let frames = nodeScreenFrames, order = nodesInPaintOrder
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.id, $0.offset) })
        let bodies = order.compactMap { node in frames[node.id].map { (node.id, $0) } }
        let scale = zoom, motions = portMotions
        func exposed(_ point: CGPoint, _ id: String) -> Bool {
            let hit = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
            guard viewport.contains(point), composer?.intersects(hit) != true,
                  !controls.contains(where: { $0.intersects(hit) }) else { return false }
            guard let body = bodies.last(where: { $0.1.contains(point) }),
                  body.0 != id else { return true }
            return (ranks[id] ?? -1) > (ranks[body.0] ?? -1)
        }
        return Set(nodes.compactMap { node in
            guard let rect = frames[node.id] else { return nil }
            let home = CGPoint(x: (output ? rect.maxX : rect.minX) + (output ? 37 : -37) * scale, y: rect.midY)
            let offset = motions.motion(nodeID: node.id, output: output).presentationOffset(output: output)
            let point = CGPoint(x: home.x + offset.x, y: home.y + offset.y)
            return exposed(home, node.id) || exposed(point, node.id) ? node.id : nil
        })
    }

    func frozenPortPoints(output: Bool) -> [String: CGPoint] {
        guard let session = pointerSession, let point = session.linkPortPoint else { return [:] }
        switch session.target {
        case .link(let id) where output, .inputLink(let id) where !output: return [id: point]
        default: return [:]
        }
    }

    func edgeEndpoint(id: String, rect: CGRect, output: Bool) -> CGPoint {
        CanvasEdgeGeometry.connectionAnchor(of: rect, output: output, zoom: zoom)
    }

    @ViewBuilder
    var edgeLayer: some View {
        if showCanvasEdges && !canvas.edges.isEmpty {
            CanvasEdgeLayer(edges: renderedCanvasEdges,
                            frames: nodeScreenFrames,
                            selectedEdgeId: canvas.selectedEdgeId,
                            selectedNodeIDs: canvas.expandedNodeIDs(canvas.selectedNodeIds),
                            visibleOutputIDs: visiblePortIDs(output: true),
                            visibleInputIDs: visiblePortIDs(output: false),
                            frozenOutputPoints: frozenPortPoints(output: true),
                            frozenInputPoints: frozenPortPoints(output: false),
                            portMotions: portMotions, zoom: zoom,
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

    /// The recovered ore branch reads edge.animated, independently of node
    /// generation state. Endpoint selection is derived in the rendering leaf.
    func edgeIsFlowing(_ edge: CanvasEdge) -> Bool {
        edge.animated
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

    /// Ports share their node's stacking context in TapNow. A selected node's
    /// visible port can overlap a lower card; a higher card still covers it.
    func portIsAboveBody(at point: CGPoint, nodeId: String) -> Bool {
        guard let body = nodeBody(at: point), body.id != nodeId else { return true }
        let order = nodesInPaintOrder
        guard let sourceIndex = order.firstIndex(where: { $0.id == nodeId }),
              let bodyIndex = order.firstIndex(where: { $0.id == body.id }) else { return false }
        return sourceIndex > bodyIndex
    }

    func portIsExposed(_ point: CGPoint, nodeId: String) -> Bool {
        let hit = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        guard canvasContentViewport.contains(point),
              composerFrame?.intersects(hit) != true,
              !activeControlRegions.contains(where: { $0.value.intersects(hit) }) else { return false }
        return portIsAboveBody(at: point, nodeId: nodeId)
    }

    func outputPortHome(of node: CanvasNode) -> CGPoint {
        let rect = screenFrame(of: node)
        return CGPoint(x: rect.maxX + TapSkin.portOffset * zoom, y: rect.midY)
    }

    func inputPortHome(of node: CanvasNode) -> CGPoint {
        let rect = screenFrame(of: node)
        return CGPoint(x: rect.minX - TapSkin.portOffset * zoom, y: rect.midY)
    }

    func inputPortPoint(of node: CanvasNode) -> CGPoint {
        portPoint(of: node, output: false)
    }

    var outputPortPoint: CGPoint? {
        guard let node = interactionNode, editingNodeId == nil, composingNodeId == nil,
              addMenu == nil, draggingNodeId == nil, inputFilesNodeId == nil,
              canvas.connectionPolicy.canConnect(nodeID: node.id) else { return nil }
        // A down/up sequence owns the handle even as hover, pan, and target
        // cards change. Never rediscover a different source mid-drag.
        if case .link(let id) = pointerSession?.target, id == node.id {
            return pointerSession?.linkPortPoint ?? pointerSession?.start
        }
        let home = outputPortHome(of: node)
        let offset = portMotions.motion(nodeID: node.id, output: true).presentationOffset(output: true)
        let point = CGPoint(x: home.x + offset.x, y: home.y + offset.y)
        return portIsExposed(point, nodeId: node.id) ? point : nil
    }

    func outputPortHit(at point: CGPoint, node: CanvasNode, port: CGPoint) -> Bool {
        if nodeBody(at: point) != nil {
            guard portIsAboveBody(at: point, nodeId: node.id) else { return false }
            // The inward-following glyph may enter the card; its large hover
            // region must not turn the rest of that card into a link handle.
            return hypot(point.x - port.x, point.y - port.y) < TapSkin.portDiameter / 2
        }
        return hypot(point.x - port.x, point.y - port.y) < 20
    }

    /// 悬停 / 单选节点右侧的「拖我连线」把手。
    ///
    /// 只给**一个**节点画（hover 优先于选中）：给所有节点都画会让画布变成一片小圆点，而同一时刻
    /// 用户只可能从一个节点开始拖。
    @ViewBuilder
    var outputPortOverlay: some View {
        let drag = linkDrag, scale = zoom, frames = nodeScreenFrames
        let connected = Set(canvas.edges.map(\.fromNodeId))
        let nodes = drag.flatMap { canvas.node(id: $0.fromNodeId).map { [$0] } } ?? staticPortNodes
        let exposed = exposedPortIDs(nodes: nodes, output: true)
        let shown = Set(staticPortNodes.map(\.id)), hovered = hoverHoldNodeId
        let multi = canvas.selectedNodeIds.count > 1, dragged = draggingIds
        ForEach(nodes) { node in
            let rect = frames[node.id] ?? .zero
            let home = CGPoint(x: rect.maxX + 37 * scale, y: rect.midY)
            // A hidden inward position may intersect another control. Keep an
            // exposed home mounted so its reveal can actually leave that position.
            if drag?.fromInput != true && (drag != nil || exposed.contains(node.id)) {
                CanvasNodePort(nodeID: node.id, output: true, home: home,
                               frozenPoint: drag == nil ? nil : portPoint(of: node, output: true),
                               active: drag != nil,
                               connected: connected.contains(node.id), motions: portMotions,
                               visible: shown.contains(node.id) || hovered == node.id,
                               zoom: scale, forceHidden: multi || dragged.contains(node.id))
                    .zIndex(20)
            }
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
        let frames = nodeScreenFrames, scale = zoom
        let shown = Set(staticPortNodes.map(\.id)), hovered = hoverHoldNodeId
        let incoming = Set(canvas.edges.map(\.toNodeId)), outgoing = Set(canvas.edges.map(\.fromNodeId))
        let multi = canvas.selectedNodeIds.count > 1, dragged = draggingIds
        if let drag = linkDrag {
            if drag.fromInput, let node = canvas.node(id: drag.fromNodeId) {
                CanvasNodePort(nodeID: node.id, output: false, home: inputPortHome(of: node),
                               frozenPoint: inputPortPoint(of: node), active: true,
                               connected: !canvas.incomingEdges(of: node.id).isEmpty, motions: portMotions,
                               zoom: zoom)
                    .zIndex(20)
            }
            let shownIDs = shown.union(hovered.map { [$0] } ?? [])
            let nodes = linkCandidates(from: drag.fromNodeId, reverse: drag.fromInput).filter { shownIDs.contains($0.id) }
            let exposed = exposedPortIDs(nodes: nodes, output: drag.fromInput)
            ForEach(nodes, id: \.id) { node in
                let rect = frames[node.id] ?? .zero
                let home = CGPoint(x: (drag.fromInput ? rect.maxX : rect.minX)
                    + (drag.fromInput ? 37 : -37) * scale, y: rect.midY)
                if exposed.contains(node.id) {
                    CanvasNodePort(nodeID: node.id, output: drag.fromInput,
                                   home: home,
                                   frozenPoint: nil, active: drag.targetNodeId == node.id,
                                   connected: (drag.fromInput ? outgoing : incoming).contains(node.id),
                                   motions: portMotions, visible: hovered == node.id || shown.contains(node.id),
                                   zoom: scale)
                    .zIndex(20)
                }
            }
        } else {
            let nodes = staticPortNodes
            let exposed = exposedPortIDs(nodes: nodes, output: false)
            ForEach(nodes) { node in
                let rect = frames[node.id] ?? .zero
                if exposed.contains(node.id) {
                    CanvasNodePort(nodeID: node.id, output: false,
                                   home: CGPoint(x: rect.minX - 37 * scale, y: rect.midY),
                                   frozenPoint: nil, active: false,
                                   connected: incoming.contains(node.id), motions: portMotions,
                                   visible: shown.contains(node.id), zoom: scale,
                                   forceHidden: multi || dragged.contains(node.id))
                        .zIndex(20)
                }
            }
        }
    }

    /// 从某个节点出发，此刻能连到哪些节点。
    ///
    /// 复用 `CanvasEdgeGraph.canConnect` 而不是自己判重 / 判环：落点高亮与真正的连接必须同一个
    /// 判据，否则会出现"圆点亮着、松手却弹「连不上」"。
    func linkConnectionRejection(from sourceID: String, to targetID: String) -> CanvasEdgeGraph.Rejection? {
        guard canvas.connectionPolicy.canConnect(from: sourceID, to: targetID) else { return .disabled }
        guard let target = canvas.node(id: targetID) else { return .missingNode }
        return CanvasEdgeGraph.canConnect(from: sourceID, to: targetID,
            nodes: canvas.nodes, edges: canvas.edges, purpose: CanvasEdgeGraph.defaultPurpose(for: target))
    }

    func linkCandidates(from sourceId: String, reverse: Bool = false) -> [CanvasNode] {
        let ids = linkCandidateCache.candidates(canvas: canvas, source: sourceId, reverse: reverse)
        return canvas.nodes.filter { ids.contains($0.id) }
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
    func linkTarget(at screenPoint: CGPoint, from sourceId: String, reverse: Bool = false) -> String? {
        guard canvasContentViewport.contains(screenPoint),
              !canvasOverlayContains(screenPoint) else { return nil }
        let frames = nodeScreenFrames
        let paintOrder = nodesInPaintOrder
        let scale = zoom, motions = portMotions
        let coveringBody = paintOrder.last { frames[$0.id]?.contains(screenPoint) == true }
        let ranks = Dictionary(uniqueKeysWithValues: paintOrder.enumerated().map { ($0.element.id, $0.offset) })
        let nearest = paintOrder.reversed().compactMap { node -> (CanvasNode, CGFloat)? in
            guard let rect = frames[node.id] else { return nil }
            let port = CanvasEdgeGeometry.connectionAnchor(of: rect, output: reverse, zoom: scale)
            if let body = coveringBody, body.id != node.id,
               (ranks[body.id] ?? 0) > (ranks[node.id] ?? 0) { return nil }
            let distance = hypot(screenPoint.x - port.x, screenPoint.y - port.y)
            // Handle hit and the moving plus are separate. A visible plus is a
            // descendant of its fixed Handle and therefore wins a direct hit.
            let motion = motions.motion(nodeID: node.id, output: reverse)
            let offset = motion.presentationOffset(output: reverse)
            let glyph = CGPoint(x: (reverse ? rect.maxX : rect.minX) + (reverse ? 37 : -37) * scale + offset.x,
                                y: rect.midY + offset.y)
            if motion.opacity() > 0.01,
               hypot(screenPoint.x - glyph.x, screenPoint.y - glyph.y) <= TapSkin.portDiameter * scale / 2 {
                return (node, -1)
            }
            return distance <= CanvasReplicaGeometry.connectionRadius * scale ? (node, distance) : nil
        }.min { $0.1 < $1.1 }?.0
        guard let node = nearest, node.id != sourceId,
              linkCandidateCache.candidates(canvas: canvas, source: sourceId, reverse: reverse).contains(node.id)
        else { return nil }
        return node.id
    }

    /// 松手：落在节点上就连线，落在空白就弹 ADD NODE（新节点建好后自动连上）。
    ///
    /// 落空不是失败而是**创作动作**，这是 TapNow 那类画布最顺手的一招："从这儿拉一条线出来，
    /// 给我一个新节点"。旧版的下游 `+` 也走同一条路（`AddNodeRequest.parentNodeId`），所以这里
    /// 只需要把落点喂给同一个入口。
    func finishLinkDrag(from node: CanvasNode, at screenPoint: CGPoint, target: String?, reverse: Bool = false) {
        guard canvas.connectionPolicy.canConnect(nodeID: node.id) else { return }
        guard isCanvasSurface(at: screenPoint) else { return }
        if let target {
            if let rejection = canvas.connect(from: reverse ? target : node.id, to: reverse ? node.id : target) {
                store.transientUI.showToast(rejection.message)
            } else {
                store.transientUI.showToast("已连接")
            }
            return
        }
        // Body fallback happens only on release, after Handle snapping failed.
        if let body = nodeBody(at: screenPoint), body.id != node.id {
            let source = reverse ? body.id : node.id
            let destination = reverse ? node.id : body.id
            if linkConnectionRejection(from: source, to: destination) == nil {
                _ = canvas.connect(from: source, to: destination)
                return
            }
            if canvas.node(id: destination)?.draftReference != nil { return }
        }
        openAddMenu(atScreen: screenPoint, parentNodeId: reverse ? nil : node.id,
                    childNodeId: reverse ? node.id : nil)
    }

    @ViewBuilder
    var linkDragOverlay: some View {
        if let drag = linkDrag {
            if let target = drag.targetNodeId.flatMap({ canvas.node(id: $0) }) {
                CanvasLinkDragPreview(
                    start: drag.start,
                    cursor: CanvasEdgeGeometry.connectionAnchor(of: screenFrame(of: target), output: drag.fromInput, zoom: zoom),
                    hasTarget: true, zoom: zoom, fromInput: drag.fromInput)
                    .transaction { $0.animation = nil }.zIndex(0)
            } else {
                CanvasLinkDragPreview(start: drag.start,
                                      cursor: drag.cursor, hasTarget: false, zoom: zoom, fromInput: drag.fromInput)
                    .transaction { $0.animation = nil }.zIndex(0)
            }
        } else if let request = addMenu {
            // TapNow's command node owns a temporary edge until a choice is
            // made. Keep that edge in view state, outside the persisted graph.
            let destination = CanvasGeometry.screenPoint(canvas: request.canvasPoint,
                                                         pan: effectivePan, zoom: zoom)
            CanvasPendingLinkPreview(starts: request.allParentIds.compactMap { id in
                canvas.node(id: id).map { CanvasEdgeGeometry.connectionAnchor(of: screenFrame(of: $0), output: true, zoom: zoom) }
            }, destination: destination, zoom: zoom)
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
                .zIndex(0)
            if let child = request.childNodeId, let node = canvas.node(id: child) {
                CanvasLinkDragPreview(start: destination,
                                      cursor: CanvasEdgeGeometry.connectionAnchor(of: screenFrame(of: node), output: false, zoom: zoom),
                                      hasTarget: false, zoom: zoom)
                    .allowsHitTesting(false).zIndex(0)
            }
        }
    }

    // MARK: - 节点操作条

    /// 操作条挂给谁：hover 的节点优先，其次是单选的节点。
    ///
    /// hover 优先是刻意的：用户把光标移到某张卡上时，注意力已经在那张卡上了；此时还把操作条留在
    /// 另一张（选中的）卡上，就是"我按的按钮属于另一个节点"这种最难查的误操作。
    var interactionNode: CanvasNode? {
        if let drag = linkDrag { return canvas.node(id: drag.fromNodeId) }
        if case .link(let id) = pointerSession?.target { return canvas.node(id: id) }
        if case .inputLink(let id) = pointerSession?.target { return canvas.node(id: id) }
        guard canvas.selectedGroupID == nil else { return nil }
        guard canvas.selectedNodeIds.count < 2 else { return nil }
        if canvasOverlayContains(inputRouter.cursorPoint) { return canvas.soleSelectedNode }
        if let hovered = hoverHoldNodeId, let node = canvas.node(id: hovered) { return node }
        return canvas.soleSelectedNode
    }

    func hitsInputPort(_ point: CGPoint, rect: CGRect) -> Bool {
        let visiblePort = CGPoint(x: rect.minX - TapSkin.portOffset, y: rect.midY)
        return rect.contains(point)
            || CanvasPortInteractionGeometry.follows(point, home: visiblePort, output: false, zoom: zoom)
            || hypot(point.x - visiblePort.x, point.y - visiblePort.y) <= CanvasReplicaGeometry.connectionRadius * zoom
    }

    @ViewBuilder
    var actionBarOverlay: some View {
        let node = addMenu == nil && draggingNodeId == nil && inputFilesNodeId == nil && linkDrag == nil
            ? canvas.soleSelectedNode : nil
        let item = node.map { CanvasFloatingSnapshot(project: canvas.activeProjectId, node: $0, frame: screenFrame(of: $0)) }
        CanvasFloatingRetainer(item: item, bottom: false) { snapshot in
            let rect = snapshot.frame
            selectionToolbar(at: CGPoint(x: rect.midX,
                y: actionBarY(for: rect) - (selectionIsWholeGroup ? 52 : 0) - (actionToolbarHeight - 42) / 2),
                retainedSelection: [snapshot.node])
        }
        .id(canvas.activeProjectId)
        .zIndex(18)
    }

    /// 文本节点的「复制全文」动作；非文本节点或空文本返回 nil（按钮随之消失）。
    ///
    /// 走剪贴板而不是"导出成文件"：文本节点的下游几乎总是另一个输入框（另一个节点的提示词、
    /// 聊天窗口、代码编辑器），而 Cmd+V 是那条路上唯一不需要解释的动作。
    func copyTextAction(for node: CanvasNode) -> (() -> Void)? {
        guard node.kind == .text else { return nil }
        guard !renderText(for: node).isEmpty else { return nil }
        return {
            let content = liveText(for: node)
            guard !content.isEmpty else { return }
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
        let rect = screenFrame(of: node)
        let point = CGPoint(x: rect.maxX + 80, y: rect.midY)
        let center = CanvasGeometry.canvasPoint(screen: CGPoint(x: point.x + 160 * zoom, y: point.y),
                                                pan: effectivePan, zoom: zoom)
        openAddMenu(atScreen: point, canvasPoint: center, parentNodeId: node.id)
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
