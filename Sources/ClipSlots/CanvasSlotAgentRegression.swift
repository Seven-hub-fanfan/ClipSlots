#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runSlotAgentProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        var skipped: [String] = []
        let run = ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix"
        let directDispatch = ProcessInfo.processInfo.environment["CLIPSLOTS_DIRECT_EVENTS"] == "1"
        func check(_ condition: Bool, _ label: String, data: [String: Any] = [:]) {
            if condition { passed += 1 } else { failures.append(label) }
            NSLog("[SlotAgent] \(condition ? "PASS" : "FAIL") \(label)")
            // #region debug-point A-B:probe-result
            var r = URLRequest(url: URL(string: "http://127.0.0.1:7783/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-slot-interactions", "runId": run, "hypothesisId": label.contains("theme") ? "A" : "B", "msg": "[DEBUG] \(label)", "data": data.merging(["passed": condition]) { _, new in new }]); URLSession.shared.dataTask(with: r).resume()
            // #endregion
        }
        @MainActor func settle(_ seconds: Double = 0.35) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        @MainActor func mouse(_ type: NSEvent.EventType, _ point: CGPoint, view: NSView? = nil) async {
            guard let view = view ?? inputRouter.anchorView, let window = view.window else { return }
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if directDispatch {
                _ = inputRouter.routeForRegression(event)
            } else {
                NSApp.postEvent(event, atStart: false)
            }
            await settle(0.1)
        }
        @MainActor func click(_ point: CGPoint, view: NSView? = nil) async {
            if let window = (view ?? inputRouter.anchorView)?.window {
                NSApp.activate(ignoringOtherApps: true)
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                window.makeKey()
                await settle(0.15)
                // #region debug-point A-B:fixture-focus
                var r = URLRequest(url: URL(string: "http://127.0.0.1:7783/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-slot-interactions", "runId": run, "hypothesisId": "B", "msg": "[DEBUG] fixture focus", "data": ["active": NSApp.isActive, "key": window.isKeyWindow, "canKey": window.canBecomeKey, "number": window.windowNumber, "keyNumber": NSApp.keyWindow?.windowNumber ?? -1, "style": window.styleMask.rawValue, "visible": window.isVisible]]); URLSession.shared.dataTask(with: r).resume()
                // #endregion
            }
            await mouse(.mouseMoved, point, view: view)
            await mouse(.leftMouseDown, point, view: view)
            await mouse(.leftMouseUp, point, view: view)
            await settle()
        }
        @MainActor func drag(_ point: CGPoint, by delta: CGSize) async {
            await mouse(.leftMouseDown, point)
            for step in 1...8 {
                await mouse(.leftMouseDragged, CGPoint(x: point.x + delta.width * CGFloat(step)/8,
                                                       y: point.y + delta.height * CGFloat(step)/8))
            }
            await mouse(.leftMouseUp, CGPoint(x: point.x + delta.width, y: point.y + delta.height))
            await settle()
        }
        canvas.isLibraryExpanded = false
        agentVisible = false
        pan = CGSize(width: 80, height: 70)
        zoom = 1
        NSApp.activate(ignoringOtherApps: true)
        inputRouter.anchorView?.window?.makeKeyAndOrderFront(nil)
        guard let slot = createNode(kind: .slot, at: CGPoint(x: 500, y: 300),
                                    parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        await settle()
        canvas.clearSelection()
        await settle()
        let rect = screenFrame(of: slot)
        let bodyPoint = CGPoint(x: rect.minX + 5, y: rect.midY)
        await click(bodyPoint)
        check(canvas.selectedNodeIds == [slot.id], "slot body click selects node")
        await mouse(.leftMouseDown, bodyPoint)
        for step in 1...8 {
            await mouse(.leftMouseDragged, CGPoint(x: bodyPoint.x + CGFloat(step) * 10, y: bodyPoint.y + CGFloat(step) * 4))
        }
        await mouse(.leftMouseUp, CGPoint(x: bodyPoint.x + 80, y: bodyPoint.y + 32))
        await settle()
        let moved = canvas.node(id: slot.id)!
        check(abs(moved.x-slot.x-80) < 1 && abs(moved.y-slot.y-32) < 1, "slot body drag moves node",
              data: ["before": NSStringFromRect(slot.frame), "after": NSStringFromRect(moved.frame)])
        if moved.x != slot.x {
            _ = canvas.undo()
            check(abs(canvas.node(id: slot.id)!.x-slot.x) < 1, "slot drag is undoable")
        }
        await settle()
        let emptyPreviewPoint = CGPoint(x: rect.midX, y: rect.minY + 80)
        await click(emptyPreviewPoint)
        check(canvas.selectedNodeIds == [slot.id], "empty preview click selects")
        await drag(emptyPreviewPoint, by: CGSize(width: -30, height: 20))
        check(abs(canvas.node(id: slot.id)!.x-slot.x+30) < 1, "empty preview drag moves")
        _ = canvas.undo()
        await settle()
        if let prompt = controlRegions["slot-prompt-\(slot.id)"] {
            let p = CGPoint(x: prompt.midX, y: prompt.midY)
            await drag(p, by: CGSize(width: 45, height: 10))
            check(abs(canvas.node(id: slot.id)!.x-slot.x-45) < 1, "prompt preview drag moves without editing")
            check(editingNodeId == nil, "drag does not open text editor")
            _ = canvas.undo()
            await settle()
            await click(p)
            check(editingNodeId == slot.id, "prompt click opens editor")
            await settle()
            check(controlRegions["slot-editor-\(slot.id)"] != nil, "editor owns its control region")
            editingNodeId = nil
            await settle()
        } else { check(false, "prompt hit geometry exists") }
        if let other = createNode(kind: .slot, at: CGPoint(x: 900, y: 300),
                                  parentNodeId: nil, beginEditing: false, quiet: true) {
            canvas.select(id: slot.id, additive: false)
            canvas.select(id: other.id, additive: true)
            await settle()
            await drag(bodyPoint, by: CGSize(width: 40, height: -20))
            check(abs(canvas.node(id: slot.id)!.x-slot.x-40) < 1 &&
                  abs(canvas.node(id: other.id)!.x-other.x-40) < 1, "selected slots move together")
            _ = canvas.undo()
            check(abs(canvas.node(id: slot.id)!.x-slot.x) < 1 &&
                  abs(canvas.node(id: other.id)!.x-other.x) < 1, "group drag undoes in one step")
            canvas.removeNodes(ids: [other.id])
        }
        editingNodeId = nil
        canvas.select(id: slot.id, additive: false)
        await settle()
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-slot-\(run).png").path)
        if directDispatch {
            skipped.append("Native theme padded-edge clicks, input button, fan gestures and Agent clicks require unlocked desktop")
        } else if let bounds = controlRegions["appearance"] {
            await click(CGPoint(x: bounds.midX, y: bounds.midY))
            if let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let view = popup.contentView {
                @MainActor func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: view.isFlipped ? y : view.bounds.height-y) }
                await click(p(222, 61), view: view)
                check(UserDefaults.standard.string(forKey: AppearanceDefaults.key) == "dark",
                      "theme mode padded edge is clickable")
                await click(p(254, 68), view: view)
                check(UserDefaults.standard.string(forKey: AppearanceDefaults.key) == "dark",
                      "theme mode text centre is clickable")
                let skin = AppSkinCenter.current
                await click(p(skin == .minimal ? 176 : 25, 139), view: view)
                check(AppSkinCenter.current != skin, "theme tile padded corner is clickable")
                if popup.isVisible { popup.close() }
            } else { check(false, "theme popover opens") }
        }
        agentVisible = true
        await settle()
        if let anchor = inputRouter.anchorView, let window = anchor.window {
            let point = CGPoint(x: viewSize.width + 100, y: 350)
            let selection = canvas.selectedNodeIds
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: anchor.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            check(!inputRouter.routeForRegression(event) && canvas.selectedNodeIds == selection,
                  "Agent panel clicks bypass canvas selection routing")
        }
        canvas.moveNode(id: slot.id, to: CGPoint(x: 150, y: 120))
        canvas.clearSelection()
        if let populated = createNode(kind: .slot, at: CGPoint(x: 620, y: 290),
                                       parentNodeId: nil, beginEditing: false, quiet: true) {
            _ = store.writeCanvasSlotText(groupId: populated.groupId, slot: populated.slot,
                                           text: "晨光照进窗边，柔和侧光。\n\n镜头缓慢向前，保留真实比例。\n\n构图简洁，画面安静。")
            canvas.noteSlotDataChanged()
            hoverHoldNodeId = populated.id
            await settle()
            if let fan = controlRegions["slot-fan-\(populated.id)"],
               let inputs = controlRegions["slot-input-\(populated.id)"] {
                check(!isCanvasSurface(at: CGPoint(x: fan.midX, y: fan.midY)),
                      "native router yields preview to fan controls")
                check(!isCanvasSurface(at: CGPoint(x: inputs.midX, y: inputs.midY)),
                      "native router yields input-file button")
                let point = CGPoint(x: fan.midX, y: fan.midY)
                check(isCanvasSurface(at: point, allowingSlotPreview: true),
                      "hand tool accepts slot preview surface")
                if let window = inputRouter.anchorView?.window {
                    window.makeFirstResponder(nil)
                    let oldPan = pan
                    let oldFrame = canvas.node(id: populated.id)!.frame
                    let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                    _ = inputRouter.routeForRegression(down)
                    await drag(point, by: CGSize(width: 32, height: 16))
                    let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                    _ = inputRouter.routeForRegression(up)
                    check(abs(pan.width-oldPan.width-32) < 1 && abs(pan.height-oldPan.height-16) < 1,
                          "space drag over slot preview pans canvas")
                    check(canvas.node(id: populated.id)!.frame == oldFrame, "hand drag keeps slot coordinates")
                    pan = oldPan
                }
            } else { check(false, "populated slot control geometry exists") }
        }
        canvas.clearSelection()
        for skin in [AppSkin.minimal, .colorful] {
            AppSkinCenter.apply(skin)
            for appearance in ["light", "dark"] {
                UserDefaults.standard.set(appearance, forKey: AppearanceDefaults.key)
                await settle(0.5)
                PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-agent-\(skin.rawValue)-\(appearance)-\(run).png").path)
                addMenu = AddNodeRequest(screenPoint: CGPoint(x: 660, y: 160),
                                         canvasPoint: CGPoint(x: 580, y: 90), parentNodeId: nil)
                await settle()
                PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-menu-\(skin.rawValue)-\(appearance)-\(run).png").path)
                addMenu = nil
            }
        }
        await runAgentModelProbe(directory: directory) { condition, label in check(condition, label) }
        let report: [String: Any] = ["passed": passed, "failures": failures,
                                     "skipped": skipped,
                                     "eventDelivery": directDispatch ? "direct canvas router (no desktop focus)" : "native event queue"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        await settle()
        NSApp.terminate(nil)
    }
}
#endif
