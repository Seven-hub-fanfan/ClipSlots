#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runNativeControlsProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        let run = ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "controls-before"
        func check(_ condition: Bool, _ label: String, data: [String: Any] = [:]) {
            if condition { passed += 1 } else { failures.append(label) }
            // #region debug-point A-D:control-probe
            var r = URLRequest(url: URL(string: "http://127.0.0.1:7784/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "slot-input-controls", "runId": run, "hypothesisId": "A-D", "msg": "[DEBUG] \(label)", "data": data.merging(["passed": condition]) { _, new in new }]); URLSession.shared.dataTask(with: r).resume()
            // #endregion
        }
        @MainActor func settle(_ seconds: Double = 0.4) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        guard let window = inputRouter.anchorView?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle()
        check(window.isKeyWindow && NSApp.isActive, "native control fixture has desktop focus")
        @MainActor func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) async {
            guard let hostWindow = view.window else { return }
            if ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1" {
                let p = hostWindow.convertPoint(toScreen: view.convert(point, to: nil))
                let payload: [String: Any] = [
                    "pid": Int(ProcessInfo.processInfo.processIdentifier), "window": hostWindow.windowNumber,
                    "type": (type == .leftMouseDown ? CGEventType.leftMouseDown : type == .leftMouseUp ? .leftMouseUp : type == .leftMouseDragged ? .leftMouseDragged : .mouseMoved).rawValue,
                    "x": p.x, "y": (NSScreen.screens.first?.frame.maxY ?? 0) - p.y, "clicks": 1]
                var data = try! JSONSerialization.data(withJSONObject: payload)
                data.append(10)
                let file = directory.appendingPathComponent("mouse-events.jsonl")
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile(); handle.write(data); try? handle.close()
                }
                await settle(0.12)
                return
            }
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hostWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
            await settle(0.1)
        }
        @MainActor func click(_ point: CGPoint, in view: NSView? = nil) async {
            guard let view = view ?? inputRouter.anchorView else { return }
            view.window?.makeKeyAndOrderFront(nil)
            await settle(0.1)
            await mouse(.mouseMoved, at: point, in: view)
            await mouse(.leftMouseDown, at: point, in: view)
            await mouse(.leftMouseUp, at: point, in: view)
            await settle()
        }
        @MainActor func axElements(_ element: Any, depth: Int = 0) -> [AnyObject] {
            guard depth < 24 else { return [] }
            let node = element as AnyObject
            return [node] + (node.accessibilityChildren?() ?? []).flatMap { axElements($0, depth: depth + 1) }
        }
        @MainActor func clickAX(_ text: String) async -> Bool {
            guard let root = window.contentView else { return false }
            let candidates = axElements(root).filter {
                $0.accessibilityRole?() == .button &&
                (($0.accessibilityLabel?() ?? "").contains(text) || ($0.accessibilityHelp?() ?? "").contains(text))
            }
            guard let element = candidates.first else { return false }
            guard let rect = element.accessibilityFrame?() else { return false }
            let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
            await click(root.convert(point, from: nil), in: root)
            return true
        }
        @MainActor func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        canvas.isLibraryExpanded = false
        agentVisible = false
        pan = CGSize(width: 80, height: 65)
        zoom = 0.8
        guard let slot = createNode(kind: .slot, at: CGPoint(x: 250, y: 300),
                                    parentNodeId: nil, beginEditing: false, quiet: true),
              let image = createNode(kind: .image, at: CGPoint(x: 700, y: 300),
                                     parentNodeId: slot.id, beginEditing: false, quiet: true),
              let video = createNode(kind: .video, at: CGPoint(x: 1100, y: 300),
                                     parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        _ = store.writeCanvasSlotText(groupId: slot.groupId, slot: slot.slot, text: "槽位上游提示词：晨光中的山脉。")
        let attachments = (1...7).map { index -> SlotContent.SlotAttachment in
            var att = SlotContent.SlotAttachment(name: index == 7 ? "crate_previous.png" : "input\(index).png",
                                                 type: index == 1 ? .file : .image)
            let path = directory.appendingPathComponent("input\(index).png")
            try? FileManager.default.copyItem(at: directory.appendingPathComponent("fixture.png"), to: path)
            att.storagePath = path.path
            return att
        }
        _ = store.writeCanvasSlotAttachments(groupId: slot.groupId, slot: slot.slot, attachments: attachments)
        canvas.noteSlotDataChanged()
        let expectedImages = slotReferenceImagePaths(for: slot)
        canvas.select(id: image.id, additive: false)
        await settle()
        if let run = controlRegions["composer-run"] { await click(CGPoint(x: run.midX, y: run.midY)) }
        for _ in 0..<40 {
            if case .succeeded = canvas.node(id: image.id)?.state { break }
            await settle(0.2)
        }
        check(canvas.node(id: image.id)?.taskId != nil, "generation button submits slot body and seven images",
              data: ["state": String(describing: canvas.node(id: image.id)?.state)])
        let commandText = (try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"))) ?? ""
        let commands = commandText.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]
        }
        let submitted = commands.first { $0.starts(with: ["generate", "image"]) } ?? []
        let submittedImages = submitted.indices.filter { submitted[$0] == "--image" && $0+1 < submitted.count }.map { submitted[$0+1] }
        let promptIndex = submitted.firstIndex(of: "--prompt")
        check(expectedImages.count == 7 && submittedImages == expectedImages,
              "CLI receives all seven ordered images including file-type and generated references",
              data: ["expected": expectedImages.count, "actual": submittedImages.count])
        check(promptIndex.map { submitted[$0+1] == "槽位上游提示词：晨光中的山脉。" } ?? false,
              "CLI receives upstream slot body as prompt")
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-slot-inputs-\(run).png").path)

        canvas.select(id: video.id, additive: false)
        _ = store.writeCanvasSlotText(groupId: video.groupId, slot: video.slot, text: "工具栏复制验证")
        canvas.noteSlotDataChanged()
        await settle()
        if let bar = controlRegions["node-toolbar"] {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("unchanged", forType: .string)
            await click(CGPoint(x: bar.minX + 113, y: bar.midY))
            check(NSPasteboard.general.string(forType: .string) == "工具栏复制验证", "node toolbar copy centre is clickable")
            await click(CGPoint(x: bar.minX + 75, y: bar.midY))
            check(editingNodeId == video.id, "node toolbar edit centre is clickable")
            editingNodeId = nil
            window.makeFirstResponder(nil)
            await settle()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("edge-unchanged", forType: .string)
            await click(CGPoint(x: bar.minX + 101, y: bar.midY - 10))
            check(NSPasteboard.general.string(forType: .string) == "工具栏复制验证", "node toolbar copy padded area is clickable")
        } else { check(false, "node toolbar has geometry") }

        canvas.select(id: slot.id, additive: false)
        await settle()
        if let row = controlRegions["slot-input-\(slot.id)"] {
            await click(CGPoint(x: row.midX, y: row.midY))
            check(inputFilesNodeId == slot.id, "slot input files button opens attachment manager")
            if ProcessInfo.processInfo.environment["CLIPSLOTS_OPTIMIZATION_PROBE"] == "1",
               let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let root = popup.contentView {
                if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("attachment-panel.png"))
                }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let handles = descendants(root).filter { $0 is ClickHandleNSView || $0 is DragHandleNSView }
                let geometry = handles.map { view in
                    ["class": String(describing: type(of: view)), "bounds": NSStringFromRect(view.bounds),
                     "visible": NSStringFromRect(view.visibleRect),
                     "frameInRoot": NSStringFromRect(root.convert(view.bounds, from: view)),
                     "hit": String(describing: root.hitTest(root.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)))]
                }
                try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted])
                    .write(to: directory.appendingPathComponent("attachment-handles.json"))
                let before = store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot)
                let historyCount = canvas.history.entries.count
                // #region debug-point C:event-target
                let panelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { event in
                    var r = URLRequest(url: URL(string: "http://127.0.0.1:7785/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "optimization-repairs", "runId": run, "hypothesisId": "C", "msg": "[DEBUG] panel event target", "data": ["window": event.windowNumber, "expectedWindow": popup.windowNumber, "type": event.type.rawValue, "location": NSStringFromPoint(event.locationInWindow), "rootBounds": NSStringFromRect(root.bounds), "rootFrame": NSStringFromRect(root.frame), "hit": String(describing: root.hitTest(event.locationInWindow))]]); URLSession.shared.dataTask(with: r).resume()
                    return event
                }
                defer { if let panelMonitor { NSEvent.removeMonitor(panelMonitor) } }
                // #endregion
                if let button = descendants(root).first(where: { $0 is ClickHandleNSView && abs($0.bounds.width - 22) < 1 }) {
                    await click(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
                    let after = store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot)
                    check(after.count == before.count - 1, "attachment manager native delete removes one image")
                    check(canvas.history.entries.count == historyCount + 1, "attachment manager delete creates one canvas undo entry")
                    // #region debug-point C:native-history
                    var r = URLRequest(url: URL(string: "http://127.0.0.1:7785/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "optimization-repairs", "runId": run, "hypothesisId": "C", "msg": "[DEBUG] native attachment deletion history", "data": ["before": before.count, "after": after.count, "historyDelta": canvas.history.entries.count-historyCount]]); URLSession.shared.dataTask(with: r).resume()
                    // #endregion
                    if canvas.history.entries.count == historyCount + 1 {
                        canvas.undo()
                        check(store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).map(\.id) == before.map(\.id),
                              "attachment manager delete undo restores order and image")
                        check(store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).allSatisfy { $0.resolveData()?.isEmpty == false },
                              "attachment manager delete undo restores image bytes")
                        canvas.redo()
                        check(store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).map(\.id) == after.map(\.id),
                              "attachment manager delete redo removes same image")
                        canvas.undo()
                    } else {
                        _ = store.writeCanvasSlotAttachments(groupId: slot.groupId, slot: slot.slot, attachments: before)
                    }
                    await settle()
                } else { check(false, "attachment manager exposes native delete handle") }
                let orderBefore = store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).map(\.id)
                let reorderHistory = canvas.history.cursor
                if let handle = descendants(root).first(where: { $0 is DragHandleNSView }) {
                    let p = CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)
                    await mouse(.leftMouseDown, at: p, in: handle)
                    // Use window coordinates because the row moves during the gesture.
                    let origin = root.convert(p, from: handle)
                    let sign: CGFloat = root.isFlipped ? 1 : -1
                    for step in 1...8 {
                        await mouse(.leftMouseDragged, at: CGPoint(x: origin.x, y: origin.y + sign * CGFloat(step) * 16), in: root)
                    }
                    await mouse(.leftMouseUp, at: CGPoint(x: origin.x, y: origin.y + sign * 128), in: root)
                    await settle()
                    let orderAfter = store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).map(\.id)
                    check(orderAfter != orderBefore, "attachment manager native drag changes order")
                    check(canvas.history.cursor == reorderHistory + 1, "attachment manager drag creates one undo transaction")
                    if canvas.history.cursor == reorderHistory + 1 {
                        canvas.undo()
                        check(store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).map(\.id) == orderBefore,
                              "attachment manager reorder undo restores original order")
                        canvas.redo()
                        check(store.canvasSlotAttachments(groupId: slot.groupId, slot: slot.slot).map(\.id) == orderAfter,
                              "attachment manager reorder redo restores final order")
                        canvas.undo()
                    }
                } else { check(false, "attachment manager exposes native reorder handle") }
            }
            inputFilesNodeId = nil
            AttachmentManagerPanelController.shared.close()
            await settle()
        }
        if let fan = controlRegions["slot-fan-\(slot.id)"], let anchor = inputRouter.anchorView {
            let before = canvas.node(id: slot.id)!.frame
            let p = CGPoint(x: fan.midX, y: fan.midY)
            await mouse(.leftMouseDown, at: p, in: anchor)
            for step in 1...8 {
                await mouse(.leftMouseDragged, at: CGPoint(x: p.x + CGFloat(step)*6, y: p.y+CGFloat(step)*2), in: anchor)
            }
            await mouse(.leftMouseUp, at: CGPoint(x: p.x+48, y: p.y+16), in: anchor)
            check(abs(canvas.node(id: slot.id)!.x-before.minX-48/zoom) < 1,
                  "populated slot preview native drag moves node")
        }
        await settle()
        if let fan = controlRegions["slot-fan-\(slot.id)"], let anchor = inputRouter.anchorView {
            await mouse(.mouseMoved, at: CGPoint(x: fan.midX, y: fan.midY), in: anchor)
            await settle()
            let key = CanvasFanWindowState.key(nodeId: slot.id, styleTag: "fan")
            let before = CanvasFanWindowRegistry.shared.start(for: key, total: 8, capacity: 5)
            await click(CGPoint(x: fan.maxX - 15 * zoom, y: fan.midY))
            let after = CanvasFanWindowRegistry.shared.start(for: key, total: 8, capacity: 5)
            check(after != before, "slot fan next-page arrow is clickable", data: ["before": before, "after": after])
        }
        canvas.select(id: video.id, additive: false)
        await settle()
        if let aspect = controlRegions["composer-aspect"] {
            await click(CGPoint(x: aspect.midX, y: aspect.midY))
            if let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let view = popup.contentView {
                await click(CGPoint(x: 48, y: view.isFlipped ? 78 : view.bounds.height - 78), in: view)
                check(canvas.node(id: video.id)?.ratio == "16:9", "aspect picker selects 16:9 by mouse")
            } else { check(false, "aspect picker opens") }
        } else { check(false, "aspect picker has geometry") }
        canvas.select(id: image.id, additive: false)
        await settle()
        if let bar = controlRegions["node-toolbar"] {
            await click(CGPoint(x: bar.maxX - 27, y: bar.midY))
            check(inputRouter.blocksCanvasInput?() == true, "node toolbar opens media fullscreen")
            await click(CGPoint(x: viewSize.width - 30, y: 24))
            check(inputRouter.blocksCanvasInput?() != true, "fullscreen close button responds")
        }
        canvas.select(id: video.id, additive: false)
        await settle()
        if let bar = controlRegions["node-toolbar"] {
            await click(CGPoint(x: bar.minX + 151, y: bar.midY))
            check(canvas.nodes.contains { $0.createdAt == video.createdAt && !canArchiveToLibrary($0) },
                  "node toolbar archives content into slot library")
        }
        if let bounds = controlRegions["appearance"] {
            await click(CGPoint(x: bounds.midX, y: bounds.midY))
            if let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let view = popup.contentView {
                func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    CGPoint(x: x, y: view.isFlipped ? y : view.bounds.height-y)
                }
                await click(point(222, 61), in: view)
                check(UserDefaults.standard.string(forKey: AppearanceDefaults.key) == "dark",
                      "appearance mode padded area is clickable")
                let skin = AppSkinCenter.current
                await click(point(skin == .minimal ? 176 : 25, 139), in: view)
                check(AppSkinCenter.current != skin, "theme tile padded corner is clickable")
                if popup.isVisible { popup.close() }
            } else { check(false, "appearance popover opens") }
        } else { check(false, "appearance control has geometry") }
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["CLIPSLOTS_TEST_APPEARANCE"] ?? "light",
                                  forKey: AppearanceDefaults.key)
        AppSkinCenter.apply(AppSkin(rawValue: ProcessInfo.processInfo.environment["CLIPSLOTS_TEST_SKIN"] ?? "minimal") ?? .minimal)
        agentVisible = true
        await settle()
        if let root = window.contentView {
            let elements = axElements(root)
            let descriptions = elements.map { [
                "role": $0.accessibilityRole?()?.rawValue ?? "",
                "label": $0.accessibilityLabel?() ?? "",
                "help": $0.accessibilityHelp?() ?? "",
                "frame": NSStringFromRect($0.accessibilityFrame?() ?? .zero)
            ] }
            try? JSONSerialization.data(withJSONObject: descriptions, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("controls-accessibility.json"))
        }
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-agent-welcome-\(run).png").path)
        let clickedSuggestion = await clickAX("打磨成画面")
        if !clickedSuggestion, let root = window.contentView {
            await click(CGPoint(x: root.bounds.width-360, y: root.isFlipped ? root.bounds.height*0.47 : root.bounds.height*0.53), in: root)
        }
        check(window.contentView.map { editors($0).contains { $0.string.contains("画面想法") } } ?? false,
              "canvas Agent suggestion click fills draft")
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-controls-\(run).png").path)
        UserDefaults.standard.set(true, forKey: AgentPreferences.editSidebarVisibleKey)
        NotificationCenter.default.post(name: .setWorkspaceMode, object: nil, userInfo: ["mode": "edit"])
        await settle(0.7)
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-editor-agent-welcome-\(run).png").path)
        let clickedEditorSuggestion = await clickAX("润色槽位内容")
        if !clickedEditorSuggestion, let root = window.contentView {
            await click(CGPoint(x: root.bounds.width-360, y: root.isFlipped ? root.bounds.height*0.47 : root.bounds.height*0.53), in: root)
        }
        check(window.contentView.map { editors($0).contains { $0.string.contains("帮我编辑当前组的槽位内容") } } ?? false,
              "editor Agent suggestion fills slot editing instruction")
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-editor-controls-\(run).png").path)
        let isolatedModel = AgentChatModel(displayName: "isolated")
        let isolated = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 780),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isolated.isReleasedWhenClosed = false
        let isolatedHost = NSHostingView(rootView: AgentSidebarView(model: isolatedModel, isVisible: .constant(true)))
        isolated.contentView = isolatedHost
        isolated.makeKeyAndOrderFront(nil)
        await settle()
        await click(CGPoint(x: 110, y: isolatedHost.isFlipped ? 360 : 420), in: isolatedHost)
        check(!isolatedModel.draft.isEmpty, "standalone Agent suggestion can be clicked")
        isolated.close()
        var plainClicks = 0
        let plain = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 100),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        let plainHost = NSHostingView(rootView: Button { plainClicks += 1 } label: {
            Text("Native button probe").frame(width: 280, height: 80).contentShape(Rectangle())
        }.buttonStyle(.plain))
        plain.contentView = plainHost
        plain.makeKeyAndOrderFront(nil)
        await settle()
        await click(CGPoint(x: 150, y: 50), in: plainHost)
        check(plainClicks == 1, "standalone plain SwiftUI button receives system mouse")
        plain.close()
        let report: [String: Any] = ["passed": passed, "failures": failures, "eventDelivery":
            ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1" ? "system CGEvent mouse" : "native event queue"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        await settle()
        NSApp.terminate(nil)
    }
}
#endif
