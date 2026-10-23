#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    func runReplicaProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ title: String) {
            if condition { passed += 1 } else { failures.append(title) }
            NSLog("[CanvasReplica] \(condition ? "PASS" : "FAIL") \(title)")
        }
        func settle(_ duration: Double = 0.15) async { try? await Task.sleep(for: .seconds(duration)) }
        func screenshot(_ name: String) {
            guard let content = (CanvasAgentGroupsProbeBridge.current ?? self).inputRouter.anchorView?.window?.contentView,
                  let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(
                to: directory.appendingPathComponent(name + ".png"))
        }
        _ = await AgentProcessRunner.run(executable: "/usr/bin/swift", arguments: [
            "-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            print(AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)
            var windows: CFTypeRef?
            print(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows).rawValue)
            """, String(ProcessInfo.processInfo.processIdentifier)
        ], timeout: 15)
        canvas.isLibraryExpanded = false
        pan = CGSize(width: 80, height: 90)
        zoom = 0.65
        await settle()
        guard let text = createNode(kind: .text, at: CGPoint(x: 260, y: 360), parentNodeId: nil,
                                    beginEditing: false, quiet: true),
              let image = createNode(kind: .image, at: CGPoint(x: 820, y: 360), parentNodeId: text.id,
                                     beginEditing: false, quiet: true),
              let video = createNode(kind: .video, at: CGPoint(x: 1400, y: 360), parentNodeId: text.id,
                                     beginEditing: false, quiet: true) else { return }
        commitEdit(text, text: "Replica reference prompt")
        commitEdit(image, text: "Replica image")
        commitEdit(video, text: "Replica video")
        if let edge = canvas.incomingEdges(of: video.id).first { _ = canvas.disconnect(edgeId: edge.id) }
        await settle()
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) -> Bool {
            let location = (inputRouter.anchorView ?? anchor).convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: 1)!
            return inputRouter.routeForRegression(event)
        }
        canvas.select(id: text.id, additive: false)
        hoverHoldNodeId = nil
        inputRouter.cursorPoint = CGPoint(x: screenFrame(of: text).midX, y: screenFrame(of: text).midY)
        await settle()
        let sourceFrame = screenFrame(of: text)
        let port = CGPoint(x: sourceFrame.maxX + TapSkin.portOffset, y: sourceFrame.midY)
        check(outputPortPoint != nil, "source port is exposed")
        check(mouse(.leftMouseDown, port) && pointerSession?.linkPortPoint != nil && linkDrag == nil,
              "press owns the port while waiting for connection threshold")
        check(mouse(.leftMouseDragged, CGPoint(x: port.x + 1, y: port.y)) && linkDrag == nil,
              "one-pixel movement remains a plus click")
        var continuous = true
        for step in 1...60 {
            let point = CGPoint(x: port.x + CGFloat(step) * 9, y: port.y + sin(CGFloat(step)) * 50)
            continuous = mouse(.leftMouseDragged, point, flags: step % 2 == 0 ? .shift : []) && linkDrag != nil && continuous
            await settle(0.004)
        }
        let destination = screenFrame(of: video)
        let target = CGPoint(x: destination.minX - TapSkin.portOffset, y: destination.midY)
        _ = mouse(.leftMouseDragged, target)
        check(continuous && linkDrag?.targetNodeId == video.id, "drag stays owned through all moves and modifier changes")
        screenshot("replica-wire-preview")
        _ = mouse(.leftMouseUp, target)
        check(canvas.edges.contains { $0.fromNodeId == text.id && $0.toNodeId == video.id }
              && linkDrag == nil && pointerSession == nil, "release commits exactly one connection")
        check(canvas.node(id: text.id)?.frame == text.frame, "link drag never moves its source")
        let edgeCount = canvas.edges.count
        _ = mouse(.leftMouseDown, port)
        _ = mouse(.leftMouseDragged, target)
        _ = mouse(.leftMouseUp, target)
        check(canvas.edges.count == edgeCount && addMenu?.parentNodeId == text.id,
              "duplicate target offers a new node without adding a duplicate edge")
        addMenu = nil
        showCanvasEdges = false
        check(canvas.edges.count == edgeCount, "hiding wires preserves the graph")
        showCanvasEdges = true
        if let navigation = controlRegions["canvas-navigation"] {
            let before = canvas.nodes.count
            let point = CGPoint(x: navigation.minX + 20, y: navigation.minY + 20)
            check(!mouse(.leftMouseDown, point) && canvas.nodes.count == before,
                  "minimap controls never start canvas node gestures")
        }
        for scale in [CGFloat(0.25), 0.65, 1, 2, 4] {
            let moving = CGRect(x: 0, y: 0, width: 100, height: 100)
            let stationary = CGRect(x: 250, y: 0, width: 100, height: 100)
            let proposed = CGSize(width: 150 + 5 / scale, height: 3 / scale)
            let result = CanvasMagnetGeometry.resolve(moving: [moving], stationary: [stationary],
                                                       proposed: proposed, zoom: scale, grid: false)
            check(abs(result.delta.width - 150) < 0.001 && result.horizontalGuide != nil,
                  "alignment magnet uses a fixed screen threshold at \(scale)x")
        }
        let grid = CanvasMagnetGeometry.resolve(moving: [CGRect(x: 3, y: 5, width: 20, height: 20)],
                                                stationary: [], proposed: CGSize(width: 18, height: 20),
                                                zoom: 1, grid: true)
        check((3 + grid.delta.width).truncatingRemainder(dividingBy: 15) == 0
              && (5 + grid.delta.height).truncatingRemainder(dividingBy: 15) == 0, "grid option follows shipped 15-point cells")
        let viewport = canvasContentViewport
        check(CanvasReplicaGeometry.edgePan(point: CGPoint(x: viewport.midX, y: viewport.midY),
                                             viewport: viewport) == .zero, "edge pan stays idle away from the 40-point border")
        let right = CGPoint(x: viewport.maxX - 10, y: viewport.midY)
        check(abs(CanvasReplicaGeometry.edgePan(point: right, viewport: viewport).width + 11.25) < 0.001,
              "edge pan matches original 40-point margin and proportional 15-point speed")
        check(CanvasReplicaGeometry.edgePan(point: CGPoint(x: CGFloat.nan, y: 0), viewport: viewport) == .zero,
              "invalid pointer cannot corrupt viewport")
        for scale in [CGFloat(0.15), 0.65, 1, 2, 4] {
            zoom = scale
            let rect = CGRect(x: 300, y: 300, width: 260 * scale, height: 300 * scale)
            let port = CGPoint(x: rect.minX - TapSkin.portOffset, y: rect.midY)
            check(hitsInputPort(CGPoint(x: port.x - 29 * scale, y: port.y), rect: rect)
                  && !hitsInputPort(CGPoint(x: port.x - 31 * scale, y: port.y), rect: rect),
                  "connection hit radius follows 30 canvas points at \(scale)x")
        }
        zoom = 0.65
        canvas.select(id: text.id, additive: false)
        inputRouter.cursorPoint = CGPoint(x: screenFrame(of: text).midX, y: screenFrame(of: text).midY)
        await settle()
        let nodePoint = inputRouter.cursorPoint
        let oldPan = pan
        _ = mouse(.leftMouseDown, nodePoint)
        _ = mouse(.leftMouseDragged, right)
        await settle(0.12)
        check(pan.width < oldPan.width && edgePanTask != nil && draggingNodeId == text.id,
              "held node drag pans continuously at the edge without new pointer events")
        let moving = screenFrame(of: text)
        check(abs(moving.midX - right.x) < 9 && abs(moving.midY - right.y) < 9,
              "node remains under the pointer while viewport pans")
        cancelCanvasPointer()
        check(edgePanTask == nil && linkDrag == nil && canvas.node(id: text.id)?.frame == text.frame,
              "cancel stops edge motion and does not commit node movement")
        pan = oldPan
        canvas.select(id: text.id, additive: false)
        inputRouter.cursorPoint = nodePoint
        await settle()
        _ = mouse(.leftMouseDown, port)
        _ = mouse(.leftMouseDragged, right)
        await settle(0.12)
        check(linkDrag != nil && pan.width < oldPan.width,
              "link remains visible throughout held edge auto-pan")
        cancelCanvasPointer()
        pan = oldPan
        let projected = CanvasReplicaGeometry.mapProjection(nodes: [CGRect(x: 0, y: 0, width: 100, height: 80)],
            viewport: CGRect(x: -1000, y: -500, width: 800, height: 600))
        check(projected.rect(CGRect(x: -1000, y: -500, width: 800, height: 600))
            .maxX <= 200.001 && projected.bounds.minX == -1000,
              "minimap projection includes the current off-node viewport")
        let newPoint = CanvasMagnetGeometry.resultOrigin(source: text.frame, size: image.frame.size,
                                                         occupied: [text.frame])
        check(newPoint.y == text.y && newPoint.x == text.frame.maxX + 28, "result geometry preserves the row and 28-point gap")

        let referenceBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!
        let referenceFile = directory.appendingPathComponent("replica-reference.png")
        try? referenceBytes.write(to: referenceFile)
        var reference = SlotContent.SlotAttachment(name: "replica-reference.png", type: .image)
        reference.storagePath = referenceFile.path
        check(store.writeCanvasSlotAttachments(groupId: image.groupId, slot: image.slot, attachments: [reference]),
              "source reference fixture is persisted")
        let sourceReference = store.canvasSlotAttachments(groupId: image.groupId, slot: image.slot).first!
        for kind in [CanvasNodeKind.image, .video] {
            let source = kind == .image ? image : video
            for count in 1...4 {
                canvas.updateNodeGeneration(id: source.id, count: count)
                let before = Set(canvas.nodes.map(\.id))
                let live = canvas.node(id: source.id)!
                let task = generateAdjacentResults(live)
                let created = canvas.nodes.filter { !before.contains($0.id) }
                check(created.count == count - 1 && created.allSatisfy {
                    $0.generationSourceID == source.id && $0.kind == kind && $0.y == live.y && $0.x > live.frame.maxX
                }, "\(kind.rawValue) \(count) attempts use source and N minus one adjacent results")
                check(generateAdjacentResults(live) == nil, "\(kind.rawValue) duplicate click is blocked during batch")
                if count > 1 {
                    let cursor = canvas.history.cursor
                    check(canvas.undo() == nil && canvas.history.cursor == cursor,
                          "\(kind.rawValue) submitting results cannot be removed by undo")
                }
                await task?.value
                check(([source] + created).allSatisfy {
                    if case .succeeded = canvas.node(id: $0.id)?.state { return true }; return false
                }, "\(kind.rawValue) \(count) attempts all persist generated outputs")
                check(canvas.node(id: source.id)?.taskId != nil
                      && liveText(for: source) == (kind == .image ? "Replica image" : "Replica video"),
                      "\(kind.rawValue) source prompt remains intact")
                check(created.allSatisfy { result in
                    let plan = CanvasWorkflowCapture.plan(node: canvas.node(id: result.id)!, canvas: canvas, store: store)
                    return plan.prompt.components(separatedBy: "Replica reference prompt").count == 2
                }, "\(kind.rawValue) lineage does not duplicate upstream prompts")
                if kind == .image {
                    check(created.allSatisfy { result in
                        let inputs = inputAttachments(for: result)
                        return inputs.count == 1 && inputs[0].id != sourceReference.id
                            && inputs[0].resolveData() == referenceBytes
                    }, "image \(count) results own independent reference copies")
                }
                if count == 2 {
                    let completed = created.compactMap { canvas.node(id: $0.id) }
                    check(canvas.undo() != nil && created.allSatisfy { canvas.node(id: $0.id) == nil },
                          "\(kind.rawValue) whole-batch undo removes all results")
                    check(canvas.redo() != nil && completed.allSatisfy { result in
                        guard let restored = canvas.node(id: result.id) else { return false }
                        return restored.taskId == result.taskId && restored.state == result.state
                            && restored.outputAttachmentIds == result.outputAttachmentIds
                            && liveText(for: restored) == liveText(for: source)
                            && store.canvasSlotAttachments(groupId: restored.groupId, slot: restored.slot)
                                .contains { restored.outputAttachmentIds.contains($0.id.uuidString)
                                    && $0.storageFileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true }
                    }, "\(kind.rawValue) redo restores completed task and managed output without resubmission")
                    if kind == .image {
                        check(created.allSatisfy { result in inputAttachments(for: result).first?.resolveData() == referenceBytes },
                              "redo restores reference bytes with the generated result")
                    }
                }
            }
        }
        do {
            let result = canvas.nodes.first { $0.generationSourceID == image.id }!
            let facts = CanvasWorkflowCapture.facts(nodes: canvas.nodes.filter {
                [text.id, image.id, result.id].contains($0.id)
            }, store: store, includeMediaMetadata: false)
            let snapshot = CanvasWorkflowSnapshot(projectID: canvas.activeProjectId, facts: facts,
                edges: canvas.edges.filter {
                    [text.id, image.id, result.id].contains($0.fromNodeId)
                        && [text.id, image.id, result.id].contains($0.toNodeId)
                }, selectionIDs: [])
            let skill = try WorkflowSkill(snapshot: .init(graph: snapshot, runs: []),
                method: "生成来源映射验收", messageID: nil, receipts: [])
            let instance = try skill.instantiate(values: [:])
            let transaction = WorkflowProjectTransaction(root: directory.appendingPathComponent("workflow-remap"))
            let prepared = try transaction.prepare(name: "结果来源映射", instance: instance)
            defer { transaction.discard(prepared) }
            let remapped = prepared.document.nodes.first { $0.generationSourceID != nil }!
            check(prepared.document.nodes.contains { $0.id == remapped.generationSourceID }
                  && remapped.generationSourceID != image.id,
                  "workflow reuse maps result lineage to the new source identity")
            let reopened = try JSONDecoder().decode(CanvasDocument.self,
                from: CanvasWorkflowSnapshot.jsonData(prepared.document))
            check(reopened.nodes.first { $0.id == remapped.id }?.generationSourceID == remapped.generationSourceID,
                  "result lineage survives persisted document decoding")
        } catch { check(false, "workflow result lineage exception: \(error.localizedDescription)") }
        canvas.updateNodeGeneration(id: image.id, count: 1)
        canvas.updateNodeGeneration(id: video.id, count: 1)
        check(canvas.connect(from: image.id, to: video.id, role: .auto) == nil,
              "selected batch dependency fixture connects image to video")
        let beforeDependentBatch = Set(canvas.nodes.map(\.id))
        runGeneration(nodeIDs: [image.id, video.id])
        await canvas.selectionGenerationTask?.value
        let addedDependentResults = canvas.nodes.filter { !beforeDependentBatch.contains($0.id) }
        let dependentResults = [image.id, video.id].compactMap { canvas.node(id: $0) }
        let upstreamResult = canvas.node(id: image.id)
        let downstreamResult = canvas.node(id: video.id)
        check(addedDependentResults.isEmpty && dependentResults.allSatisfy {
            if case .succeeded = $0.state { return true }; return false
        }, "selected dependency batch completes on both original nodes")
        check(upstreamResult != nil && downstreamResult != nil && canvas.edges.contains {
            $0.fromNodeId == upstreamResult?.id && $0.toNodeId == downstreamResult?.id && $0.role == .auto
        }, "dependent result consumes the new upstream result rather than the original source")
        await settle(0.5)
        synchronizeMediaLayouts()
        await settle(0.5)
        let results = canvas.nodes.filter { $0.generationSourceID != nil }.sorted { $0.x < $1.x }
        check(zip(results, results.dropFirst()).allSatisfy { a, b in
            a.frame.maxX <= b.frame.minX || !a.frame.intersects(b.frame)
        }, "native output aspect updates keep generated result cards separate")
        canvas.clearSelection()
        _ = handleKeyAction(.fitContent)
        await settle()
        screenshot("replica-canvas-light")
        AppSkinCenter.apply(.minimal)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle()
        // Skin changes rebuild the view; continue through the current mounted state.
        let current = CanvasAgentGroupsProbeBridge.current ?? self
        current.canvas.clearSelection()
        screenshot("replica-canvas-minimal-dark")
        AppSkinCenter.apply(.colorful)
        await settle()
        screenshot("replica-canvas-colorful-dark")
        func rgb(_ color: Color, dark: Bool) -> [CGFloat] {
            var values: [CGFloat] = []
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                if let color = NSColor(color).usingColorSpace(.sRGB) {
                    values = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                }
            }
            return values
        }
        let colorfulDark = [CanvasSkin.void, CanvasSkin.cardEmptyFill, CanvasSkin.chromeFill,
                            CanvasSkin.accent, CanvasSkin.nodeAccent(.image)].map { rgb($0, dark: true) }
        AppSkinCenter.apply(.minimal)
        let minimalDark = [CanvasSkin.void, CanvasSkin.cardEmptyFill, CanvasSkin.chromeFill,
                           CanvasSkin.accent, CanvasSkin.nodeAccent(.image)].map { rgb($0, dark: true) }
        check(colorfulDark == minimalDark, "canvas dark color tokens match across both skins")
        await settle()
        let mounted = CanvasAgentGroupsProbeBridge.current ?? self
        func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 30 else { return [] }
            let children = node.accessibilityChildren?() ?? []
            let fallback = (node as? NSView)?.subviews ?? []
            return [node] + (children.isEmpty ? fallback : children).flatMap {
                elements($0 as AnyObject, depth: depth + 1)
            }
        }
        let navigationState = ReplicaNavigationState()
        let navigationNodes = [
            CGPoint(x: 50, y: 240), CGPoint(x: 210, y: 240), CGPoint(x: 330, y: 235),
            CGPoint(x: 350, y: 60), CGPoint(x: 500, y: 135)
        ].enumerated().map { index, point in
            var node = text
            node.slot = index + 1
            node.x = point.x; node.y = point.y; node.width = 120; node.height = 65
            return node
        }
        let navigation = CanvasNavigationControls(nodes: navigationNodes,
            viewport: CGRect(x: 0, y: 0, width: 1000, height: 700), saveStatus: .saved,
            pan: Binding(get: { navigationState.pan }, set: { navigationState.pan = $0 }),
            zoom: Binding(get: { navigationState.zoom }, set: { navigationState.zoom = $0 }),
            showMap: Binding(get: { navigationState.showMap }, set: { navigationState.showMap = $0 }),
            showEdges: Binding(get: { navigationState.showEdges }, set: { navigationState.showEdges = $0 }),
            gridSnap: Binding(get: { navigationState.grid }, set: { navigationState.grid = $0 }),
            onZoom: { navigationState.zoom = $0 }, onFit: {}, onViewportEnd: {},
            onSave: {}, onAgent: {})
        let navigationHost = NSHostingView(rootView: navigation)
        let navigationWindow = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 390, height: 240),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        navigationWindow.isReleasedWhenClosed = false
        navigationWindow.contentView = navigationHost
        navigationWindow.makeKeyAndOrderFront(nil)
        await settle()
        do {
            let buttons = elements(navigationHost)
            let map = buttons.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-navigation-map" }
            check(map?.accessibilityPerformPress?() == true, "minimap visibility toggles through the native control")
            await settle(0.25)
            check(!navigationState.showMap, "minimap close animation ends in hidden state")
            _ = map?.accessibilityPerformPress?()
            await settle(0.25)
            check(navigationState.showMap,
                  "minimap reopens without changing canvas selection")
            if let bitmap = navigationHost.bitmapImageRepForCachingDisplay(in: navigationHost.bounds) {
                navigationHost.cacheDisplay(in: navigationHost.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("replica-navigation-native.png"))
            }
            let grid = buttons.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-navigation-grid" }
            let edges = buttons.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-navigation-edges" }
            _ = grid?.accessibilityPerformPress?()
            _ = edges?.accessibilityPerformPress?()
            check(navigationState.grid && !navigationState.showEdges, "native grid and edge controls update independent states")
        }
        navigationWindow.close()
        let mapView = CanvasMiniMapView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        var distantNode = text
        distantNode.x = 7000; distantNode.y = 3000; distantNode.width = 400; distantNode.height = 300
        mapView.nodes = [distantNode]
        mapView.viewport = CGRect(x: 0, y: 0, width: 1000, height: 700)
        mapView.zoom = 1; mapView.synchronize(pan: .zero)
        var observedPan = CGSize.zero
        var mapEnds = 0
        mapView.onPan = { observedPan = $0 }
        mapView.onEnd = { mapEnds += 1 }
        let mapWindow = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 200, height: 150),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        mapWindow.isReleasedWhenClosed = false
        mapWindow.contentView = mapView; mapWindow.makeKeyAndOrderFront(nil)
        func mapEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: mapView.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mapWindow.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        }
        let mapRect = mapView.viewportRect
        let mapCenter = CGPoint(x: mapRect.midX, y: mapRect.midY)
        mapView.mouseDown(with: mapEvent(.leftMouseDown, mapCenter))
        check(mapView.isDraggingViewport, "native minimap captures mouse-down inside viewport")
        let pointer = CGPoint(x: mapCenter.x + 28, y: mapCenter.y + 17)
        mapView.mouseDragged(with: mapEvent(.leftMouseDragged, pointer))
        check(abs(mapView.viewportRect.minX - mapRect.minX - 28) < 0.001
              && abs(mapView.viewportRect.minY - mapRect.minY - 17) < 0.001 && observedPan == .zero,
              "minimap viewport follows pointer immediately while canvas awaits spring frame")
        await settle(0.08)
        check(observedPan.width < 0 && observedPan.height < 0,
              "native spring timer moves actual canvas in both axes")
        let capturedRect = mapView.viewportRect
        check(abs(capturedRect.minX - mapRect.minX - 28) < 0.001,
              "minimap overlay remains attached to pointer while node projection changes")
        mapView.mouseDragged(with: mapEvent(.leftMouseDragged, CGPoint(x: 235, y: 170)))
        check(mapView.isDraggingViewport && mapView.viewportRect.maxX > 200,
              "native minimap retains drag outside map bounds")
        mapView.mouseUp(with: mapEvent(.leftMouseUp, CGPoint(x: 235, y: 170)))
        check(!mapView.isDraggingViewport, "release outside minimap ends captured gesture")
        await settle(0.4)
        check(mapEnds == 1, "minimap release persists viewport once after 300ms settling")
        mapView.synchronize(pan: .zero)
        observedPan = .zero
        let outside = CGPoint(x: 180, y: 130)
        mapView.mouseDown(with: mapEvent(.leftMouseDown, outside))
        check(!mapView.isDraggingViewport, "outside minimap click starts positioning without drag capture")
        mapView.mouseDragged(with: mapEvent(.leftMouseDragged, CGPoint(x: 90, y: 90)))
        await settle(0.04)
        check(observedPan != .zero && !mapView.isDraggingViewport,
              "outside positioning click ignores later mouse-drag events")
        mapView.cancelMotion()
        let cancelledPan = observedPan
        await settle(0.06)
        check(observedPan == cancelledPan, "minimap teardown cancels spring timer and pending persistence")
        mapView.reduceMotion = true; mapView.synchronize(pan: .zero)
        observedPan = .zero
        mapView.mouseDown(with: mapEvent(.leftMouseDown, outside))
        check(observedPan != .zero, "reduce-motion setting positions canvas immediately")
        mapWindow.close()

        let sizeSelection = CanvasImageConfiguration.selection(ratio: "3:4", resolution: "3K")
        let sizePicker = NSHostingView(rootView: CanvasImageSizePicker(selection: sizeSelection) { _, _ in })
        let sizeWindow = NSWindow(contentRect: CGRect(x: 250, y: 250, width: 320, height: 170),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        sizeWindow.isReleasedWhenClosed = false
        sizeWindow.contentView = sizePicker; sizeWindow.makeKeyAndOrderFront(nil)
        await settle()
        let sizeElements = elements(sizePicker)
        check(CanvasImageConfiguration.ratios.allSatisfy { ratio in sizeElements.contains {
            ($0.accessibilityIdentifier?() ?? "") == "canvas-ratio-" + ratio
        } }, "native image panel exposes all eight reference aspect ratios")
        check(CanvasImageConfiguration.qualities.allSatisfy { quality in sizeElements.contains {
            ($0.accessibilityIdentifier?() ?? "") == "canvas-image-quality-" + quality
        } }, "native image panel exposes separate 2K and 3K controls")
        if let bitmap = sizePicker.bitmapImageRepForCachingDisplay(in: sizePicker.bounds) {
            sizePicker.cacheDisplay(in: sizePicker.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: directory.appendingPathComponent("replica-image-size-native.png"))
        }
        sizeWindow.close()
        var countValue = 1
        let countPicker = NSHostingView(rootView: CanvasGenerationCountPicker(count: countValue) { countValue = $0 })
        let countWindow = NSWindow(contentRect: CGRect(x: 250, y: 250, width: 96, height: 144),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        countWindow.isReleasedWhenClosed = false
        countWindow.contentView = countPicker; countWindow.makeKeyAndOrderFront(nil)
        await settle()
        let countElements = elements(countPicker)
        for value in 1...4 {
            let option = countElements.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-count-option-\(value)" }
            _ = option?.accessibilityPerformPress?()
            check(countValue == value && option != nil, "native count menu selects \(value) attempts")
        }
        countWindow.close()
        CrateModelCatalogStore.shared.reload()
        for _ in 0..<40 {
            if !CrateModelCatalogStore.shared.isLoading { break }
            await settle(0.05)
        }
        canvas.updateNodeGeneration(id: image.id, model: "seedream5", ratio: "3:4", count: 1, resolution: "3K")
        let configuredImage = canvas.node(id: image.id)!
        let configuredPlan = CanvasWorkflowCapture.plan(node: configuredImage, canvas: canvas, store: store)
        check(configuredPlan.imageRequest?.width == 2304 && configuredPlan.imageRequest?.height == 3072,
              "mounted canvas model capture maps 3K choice into exact image dimensions")
        let exactTask = generateAdjacentResults(configuredImage)
        await exactTask?.value
        let exactResult = canvas.node(id: configuredImage.id)
        check(exactResult?.resolution == "3K" && exactResult?.ratio == "3:4",
              "original result retains separate image quality and aspect")
        if let exactResult, let run = GenerationRunStore.shared.latest(project: canvas.activeProjectId, node: exactResult) {
            check(run.attempts.last?.effectiveRequest.width == 2304
                  && run.attempts.last?.effectiveRequest.height == 3072,
                  "actual local CLI attempt records 2304 by 3072 request")
        } else { check(false, "exact image size request has persisted generation history") }
        let suite = "replica-launch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("tika", forKey: AgentBackendScope.workspace.preferenceKey)
        defaults.set("colorful", forKey: AppSkin.defaultsKey)
        defaults.set("dark", forKey: AppearanceDefaults.key)
        LaunchDefaults.applyForUpdate(defaults: defaults, build: "fixture-new-build")
        check(defaults.string(forKey: AppSkin.defaultsKey) == "minimal"
              && defaults.string(forKey: AppearanceDefaults.key) == "light"
              && defaults.string(forKey: AgentBackendScope.workspace.preferenceKey) == "deepseek"
              && defaults.string(forKey: AgentBackendScope.sidebar.preferenceKey) == "deepseek",
              "new build resets minimal light and both DeepSeek scopes")
        defaults.set("dark", forKey: AppearanceDefaults.key)
        LaunchDefaults.applyForUpdate(defaults: defaults, build: "fixture-new-build")
        check(defaults.string(forKey: AppearanceDefaults.key) == "dark", "same build retains manual appearance choice")
        let report: [String: Any] = ["passed": passed, "failures": failures,
                                     "expectedCrateSubmissions": 23, "systemInputValidated": false,
                                     "scope": "native router, actual generated result slots, local Crate fixture, canvas-only colors"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}

private final class ReplicaNavigationState {
    var pan = CGSize.zero
    var zoom: CGFloat = 1
    var showMap = true
    var showEdges = true
    var grid = false
}
#endif
