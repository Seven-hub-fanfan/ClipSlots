#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runNodeDesignProbe(directory: URL) async {
        // Keep bottom navigation above the macOS Dock during physical mouse tests.
        if let window = inputRouter.anchorView?.window, let screen = window.screen {
            let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            window.setFrame(CGRect(x: visible.minX, y: visible.minY,
                                  width: min(1440, visible.width), height: min(860, visible.height)), display: true)
        }
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ title: String) {
            if condition { passed += 1 } else { failures.append(title) }
            NSLog("[NodeDesign] \(condition ? "PASS" : "FAIL") \(title)")
        }
        func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(for: .seconds(seconds)) }
        func writeReport(_ complete: Bool) {
            let result: [String: Any] = ["passed": passed, "failures": failures,
                "complete": complete, "expectedCrateSubmissions": 0,
                "input": ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1"
                    ? "system CGEvent clicks, native AppKit drag/key events and accessibility geometry"
                    : "native AppKit mouse events and accessibility geometry"]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
        }
        func descendants(_ object: AnyObject, depth: Int = 0) -> [AnyObject] {
            var result: [AnyObject] = [], pending = [object]
            var seen: Set<ObjectIdentifier> = []
            while let current = pending.popLast() {
                guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
                result.append(current)
                pending += (current.accessibilityChildren?() ?? []).map { $0 as AnyObject }
                pending += (current as? NSView)?.subviews ?? []
            }
            return result
        }
        func find(_ identifier: String) -> (AnyObject, NSWindow)? {
            for window in NSApp.windows where window.isVisible {
                guard let content = window.contentView else { continue }
                if let item = descendants(content).first(where: {
                    if let view = $0 as? NSView,
                       view.window !== window || view.isHiddenOrHasHiddenAncestor { return false }
                    return ($0.accessibilityIdentifier?() ?? "") == identifier ||
                    ($0.accessibilityLabel?() ?? "") == identifier
                }) { return (item, window) }
            }
            return nil
        }
        func click(_ identifier: String) async -> Bool {
            guard let (item, window) = find(identifier),
                  let frame = item.accessibilityFrame?(), frame.width > 0, frame.height > 0 else {
                NSLog("[NodeDesign] MISSING \(identifier)")
                return false
            }
            let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
            NSLog("[NodeDesign] CLICK \(identifier) window=\(window.windowNumber) point=\(point)")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle(0.08)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1" {
                    let payload: [String: Any] = [
                        "pid": Int(ProcessInfo.processInfo.processIdentifier), "window": window.windowNumber,
                        "type": (type == .leftMouseDown ? CGEventType.leftMouseDown : .leftMouseUp).rawValue,
                        "x": frame.midX, "y": (NSScreen.screens.first?.frame.maxY ?? 0) - frame.midY, "clicks": 1]
                    if var bytes = try? JSONSerialization.data(withJSONObject: payload) {
                        bytes.append(10)
                        let file = directory.appendingPathComponent("mouse-events.jsonl")
                        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                        if let handle = try? FileHandle(forWritingTo: file) {
                            handle.seekToEndOfFile(); handle.write(bytes); try? handle.close()
                        }
                    }
                    await settle(0.12)
                    continue
                }
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                NSApp.postEvent(event, atStart: false)
                // NSButton tracks mouse-up in a nested AppKit event loop.
                // Queue both native events before yielding the main actor.
                if !(item is NSButton) { await settle(0.06) }
            }
            await settle(0.3)
            return true
        }
        func screenshot(_ name: String, window: NSWindow? = nil) {
            guard let content = (window ?? inputRouter.anchorView?.window)?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func escape() async {
            guard let window = NSApp.keyWindow ?? CanvasParameterPopoverSession.popover?.contentViewController?.view.window
                ?? inputRouter.anchorView?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle(0.08)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            await settle(0.25)
        }
        func frame(_ id: String) -> CGRect? { find(id)?.0.accessibilityFrame?() }
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
        pan = CGSize(width: 80, height: 80); zoom = 0.7
        guard let source = createNode(kind: .text, at: CGPoint(x: 200, y: 350), parentNodeId: nil, beginEditing: false, quiet: true),
              let image = createNode(kind: .image, at: CGPoint(x: 700, y: 350), parentNodeId: source.id, beginEditing: false, quiet: true),
              let video = createNode(kind: .video, at: CGPoint(x: 1200, y: 350), parentNodeId: source.id, beginEditing: false, quiet: true)
        else { check(false, "create image/video fixtures"); writeReport(false); NSApp.terminate(nil); return }
        commitEdit(image, text: "尺寸切换保留这段提示词")
        commitEdit(video, text: "视频尺寸切换保留这段提示词")
        canvas.updateNodeGeneration(id: video.id, model: "seedance2-mini")
        modelCatalog.reload()
        for _ in 0..<60 { if !modelCatalog.isLoading { break }; await settle(0.05) }
        canvas.select(id: image.id, additive: false)
        await settle()
        _ = await click("canvas-model-picker")
        _ = await click("creative-model-seedream5")
        check(canvas.node(id: image.id)?.model == "seedream5", "native model selection enables published 2K/3K image settings")
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await settle()
            for node in (ProcessInfo.processInfo.environment["CLIPSLOTS_NODE_MAP_ONLY"] == "1" ? [] : [image, video]) {
                canvas.select(id: node.id, additive: false)
                pan = CGSize(width: node.kind == .image ? -50 : -350, height: 60); zoom = 0.7
                await settle(0.25)
                beginEdit(canvas.node(id: node.id)!)
                await settle(0.2)
                let prefix = theme + "-" + node.kind.rawValue
                let prompt = node.kind == .image ? "尺寸切换保留这段提示词" : "视频尺寸切换保留这段提示词"
                // Include an uncommitted edit in the exact blur -> size-picker path.
                if let editor = inputRouter.anchorView?.window?.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    editor.insertText("。", replacementRange: editor.selectedRange())
                }
                let opened = await click("画面比例选择器")
                check(opened, "\(prefix) opens size picker during prompt edit")
                let ratios = node.kind == .image ? CanvasImageConfiguration.ratios
                    : ["9:16", "4:3", "3:4", "21:9", "adaptive", "16:9", "1:1"]
                let qualities = node.kind == .image ? ["3K", "2K"] : [""]
                for quality in qualities {
                    if !quality.isEmpty {
                        _ = await click("canvas-image-quality-" + quality)
                        check(canvas.node(id: node.id)?.resolution == quality, "\(prefix) quality \(quality) persists")
                    }
                    for ratio in ratios {
                        writeReport(false)
                        let picked = await click("canvas-ratio-" + ratio)
                        check(picked && canvas.node(id: node.id)?.ratio == ratio,
                              "\(prefix) \(quality) \(ratio) responds to tile-center mouse click")
                        check(find("canvas-ratio-" + ratio) != nil,
                              "\(prefix) \(quality) \(ratio) keeps popover mounted")
                        if let latest = canvas.node(id: node.id) {
                            if let aspect = CanvasNodeSizing.aspectRatio(ratio) {
                                check(abs(latest.width / latest.height - aspect) < 0.01,
                                      "\(prefix) \(quality) \(ratio) updates node frame")
                            }
                            check(liveText(for: latest).hasPrefix(prompt) && liveText(for: latest).hasSuffix("。"),
                                  "\(prefix) \(quality) \(ratio) retains edited prompt")
                        }
                    }
                }
                if let (_, popup) = find("canvas-ratio-1:1") { screenshot("size-popup-" + prefix, window: popup) }
                await escape()
                check(find("canvas-ratio-1:1") == nil, "\(prefix) Esc closes size picker")
                check(canvas.soleSelectedNode?.id == node.id, "\(prefix) Esc preserves node selection")
                for count in 1...4 {
                    _ = await click("canvas-generation-count")
                    _ = await click("canvas-count-option-\(count)")
                    check(canvas.node(id: node.id)?.count == count, "\(prefix) count \(count) persists")
                }
                if let model = frame("canvas-model-picker"), let count = frame("canvas-generation-count"),
                   let run = frame("canvas-generate") {
                    check(model.maxX < count.minX && count.maxX < run.minX && run.minX - count.maxX < 30,
                          "\(prefix) model left and count adjacent to generation control")
                } else { check(false, "\(prefix) action bar exposes all controls") }
                if node.kind == .video {
                    let before = canvas.node(id: node.id)?.generateAudio ?? true
                    _ = await click("canvas-video-audio")
                    check(canvas.node(id: node.id)?.generateAudio == !before, "\(prefix) audio toggles")
                    check(find("canvas-video-duration") != nil && find("canvas-video-resolution") != nil,
                          "\(prefix) published video duration and resolution are visible")
                }
                screenshot("node-" + prefix)
                _ = await click("canvas-inspector-toggle")
                _ = await click("canvas-inspector-size")
                _ = await click("canvas-ratio-9:16")
                check(canvas.node(id: node.id)?.ratio == "9:16", "\(prefix) inspector size updates same node")
                await escape()
                _ = await click("canvas-inspector-toggle")
                _ = await click("画面比例选择器")
                // Clicking another control dismisses the transient picker.
                _ = await click("canvas-generation-count")
                check(find("canvas-ratio-9:16") == nil, "\(prefix) outside control dismisses size popover")
                await escape()
                writeReport(false)
            }
            showMiniMap = true
            await settle()
            if let (item, _) = find("canvas-minimap"), let map = item as? CanvasMiniMapView,
               let bitmap = map.bitmapImageRepForCachingDisplay(in: map.bounds) {
                map.cacheDisplay(in: map.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("minimap-" + theme + ".png"))
                let color = bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB)
                let brightness = color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? -1
                check(theme == "light" ? brightness > 0.65 : brightness < 0.3, "\(theme) minimap renders matching palette")
                check(map.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                      "\(theme) minimap appearance follows live theme")
                let before = pan
                let center = CGPoint(x: map.viewportRect.midX, y: map.viewportRect.midY)
                for (type, point) in [(NSEvent.EventType.leftMouseDown, center),
                    (.leftMouseDragged, CGPoint(x: center.x + 15, y: center.y + 10)),
                    (.leftMouseUp, CGPoint(x: center.x + 15, y: center.y + 10))] {
                    if let window = map.window, let event = NSEvent.mouseEvent(with: type,
                        location: map.convert(point, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 2, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                        await settle(0.06)
                    }
                }
                await settle(0.4)
                check(pan != before && !map.isDraggingViewport, "\(theme) map drag pans canvas and releases")
            } else { check(false, "\(theme) map is rendered") }
            _ = await click("canvas-navigation-map")
            screenshot("map-hidden-" + theme)
            // AppStorage in this async View value is a snapshot; read the persisted
            // preference and mounted view after the real control changes it.
            check(!UserDefaults.standard.bool(forKey: "canvas.navigation.map") &&
                  find("canvas-minimap") == nil, "\(theme) map hides")
            _ = await click("canvas-navigation-map")
            check(UserDefaults.standard.bool(forKey: "canvas.navigation.map") &&
                  find("canvas-minimap") != nil, "\(theme) map reopens")
            screenshot("canvas-" + theme)
        }
        // Removing a size-picker anchor must dismiss the native window safely.
        canvas.select(id: image.id, additive: false)
        await settle()
        _ = await click("画面比例选择器")
        canvas.clearSelection()
        await settle()
        check(find("canvas-ratio-1:1") == nil, "selection teardown dismisses open size picker")
        writeReport(true)
        NSApp.terminate(nil)
    }
}
#endif
