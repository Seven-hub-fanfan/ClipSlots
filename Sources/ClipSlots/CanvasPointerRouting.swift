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
    enum Target { case blank, node(String), slotPrompt(String), link(String), junction, edge, menu(UUID, CanvasAddNodeMenu.Choice?) }
    let target: Target
    let start: CGPoint
    let modifiers: NSEvent.ModifierFlags
    var moved = false
}

extension CanvasWorkspaceView {
    /// 只采用当前存在的浮层。面板区域同步计算，避免上一帧 preference 造成穿透/幽灵遮挡。
    var activeControlRegions: [String: CGRect] {
        controlRegions.filter { key, _ in
            // 正文预览也能起拖；松手未移动时才进入编辑。
            if key.hasPrefix("slot-prompt-") { return false }
            if key.hasPrefix("slot-editor-") { return key == "slot-editor-\(editingNodeId ?? "")" }
            if key == "composer" { return false }
            if key.hasPrefix("composer-") { return composerFrame != nil }
            if key.hasPrefix("edge-") { return canvas.selectedEdgeId != nil && addMenu == nil && linkDrag == nil && draggingNodeId == nil }
            if key == "node-toolbar" { return canvas.soleSelectedNode != nil && addMenu == nil && draggingNodeId == nil && linkDrag == nil }
            if key == "selection-toolbar" { return selectedCanvasNodes.count > 1 && addMenu == nil && selectionLinkPoint == nil }
            if key.hasPrefix("add-menu") { return addMenu != nil }
            return true
        }
    }

    func canvasOverlayContains(_ point: CGPoint) -> Bool {
        composerFrame?.contains(point) == true || activeControlRegions.values.contains { $0.contains(point) }
    }

    func isCanvasSurface(at point: CGPoint, allowingSlotPreview: Bool = false) -> Bool {
        addMenu == nil && inputFilesNodeId == nil && point.x >= sidebarWidth
            && point.x < viewSize.width && point.y >= 70 && point.y < viewSize.height - 62
            && composerFrame?.contains(point) != true
            && !activeControlRegions.contains {
                !(allowingSlotPreview && $0.key.hasPrefix("slot-fan-")) && $0.value.contains(point)
            }
    }

    func cancelCanvasPointer() {
        pointerSession = nil
        selectionLinkPoint = nil
        linkDrag = nil
        marqueeStart = nil
        marqueeCurrent = nil
        if draggingNodeId != nil { NSCursor.pop() }
        draggingNodeId = nil
        draggingIds = []
        dragDelta = .zero
        archiveDrag = nil
    }

    func routeCanvasPointer(_ event: NSEvent, at point: CGPoint) -> Bool {
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
                if controlRegions["add-menu"]?.contains(point) == true, choice == nil { return false }
                pointerSession = .init(target: .menu(request.id, choice), start: point, modifiers: event.modifierFlags)
                return true
            }
            guard isCanvasSurface(at: point) else { return false }
            let target: CanvasPointerSession.Target
            if let junction = selectionJunction, hypot(point.x - junction.x, point.y - junction.y) < 20 {
                target = .junction
            } else if let node = interactionNode, let port = outputPortPoint,
                      hypot(point.x - port.x, point.y - port.y) < 20 {
                target = .link(node.id)
            } else if let node = canvas.nodes.reversed().first(where: { screenFrame(of: $0).contains(point) }) {
                // #region debug-point B:slot-pointer
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLIPSLOTS_SLOT_AGENT_PROBE"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7783/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-slot-interactions", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] node pointer ownership", "data": ["kind": node.kind.rawValue, "point": NSStringFromPoint(point), "frame": NSStringFromRect(screenFrame(of: node)), "editing": editingNodeId ?? "", "selected": Array(canvas.selectedNodeIds)]]); URLSession.shared.dataTask(with: r).resume() }
                #endif
                // #endregion
                guard !(node.kind == .text && editingNodeId == node.id) else { return false }
                endInlineEditing()
                lastBlankClick = nil
                if event.clickCount > 1 {
                    if let media = previewableMedia(of: node) { openFullscreen(node, attachment: media) }
                    else { beginEdit(node) }
                    target = .edge
                } else {
                    if event.modifierFlags.contains(.shift) || !canvas.selectedNodeIds.contains(node.id) {
                        canvas.select(id: node.id, additive: event.modifierFlags.contains(.shift))
                    }
                    target = node.kind == .slot && controlRegions["slot-prompt-\(node.id)"]?.contains(point) == true
                        ? .slotPrompt(node.id) : .node(node.id)
                }
            } else if let edge = canvas.edges.reversed().first(where: { edge in
                guard let source = canvas.node(id: edge.fromNodeId), let dest = canvas.node(id: edge.toNodeId) else { return false }
                let start = CanvasEdgeGeometry.outputHandle(of: screenFrame(of: source))
                let end = CanvasEdgeGeometry.inputHandle(of: screenFrame(of: dest))
                let controls = CanvasEdgeGeometry.controlPoints(start: start, end: end, outSide: .right, inSide: .left)
                return CanvasEdgeGeometry.hitTest(point: point, start: start, c1: controls.0, c2: controls.1,
                                                  end: end, tolerance: TapSkin.edgeHitSlop)
            }) {
                endInlineEditing()
                lastBlankClick = nil
                canvas.clearSelection()
                canvas.selectedEdgeId = edge.id
                target = .edge
            } else {
                endInlineEditing()
                target = .blank
            }
            pointerSession = .init(target: target, start: point, modifiers: event.modifierFlags)
            return true
        case .leftMouseDragged:
            guard var session = pointerSession else { return false }
            if !CanvasGeometry.isClickWithoutDrag(translation: delta) { session.moved = true }
            pointerSession = session
            guard session.moved else { return true }
            switch session.target {
            case .blank:
                marqueeStart = session.start
                marqueeCurrent = point
            case .node(let id), .slotPrompt(let id):
                if let node = canvas.node(id: id) { updateNodeDrag(node, translation: delta, point: point) }
            case .link(let id):
                if let node = canvas.node(id: id) {
                    linkDrag = .init(fromNodeId: id, start: CanvasEdgeGeometry.outputHandle(of: screenFrame(of: node)),
                                     cursor: point, targetNodeId: linkTarget(at: point, from: id))
                }
            case .junction: selectionLinkPoint = point
            case .edge, .menu: break
            }
            return true
        case .leftMouseUp:
            // #region debug-point B:pointer-up
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { var r = URLRequest(url: URL(string: "http://127.0.0.1:7780/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-overlay-hit", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "B", "msg": "[DEBUG] pointer up", "data": ["point": NSStringFromPoint(point), "target": pointerSession.map { String(describing: $0.target) } ?? "nil", "moved": pointerSession?.moved ?? false, "selected": Array(canvas.selectedNodeIds), "menu": addMenu != nil]]); URLSession.shared.dataTask(with: r).resume() }
            #endif
            // #endregion
            guard let session = pointerSession else { return false }
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
            case .node(let id):
                if let node = canvas.node(id: id), session.moved {
                    endNodeDrag(node, translation: delta, point: point)
                } else if !session.modifiers.contains(.shift) {
                    canvas.select(id: id, additive: false)
                }
            case .slotPrompt(let id):
                if let node = canvas.node(id: id) {
                    if session.moved { endNodeDrag(node, translation: delta, point: point) }
                    else if !session.modifiers.contains(.shift) { beginEdit(node) }
                }
            case .link(let id):
                let target = linkTarget(at: point, from: id)
                linkDrag = nil
                if let node = canvas.node(id: id) {
                    if session.moved { finishLinkDrag(from: node, at: point, target: target) }
                    else { spawnDownstream(from: node) }
                }
            case .junction:
                spawnSelectionDownstream(at: session.moved ? point : nil)
                selectionLinkPoint = nil
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
}
