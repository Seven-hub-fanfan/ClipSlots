#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

/// A manual foreground fixture: no AX presses, synthetic input, or provider.
private actor InteractiveCandidateBackend: AgentBackend {
    private var callback: (@Sendable (AgentRunEvent) async -> Void)?
    private var completion: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func ready() async {
        if callback != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func emit(_ event: AgentRunEvent) async { await callback?(event) }
    func finish() { completion?.resume(); completion = nil }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        callback = onEvent
        await withCheckedContinuation {
            completion = $0; waiter?.resume(); waiter = nil
        }
        return history
    }
}

@MainActor enum InteractiveCandidateFixture {
    private static var window: NSWindow?
    private static var telemetry: Timer?
    private static var inputMonitor: Any?
    static func open(store: SlotStoreObservable, root: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.clipslots.app.interactive-s11-test",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true,
              root.path.hasPrefix("/tmp/clipslots-interactive-"),
              env["CLIPSLOTS_DATA_DIR"] == root.appendingPathComponent("data").path,
              env["CLIPSLOTS_CONFIG_PATH"] == root.appendingPathComponent("config.toml").path,
              env["CLIPSLOTS_FIXTURE_DIR"] == root.appendingPathComponent("fixtures").path,
              (try? CrateGenerationService.shared.resolveBinary()) != nil else { return }
        do {
            NativeAccessibilityProbe.enable()
            let file = root.appendingPathComponent("foreground-session.json")
            let backend = InteractiveCandidateBackend()
            let model = AgentChatModel(displayName: "S11 前台验收", backend: backend, persistenceURL: file)
            let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root.appendingPathComponent("canvas")),
                projectStorage: CanvasProjectStorage(rootOverride: root.appendingPathComponent("canvas")))
            let context = CanvasAgentContext(canvas: canvas, store: store, projectID: canvas.activeProjectId)
            model.canvasContext = context
            if model.messages.isEmpty {
                guard model.send(text: "前台交互夹具：查看任务记录与项目创作 Skill。", config: .init(model: "fixture"),
                                 enabledSkills: []) else { return }
                await backend.ready()
                await backend.emit(.runState(phase: "streaming", runID: "s11-fixture", cursor: nil))
                await backend.emit(.contentDelta("验收正文前段🙂\n"))
                await backend.emit(.contextCompaction(phase: .started, eventID: "compact-start"))
                await backend.emit(.contextCompaction(phase: .finished, eventID: "compact-finish"))
                let plan = try AgentTaskPlanSnapshot(validating: ["schema_version": "agent_task_snapshot.v1",
                    "plan_ready": true, "tasks": [
                        ["task_id": "one", "subject": "核对画布引用与原始比例", "status": "completed"],
                        ["task_id": "two", "subject": "检查未结束子任务的状态", "status": "in_progress"]]])
                await backend.emit(.taskSnapshot(plan, eventID: "plan"))
                var child: [String: JSONValue] = ["schema_version": "subagent_event.v1", "subagent_id": "child",
                    "parent_tool_call_id": "parent-one", "agent_type": "分析子任务",
                    "task_description": "核对引用与连线，保留停止和未知状态", "phase": "started"]
                await backend.emit(.subagentEvent(.object(child), eventID: "child|1"))
                child["phase"] = "content"
                child["text"] = .string((1...24).map { "子任务正文 \($0)：保留引用顺序与媒体比例。" }.joined(separator: "\n"))
                await backend.emit(.subagentEvent(.object(child), eventID: "child|2"))
                child["phase"] = "tool_completed"
                child["tool_event"] = ["schema_version": "tool_event.v1", "type": "tool_event",
                    "tool_call_id": "read-fixture", "tool": "Read", "status": "completed",
                    "request": ["path": "fixture-only.txt"], "response": "前台工具结果哨兵"]
                await backend.emit(.subagentEvent(.object(child), eventID: "child|3"))
                child["phase"] = "stopped"
                await backend.emit(.subagentEvent(.object(child), eventID: "child|4"))
                child["phase"] = "started"; child["parent_tool_call_id"] = "parent-two"
                child.removeValue(forKey: "text"); child.removeValue(forKey: "tool_event")
                await backend.emit(.subagentEvent(.object(child), eventID: "child|5"))
                await backend.emit(.assistantCompleted(.init(role: .assistant, content: "验收正文前段🙂\n验收正文后段。")))
                await backend.finish()
                while model.isRunning { await Task.yield() }
                guard model.flushSession() else { return }
            }
            let sync = AgentMarketSyncStore(service: .init(root: root.appendingPathComponent("market")),
                fixture: AgentMarketSnapshot(catalog: ["items": []], details: [:], accountStatus: "本地夹具"),
                readsDesktop: false)
            let w = NSWindow(contentRect: CGRect(x: 110, y: 100, width: 520, height: 850),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: InteractiveCandidateView(model: model, context: context, sync: sync,
                file: file, narrow: { w.setContentSize(CGSize(width: 320, height: 850)) }))
            w.title = "S11 前台交互验收"
            w.isReleasedWhenClosed = false; w.contentView = host
            window = w
            let inputFile = root.appendingPathComponent("native-input.jsonl")
            try Data().write(to: inputFile)
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp,
                .keyDown, .keyUp, .scrollWheel]) { event in
                let sample: [String: Any] = ["unixSeconds": Date().timeIntervalSince1970,
                    "type": event.type.rawValue, "window": event.windowNumber,
                    "keyCode": [.keyDown, .keyUp].contains(event.type) ? Int(event.keyCode) : -1,
                    "clickCount": [.leftMouseDown, .leftMouseUp].contains(event.type) ? event.clickCount : 0,
                    "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]
                if let bytes = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]),
                   let handle = try? FileHandle(forWritingTo: inputFile) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes + Data("\n".utf8))
                }
                return event
            }
            NSApp.setActivationPolicy(.regular)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
            telemetry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let sample: [String: Any] = ["unixSeconds": Date().timeIntervalSince1970,
                        "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
                        "window": w.windowNumber, "visible": w.isVisible, "width": w.frame.width,
                        "height": w.frame.height, "mouseX": NSEvent.mouseLocation.x, "mouseY": NSEvent.mouseLocation.y]
                    if let bytes = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]),
                       let handle = try? FileHandle(forWritingTo: root.appendingPathComponent("foreground.jsonl")) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes + Data("\n".utf8))
                    }
                }
            }
            try Data().write(to: root.appendingPathComponent("foreground.jsonl"))
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "window": w.windowNumber, "providerRequests": 0, "fixtureReady": true], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("ready.json"))
        } catch {
            try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("fixture-error.txt"))
        }
    }
}

private struct InteractiveCandidateView: View {
    @State var model: AgentChatModel
    let context: CanvasAgentContext
    let sync: AgentMarketSyncStore
    let file: URL
    let narrow: () -> Void
    @State private var reloads = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("浅色") { NSApp.appearance = NSAppearance(named: .aqua) }
                Button("深色") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                Button("窄窗口", action: narrow)
                Button("恢复会话") {
                    guard model.flushSession() else { return }
                    let restored = AgentChatModel(displayName: "S11 前台验收", backend: InteractiveCandidateBackend(),
                                                  persistenceURL: file)
                    restored.canvasContext = context; model = restored; reloads += 1
                }
                Text("恢复 \(reloads)").font(.system(size: 11))
            }.padding(8)
            AgentSidebarView(model: model, isVisible: .constant(true), isExpanded: true,
                credentialStateProvider: { (true, nil) }, marketSync: sync)
                .id(ObjectIdentifier(model))
        }
    }
}
#endif
