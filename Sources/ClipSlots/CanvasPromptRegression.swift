#if DEBUG
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runPromptSizingProbe(directory: URL) async {
        var failures: [String] = []
        var skipped: [String] = []
        var passed = 0
        @MainActor func waitForText(_ id: String, seconds: Int = 5) async {
            for _ in 0..<(seconds * 20) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if case .running = canvas.node(id: id)?.state { continue }
                if case .queued = canvas.node(id: id)?.state { continue }
                return
            }
        }
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failures.append(label) }
            NSLog("[CanvasPromptProbe] \(value ? "PASS" : "FAIL") \(label)")
        }
        guard let text = createNode(kind: .text, at: CGPoint(x: 300, y: 250), parentNodeId: nil, beginEditing: false, quiet: true),
              let image = createNode(kind: .image, at: CGPoint(x: 750, y: 250), parentNodeId: text.id, beginEditing: false, quiet: true) else { return }
        canvas.setTextGenerationPrompt(id: text.id, text: "生成橘猫")
        let original = "一只橘猫坐在窗边，柔和自然光。"
        _ = store.writeCanvasSlotText(groupId: text.groupId, slot: text.slot, text: original)
        let svg = "```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0\"/></svg>\n```"
        let payload: [String: Any] = ["choices": [["delta": ["content": svg], "finish_reason": "stop"]]]
        let sse = "data: " + String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)! + "\n\ndata: [DONE]\n\n"
        let transport = AgentScriptedTransport(steps: [.sse(sse), .sse(sse)])
        startTextGeneration(text, service: AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture")))
        await waitForText(text.id)
        check(!liveText(for: text).contains("<svg"), "SVG response never replaces prompt body")
        check(liveText(for: text) == original, "two unsuitable answers preserve existing text")
        check(transport.requestJSON(at: 1) != nil && transport.requestJSON(at: 2) == nil,
              "format correction is bounded to one extra text request")
        let valid = "一只毛发柔软的橘猫坐在木质窗台上，琥珀色眼睛望向窗外，午后的暖光轻柔地照亮面部与胡须，背景是虚化的庭院绿植，中近景平视构图，写实摄影风格，保留细腻毛发与自然色彩。"
        let encoded = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": valid], "finish_reason": "stop"]]])
        let repair = AgentScriptedTransport(steps: [.sse(sse), .sse("data: " + String(data: encoded, encoding: .utf8)! + "\n\ndata: [DONE]\n\n")])
        startTextGeneration(text, service: AgentService(transport: repair, secretStore: AgentInMemorySecretStore(key: "fixture")))
        await waitForText(text.id)
        check(liveText(for: text) == valid, "SVG answer is corrected to an editable image prompt")
        if case .object(let request) = repair.lastRequestJSON() {
            check(request["tools"] == nil, "prompt optimizer never exposes image-generation tools")
            check(String(describing: request["messages"]).contains("生图提示词"), "request specifies prompt optimization")
        }
        _ = canvas.undo()
        check(liveText(for: text) == original, "prompt optimization undo restores previous body")
        check(canvas.node(id: text.id)?.textGenerationPrompt == "生成橘猫", "optimization preserves original instruction")
        let before = canvas.node(id: image.id)!
        canvas.updateNodeGeneration(id: image.id, ratio: "16:9")
        let resized = canvas.node(id: image.id)!
        check(abs(resized.width / resized.height - 16.0/9) < 0.001, "ratio changes node geometry")
        check(resized.frame.midX == before.frame.midX && resized.frame.midY == before.frame.midY,
              "ratio switch retains card center")
        _ = canvas.undo()
        check(canvas.node(id: image.id)?.frame == before.frame, "ratio and frame undo together")
        _ = canvas.redo()
        check(canvas.node(id: image.id)?.frame == resized.frame, "ratio and frame redo together")
        for ratio in ["3:4", "16:9 4K", "3:2", "9:16", "1:1"] {
            canvas.updateNodeGeneration(id: image.id, ratio: ratio)
            let frame = canvas.node(id: image.id)!.frame
            check(abs(frame.width / frame.height - CanvasNodeSizing.aspectRatio(ratio)!) < 0.001,
                  "\(ratio) matches visible card dimensions")
        }
        canvas.select(id: image.id, additive: false)
        canvas.updateNodeGeneration(id: image.id, ratio: "9:16")
        zoom = 0.8
        pan = CGSize(width: 100, height: 100)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let card = screenFrame(of: canvas.node(id: image.id)!)
        check(outputPortPoint == CGPoint(x: card.maxX + TapSkin.portOffset, y: card.midY), "visible port follows resized card")
        check(composerFrame?.intersects(card) == false, "portrait composer avoids covering the card")
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-ratio-portrait.png").path)
        canvas.updateNodeGeneration(id: image.id, ratio: "16:9")
        try? await Task.sleep(nanoseconds: 400_000_000)
        PerfAutoTest.snapshotWindow(to: directory.appendingPathComponent("canvas-ratio-landscape.png").path)
        if ProcessInfo.processInfo.environment["CLIPSLOTS_SKIP_NATIVE_UI"] == "1" {
            skipped.append("Ratio popover click and tile selection require unlocked desktop")
        } else if let bounds = controlRegions["composer-aspect"], let anchor = inputRouter.anchorView,
           let window = anchor.window {
            let location = anchor.convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            for popup in NSApp.windows where popup.isVisible && !popup.canBecomeMain {
                if let view = popup.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("canvas-aspect-picker.png"))
                }
            }
            if let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
               let view = popup.contentView {
                check(true, "ratio picker opens from native click")
                // The fixture supplies [16:9,1:1,9:16]. Third tile center is verified
                // against the captured popup, then clicked through its own NSWindow.
                let point = CGPoint(x: 175, y: view.isFlipped ? 74 : view.bounds.height - 74)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.postEvent(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: popup.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!,
                        atStart: false)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                check(canvas.node(id: image.id)?.ratio == "9:16", "native tile updates model ratio")
                let rect = canvas.node(id: image.id)!.frame
                check(abs(rect.width / rect.height - 9.0/16) < 0.001, "native tile resizes node")
            } else {
                // #region debug-point C:picker-accessibility
                let roots = NSApp.windows.map { window -> [String: Any] in
                    ["class": String(describing: type(of: window)), "visible": window.isVisible, "main": window.canBecomeMain,
                     "children": window.accessibilityChildren()?.count ?? 0, "subviews": window.contentView?.subviews.map { String(describing: type(of: $0)) } ?? []]
                }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:7781/event")!); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-prompt-sizing", "runId": "picker", "hypothesisId": "C", "msg": "[DEBUG] picker windows", "data": roots]); URLSession.shared.dataTask(with: request).resume()
                // #endregion
                check(false, "ratio popup is visible")
            }
        } else { check(false, "ratio trigger reports visible geometry") }
        canvas.flushSave()
        if let root = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"] {
            let restored = CanvasStorage(rootOverride: URL(fileURLWithPath: root)).load(projectId: canvas.activeProjectId)
            check(restored.nodes.first { $0.id == image.id }?.frame == canvas.node(id: image.id)?.frame,
                  "node aspect survives project reload")
            check(restored.edges.contains { $0.fromNodeId == text.id && $0.toNodeId == image.id },
                  "resizing preserves upstream connection")
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_PROMPT_LIVE"] == "1" {
            let defaults = UserDefaults(suiteName: "com.clipslots.app") ?? .standard
            let config = CanvasTextGeneration.configuration(defaults: defaults)
            startTextGeneration(text, configuration: config)
            await waitForText(text.id, seconds: 90)
            let output = liveText(for: text)
            let success: Bool
            if case .succeeded = canvas.node(id: text.id)?.state { success = true } else { success = false }
            check(success && output != original && (try? CanvasImagePrompt.normalized(output)) != nil,
                  "configured live model returns a natural-language image prompt")
            if success {
                try? output.write(to: directory.appendingPathComponent("live-image-prompt.txt"), atomically: true, encoding: .utf8)
            }
        }
        // #region debug-point C:size
        var request = URLRequest(url: URL(string: "http://127.0.0.1:7781/event")!); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "canvas-prompt-sizing", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] ratio geometry", "data": ["ratio": resized.ratio, "width": resized.width, "height": resized.height]]); URLSession.shared.dataTask(with: request).resume()
        // #endregion
        let report: [String: Any] = ["passed": passed, "failures": failures, "skipped": skipped]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("report.json"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        NSApp.terminate(nil)
    }
}
#endif
