#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runSidebarPortProbe(directory: URL) async {
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[SidebarPorts] \(value ? "PASS" : "FAIL") \(name)")
        }
        func settle(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }
        canvas.isLibraryExpanded = true
        pan = CGSize(width: 100, height: 100); zoom = 1
        let frameA = CGRect(x: 320, y: 200, width: 220, height: 160)
        let frameB = CGRect(x: 568, y: 200, width: 220, height: 160)
        guard let a = createNode(kind: .image, at: frameA.centerPoint, parentNodeId: nil, beginEditing: false, quiet: true),
              let b = createNode(kind: .image, at: frameB.centerPoint, parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        canvas.updateNode(id: a.id) { $0.x = frameA.minX; $0.y = frameA.minY; $0.width = 220; $0.height = 160; $0.mediaRole = .generation }
        canvas.updateNode(id: b.id) { $0.x = frameB.minX; $0.y = frameB.minY; $0.width = 220; $0.height = 160; $0.mediaRole = .generation }
        if let file = ProcessInfo.processInfo.environment["CLIPSLOTS_PORT_IMAGE_FIXTURE"] {
            for node in [a, b] {
                var attachment = SlotContent.SlotAttachment(name: "cat.png", type: .image)
                attachment.storagePath = file
                if let saved = store.appendCanvasGeneratedAttachment(attachment, groupId: node.groupId, slot: node.slot) {
                    canvas.updateNode(id: node.id) { $0.outputAttachmentIds = [saved.id.uuidString] }
                }
            }
        }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            if ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1" {
                let location = (inputRouter.anchorView ?? anchor).convert(point, to: nil)
                let screen = window.convertPoint(toScreen: location)
                let kind: CGEventType = type == .mouseMoved ? .mouseMoved : type == .leftMouseDown ? .leftMouseDown
                    : type == .leftMouseUp ? .leftMouseUp : .leftMouseDragged
                let data: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "window": window.windowNumber, "type": kind.rawValue, "x": screen.x,
                    "y": (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y, "flags": 0, "clicks": 1]
                var bytes = try! JSONSerialization.data(withJSONObject: data); bytes.append(10)
                let file = directory.appendingPathComponent("mouse-events.jsonl")
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile(); handle.write(bytes); try? handle.close()
                }
                return
            }
            let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            _ = inputRouter.routeForRegression(event)
        }
        func click(_ point: CGPoint) async {
            mouse(.mouseMoved, point); await settle(280)
            mouse(.leftMouseDown, point); await settle(35)
            mouse(.leftMouseUp, point); await settle(180)
        }
        func bitmap(_ name: String) -> NSBitmapImageRep? {
            guard let content = window.contentView,
                  let result = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
            content.cacheDisplay(in: content.bounds, to: result)
            try? result.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            return result
        }
        canvas.select(id: a.id, additive: false); hoverHoldNodeId = nil
        await settle(350)
        check(controlRegions["library-panel"].map { abs($0.minY) < 1 && abs($0.minX) < 1 && abs($0.height - viewSize.height) < 1 } == true,
              "sidebar occupies the fixed top-left full-height rectangle")
        let oldA = canvas.node(id: a.id)!
        canvas.updateNode(id: a.id) { $0.x = -100 }
        await settle()
        _ = bitmap("sidebar-covers-node")
        let libraryPoint = CGPoint(x: 100, y: 360)
        let selection = canvas.selectedNodeIds
        mouse(.leftMouseDown, libraryPoint); mouse(.leftMouseUp, libraryPoint)
        await settle()
        check(canvas.selectedNodeIds == selection && pointerSession == nil,
              "sidebar press never selects or drags a node behind it")
        canvas.updateNode(id: a.id) { $0.x = oldA.x }
        await settle()

        mouse(.mouseMoved, CGPoint(x: 760, y: 340)); await settle(300)
        check(staticPortNodes.map(\.id).contains(a.id) && staticPortNodes.map(\.id).contains(b.id),
              "selected and hovered neighbours retain independent handles")
        let out = outputPortHome(of: canvas.node(id: a.id)!)
        let before = canvas.nodes.count
        await click(out)
        check(addMenu?.allParentIds == [a.id] && addMenu?.childNodeId == nil,
              "right plus click opens the source-owned downstream menu")
        check(canvas.nodes.count == before && linkDrag == nil, "plus menu keeps node creation pending")
        _ = bitmap("right-plus-menu"); _ = handleKeyAction(.cancel)
        canvas.select(id: b.id, additive: false); hoverHoldNodeId = nil
        let inlet = inputPortHome(of: canvas.node(id: b.id)!)
        await click(inlet)
        check(addMenu?.childNodeId == b.id && addMenu?.allParentIds.isEmpty == true,
              "left plus click opens an upstream menu for its displayed node")
        check(controlRegions["add-menu-row-text"] != nil && controlRegions["add-menu-row-image"] != nil
              && controlRegions["add-menu-row-video"] == nil,
              "upstream menu offers the observed text and image context choices")
        _ = bitmap("left-plus-menu")
        if let request = addMenu {
            handleAddNode(.text, request: request)
            check(canvas.edges.last?.toNodeId == b.id && canvas.edges.last?.fromNodeId != b.id,
                  "left plus creates the incoming connection in the correct direction")
            if let created = canvas.edges.last?.fromNodeId {
                canvas.updateNode(id: created) { $0.x = 1800; $0.y = 1800 }
            }
        } else { check(false, "left plus has a pending request") }
        endInlineEditing(); canvas.select(id: a.id, additive: false)
        await click(screenFrame(of: canvas.node(id: b.id)!).centerPoint)
        check(canvas.selectedNodeIds == [b.id] && addMenu == nil, "adjacent body selects on the first click beside an overlapping plus")

        // Reproduce the six-second recording: move around the common edge
        // repeatedly, while the selected node and its composer remain mounted.
        let selected = canvas.selectedNodeIds
        let bodyCount = CanvasRenderDiagnostics.count
        var owners: [String] = [], noDropouts = true
        let hasImage = ProcessInfo.processInfo.environment["CLIPSLOTS_PORT_IMAGE_FIXTURE"] != nil
        var pixelStable = true
        let bodyPixel = screenFrame(of: canvas.node(id: b.id)!).centerPoint
        func pixel() -> NSColor? {
            guard let content = window.contentView else { return nil }
            let area = anchor.convert(CGRect(x: bodyPixel.x, y: bodyPixel.y, width: 1, height: 1), to: content)
            guard let image = content.bitmapImageRepForCachingDisplay(in: area) else { return nil }
            content.cacheDisplay(in: area, to: image)
            return image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
        }
        let initialPixel = hasImage ? pixel() : nil
        if hasImage {
            check(initialPixel.map { abs($0.redComponent - $0.blueComponent) > 0.05 } == true,
                  "image fixture is visibly rendered before stability sampling")
        }
        for i in 0..<90 {
            let p = CGPoint(x: inlet.x + CGFloat((i % 9) - 4), y: inlet.y + CGFloat((i % 7) - 3))
            mouse(.mouseMoved, p)
            await settle(17)
            owners.append(displayedPortHit(at: p)?.node.id ?? "")
            noDropouts = noDropouts && composerFrame != nil && canvas.selectedNodeIds == selected
            if hasImage, i.isMultiple(of: 15) {
                pixelStable = pixelStable && pixel() == initialPixel
            }
        }
        check(noDropouts, "hover at the shared boundary never unmounts the selected composer")
        check(Set(owners.filter { !$0.isEmpty }).count <= 1 && owners.contains(b.id),
              "shared-boundary hover does not oscillate between port owners")
        check(CanvasRenderDiagnostics.count - bodyCount < 8,
              "90 hover events do not repeatedly rebuild node/composer content")
        if hasImage {
            check(initialPixel != nil && pixelStable, "image body pixel stays present and unchanged across boundary hover samples")
        }
        _ = bitmap("stable-adjacent-hover")
        canvas.select(id: a.id, additive: false); hoverHoldNodeId = nil
        let inputA = inputPortHome(of: canvas.node(id: a.id)!)
        mouse(.mouseMoved, inputA); await settle(280)
        mouse(.leftMouseDown, inputA)
        await settle()
        let end = CGPoint(x: 1100, y: 640)
        for i in 1...20 {
            mouse(.leftMouseDragged, CGPoint(x: inputA.x + (end.x-inputA.x)*CGFloat(i)/20,
                                             y: inputA.y + (end.y-inputA.y)*CGFloat(i)/20))
        }
        await settle(300)
        check(linkDrag?.fromInput == true && linkDrag?.fromNodeId == a.id,
              "input drag retains its upstream direction and original owner")
        mouse(.leftMouseUp, end)
        await settle()
        check(addMenu?.childNodeId == a.id && linkDrag == nil, "input blank release retains an upstream pending connection")
        _ = handleKeyAction(.cancel)
        check(addMenu == nil && pointerSession == nil, "cancel clears the upstream preview and pointer session")
        let report: [String: Any] = ["passed": passed, "failures": failures, "complete": true,
            "expectedCrateSubmissions": 0, "scope": "sidebar layering, both plus buttons, neighbour ownership, hover stability",
            "eventDelivery": ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1" ? "system CGEvent mouse" : "direct native router"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}

private extension CGRect {
    var centerPoint: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
