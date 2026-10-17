#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runComposerLayerProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        var samples: [[String: Any]] = []
        let systemPointer = ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1"
        var postedSystemEvents = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failures.append(label) }
            NSLog("[ComposerLayer] \(ok ? "PASS" : "FAIL") \(label)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(450)) }
        guard let window = inputRouter.anchorView?.window,
              let root = window.contentView else { return }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> Bool {
            guard let anchor = inputRouter.anchorView else { return false }
            guard let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1) else { return false }
            return inputRouter.routeForRegression(event)
        }
        func deliver(_ type: NSEvent.EventType, _ point: CGPoint) async -> Bool {
            guard let anchor = inputRouter.anchorView else { return false }
            let location = anchor.convert(point, to: nil)
            if systemPointer {
                let token = UUID().uuidString
                let screen = window.convertPoint(toScreen: location)
                let kind: CGEventType = type == .leftMouseDown ? .leftMouseDown
                    : type == .leftMouseUp ? .leftMouseUp : .leftMouseDragged
                let row: [String: Any] = ["token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "window": window.windowNumber, "type": kind.rawValue, "x": screen.x,
                    "y": (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y, "flags": 0, "clicks": 1]
                let fileURL = directory.appendingPathComponent("mouse-events.jsonl")
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                guard let file = try? FileHandle(forWritingTo: fileURL),
                      var data = try? JSONSerialization.data(withJSONObject: row) else { return false }
                data.append(10)
                file.seekToEndOfFile(); file.write(data); try? file.close()
                for _ in 0..<300 {
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("mouse-ack-\(token).json").path) {
                        postedSystemEvents += 1
                        try? await Task.sleep(for: .milliseconds(100))
                        return true
                    }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("mouse-driver-result.json").path) {
                        return false
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            guard let event = NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(100))
            return true
        }
        func snapshot(_ name: String, at point: CGPoint) -> Double {
            guard let anchor = inputRouter.anchorView,
                  let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return -1 }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
            let p = anchor.convert(point, to: root)
            let sx = CGFloat(bitmap.pixelsWide) / root.bounds.width
            let sy = CGFloat(bitmap.pixelsHigh) / root.bounds.height
            let x = Int(p.x * sx)
            let y = Int((root.isFlipped ? p.y : root.bounds.height - p.y) * sy)
            var magenta = 0, total = 0
            for dx in -12...12 {
                for dy in -12...12 {
                    guard let c = bitmap.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.deviceRGB) else { continue }
                    total += 1
                    // AppKit color management lifts the fixture's green channel
                    // on wide-gamut displays; neutral UI fills still have green > 0.8.
                    if c.redComponent > 0.8 && c.blueComponent > 0.8 && c.greenComponent < 0.5 { magenta += 1 }
                }
            }
            return total == 0 ? -1 : Double(magenta) / Double(total)
        }
        canvas.isLibraryExpanded = false
        gridSnapEnabled = false
        pan = CGSize(width: 100, height: 90)
        zoom = 1
        let image = NSImage(size: CGSize(width: 128, height: 128))
        image.lockFocus()
        NSColor.magenta.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 128, height: 128)).fill()
        image.unlockFocus()
        let imageURL = directory.appendingPathComponent("layer-fixture.png")
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: imageURL)
        }
        guard let target = createNode(kind: .image, at: CGPoint(x: 320, y: 180),
                                      parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        canvas.updateNode(id: target.id) { $0.width = 220; $0.height = 160; $0.mediaRole = .generation }
        let priorIDs = Set(canvas.nodes.map(\.id))
        importCanvasResource(imageURL, at: CGPoint(x: 950, y: 200))
        await settle()
        guard let media = canvas.nodes.first(where: { !priorIDs.contains($0.id) }) else { return }
        check(previewableMedia(of: media) != nil, "fixture uses a real imported image attachment")
        for scale in [CGFloat(0.65), 1, 1.5] {
            zoom = scale
            canvas.select(id: target.id, additive: false)
            editingNodeId = nil
            hoverHoldNodeId = nil
            await settle()
            guard let form = composerFrame else {
                check(false, "generation panel exists at \(scale)x")
                continue
            }
            // The prompt starts after the 32-point input row and 12-point gap.
            let point = CGPoint(x: form.midX, y: form.minY + 100)
            let world = CanvasGeometry.canvasPoint(screen: point, pan: effectivePan, zoom: zoom)
            canvas.updateNode(id: media.id) {
                $0.x = world.x - 160 / scale; $0.y = world.y - 100 / scale
                $0.width = 320 / scale; $0.height = 200 / scale
            }
            // Validate the pixel oracle before testing occlusion.
            canvas.select(id: media.id, additive: false)
            await settle()
            let exposed = snapshot("layer-\(scale)-image-exposed", at: point)
            check(exposed > 0.8, "imported fixture is actually visible at overlap \(scale)x")
            canvas.select(id: target.id, additive: false)
            await settle()
            let hidden = snapshot("layer-\(scale)-panel-foreground", at: point)
            samples.append(["zoom": scale, "exposedMagenta": exposed, "coveredMagenta": hidden,
                            "composer": NSStringFromRect(composerFrame ?? .zero)])
            check(hidden >= 0 && hidden < 0.02, "panel visually covers image pixels \(scale)x")
            check(nodeBody(at: point)?.id == media.id && composerContains(point),
                  "panel owns the rectangle over a real underlying image \(scale)x")
            check(!isCanvasSurface(at: point) && canvasOverlayContains(point),
                  "overlap cannot become a canvas drag surface \(scale)x")
            check(inputRouter.canFocusEditorAt?(point) == true,
                  "visible prompt accepts focus over an underlying image \(scale)x")
            check(!portIsExposed(point, nodeId: media.id), "panel covers underlying ports \(scale)x")
            let origin = canvas.node(id: media.id)!.frame
            check(!mouse(.leftMouseDown, point), "canvas router yields panel press \(scale)x")
            _ = mouse(.leftMouseDragged, CGPoint(x: point.x + 60, y: point.y + 20))
            _ = mouse(.leftMouseUp, CGPoint(x: point.x + 60, y: point.y + 20))
            check(canvas.node(id: media.id)?.frame == origin && pointerSession == nil && draggingNodeId == nil
                  && canvas.selectedNodeIds == [target.id], "panel drag never moves or selects the image \(scale)x")
            // Deliver the click through AppKit, then exercise the native text editor.
            if systemPointer {
                let down = await deliver(.leftMouseDown, point)
                let drag = await deliver(.leftMouseDragged, CGPoint(x: point.x + 60, y: point.y + 20))
                let up = await deliver(.leftMouseUp, CGPoint(x: point.x + 60, y: point.y + 20))
                await settle()
                check(down && drag && up && canvas.node(id: media.id)?.frame == origin
                      && canvas.selectedNodeIds == [target.id] && draggingNodeId == nil,
                      "independent system drag over panel preserves the image \(scale)x")
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                check(await deliver(type, point), "native prompt pointer delivered \(type.rawValue) \(scale)x")
            }
            await settle()
            if let editor = window.firstResponder as? NSTextView {
                let marker = "LAYER_\(scale)"
                editor.insertText(marker, replacementRange: NSRange(location: NSNotFound, length: 0))
                check(editor.string.contains(marker) && canvas.selectedNodeIds == [target.id],
                      "native editor receives text without changing selection \(scale)x")
                window.makeFirstResponder(nil)
                await settle()
                check(liveText(for: canvas.node(id: target.id)!).contains(marker),
                      "prompt commits to the selected generation node \(scale)x")
            } else { check(false, "native prompt becomes first responder \(scale)x") }
            editingNodeId = nil
            canvas.select(id: media.id, additive: false)
            await settle()
            check(isCanvasSurface(at: point), "closing panel exposes the image again \(scale)x")
        }
        let report: [String: Any] = ["passed": passed, "failures": failures, "complete": true,
            "expectedCrateSubmissions": 0, "samples": samples,
            "systemPointerValidated": systemPointer && postedSystemEvents == 15,
            "systemKeyboardValidated": false, "postedSystemEvents": postedSystemEvents,
            "scope": "native AppKit panel/image pixel occlusion, pointer/port ownership, text focus and persistence; three zoom levels"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
