#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor DecisionForegroundTransport: AgentGatewayTransport {
    let network = URLSessionAgentGatewayTransport()
    let failPreflight: Bool
    var reads = 0
    init(failPreflight: Bool) { self.failPreflight = failPreflight }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        if request.httpMethod == "GET", request.url?.path.contains("/interactions/") == true {
            reads += 1
            if failPreflight && (2...3).contains(reads) { throw URLError(.networkConnectionLost) }
        }
        return try await network.send(request: request)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream { try await network.stream(request: request) }
}

@MainActor private final class DecisionForegroundController: ObservableObject {
    @Published var model = AgentChatModel(displayName: "S15 本地决策验收")
    @Published var scenario = ""
    let root: URL
    let endpoint: URL
    init(root: URL, endpoint: URL) { self.root = root; self.endpoint = endpoint }
    func start(_ scenario: String) {
        do {
            let directory = root.appendingPathComponent("sessions").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let model = AgentChatModel(displayName: "S15 · \(scenario)",
                persistenceURL: directory.appendingPathComponent("session.json"))
            let gateway = AgentGatewayBackend(baseURL: endpoint,
                binding: .init(sessionID: model.selectedConversationID.uuidString),
                journalRoot: directory.appendingPathComponent("journal"), apiKeyProvider: { "decision-client-auth" },
                transport: DecisionForegroundTransport(failPreflight: scenario == "保存后断线"))
            model.setBackend(gateway, kind: .gateway)
            let cost: JSONValue = ["summary": "本地合成报价，无实际扣费",
                "amount": 12.34, "currency": "CNY", "maximum": 15.5,
                "quantity": 2, "unit": "次", "availableDecisions": ["accept", "decline"]]
            let params: JSONValue
            if scenario == "问题与费用" {
                params = ["questions": [
                    ["id": "style", "question": "请选择展示风格", "isOther": true,
                     "options": [["label": "简洁", "description": "保留清晰布局"],
                                 ["label": "温暖", "description": "柔和的棚拍光线"]]],
                    ["id": "note", "question": "补充说明", "isOther": true, "options": []]], "cost": cost]
            } else if scenario == "批量决定" {
                params = ["title": "本地合成批量操作", "items": [
                    ["index": 9, "action": "write_file", "title": "编辑演示正文（不会实际写文件）",
                     "text": "原始正文", "quantity": 3, "enabled": false,
                     "allowedModifications": ["text", "quantity", "enabled"]],
                    ["index": 2, "action": "organize", "title": "演示归档决定",
                     "target": "原目录", "allowedModifications": ["target"]]], "cost": cost]
            } else {
                params = ["title": scenario == "短时请求" ? "三秒后到期的原请求" : "保存后模拟核对断线",
                          "availableDecisions": ["accept", "decline"], "cost": cost]
            }
            let fixture: JSONValue = ["id": "foreground/a+汉", "ttl": .number(scenario == "短时请求" ? 3 : 600),
                "kind": .string(scenario == "问题与费用" ? "waiting_question" : "waiting_confirmation"), "params": params]
            var config = AgentConfig(model: "synthetic", systemPrompt: "本地前台合成决策验收")
            config.supportsImageInput = false
            self.model = model; self.scenario = scenario
            _ = model.send(text: "test:decision:" + (try fixture.encodedText()), config: config, enabledSkills: [])
        } catch { scenarioError(error) }
    }
    private func scenarioError(_ error: Error) {
        try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("fixture-error.txt"))
    }
}

@MainActor enum DecisionForegroundFixture {
    private static var window: NSWindow?
    private static var timer: Timer?
    private static var inputMonitor: Any?
    static func open(root: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.clipslots.app.interactive-s15-decision",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true,
              root.path.hasPrefix("/tmp/clipslots-interactive-"),
              env["CLIPSLOTS_DATA_DIR"] == root.appendingPathComponent("data").path,
              env["CLIPSLOTS_CONFIG_PATH"] == root.appendingPathComponent("config.toml").path,
              let endpoint = env["DECISION_GATEWAY_URL"].flatMap(URL.init(string:)),
              endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              (try? CrateGenerationService.shared.resolveBinary()) != nil else { return }
        do {
            UserDefaults.standard.set(endpoint.absoluteString, forKey: AgentGatewayPreferences.endpointKey)
            UserDefaults.standard.set("synthetic", forKey: AgentGatewayPreferences.modelKey)
            NativeAccessibilityProbe.enable()
            let controller = DecisionForegroundController(root: root, endpoint: endpoint)
            let sync = AgentMarketSyncStore(service: .init(root: root.appendingPathComponent("market")),
                fixture: .init(catalog: ["items": []], details: [:], accountStatus: "本地夹具"), readsDesktop: false)
            let w = NSWindow(contentRect: CGRect(x: 160, y: 80, width: 640, height: 880),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "S15 决策前台验收"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DecisionForegroundView(controller: controller, sync: sync,
                narrow: { w.setContentSize(CGSize(width: 360, height: 880)) },
                wide: { w.setContentSize(CGSize(width: 640, height: 880)) }))
            window = w
            NSApp.setActivationPolicy(.regular)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let inputFile = root.appendingPathComponent("native-input.jsonl")
            try Data().write(to: inputFile)
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp,
                .keyDown, .keyUp, .scrollWheel]) { event in
                append(["time": Date().timeIntervalSince1970, "type": event.type.rawValue,
                    "window": event.windowNumber, "keyCode": event.type == .keyDown ? Int(event.keyCode) : -1,
                    "active": NSApp.isActive], to: inputFile)
                return event
            }
            let telemetryFile = root.appendingPathComponent("foreground.jsonl")
            try Data().write(to: telemetryFile)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let model = controller.model
                    append(["time": Date().timeIntervalSince1970, "active": NSApp.isActive,
                        "keyWindow": NSApp.keyWindow?.windowNumber ?? -1, "window": w.windowNumber,
                        "width": w.frame.width, "visible": w.isVisible, "scenario": controller.scenario,
                        "phase": model.runPhase.rawValue, "isRunning": model.isRunning,
                        "runID": model.gatewayRunID ?? "", "interactions": model.pendingInteractions.map {
                            ["id": $0.id.uuidString, "state": $0.state.rawValue, "canSendSaved": $0.canSendSaved] as [String: Any]
                        }], to: telemetryFile)
                    _ = model.flushSession()
                }
            }
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "window": w.windowNumber, "fixtureReady": true])
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

private struct DecisionForegroundView: View {
    @ObservedObject var controller: DecisionForegroundController
    let sync: AgentMarketSyncStore
    let narrow: () -> Void
    let wide: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(["问题与费用", "批量决定", "短时请求", "保存后断线"], id: \.self) { scenario in
                    Button(scenario) { controller.start(scenario) }.font(.system(size: 11))
                }
            }.padding(8)
            HStack {
                Button("窄窗口", action: narrow)
                Button("宽窗口", action: wide)
                Button("浅色") { NSApp.appearance = NSAppearance(named: .aqua) }
                Button("深色") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                Text("仅本地合成服务").font(.system(size: 11))
            }.padding(.bottom, 6)
            AgentSidebarView(model: controller.model, isVisible: .constant(true), isExpanded: true,
                credentialStateProvider: { (true, nil) }, marketSync: sync)
                .id(ObjectIdentifier(controller.model))
        }
    }
}
#endif
