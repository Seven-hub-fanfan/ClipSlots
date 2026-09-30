#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runWindowLifecycleProbe(directory: URL) async {
        var checks: [String: Bool] = [:]
        var snapshots: [[String: Any]] = []
        func pause(_ seconds: Double = 0.7) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
        func snapshot(_ stage: String) {
            let windows: [[String: Any]] = NSApp.windows.map { window in
                let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                let buttons: [[String: Any]] = kinds.map { kind in
                    let button = window.standardWindowButton(kind)
                    let rect = button.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? ""
                    let action = button?.action.map { NSStringFromSelector($0) } ?? ""
                    return ["kind": kind.rawValue, "enabled": button?.isEnabled ?? false, "frame": rect, "action": action]
                }
                return ["number": window.windowNumber, "visible": window.isVisible, "mini": window.isMiniaturized,
                        "mask": window.styleMask.rawValue, "class": String(describing: type(of: window)), "buttons": buttons]
            }
            snapshots.append(["stage": stage, "windows": windows])
        }
        func mouseClick(_ button: NSButton, window: NSWindow) async {
            let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let screen = window.convertPoint(toScreen: center)
            let quartz = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let payload: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "window": window.windowNumber, "type": type.rawValue, "x": quartz.x, "y": quartz.y,
                    "flags": 0, "clicks": 1]
                var bytes = try! JSONSerialization.data(withJSONObject: payload)
                bytes.append(10)
                let path = directory.appendingPathComponent("mouse-events.jsonl")
                if !FileManager.default.fileExists(atPath: path.path) {
                    FileManager.default.createFile(atPath: path.path, contents: nil)
                }
                let handle = try! FileHandle(forWritingTo: path)
                handle.seekToEndOfFile()
                handle.write(bytes)
                try? handle.close()
                await pause(0.12)
            }
            await pause()
        }
        func reopen() async {
            _ = await AgentProcessRunner.run(executable: "/usr/bin/open", arguments: [Bundle.main.bundlePath], timeout: 10)
            await pause(1.3)
        }
        func mainWindow() -> NSWindow? {
            NSApp.windows.first { $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        }
        let marker = "window lifecycle retained content"
        let node = createNode(kind: .text, at: CGPoint(x: 300, y: 200), parentNodeId: nil,
                              beginEditing: false, quiet: true)!
        commitEdit(node, text: marker)
        canvas.flushSave()
        await pause(1)
        snapshot("canvas-start")
        if let window = mainWindow(), let button = window.standardWindowButton(.miniaturizeButton) {
            checks["canvas minimize button enabled"] = button.isEnabled
            await mouseClick(button, window: window)
            checks["canvas yellow button minimizes"] = window.isMiniaturized
            snapshot("after-yellow")
            if !window.isMiniaturized { window.performMiniaturize(nil); await pause() }
            checks["native performMiniaturize works"] = window.isMiniaturized
            await pause(1)
            checks["window remains minimized"] = window.isMiniaturized
            await reopen()
            checks["reopen restores minimized canvas"] = window.isVisible && !window.isMiniaturized
            snapshot("after-minimized-reopen")
            // 确保无窗口分支被实际触发，避免只验证隐藏窗口。
            if let close = window.standardWindowButton(.closeButton) { await mouseClick(close, window: window) }
            checks["canvas red button closes"] = !window.isVisible
            if window.isVisible { window.performClose(nil); await pause() }
        }
        snapshot("after-close")
        await reopen()
        let reopened = mainWindow()
        checks["reopen after close creates visible main window"] = reopened?.isVisible == true
        snapshot("after-closed-reopen")
        checks["canvas document survives close and reopen"] =
            store.canvasSlotText(groupId: node.groupId, slot: node.slot) == marker
        if let window = reopened, window.isVisible {
            NotificationCenter.default.post(name: .setWorkspaceMode, object: nil, userInfo: ["mode": "edit"])
            await pause()
            if let button = window.standardWindowButton(.miniaturizeButton) {
                await mouseClick(button, window: window)
                checks["editor yellow button minimizes"] = window.isMiniaturized
            }
            await reopen()
            checks["reopen restores minimized editor"] = window.isVisible && !window.isMiniaturized
            window.performClose(nil)
            await pause()
            await reopen()
            checks["editor close and reopen restores window"] = mainWindow()?.isVisible == true
        }
        let report: [String: Any] = ["checks": checks, "passed": checks.values.filter { $0 }.count,
            "failures": checks.filter { !$0.value }.map(\.key).sorted(), "snapshots": snapshots,
            "eventDelivery": "system CGEvent buttons; LaunchServices reopen"]
        let bytes = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? bytes.write(to: directory.appendingPathComponent("report.json"))
        // #region debug-point A-C:probe-results
        var r = URLRequest(url: URL(string: "http://127.0.0.1:7786/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "window-lifecycle", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A-C", "msg": "[DEBUG] window lifecycle probe", "data": report]); _ = try? await URLSession.shared.data(for: r)
        // #endregion
        NSApp.terminate(nil)
    }
}
#endif
