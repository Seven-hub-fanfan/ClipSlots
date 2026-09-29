#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runMediaThemeProbe(directory: URL) async {
        var failures: [String] = []
        var passed = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failures.append(label) }
            NSLog("[MediaTheme] \(ok ? "PASS" : "FAIL") \(label)")
        }
        func waitForLayout(_ id: String) async {
            // 槽位通知可替换正在等待的任务；等待实际布局就绪，不能只等某个已取消的句柄。
            for _ in 0..<100 {
                if let node = canvas.node(id: id), node.mediaLayoutAttachmentID != nil { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        @MainActor func click(_ point: CGPoint, in view: NSView, canvasCoordinates: Bool = true) async {
            guard let window = view.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 150_000_000)
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let currentView = canvasCoordinates ? (inputRouter.anchorView ?? view) : view
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: currentView.convert(point, to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1)!, atStart: false)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pb.clearContents()
        pb.writeObjects([directory.appendingPathComponent("fixture.mp4") as NSURL])
        _ = handleKeyAction(.paste)
        // Restore user clipboard immediately; no asynchronous work while it is replaced.
        pb.clearContents()
        for values in saved {
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            pb.writeObjects([item])
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if let node = canvas.soleSelectedNode {
            check(node.kind == .video, "pasted movie becomes VIDEO node")
            check(abs(node.width / node.height - 16.0/9) < 0.001, "pasted movie keeps 16:9 shape")
        } else { check(false, "pasted movie exists") }
        let mode = ProcessInfo.processInfo.environment["CLIPSLOTS_TEST_APPEARANCE"] ?? "light"
        UserDefaults.standard.set(mode, forKey: "appearanceMode")
        NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let dark = inputRouter.anchorView?.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        check(dark == (mode == "dark"), "canvas window respects \(mode) mode")
        // #region debug-point C:appearance
        var r = URLRequest(url: URL(string: "http://127.0.0.1:7782/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-media-theme", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] canvas light appearance", "data": ["forcedDark": dark]]); URLSession.shared.dataTask(with: r).resume()
        // #endregion
        let appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)!
        func components(_ color: Color) -> [CGFloat] {
            var result: [CGFloat] = []
            appearance.performAsCurrentDrawingAppearance {
                let c = NSColor(color).usingColorSpace(.sRGB)!
                result = [c.redComponent, c.greenComponent, c.blueComponent]
            }
            return result
        }
        func contrast(_ fg: Color, _ bg: Color) -> Double {
            func l(_ color: Color) -> Double {
                let rgb: [Double] = components(color).map { component in
                    let value = Double(component)
                    if value <= 0.04045 { return value / 12.92 }
                    return pow((value + 0.055) / 1.055, 2.4)
                }
                let red = 0.2126 * rgb[0]
                let green = 0.7152 * rgb[1]
                let blue = 0.0722 * rgb[2]
                return red + green + blue
            }
            let a = l(fg), b = l(bg)
            return (max(a,b)+0.05)/(min(a,b)+0.05)
        }
        check(contrast(TapSkin.ink, TapSkin.cardEmptyFill) >= 7, "node text contrast exceeds 7:1")
        check(contrast(TapSkin.secondaryInk, TapSkin.chromeFill) >= 4.5, "panel secondary text contrast exceeds 4.5:1")
        check(contrast(TapSkin.onAccent, TapSkin.accent) >= 4.5, "action button text contrast exceeds 4.5:1")
        if let movie = canvas.soleSelectedNode {
            canvas.updateNodeGeneration(id: movie.id, ratio: "1:1")
            synchronizeMediaLayouts()
            await mediaLayoutTask?.value
            check(canvas.node(id: movie.id)?.ratio == "1:1", "explicit ratio override survives media sync")
            _ = canvas.undo()
            check(abs(canvas.node(id: movie.id)!.width / canvas.node(id: movie.id)!.height - 16.0/9) < 0.001,
                  "undo restores source geometry")
            canvas.updateNode(id: movie.id) { $0.kind = .image; $0.width = 320; $0.height = 320; $0.model = "seedream45"; $0.mediaLayoutAttachmentID = nil }
            synchronizeMediaLayouts()
            await mediaLayoutTask?.value
            await waitForLayout(movie.id)
            check(canvas.node(id: movie.id)?.kind == .video && canvas.node(id: movie.id)?.model == CanvasNode.defaultModel(for: .video),
                  "legacy IMAGE video is repaired with video model")
            check(abs(canvas.node(id: movie.id)!.width / canvas.node(id: movie.id)!.height - 16.0/9) < 0.001,
                  "legacy square video is repaired")
            canvas.moveNode(id: movie.id, to: CGPoint(x: 820, y: 180))
        }
        let movieID = canvas.soleSelectedNode?.id
        importCanvasResource(directory.appendingPathComponent("fixture.png"), at: CGPoint(x: 430, y: 340))
        await mediaLayoutTask?.value
        if let id = canvas.soleSelectedNode?.id { await waitForLayout(id) }
        let imageID = canvas.soleSelectedNode?.id
        if let image = canvas.soleSelectedNode {
            check(abs(image.width / image.height - 16.0/9) < 0.001, "uploaded landscape image adopts native size")
            _ = canvas.undo()
            check(canvas.node(id: image.id) == nil, "undo removes imported media")
            _ = canvas.redo()
            synchronizeMediaLayouts()
            await mediaLayoutTask?.value
            await waitForLayout(image.id)
            check(abs(canvas.node(id: image.id)!.width / canvas.node(id: image.id)!.height - 16.0/9) < 0.001,
                  "redo restores imported media dimensions")
            canvas.moveNode(id: image.id, to: CGPoint(x: 80, y: 440))
        }
        if let text = createNode(kind: .text, at: CGPoint(x: 420, y: 120), parentNodeId: nil, beginEditing: false, quiet: true),
           let movieID {
            canvas.moveNode(id: text.id, to: CGPoint(x: 80, y: 40))
            _ = store.writeCanvasSlotText(groupId: text.groupId, slot: text.slot, text: "晨光照进窗边，保留真实的画面比例。\n清晰可读的文字与安静的工作区。")
            canvas.noteSlotDataChanged()
            _ = canvas.connect(from: text.id, to: movieID)
            if let imageID { _ = canvas.connect(from: imageID, to: movieID) }
            canvas.select(id: movieID, additive: false)
        }
        canvas.isLibraryExpanded = false
        pan = CGSize(width: 80, height: 90)
        zoom = 0.65
        agentVisible = true
        try? await Task.sleep(nanoseconds: 600_000_000)
        let schemeName = "\(AppSkinCenter.current.rawValue)-\(mode)"
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-\(schemeName).png").path)
        if let id = canvas.edges.first?.id {
            canvas.clearSelection()
            canvas.selectedEdgeId = id
            try? await Task.sleep(nanoseconds: 400_000_000)
            check(controlRegions["edge-toolbar"] != nil, "selected edge exposes role and disconnect controls")
            PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-edge-\(schemeName).png").path)
            if let bounds = controlRegions["edge-disconnect"], let anchor = inputRouter.anchorView {
                await click(CGPoint(x: bounds.midX, y: bounds.midY), in: anchor)
                check(!canvas.edges.contains { $0.id == id }, "native scissors click disconnects selected edge")
                _ = canvas.undo()
                check(canvas.edges.contains { $0.id == id }, "undo restores clicked connection")
            } else { check(false, "disconnect button has hit geometry") }
        }
        canvas.flushSave()
        if let root = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"], let movieID {
            let restored = CanvasStorage(rootOverride: URL(fileURLWithPath: root)).load(projectId: canvas.activeProjectId)
            check(restored.nodes.first { $0.id == movieID }?.kind == .video, "video type survives document reload")
        }
        let draft = "主题切换后保留这段尚未按回车的提示词"
        if let movieID {
            canvas.select(id: movieID, additive: false)
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let frame = composerFrame, let anchor = inputRouter.anchorView {
                await click(CGPoint(x: frame.minX + 90, y: frame.minY + 85), in: anchor)
                if let editor = anchor.window?.firstResponder as? NSTextView {
                    editor.insertText(draft, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                    // #region debug-point E:draft-inserted
                    var r = URLRequest(url: URL(string: "http://127.0.0.1:7785/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "optimization-repairs", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "", "hypothesisId": "E", "msg": "[DEBUG] draft entered before theme switch", "data": ["editor": String(describing: type(of: editor)), "expectedDraft": editor.string == draft, "editingMovie": editingNodeId == movieID, "savedDraft": canvas.node(id: movieID).map { liveText(for: $0) == draft } ?? false]]); URLSession.shared.dataTask(with: r).resume()
                    // #endregion
                } else { check(false, "composer accepts draft before theme switch") }
            }
        }
        let originalSkin = AppSkinCenter.current
        if let bounds = controlRegions["appearance"], let anchor = inputRouter.anchorView {
            await click(CGPoint(x: bounds.midX, y: bounds.midY), in: anchor)
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let view = popup.contentView {
                check(true, "native appearance button opens shared controls")
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("canvas-appearance-\(schemeName).png"))
                }
                let otherMode = mode == "dark" ? "light" : "dark"
                @MainActor func popupPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    CGPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
                }
                await click(popupPoint(otherMode == "dark" ? 254 : 158, 68), in: view, canvasCoordinates: false)
                try? await Task.sleep(nanoseconds: 350_000_000)
                check(UserDefaults.standard.string(forKey: AppearanceDefaults.key) == otherMode,
                      "native mode control changes appearance preference")
                let nowDark = anchor.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                check(nowDark == (otherMode == "dark"), "native mode control updates canvas appearance")
                await click(popupPoint(mode == "dark" ? 254 : 158, 68), in: view, canvasCoordinates: false)
                let otherSkin: AppSkin = originalSkin == .minimal ? .colorful : .minimal
                await click(popupPoint(otherSkin == .colorful ? 232 : 86, 172), in: view, canvasCoordinates: false)
                try? await Task.sleep(nanoseconds: 450_000_000)
                check(AppSkinCenter.current == otherSkin, "native theme tile changes app skin")
                if let movieID, let movie = canvas.node(id: movieID) {
                    check(liveText(for: movie) == draft, "theme switching preserves unsubmitted composer text")
                }
                if popup.isVisible { popup.close() }
                AppSkinCenter.apply(originalSkin)
            } else { check(false, "appearance popover is visible") }
        } else { check(false, "appearance button reports geometry") }
        UserDefaults.standard.set(true, forKey: AgentPreferences.editSidebarVisibleKey)
        NotificationCenter.default.post(name: .setWorkspaceMode, object: nil, userInfo: ["mode": "edit"])
        try? await Task.sleep(nanoseconds: 500_000_000)
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-editor-\(schemeName).png").path)
        try? JSONSerialization.data(withJSONObject: ["passed": passed, "failures": failures], options: .prettyPrinted).write(to: directory.appendingPathComponent("report.json"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        NSApp.terminate(nil)
    }
}
#endif
