#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runConnectionInteractionProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failures.append(message) }
            NSLog("[CanvasConnection] \(condition ? "PASS" : "FAIL") \(message)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(360)) }
        func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        func screenshot(_ name: String) {
            guard let content = inputRouter.anchorView?.window?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let motion = CanvasPortMotion(ticksAutomatically: false)
        let home = CGPoint(x: 500, y: 400)
        motion.update(cursor: CGPoint(x: 520, y: 412), home: home, output: true, zoom: 1, now: 10)
        check(motion.offset(at: 10) == .zero && motion.offset(at: 10.125).x > 20,
              "entry interpolates with recovered cubic overshoot rather than teleporting")
        motion.update(cursor: CGPoint(x: 530, y: 410), home: home, output: true, zoom: 1, now: 10.3)
        check(motion.offset(at: 10.3) == CGPoint(x: 30, y: 10),
              "after entry the port follows immediately without accumulating animation lag")
        motion.update(cursor: CGPoint(x: 600, y: 400), home: home, output: true, zoom: 1, now: 11)
        check(motion.offset(at: 11) == CGPoint(x: 30, y: 10)
              && motion.offset(at: 11.4) == .zero,
              "leaving recovered bounds returns from the displayed point over 400ms")
        motion.update(cursor: CGPoint(x: 512, y: 406), home: home, output: true, zoom: 1, now: 12)
        motion.update(cursor: CGPoint(x: 520, y: 414), home: CGPoint(x: 510, y: 410),
                      output: true, zoom: 2, now: 12.3)
        check(motion.offset(at: 12.3) == .zero,
              "viewport changes start a fresh hover session with no stale screen offset")
        canvas.isLibraryExpanded = false
        gridSnapEnabled = false
        pan = CGSize(width: 100, height: 90)
        zoom = 1
        guard let source = createNode(kind: .image, at: CGPoint(x: 320, y: 320),
                                      parentNodeId: nil, beginEditing: false, quiet: true),
              let target = createNode(kind: .image, at: CGPoint(x: 840, y: 320),
                                      parentNodeId: nil, beginEditing: false, quiet: true),
              let covered = createNode(kind: .image, at: CGPoint(x: 410, y: 660),
                                       parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        for node in [source, target, covered] {
            canvas.updateNode(id: node.id) {
                $0.width = 220; $0.height = 160; $0.mediaRole = .generation
                $0.x = node.id == target.id ? 840 : 320
                $0.y = node.id == covered.id ? 660 : 200
            }
        }
        canvas.select(id: source.id, additive: false)
        inputRouter.cursorPoint = center(screenFrame(of: canvas.node(id: source.id)!))
        hoverHoldNodeId = nil
        await settle()
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1) else { return false }
            return inputRouter.routeForRegression(event)
        }

        guard let port = outputPortPoint else { return }
        let original = canvas.node(id: source.id)!.frame
        let end = CGPoint(x: 1170, y: 660)
        check(mouse(.leftMouseDown, port) && pointerSession?.linkPortPoint != nil && linkDrag == nil,
              "press owns the source and waits for connection threshold")
        var continuous = true
        for index in 1...80 {
            let amount = CGFloat(index) / 80
            let point = CGPoint(x: port.x + (end.x - port.x) * amount,
                                y: port.y + (end.y - port.y) * amount)
            if index == 40 { inputRouter.anchorView = nil }
            continuous = mouse(.leftMouseDragged, point, flags: index.isMultiple(of: 2) ? .shift : [])
                && linkDrag?.fromNodeId == source.id && continuous
            if index == 40 { inputRouter.anchorView = anchor }
        }
        check(continuous, "80 continuous moves retain the same connection owner")
        let before = canvas.nodes.count
        check(mouse(.leftMouseUp, end) && addMenu?.parentNodeId == source.id && linkDrag == nil,
              "blank release transfers preview to the pending create menu")
        check(canvas.nodes.count == before && canvas.edges.isEmpty,
              "pending preview never adds a persisted node or edge")
        await settle()
        screenshot("connection-pending-menu")
        if let request = addMenu {
            handleAddNode(.image, request: request)
            await menuCreationTask?.value
            await settle()
            let children = canvas.nodes.filter { ![source.id, target.id, covered.id].contains($0.id) }
            check(children.count == 1 && canvas.edges.count == 1
                  && canvas.edges.first?.fromNodeId == source.id
                  && canvas.edges.first?.toNodeId == children.first?.id,
                  "choosing a node replaces preview with exactly one real edge")
        } else { check(false, "pending menu exists for selection") }
        check(canvas.node(id: source.id)?.frame == original, "connection never moves the source")

        canvas.select(id: source.id, additive: false)
        hoverHoldNodeId = nil
        inputRouter.cursorPoint = center(screenFrame(of: canvas.node(id: source.id)!))
        await settle()
        if let port = outputPortPoint {
            let body = center(screenFrame(of: canvas.node(id: target.id)!))
            _ = mouse(.leftMouseDown, port)
            // Coalesced events can deliver a release without a final drag.
            _ = mouse(.leftMouseUp, body)
            check(canvas.edges.contains { $0.fromNodeId == source.id && $0.toNodeId == target.id },
                  "far release without a final drag still connects the intended node")
            let count = canvas.edges.count
            canvas.select(id: source.id, additive: false)
            hoverHoldNodeId = nil
            inputRouter.cursorPoint = center(screenFrame(of: canvas.node(id: source.id)!))
            await settle()
            _ = mouse(.leftMouseDown, outputPortPoint ?? port)
            _ = mouse(.leftMouseDragged, body)
            _ = mouse(.leftMouseUp, body)
            check(canvas.edges.count == count && addMenu?.parentNodeId == source.id,
                  "duplicate body offers a new node without mutating the graph")
            addMenu = nil
            _ = mouse(.leftMouseDown, port)
            _ = mouse(.leftMouseDragged, end)
            cancelCanvasPointer()
            _ = mouse(.leftMouseUp, end)
            check(linkDrag == nil && addMenu == nil && pointerSession == nil && canvas.edges.count == count,
                  "cancel followed by release cannot create a ghost connection")
        } else { check(false, "source port remains available after creating a child") }

        // Put an unselected node inside the selected node's generation form.
        canvas.select(id: source.id, additive: false)
        inputRouter.cursorPoint = center(screenFrame(of: canvas.node(id: source.id)!))
        hoverHoldNodeId = nil
        await settle()
        if let form = composerFrame {
            let point = CGPoint(x: form.midX, y: form.midY)
            let world = CanvasGeometry.canvasPoint(screen: point, pan: effectivePan, zoom: zoom)
            canvas.updateNode(id: covered.id) {
                $0.x = world.x - 110; $0.y = world.y - 80
            }
            await settle()
            check(nodeBody(at: point)?.id == covered.id && composerContains(point),
                  "generation form covers the adjacent card")
            check(inputRouter.canFocusEditorAt?(point) == true && !isCanvasSurface(at: point),
                  "visible editor owns focus and excludes canvas presses")
            screenshot("connection-adjacent-over-form")
            let origin = canvas.node(id: covered.id)!.frame
            check(!mouse(.leftMouseDown, point), "canvas yields a press to the foreground form")
            let moved = CGPoint(x: point.x + 160, y: point.y + 80)
            _ = mouse(.leftMouseDragged, moved)
            _ = mouse(.leftMouseUp, moved)
            check(canvas.node(id: covered.id)?.frame == origin && pointerSession == nil && draggingNodeId == nil
                  && canvas.selectedNodeIds == [source.id],
                  "dragging over the form never moves or selects an underlying card")
        } else { check(false, "selected source has a generation form") }
        // The foreground form now correctly acquires editor focus. Finish that
        // scenario before testing exposed node ports, which hide while editing.
        endInlineEditing()

        let sourceNow = canvas.node(id: source.id)!
        canvas.updateNode(id: target.id) {
            $0.x = sourceNow.x; $0.y = sourceNow.y
            $0.width = sourceNow.width; $0.height = sourceNow.height
        }
        canvas.select(id: source.id, additive: false)
        let overlap = center(screenFrame(of: sourceNow))
        check(nodeBody(at: overlap)?.id == source.id,
              "selected front card and body hit agree despite document order")
        canvas.select(id: target.id, additive: false)
        check(nodeBody(at: overlap)?.id == target.id,
              "changing selection changes paint and hit order together")
        screenshot("connection-overlap-selection")

        // Overlapping input hover bounds must choose the closer anchor, not
        // whichever moving glyph happened to collapse its distance to zero.
        canvas.updateNode(id: source.id) { $0.x = 200; $0.y = 200 }
        canvas.updateNode(id: target.id) { $0.x = 820; $0.y = 200 }
        canvas.updateNode(id: covered.id) { $0.x = 860; $0.y = 220 }
        canvas.select(id: source.id, additive: false)
        hoverHoldNodeId = nil
        portMotions = CanvasPortMotions()
        await settle()
        // Native onFocus is delivered asynchronously after the form press.
        // Drain it and finish the actual responder before this independent case.
        endInlineEditing()
        await settle()
        check(editingNodeId == nil && composingNodeId == nil,
              "previous composer editing ends before the exposed port scenario")
        NSLog("[PortResetProbe] container=%@ opacity=%@ point=%@ static=%@ editor=%@ composing=%@ interaction=%@ menu=%@ dragging=%@ inputs=%@",
              String(describing: ObjectIdentifier(portMotions)),
              String(portMotions.motion(nodeID: source.id, output: true).opacity()),
              String(describing: outputPortPoint), staticPortNodes.map(\.id).description,
              editingNodeId ?? "", composingNodeId ?? "", interactionNode?.id ?? "",
              String(addMenu != nil), draggingNodeId ?? "", inputFilesNodeId ?? "")
        if let current = canvas.node(id: source.id) {
            let home = outputPortHome(of: current), point = portPoint(of: current, output: true)
            NSLog("[PortResetProbe] home=%@ homeExposed=%@ presentationExposed=%@ blockers=%@",
                  NSStringFromPoint(home), String(portIsExposed(home, nodeId: source.id)),
                  String(portIsExposed(point, nodeId: source.id)),
                  activeControlRegions.filter { $0.value.intersects(CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)) }.description)
        }
        let targetHome = inputPortHome(of: canvas.node(id: target.id)!)
        let sharedBounds = CGPoint(x: targetHome.x + 10, y: targetHome.y + 8)
        // Remove the pre-existing source -> target edge for this valid target.
        for edge in canvas.edges.filter({ $0.fromNodeId == source.id && $0.toNodeId == target.id }) {
            _ = canvas.disconnect(edgeId: edge.id)
        }
        check(linkTarget(at: sharedBounds, from: source.id) == target.id,
              "overlapping input capture regions pick the closest actual anchor")
        if let port = outputPortPoint {
            let pressOwned = mouse(.leftMouseDown, port)
            NSLog("[PortResetProbe] press=%@ target=%@ opacity=%@",
                  String(pressOwned), String(describing: pointerSession?.target),
                  String(portMotions.motion(nodeID: source.id, output: true).opacity()))
            _ = mouse(.leftMouseDragged, targetHome)
            await settle()
            let farther = CGPoint(x: targetHome.x + 18, y: targetHome.y + 12)
            _ = mouse(.leftMouseDragged, farther)
            // Inner reveal lasts 300ms independently of the outer 250ms
            // magnet. Sample after both have settled.
            try? await Task.sleep(for: .milliseconds(360))
            NSLog("[PortResetProbe] actual=%@ expected=%@ hover=%@ target=%@",
                  NSStringFromPoint(inputPortPoint(of: canvas.node(id: target.id)!)),
                  NSStringFromPoint(farther), hoverHoldNodeId ?? "nil", linkDrag?.targetNodeId ?? "nil")
            check(inputPortPoint(of: canvas.node(id: target.id)!) == farther,
                  "input presentation follows live drag events after prior hover")
            check(outputPortPoint == pointerSession?.linkPortPoint && linkDrag?.fromNodeId == source.id,
                  "following target input leaves the source glyph and owner frozen")
            _ = mouse(.leftMouseUp, farther)
            check(canvas.edges.contains { $0.fromNodeId == source.id && $0.toNodeId == target.id },
                  "release at the displayed target connects exactly that target")
        } else { check(false, "live input follow has an available source") }

        canvas.select(id: source.id, additive: false)
        hoverHoldNodeId = nil
        portMotions = CanvasPortMotions()
        await settle()
        let frame = screenFrame(of: canvas.node(id: source.id)!)
        let edgePoint = CGPoint(x: frame.maxX - 1, y: frame.midY)
        _ = mouse(.leftMouseDown, edgePoint)
        if case .node(let id, _) = pointerSession?.target {
            check(id == source.id && linkDrag == nil, "card edge press keeps node dragging rather than acquiring a hidden link")
        } else { check(false, "card edge press keeps node dragging rather than acquiring a hidden link") }
        _ = mouse(.leftMouseUp, edgePoint)
        let sourceHome = outputPortHome(of: canvas.node(id: source.id)!)
        let under = CanvasGeometry.canvasPoint(screen: sourceHome, pan: effectivePan, zoom: zoom)
        canvas.updateNode(id: covered.id) { $0.x = under.x - 20; $0.y = under.y - 80 }
        hoverHoldNodeId = source.id
        await settle()
        check(portIsExposed(sourceHome, nodeId: source.id) && outputPortPoint == sourceHome,
              "selected source port stays visible over a lower adjacent card")
        check(resolvedHoverHold(at: sourceHome) == source.id,
              "hover over the visible overlapping glyph retains its source")
        _ = mouse(.leftMouseDown, sourceHome)
        check(pointerSession?.linkPortPoint == sourceHome && linkDrag == nil,
              "visible front glyph captures its displayed owner before drag")
        cancelCanvasPointer()
        _ = mouse(.leftMouseUp, sourceHome)
        check(linkDrag == nil && addMenu == nil,
              "cancelling an overlapping front port leaves no pending connection")
        let adjacentBody = center(screenFrame(of: canvas.node(id: covered.id)!))
        check(resolvedHoverHold(at: adjacentBody) == covered.id,
              "outside the glyph the adjacent body remains directly reachable")
        _ = mouse(.leftMouseDown, adjacentBody)
        if case .node(let id, _) = pointerSession?.target {
            check(id == covered.id && linkDrag == nil, "adjacent body owns its first press beside a front glyph")
        } else { check(false, "adjacent body owns its first press beside a front glyph") }
        check(!portIsExposed(sourceHome, nodeId: source.id),
              "selecting the adjacent card covers a lower source port")
        let adjacentEnd = CGPoint(x: adjacentBody.x + 100, y: adjacentBody.y + 40)
        _ = mouse(.leftMouseDragged, adjacentEnd)
        check(draggingNodeId == covered.id, "adjacent body drag does not change to a link")
        _ = mouse(.leftMouseUp, adjacentEnd)

        for scale in [CGFloat(0.25), 0.65, 1, 2, 4] {
            let moving = CGRect(x: 0, y: 0, width: 100, height: 100)
            let stationary = CGRect(x: 250, y: 0, width: 100, height: 100)
            let acquired = CanvasMagnetGeometry.resolve(moving: [moving], stationary: [stationary],
                proposed: CGSize(width: 150 + 5 / scale, height: 0), zoom: scale, grid: false)
            let held = CanvasMagnetGeometry.resolve(moving: [moving], stationary: [stationary],
                proposed: CGSize(width: 150 + 11 / scale, height: 0), zoom: scale, grid: false, state: acquired.state)
            let released = CanvasMagnetGeometry.resolve(moving: [moving], stationary: [stationary],
                proposed: CGSize(width: 150 + 16 / scale, height: 0), zoom: scale, grid: false, state: held.state)
            check(abs(acquired.delta.width - 150) < 0.001 && acquired.state.x != nil,
                  "alignment acquires at a constant screen distance \(scale)x")
            check(abs(held.delta.width - 150) < 0.001 && held.state.x?.guide == acquired.state.x?.guide,
                  "alignment retains the actual x guide independently \(scale)x")
            check(abs(released.delta.width - 150) > 0.001,
                  "alignment releases beyond the hold distance \(scale)x")
            let home = CGPoint(x: 500, y: 400)
            let inward = CGPoint(x: home.x - 23 * scale, y: home.y + 12 * scale)
            let outside = CGPoint(x: home.x - 25 * scale, y: home.y)
            check(CanvasPortInteractionGeometry.point(cursor: inward, home: home, output: true, zoom: scale) == inward,
                  "output handle follows inward cursor within recovered bounds \(scale)x")
            check(CanvasPortInteractionGeometry.point(cursor: outside, home: home, output: true, zoom: scale) == home,
                  "output handle returns home outside recovered bounds \(scale)x")
        }
        let first = CGRect(x: 20, y: 0, width: 100, height: 100)
        let leftmost = CGRect(x: -100, y: 0, width: 100, height: 100)
        let multi = CanvasMagnetGeometry.resolve(moving: [first, leftmost], stationary: [],
            proposed: CGSize(width: 2, height: 0), zoom: 1, grid: true)
        check(multi.delta.width == -5, "multi-grid correction uses first dragged item rather than union minimum")
        let negative = CanvasMagnetGeometry.resolve(moving: [CGRect(x: -7.5, y: 0, width: 10, height: 10)],
            stationary: [], proposed: .zero, zoom: 1, grid: true)
        check(negative.delta.width == 7.5, "grid reproduces JavaScript negative half-cell rounding")

        let report: [String: Any] = [
            "passed": passed, "failures": failures, "complete": true,
            "expectedCrateSubmissions": 0, "systemInputValidated": false,
            "scope": "native AppKit router, displayed port motion, live target follow, pending wire lifecycle, composer occlusion, stable paint/hit order",
            "competitorNodeMagnetThresholdsVerified": false
        ]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
