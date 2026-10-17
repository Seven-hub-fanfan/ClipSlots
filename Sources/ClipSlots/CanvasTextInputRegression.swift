#if DEBUG
import AppKit
import Carbon
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    /// Runs only inside the existing isolated regression entry point.
    @MainActor func runTextInputProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        var observations: [[String: Any]] = []
        let lifecycleOnly = ProcessInfo.processInfo.environment["CLIPSLOTS_TEXT_INPUT_LIFECYCLE"] == "1"
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures.append(label) }
        }
        func settle(_ seconds: Double = 0.25) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func observe(_ label: String, editor: NSTextView?) {
            let data: [String: Any] = [
                "stage": label, "windowKey": window.isKeyWindow, "active": NSApp.isActive,
                "editor": editor != nil, "firstResponder": editor.map { window.firstResponder === $0 } ?? false,
                "caret": editor?.shouldDrawInsertionPoint ?? false,
                "source": editor?.inputContext?.selectedKeyboardInputSource ?? "nil",
                "marked": editor?.hasMarkedText() ?? false, "text": editor?.string ?? "",
                "contextCurrent": editor.map { $0.inputContext === NSTextInputContext.current } ?? false]
            observations.append(data)
        }
        func capture(_ name: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            if name.contains("candidates") {
                // InputMethodKit candidates live in a separate window; a single-window
                // capture omits them. Capture only this app's on-screen frame instead.
                let f = window.frame
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - f.maxY
                process.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))",
                                     directory.appendingPathComponent(name + ".png").path]
            } else {
                process.arguments = ["-x", "-l", String(window.windowNumber), directory.appendingPathComponent(name + ".png").path]
            }
            try? process.run()
            process.waitUntilExit()
        }
        func mouse(_ type: CGEventType, _ p: CGPoint, clicks: Int = 1) async {
            if lifecycleOnly {
                let nativeType: NSEvent.EventType = type == .leftMouseDown ? .leftMouseDown :
                    type == .leftMouseUp ? .leftMouseUp : .mouseMoved
                if let event = NSEvent.mouseEvent(with: nativeType, location: anchor.convert(p, to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
                await settle(0.08)
                return
            }
            let screen = window.convertPoint(toScreen: anchor.convert(p, to: nil))
            let global = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global, mouseButton: .left)
            event?.flags = []
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            event?.post(tap: .cghidEventTap)
            await settle(0.055)
        }
        func click(_ p: CGPoint, double: Bool = false) async {
            await mouse(.mouseMoved, p)
            await mouse(.leftMouseDown, p)
            await mouse(.leftMouseUp, p)
            if double {
                await mouse(.leftMouseDown, p, clicks: 2)
                await mouse(.leftMouseUp, p, clicks: 2)
            }
            await settle()
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags = []) async {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                await settle(0.04)
            }
        }
        func editors(_ view: NSView) -> [NSTextView] {
            ([view as? NSTextView].compactMap { $0 }) + view.subviews.flatMap(editors)
        }
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer { TISSelectInputSource(originalSource) }
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        let pinyin = sources.first {
            guard let value = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String == "com.apple.inputmethod.SCIM.ITABC"
        }
        guard let pinyin else {
            failures.append("System Pinyin input source is available")
            try? JSONSerialization.data(withJSONObject: ["passed": passed, "failures": failures])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.setFrameOrigin(CGPoint(x: 80, y: 80))
        window.setContentSize(CGSize(width: 1250, height: 800))
        if let mode = ProcessInfo.processInfo.environment["CLIPSLOTS_TEST_APPEARANCE"] {
            UserDefaults.standard.set(mode, forKey: "appearanceMode")
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        canvas.isLibraryExpanded = false
        pan = CGSize(width: 50, height: 70)
        zoom = CGFloat(Double(ProcessInfo.processInfo.environment["CLIPSLOTS_TEXT_INPUT_ZOOM"] ?? "") ?? 0.75)
        await settle(0.6)
        guard let node = createNode(kind: .text, at: CGPoint(x: 570, y: 260),
                                    parentNodeId: nil, beginEditing: false, quiet: true) else { return }
        await settle()
        // A competing native window leaves the canvas non-key before the real click.
        let focusHolder = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 160, height: 80),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        focusHolder.isReleasedWhenClosed = false
        if !lifecycleOnly {
            focusHolder.makeKeyAndOrderFront(nil)
            await settle()
        }
        let rect = screenFrame(of: node)
        await click(CGPoint(x: rect.midX, y: rect.midY), double: true)
        focusHolder.close()
        var nodeEditor = window.firstResponder as? NSTextView
        observe("new-node-double-click", editor: nodeEditor)
        check(editingNodeId == node.id && nodeEditor?.isEditable == true, "Double click new node activates editor")
        if !lifecycleOnly {
            check(window.isKeyWindow && NSApp.isActive, "Canvas click reactivates its native window")
            check(nodeEditor?.shouldDrawInsertionPoint == true, "New empty node draws insertion caret")
            capture("text-empty-caret")
        }

        for target in ["node", "composer"] {
            if target == "composer", let content = window.contentView,
               let composer = editors(content).first(where: { $0 !== nodeEditor && $0.isEditable }) {
                let bounds = anchor.convert(composer.visibleRect, from: composer)
                await click(CGPoint(x: bounds.midX, y: bounds.midY))
            }
            guard let editor = window.firstResponder as? NSTextView else {
                failures.append("\(target) receives native focus"); continue
            }
            if target == "node" { nodeEditor = editor }
            if target == "composer" {
                check(editor.string == liveText(for: node), "Composer opens the same live node text")
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            }
            if lifecycleOnly {
                // Tests the marked-text contract only, never claims system IME coverage.
                editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                                     replacementRange: editor.selectedRange())
                await settle()
                pan.width += 1
                await settle()
                check(editor.hasMarkedText() && editor.string == "nihao", "\(target) retains composition through canvas refresh")
                check(window.firstResponder === editor, "\(target) retains responder through canvas refresh")
                editor.insertText("你好🙂", replacementRange: editor.markedRange())
                await settle()
                check(editor.string == "你好🙂" && !editor.hasMarkedText(), "\(target) accepts committed Unicode text")
                check(liveText(for: node) == "你好🙂", "\(target) synchronizes committed Unicode into node immediately")
                check(editor.selectedRange().location == 4, "\(target) preserves UTF-16 insertion position")
                observe("\(target)-lifecycle", editor: editor)
                continue
            }
            TISSelectInputSource(pinyin)
            await settle()
            observe("\(target)-pinyin-selected", editor: editor)
            check(editor.inputContext?.selectedKeyboardInputSource == "com.apple.inputmethod.SCIM.ITABC",
                  "\(target) uses actual system Pinyin")
            // Hardware n i h a o; do not insert Chinese directly or attach Unicode to key events.
            for code: CGKeyCode in [45, 34, 4, 0, 31] { await key(code) }
            await settle(0.4)
            observe("\(target)-pinyin-composing", editor: editor)
            check(editor.hasMarkedText(), "\(target) preserves Pinyin composition")
            capture("\(target)-pinyin-candidates")
            await key(49)
            await settle(0.3)
            observe("\(target)-chinese-committed", editor: editor)
            check(editor.string == "你好" && !editor.hasMarkedText(), "\(target) commits Chinese through candidate selection")
            check(liveText(for: node) == "你好", "\(target) synchronizes Chinese into node immediately")
            check(window.firstResponder === editor, "\(target) retains focus after Chinese commit")
            capture("\(target)-chinese")
        }
        let report: [String: Any] = ["passed": passed, "failures": failures, "observations": observations,
                                    "systemInputValidated": !lifecycleOnly]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        await settle()
        TISSelectInputSource(originalSource)
        NSApp.terminate(nil)
    }
}
#endif
