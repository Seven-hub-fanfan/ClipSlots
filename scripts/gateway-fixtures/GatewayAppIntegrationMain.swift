import SwiftUI
@testable import ClipSlotsKit

// Surrounding app UI is deliberately absent from this focused compiler fixture.
enum WorkspaceMode { case agent, edit }
enum AgentPreferences {
    static let workspaceBackendKey = "agent.workspace.backend"
    static let modelKey = "agent.model"
    static let systemPromptKey = "agent.systemPrompt"
    static let thinkingModeKey = "agent.thinkingMode"
    static let reasoningEffortKey = "agent.reasoningEffort"
    static let endpointKey = "agent.endpoint"
}
enum AppTheme {
    static let windowBackground = Color.clear
    static let chromeAccentInk = Color.blue
    static let canvasCardMetaInk = Color.secondary
    static let searchFieldBackground = Color.clear
    static let subtleBorder = Color.gray
}
enum TapSkin {
    static func tone(_ light: Int, _ dark: Int) -> Color { .blue }
    static let secondaryInk = Color.secondary
}
struct ComposerEntranceGlow: View {
    let token: String
    let active: Bool
    var repeating = false
    var body: some View { EmptyView() }
}
struct EnvironmentSetupView: View { var body: some View { EmptyView() } }

private actor PolishTransport: AgentGatewayTransport {
    private var binding: JSONValue = .null
    private(set) var createBody: JSONValue = .null
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        if request.httpMethod == "POST" {
            createBody = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            binding = createBody["binding"] ?? .null
        }
        return .init(statusCode: 200, body: try JSONEncoder().encode(JSONValue.object([
            "schemaVersion": 1, "binding": binding, "runID": "polish-run", "phase": "streaming",
            "requestKey": request.value(forHTTPHeaderField: "Idempotency-Key").map(JSONValue.string) ?? .null
        ])))
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let messageID = UUID().uuidString
        let events: [(String, JSONValue)] = [
            ("initial", ["messageID": .string(messageID)]),
            ("content", ["messageID": .string(messageID), "delta": "polished draft"]),
            ("run_completed", ["messageID": .string(messageID)])
        ]
        var bytes = Data()
        for (index, event) in events.enumerated() {
            let id = "event-\(index)"
            let envelope: JSONValue = ["schemaVersion": 1, "binding": binding, "runID": "polish-run",
                                      "eventID": .string(id), "payload": event.1]
            bytes += Data("event: \(event.0)\nid: \(id)\ndata: ".utf8)
            bytes += try JSONEncoder().encode(envelope)
            bytes += Data("\n\n".utf8)
        }
        let frameBytes = bytes
        return .init(statusCode: 200, chunks: AsyncThrowingStream {
            $0.yield(frameBytes)
            $0.finish()
        })
    }
}

@main
enum GatewayAppIntegrationMain {
    static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { print("FAIL: \(name)"); exit(1) }
            passed += 1
        }
        let suite = "gateway-app-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let binding = AgentRunBinding(sessionID: "conversation", projectID: "project")
        let originalURL = URL(string: "https://original.fixture.invalid/v1")!
        let newURL = URL(string: "https://new.fixture.invalid/v1")!
        let legacy = AgentBackendCoordinator.selection(for: .sidebar, defaults: defaults)
        check(legacy.kind == .deepseek && legacy.backend is AgentService && legacy.requiresAPIKey,
              "existing selection defaults unchanged")
        defaults.set("gateway", forKey: TikaBackendPreferences.backendKindKey)
        defaults.set(newURL.absoluteString, forKey: AgentGatewayPreferences.endpointKey)
        let missing = AgentBackendCoordinator.selection(for: .sidebar, defaults: defaults)
        check(missing.backend is AgentGatewayUnavailableBackend, "missing session binding never fabricated")
        let configured = AgentBackendCoordinator.selection(for: .sidebar, defaults: defaults, binding: binding, journalRoot: root)
        check(configured.backend is AgentGatewayBackend && configured.gatewayBaseURL == newURL && !configured.requiresAPIKey,
              "gateway selection uses optional independent credentials")
        defaults.set("tika", forKey: TikaBackendPreferences.backendKindKey)
        let recovery = AgentBackendCoordinator.selection(for: .sidebar, defaults: defaults, binding: binding,
            journalRoot: root, gatewayURL: originalURL)
        check(recovery.kind == .gateway && recovery.gatewayBaseURL == originalURL,
              "recovery override pins original endpoint despite provider/preference changes")
        let normal = AgentBackendCoordinator.selection(for: .sidebar, defaults: defaults)
        check(normal.kind == .tika && normal.backend is TikaCLIService, "terminal next invocation returns to current preference")
        var polishConfig = AgentConfig(systemPrompt: "task-specific prompt")
        polishConfig.taskPolicy = .textPolish
        check(configured.normalized(polishConfig).systemPrompt == "task-specific prompt",
              "gateway normalization cannot replace isolated polish instructions")
        var previewConfig = AgentConfig(systemPrompt: "strict canvas preview")
        previewConfig.canvasPreviewOnly = true
        check(configured.normalized(previewConfig).systemPrompt == "strict canvas preview",
              "canvas preview preserves its strict read-only prompt")
        let store = AgentGatewayJournalStore(baseURL: originalURL, binding: binding, root: root)
        var seed = try store.load()
        seed.runID = "existing-run"; seed.phase = "unknown"
        seed.messages = [.init(role: .assistant, content: "existing partial")]
        seed.currentAssistantID = seed.messages[0].id
        try store.save(seed)
        let before = try Data(contentsOf: store.storageFile)
        let transport = PolishTransport()
        let backend = AgentGatewayBackend(baseURL: originalURL, binding: binding, journalRoot: root, transport: transport)
        let selection = AgentBackendCoordinator.injected(backend, scope: .sidebar)
        let result = try await AgentDraftPolish.run("draft", config: .init(), selection: selection)
        check(result == "polished draft", "actual AgentDraftPolish gateway path completes")
        check(try Data(contentsOf: store.storageFile) == before, "actual draft polish does not modify resumable conversation")
        let body = await transport.createBody
        check(body["binding"]?["sessionID"] != .string(binding.sessionID), "draft run receives new session")
        check(body["tools"] == .array([]) && body["config"]?["taskPolicy"] == "textPolish",
              "draft gateway request is explicitly tool-free")
        check(body["config"]?["systemPrompt"]?.stringValue?.contains("消息润色编辑器") == true,
              "isolated draft keeps its dedicated system prompt")
        print("Gateway app integration: \(passed) passed, 0 failed")
    }
}
