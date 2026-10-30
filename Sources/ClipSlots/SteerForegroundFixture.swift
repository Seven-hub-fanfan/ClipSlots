#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

/// Exercises the original resumable interface against the real local gateway.
/// Deliberately offers no hot-steering interface, as with the earlier backend.
private actor ForegroundLegacyGateway: AgentGatewayResuming {
    let gateway: AgentGatewayBackend
    init(_ gateway: AgentGatewayBackend) { self.gateway = gateway }
    var hasResumableRun: Bool { get async { await gateway.hasResumableRun } }
    var snapshot: AgentGatewayRunSnapshot { get async { await gateway.snapshot } }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        try await gateway.run(history: history, config: config, tools: tools, onEvent: onEvent)
    }
    func resume(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
                onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        try await gateway.resume(history: history, config: config, tools: tools, onEvent: onEvent)
    }
    func cancelRun() async { await gateway.cancelRun() }
    func waitUntilReadyToSteer() async throws -> Bool { try await gateway.waitUntilReadyToSteer() }
}

@MainActor enum SteerForegroundFixture {
    private static var window: NSWindow?
    private static var timer: Timer?
    private static var inputMonitor: Any?
    static func open(root: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["STEER_FOREGROUND_MODE"], ["steer", "legacy"].contains(mode),
              Bundle.main.bundleIdentifier == "com.clipslots.app.interactive-s12-\(mode)",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true,
              root.path.hasPrefix("/tmp/clipslots-interactive-"),
              env["CLIPSLOTS_DATA_DIR"] == root.appendingPathComponent("data").path,
              env["CLIPSLOTS_CONFIG_PATH"] == root.appendingPathComponent("config.toml").path,
              let endpoint = env["STEER_GATEWAY_URL"].flatMap(URL.init(string:)),
              endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let control = env["STEER_CONTROL_URL"].flatMap(URL.init(string:)),
              control.scheme == "http", control.host == "127.0.0.1",
              (try? CrateGenerationService.shared.resolveBinary()) != nil else { return }
        do {
            // The unique bundle has its own preferences domain.
            let defaults = UserDefaults.standard
            defaults.set("synthetic", forKey: AgentGatewayPreferences.modelKey)
            defaults.set(endpoint.absoluteString, forKey: AgentGatewayPreferences.endpointKey)
            defaults.set("synthetic", forKey: AgentPreferences.modelKey)
            defaults.set("本地前台交互验收", forKey: AgentPreferences.systemPromptKey)
            defaults.set(endpoint.absoluteString, forKey: AgentPreferences.endpointKey)
            defaults.set(AgentThinkingMode.serverDefault.rawValue, forKey: AgentPreferences.thinkingModeKey)
            defaults.set("", forKey: AgentPreferences.reasoningEffortKey)
            defaults.set("", forKey: AgentPreferences.enabledSkillsKey)
            NativeAccessibilityProbe.enable()
            let file = root.appendingPathComponent("foreground-session.json")
            let model = AgentChatModel(displayName: "S12 前台验收", persistenceURL: file)
            let gateway = AgentGatewayBackend(baseURL: endpoint,
                binding: .init(sessionID: model.selectedConversationID.uuidString),
                journalRoot: root.appendingPathComponent("journal"), apiKeyProvider: { "live-auth" })
            let backend: any AgentBackend = mode == "legacy" ? ForegroundLegacyGateway(gateway) : gateway
            model.setBackend(backend, kind: .gateway)
            var config = AgentPreferences.config(model: "synthetic", systemPrompt: "本地前台交互验收",
                thinkingRaw: AgentThinkingMode.serverDefault.rawValue, reasoningEffort: "",
                endpoint: endpoint.absoluteString)
            config.supportsImageInput = false
            guard model.send(text: "前台验收：保留当前任务的已完成工作。", config: config, enabledSkills: []) else { return }
            let sync = AgentMarketSyncStore(service: .init(root: root.appendingPathComponent("market")),
                fixture: .init(catalog: ["items": []], details: [:], accountStatus: "本地夹具"),
                readsDesktop: false)
            let w = NSWindow(contentRect: CGRect(x: 110, y: 100, width: 620, height: 850),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "S12 前台验收 · \(mode)"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SteerForegroundView(model: model, sync: sync,
                control: control, narrow: { w.setContentSize(CGSize(width: 360, height: 850)) }))
            window = w
            let inputFile = root.appendingPathComponent("native-input.jsonl")
            try Data().write(to: inputFile)
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp,
                .keyDown, .keyUp, .scrollWheel]) { event in
                let sample: [String: Any] = ["time": Date().timeIntervalSince1970,
                    "type": event.type.rawValue, "window": event.windowNumber,
                    "keyCode": [.keyDown, .keyUp].contains(event.type) ? Int(event.keyCode) : -1,
                    "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]
                append(sample, to: inputFile)
                return event
            }
            NSApp.setActivationPolicy(.regular)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let telemetryFile = root.appendingPathComponent("foreground.jsonl")
            try Data().write(to: telemetryFile)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    append(["time": Date().timeIntervalSince1970, "active": NSApp.isActive,
                        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1, "window": w.windowNumber,
                        "visible": w.isVisible, "width": w.frame.width, "height": w.frame.height,
                        "isRunning": model.isRunning, "phase": model.runPhase.rawValue,
                        "runID": model.gatewayRunID ?? "", "canHotSteer": model.canHotSteer,
                        "isControlling": model.isControllingRun, "draft": model.draft,
                        "queue": model.queuedSubmissions.map { ["id": $0.id.uuidString, "text": $0.text,
                            "status": model.queuedSteerStatus($0) ?? "未提交"] },
                        "messages": model.messages.map { ["id": $0.id.uuidString,
                            "role": $0.role.rawValue, "content": $0.content] }], to: telemetryFile)
                    model.flushSession()
                }
            }
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "window": w.windowNumber, "fixtureReady": true, "mode": mode], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("ready.json"))
        } catch {
            try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("fixture-error.txt"))
        }
    }
    private static func append(_ sample: [String: Any], to file: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}

private struct SteerForegroundView: View {
    @ObservedObject var model: AgentChatModel
    let sync: AgentMarketSyncStore
    let control: URL
    let narrow: () -> Void
    @State private var releaseStatus = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("放行当前轮") {
                    Task {
                        do {
                            let result = try await URLSessionAgentGatewayTransport().send(
                                request: .init(url: control.appendingPathComponent("release")))
                            releaseStatus = result.statusCode == 200 ? "已放行" : "放行失败"
                        } catch { releaseStatus = error.localizedDescription }
                    }
                }
                Button("窄窗口", action: narrow)
                Button("浅色") { NSApp.appearance = NSAppearance(named: .aqua) }
                Button("深色") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                Text(releaseStatus).font(.system(size: 11))
            }.padding(8)
            AgentSidebarView(model: model, isVisible: .constant(true), isExpanded: true,
                credentialStateProvider: { (true, nil) }, marketSync: sync)
        }
    }
}
#endif
