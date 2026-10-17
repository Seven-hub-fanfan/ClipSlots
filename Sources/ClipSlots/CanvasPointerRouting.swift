import SwiftUI
import ClipSlotsKit

/// SwiftUI controls retain their own gestures; canvas surfaces use one native pointer owner.
struct CanvasControlRegions: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func canvasControlRegion(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: CanvasControlRegions.self,
                                   value: [id: proxy.frame(in: .named(CanvasWorkspaceView.spaceName))])
        }.allowsHitTesting(false))
    }
}

struct CanvasPointerSession {
    enum Target {
        case blank, node(String, wasSelected: Bool), slotPrompt(String), link(String)
        case inputLink(String)
        case junction, edge, menu(UUID, CanvasAddNodeMenu.Choice?)
        case group(String), groupResize(String, CanvasGroupResizeHandle, CGRect)
        case pile(String)
    }
    let target: Target
    let start: CGPoint
    let modifiers: NSEvent.ModifierFlags
    var initialPan: CGSize = .zero
    var initialZoom: CGFloat = 1
    var linkPortPoint: CGPoint?
    var moved = false
}

extension CanvasWorkspaceView {
    /// 只采用当前存在的浮层。面板区域同步计算，避免上一帧 preference 造成穿透/幽灵遮挡。
    var activeControlRegions: [String: CGRect] {
        controlRegions.filter { key, _ in
            if key.hasPrefix("pile-toolbar-") {
                return pileDragID == nil && pileGalleryID == nil && addMenu == nil
                    && canvas.piles.contains { "pile-toolbar-\($0.id)" == key &&
                        (canvas.selectedNodeIds.contains($0.id) || hoveredPileID == $0.id) }
            }
            if key.hasPrefix("group-title-editor-") { return key == "group-title-editor-\(editingGroupID ?? "")" }
            if key.hasPrefix("group-toolbar-") {
                return key == "group-toolbar-\(canvas.selectedGroupID ?? "")" && groupDragID == nil && groupResizePreview == nil
            }
            // 正文预览也能起拖；松手未移动时才进入编辑。
            if key.hasPrefix("slot-prompt-") { return false }
            // Media bounds are passive measurements for preview validation,
            // not controls. The native canvas still owns selection and dragging.
            if key.hasPrefix("canvas-image-pixels-") || key.hasPrefix("canvas-media-") { return false }
            if key.hasPrefix("slot-editor-") { return key == "slot-editor-\(editingNodeId ?? "")" }
            if key == "composer" { return false }
            if key.hasPrefix("composer-") { return composerFrame != nil }
            if key.hasPrefix("edge-") { return canvas.selectedEdgeId != nil && addMenu == nil && linkDrag == nil && draggingNodeId == nil }
            if key == "node-toolbar" { return canvas.soleSelectedNode != nil && addMenu == nil && draggingNodeId == nil && linkDrag == nil }
            if key == "selection-toolbar" { return selectedCanvasNodes.count > 1 && addMenu == nil && selectionLinkPoint == nil }
            if key == "selection-actions" {
                return canvas.selectedPile == nil && !canvas.selectedNodeIds.isEmpty && addMenu == nil
                    && draggingNodeId == nil && pileDragID == nil && linkDrag == nil
                    && (canvas.selectedNodeIds.count > 1 ? selectionLinkPoint == nil : inputFilesNodeId == nil)
            }
            if key.hasPrefix("canvas-group-") {
                return canvas.groups.contains { "canvas-group-\($0.id)" == key && groupHeaderFrame($0) != nil }
            }
            if key.hasPrefix("add-menu") { return addMenu != nil }
            return true
        }
    }

    func canvasOverlayContains(_ point: CGPoint) -> Bool {
        composerContains(point) || activeControlRegions.contains { $0.value.contains(point) }
    }

    func isCanvasSurface(at point: CGPoint, allowingSlotPreview: Bool = false) -> Bool {
        addMenu == nil && inputFilesNodeId == nil && point.x >= sidebarWidth
            && point.x < viewSize.width && point.y >= 70 && point.y < viewSize.height - 62
            && !composerContains(point)
            && !activeControlRegions.contains {
                !(allowingSlotPreview && $0.key.hasPrefix("slot-fan-"))
                    && $0.value.contains(point)
            }
    }

    func cancelCanvasPointer() {
        stopCanvasEdgePan()
        pointerSession = nil
        selectionLinkPoint = nil
        linkDrag = nil
        marqueeStart = nil
        marqueeCurrent = nil
        if draggingNodeId != nil { NSCursor.pop() }
        draggingNodeId = nil
        draggingIds = []
        dragDelta = .zero
        groupDragID = nil
        pileDragID = nil
        groupResizePreview = nil
        magnetGuideX = nil
        magnetGuideY = nil
        magnetState = CanvasMagnetGeometry.State()
        archiveDrag = nil
        portMotions.reset()
    }

    func routeCanvasPointer(_ event: NSEvent, at point: CGPoint) -> Bool {
        // #region debug-point C:menu-latency-pointer
        #if DEBUG
        if event.type != .leftMouseDragged, let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_LATENCY_URL"], let url = URL(string: endpoint) { let now = ProcessInfo.processInfo.systemUptime; var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-menu-latency", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] pointer received", "data": ["uptime": now, "event": event.timestamp, "type": event.type.rawValue, "menu": addMenu != nil]]); URLSession.shared.dataTask(with: r).resume() }
        #endif
        // #endregion
        let delta = pointerSession.map { CGSize(width: point.x - $0.start.x, height: point.y - $0.start.y) } ?? .zero
        switch event.type {
        case .leftMouseDown:
            // The window monitor also sees the adjacent Agent panel. Only own
            // presses inside the canvas; an active drag still receives its release.
            guard CGRect(origin: .zero, size: viewSize).contains(point) else {
                addMenu = nil
                return false
            }
            // #region debug-point A-B:control-pointer
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_SLOT_AGENT_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7783/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-slot-interactions", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] pointer down", "data": ["point": NSStringFromPoint(point), "surface": isCanvasSurface(at: point), "appearance": controlRegions["appearance"].map { NSStringFromRect($0) } ?? "", "key": inputRouter.anchorView?.window?.isKeyWindow ?? false]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            // #region debug-point A-B:overlay-hit
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7780/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-overlay-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] pointer down", "data": ["point": NSStringFromPoint(point), "surface": isCanvasSurface(at: point), "regions": controlRegions.mapValues { NSStringFromRect($0) }, "selected": Array(canvas.selectedNodeIds), "junction": selectionJunction.map { NSStringFromPoint($0) } ?? "", "hover": hoverHoldNodeId ?? "", "editing": editingNodeId ?? "", "menu": addMenu != nil]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            if let request = addMenu {
                let choice = CanvasAddNodeMenu.Choice.allCases.first {
                    controlRegions["add-menu"]?.contains(point) == true &&
                        controlRegions["add-menu-row-\($0.rawValue)"]?.contains(point) == true
                }
                // #region debug-point A:reference-menu-hit
                #if DEBUG
                if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_MENU_HIT_URL"], let url = URL(string: endpoint) { var r = URLRequest(url: url); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "reference-menu-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A", "msg": "[DEBUG] menu pointer hit", "data": ["point": NSStringFromPoint(point), "choice": choice?.rawValue ?? "none", "menu": NSStringFromRect(controlRegions["add-menu"] ?? .zero), "videoRow": NSStringFromRect(controlRegions["add-menu-row-video"] ?? .zero)]]); URLSession.shared.dataTask(with: r).resume() }
                #endif
                // #endregion
                if controlRegions["add-menu"]?.contains(point) == true, choice == nil { return false }
                pointerSession = .init(target: .menu(request.id, choice), start: point, modifiers: event.modifierFlags)
                return true
            }
            guard isCanvasSurface(at: point) else { return false }
            finishGroupTitle()
            let target: CanvasPointerSession.Target
            var frozenPort: CGPoint?
            if let group = canvas.groups.first(where: { $0.id == canvas.selectedGroupID }),
               let bounds = groupScreenBounds(group),
               let frame = CanvasGroupGeometry.frame(group, nodes: canvas.nodes),
               let handle = CanvasGroupResizeHandle.allCases.first(where: {
                   let p = $0.point(in: bounds)
                   return hypot(point.x - p.x, point.y - p.y) <= 9
               }) {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                target = .groupResize(group.id, handle, frame)
            } else if let group = CanvasGroupHierarchy.parentFirst(canvas.groups).reversed().first(where: { groupHeaderFrame($0)?.contains(point) == true }) {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                canvas.selectGroup(group.id)
                if event.clickCount > 1 { beginGroupTitle(group) }
                target = .group(group.id)
            } else if let junction = selectionJunction, hypot(point.x - junction.x, point.y - junction.y) < 20 {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                target = .junction
            } else if let hit = displayedPortHit(at: point) {
                let node = hit.node
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                target = hit.output ? .link(node.id) : .inputLink(node.id)
                frozenPort = hit.point
                linkDrag = .init(fromNodeId: node.id,
                                 start: hit.output ? CanvasEdgeGeometry.outputHandle(of: screenFrame(of: node))
                                     : CanvasEdgeGeometry.inputHandle(of: screenFrame(of: node)),
                                 cursor: point, targetNodeId: nil, fromInput: !hit.output)
            } else if let pile = pileBody(at: point) {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                lastBlankClick = nil
                if event.modifierFlags.contains(.shift) || !canvas.selectedNodeIds.contains(pile.id) {
                    canvas.select(id: pile.id, additive: event.modifierFlags.contains(.shift))
                }
                target = .pile(pile.id)
            } else if let node = nodeBody(at: point) {
                // #region debug-point B:slot-pointer
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLIPSLOTS_SLOT_AGENT_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7783/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-slot-interactions", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] node pointer ownership", "data": ["kind": node.kind.rawValue, "point": NSStringFromPoint(point), "frame": NSStringFromRect(screenFrame(of: node)), "editing": editingNodeId ?? "", "selected": Array(canvas.selectedNodeIds)]]); URLSession.shared.dataTask(with: r).resume() }
                #endif
                // #endregion
                guard !(node.kind == .text && editingNodeId == node.id) else { return false }
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                lastBlankClick = nil
                if event.clickCount > 1 {
                    if let media = previewableMedia(of: node) { openFullscreen(node, attachment: media) }
                    else { beginEdit(node) }
                    target = .edge
                } else {
                    let wasSelected = canvas.selectedNodeIds.contains(node.id)
                    if canvas.selectedGroupID != nil || event.modifierFlags.contains(.shift) || !canvas.selectedNodeIds.contains(node.id) {
                        canvas.select(id: node.id, additive: event.modifierFlags.contains(.shift))
                    }
                    target = node.kind == .slot && controlRegions["slot-prompt-\(node.id)"]?.contains(point) == true
                        ? .slotPrompt(node.id) : .node(node.id, wasSelected: wasSelected)
                }
            } else if let edge = (showCanvasEdges ? renderedCanvasEdges : []).reversed().first(where: { edge in
                guard let source = canvas.node(id: edge.fromNodeId), let dest = canvas.node(id: edge.toNodeId) else { return false }
                let start = edgeEndpoint(id: source.id, rect: canvas.pile(containing: source.id).map(pileScreenFrame) ?? screenFrame(of: source), output: true)
                let end = edgeEndpoint(id: dest.id, rect: canvas.pile(containing: dest.id).map(pileScreenFrame) ?? screenFrame(of: dest), output: false)
                let controls = CanvasEdgeGeometry.controlPoints(start: start, end: end, outSide: .right, inSide: .left,
                                                                coordinateScale: zoom)
                return CanvasEdgeGeometry.hitTest(point: point, start: start, c1: controls.0, c2: controls.1,
                                                  end: end, tolerance: 10 * zoom)
            }) {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                lastBlankClick = nil
                canvas.clearSelection()
                canvas.selectedEdgeId = edge.id
                target = .edge
            } else if let group = canvas.groups.reversed().first(where: { groupScreenBounds($0)?.contains(point) == true }) {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                canvas.selectGroup(group.id)
                target = .group(group.id)
            } else {
                endInlineEditing()
                inputRouter.claimKeyboardFocus()
                target = .blank
            }
            pointerSession = .init(target: target, start: point, modifiers: event.modifierFlags,
                                   initialPan: effectivePan, initialZoom: zoom, linkPortPoint: frozenPort)
            portMotions.reset()
            return true
        case .leftMouseDragged:
            guard var session = pointerSession else { return false }
            if !CanvasGeometry.isClickWithoutDrag(translation: delta) { session.moved = true }
            pointerSession = session
            if linkDrag != nil {
                // A link exists from mouse-down; even the sub-threshold movement
                // belongs to it, never to node selection or a button underneath.
            } else if !session.moved { return true }
            switch session.target {
            case .blank:
                marqueeStart = session.start
                marqueeCurrent = point
            case .node(let id, _), .slotPrompt(let id):
                if let node = canvas.node(id: id) {
                    updateNodeDrag(node, translation: translatedDrag(session, at: point), point: point)
                    updateCanvasEdgePan(at: point)
                }
            case .link(let id), .inputLink(let id):
                if let node = canvas.node(id: id) {
                    let reverse = linkDrag?.fromInput == true
                    updatePortHover(at: point)
                    linkDrag = .init(fromNodeId: id, start: reverse ? CanvasEdgeGeometry.inputHandle(of: screenFrame(of: node))
                                     : CanvasEdgeGeometry.outputHandle(of: screenFrame(of: node)),
                                     cursor: point, targetNodeId: linkTarget(at: point, from: id, reverse: reverse),
                                     fromInput: reverse)
                    updateCanvasEdgePan(at: point)
                }
            case .junction: selectionLinkPoint = point
            case .group(let id):
                guard editingGroupID == nil else { return true }
                updateGroupDrag(id, session: session, point: point)
                updateCanvasEdgePan(at: point)
            case .pile(let id):
                pileDragID = id
                if draggingIds.isEmpty { draggingIds = canvas.selectedNodeIds }
                let translated = translatedDrag(session, at: point)
                dragDelta = CGSize(width: translated.width / zoom, height: translated.height / zoom)
                updateCanvasEdgePan(at: point)
            case .groupResize(let id, let handle, let frame):
                let translated = translatedDrag(session, at: point)
                let preview = CanvasGroupGeometry.resized(frame, handle: handle,
                    delta: CGSize(width: translated.width / zoom, height: translated.height / zoom))
                groupResizePreview = preview
                if CanvasGroupHierarchy.hasHierarchy(id, groups: canvas.groups)
                    || canvas.groups.first(where: { $0.id == id })?.provenance == .server {
                    draggingIds = canvas.groupDragEntityIDs(id)
                    dragDelta = CGSize(width: preview.minX - frame.minX, height: preview.minY - frame.minY)
                }
            case .edge, .menu: break
            }
            return true
        case .leftMouseUp:
            // #region debug-point B:pointer-up
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7780/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-overlay-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] pointer up", "data": ["point": NSStringFromPoint(point), "target": pointerSession.map { String(describing: $0.target) } ?? "nil", "moved": pointerSession?.moved ?? false, "selected": Array(canvas.selectedNodeIds), "menu": addMenu != nil]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            guard var session = pointerSession else { return false }
            if !CanvasGeometry.isClickWithoutDrag(translation: delta) { session.moved = true }
            stopCanvasEdgePan()
            pointerSession = nil
            switch session.target {
            case .blank:
                if session.moved {
                    commitMarquee(from: session.start, to: point, additive: session.modifiers.contains(.shift))
                    marqueeStart = nil
                    marqueeCurrent = nil
                } else {
                    inputRouter.cursorPoint = point
                    handleBlankTap()
                }
            case .node(let id, let wasSelected):
                if let node = canvas.node(id: id), session.moved {
                    updateNodeDrag(node, translation: translatedDrag(session, at: point), point: point)
                    endNodeDrag(node, translation: delta, point: point)
                } else if !session.modifiers.contains(.shift) {
                    canvas.select(id: id, additive: false)
                    if session.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                       let node = canvas.node(id: id), node.kind == .text, wasSelected {
                        beginEdit(node)
                    } else if session.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                              let node = canvas.node(id: id), node.kind.cardForm != .slotStack,
                              let media = previewableMedia(of: node), media.canvasIsVideoLike {
                        switch node.state {
                        case .queued, .running: break
                        default: inlinePlayback.toggle(nodeID: id, attachment: media)
                        }
                    }
                }
            case .slotPrompt(let id):
                if let node = canvas.node(id: id) {
                    if session.moved {
                        updateNodeDrag(node, translation: translatedDrag(session, at: point), point: point)
                        endNodeDrag(node, translation: delta, point: point)
                    }
                    else if !session.modifiers.contains(.shift) { beginEdit(node) }
                }
            case .link(let id), .inputLink(let id):
                let reverse = linkDrag?.fromInput == true
                updatePortHover(at: point)
                let target = linkTarget(at: point, from: id, reverse: reverse)
                if let node = canvas.node(id: id) {
                    if session.moved { finishLinkDrag(from: node, at: point, target: target, reverse: reverse) }
                    else if reverse { spawnUpstream(of: node, at: point) }
                    else { spawnDownstream(from: node) }
                }
                linkDrag = nil
            case .junction:
                spawnSelectionDownstream(at: session.moved ? point : nil)
                selectionLinkPoint = nil
            case .group(let id):
                if session.moved, groupDragID == id {
                    updateGroupDrag(id, session: session, point: point)
                    canvas.moveGroup(id, by: dragDelta)
                }
                groupDragID = nil; draggingIds = []; dragDelta = .zero
            case .pile(let id):
                if session.moved {
                    let translated = translatedDrag(session, at: point)
                    dragDelta = CGSize(width: translated.width / zoom, height: translated.height / zoom)
                    let ids = draggingIds.isEmpty ? canvas.selectedNodeIds : draggingIds
                    if let target = canvas.piles.last(where: { !ids.contains($0.id) && pileScreenFrame($0).contains(point) }) {
                        if !canvas.addToPile(target.id, entityIDs: ids) { canvas.moveNodes(ids: ids, by: dragDelta) }
                    } else { canvas.moveNodes(ids: ids, by: dragDelta) }
                } else if !session.modifiers.contains(.shift) {
                    canvas.select(id: id, additive: false)
                    pileGalleryID = id
                }
                pileDragID = nil; draggingIds = []; dragDelta = .zero
            case .groupResize(let id, let handle, let frame):
                if session.moved {
                    let translated = translatedDrag(session, at: point)
                    canvas.resizeGroup(id, frame: CanvasGroupGeometry.resized(frame, handle: handle,
                        delta: CGSize(width: translated.width / zoom, height: translated.height / zoom)))
                }
                groupResizePreview = nil
                draggingIds = []; dragDelta = .zero
            case .edge: break
            case .menu(let id, let choice):
                guard let request = addMenu, request.id == id else { return true }
                if let choice {
                    if choice.isAvailable, !session.moved,
                       controlRegions["add-menu-row-\(choice.rawValue)"]?.contains(point) == true {
                        handleAddNode(choice, request: request)
                    }
                } else {
                    addMenu = nil
                    lastBlankClick = nil
                }
            }
            return true
        default: return false
        }
    }

    func translatedDrag(_ session: CanvasPointerSession, at point: CGPoint) -> CGSize {
        CanvasReplicaGeometry.dragTranslation(start: session.start, point: point,
            initialPan: session.initialPan, initialZoom: session.initialZoom, pan: effectivePan, zoom: zoom)
    }

    func updateGroupDrag(_ id: String, session: CanvasPointerSession, point: CGPoint) {
        guard canvas.groups.contains(where: { $0.id == id }) else { return }
        groupDragID = id
        draggingIds = canvas.groupDragEntityIDs(id)
        let translated = translatedDrag(session, at: point)
        dragDelta = CGSize(width: translated.width / zoom, height: translated.height / zoom)
    }

    func updateCanvasEdgePan(at point: CGPoint) {
        edgePanPoint = point
        guard CanvasReplicaGeometry.edgePan(point: point, viewport: canvasContentViewport) != .zero,
              !canvasOverlayContains(point), archiveDrag == nil else {
            stopCanvasEdgePan()
            return
        }
        guard edgePanTask == nil else { return }
        let token = UUID()
        edgePanSessionID = token
        edgePanTask = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, edgePanSessionID == token {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, edgePanSessionID == token else { return }
                let now = ProcessInfo.processInfo.systemUptime
                advanceCanvasEdgePan(elapsed: now - previous)
                previous = now
            }
        }
    }

    func advanceCanvasEdgePan(elapsed: Double) {
        guard let session = pointerSession, let point = edgePanPoint,
              !canvasOverlayContains(point), archiveDrag == nil,
              canvas.activeTool == .select else { stopCanvasEdgePan(); return }
        let delta = CanvasReplicaGeometry.edgePan(point: point, viewport: canvasContentViewport, elapsed: elapsed)
        guard delta != .zero else { stopCanvasEdgePan(); return }
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        switch session.target {
        case .link(let id), .inputLink(let id):
            updatePortHover(at: point)
            linkDrag?.cursor = point
            linkDrag?.targetNodeId = linkTarget(at: point, from: id, reverse: linkDrag?.fromInput == true)
        case .node(let id, _), .slotPrompt(let id):
            if let node = canvas.node(id: id) {
                updateNodeDrag(node, translation: translatedDrag(session, at: point), point: point)
            }
        case .group(let id): updateGroupDrag(id, session: session, point: point)
        case .pile(let id):
            pileDragID = id
            let translated = translatedDrag(session, at: point)
            dragDelta = CGSize(width: translated.width / zoom, height: translated.height / zoom)
        default: stopCanvasEdgePan()
        }
    }

    func stopCanvasEdgePan() {
        let wasMoving = edgePanTask != nil
        edgePanSessionID = nil
        edgePanTask?.cancel()
        edgePanTask = nil
        edgePanPoint = nil
        if wasMoving { canvas.updateViewport(pan: pan, zoom: zoom) }
    }
}
