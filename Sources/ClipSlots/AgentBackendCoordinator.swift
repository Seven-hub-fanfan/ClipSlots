import Foundation
import ClipSlotsKit

enum AgentBackendScope: String, Equatable {
    case sidebar
    case workspace

    init(workspaceMode: WorkspaceMode) {
        self = workspaceMode == .agent ? .workspace : .sidebar
    }

    var preferenceKey: String {
        switch self {
        case .sidebar: return TikaBackendPreferences.backendKindKey
        case .workspace: return AgentPreferences.workspaceBackendKey
        }
    }
}

struct AgentBackendSelection {
    let scope: AgentBackendScope
    let kind: AgentBackendKind
    let backend: any AgentBackend
    let requiresAPIKey: Bool
    let supportsCanvasReadTools: Bool
    var gatewayConfiguration: AgentConfig? = nil
    var gatewayBaseURL: URL? = nil
    var modelProfile: ModelProfile? = nil

    func normalized(_ base: AgentConfig) -> AgentConfig {
        var config = base
        if let profile = modelProfile, let url = URL(string: profile.endpoint) {
            config.endpoint = url; config.model = profile.model
            config.supportsImageInput = profile.supportsImages
            config.reasoningEffort = nil; config.thinkingMode = .serverDefault
        }
        if kind == .tika {
            config.model = ""
            config.reasoningEffort = nil
            config.thinkingMode = .serverDefault
        }
        if kind == .gateway, let gateway = gatewayConfiguration {
            config.model = gateway.model
            config.thinkingMode = gateway.thinkingMode
            config.reasoningEffort = nil
            if !base.isolatedReadOnly { config.systemPrompt = gateway.systemPrompt }
        }
        return config
    }

    func invocation(history: [AgentMessage],
                    config: AgentConfig,
                    tools: (any AgentToolExecuting)?) -> AgentInvocationContext {
        var prepared = normalized(config)
        if history.last(where: { $0.role == .user })?.canvasTurn != nil {
            prepared.systemPrompt = config.systemPrompt
        }
        return AgentInvocationContext(history: history, config: prepared, tools: tools)
    }
}

// MARK: - Agent 后端协调器
//
// This is the only production entry for backend selection. A selection captures
// scope, backend, capabilities and configuration normalization together, so UI
// labels and an in-flight invocation cannot observe different preferences.

enum AgentBackendCoordinator {
    static func selection(for scope: AgentBackendScope,
                          defaults: UserDefaults = .standard,
                          binding: AgentRunBinding? = nil,
                          journalRoot: URL? = nil,
                          gatewayURL: URL? = nil) -> AgentBackendSelection {
        // An explicit original URL is only for recovering an unresolved run.
        // It pins both provider identity and credential origin across changes.
        let kind: AgentBackendKind = gatewayURL == nil ? kind(for: scope, defaults: defaults) : .gateway
        let resolvedURL = kind == .gateway ? gatewayURL ?? AgentGatewayPreferences.endpoint(defaults: defaults) : nil
        let backend = makeBackend(kind: kind, defaults: defaults, binding: binding,
                                  journalRoot: journalRoot, gatewayURL: resolvedURL)
        let gatewayConfig = kind == .gateway ? AgentConfig(
            model: defaults.string(forKey: AgentGatewayPreferences.modelKey) ?? AgentGatewayPreferences.defaultModel,
            systemPrompt: defaults.string(forKey: AgentGatewayPreferences.systemPromptKey) ?? AgentConfig.defaultSystemPrompt,
            thinkingMode: defaults.string(forKey: AgentGatewayPreferences.thinkingModeKey)
                .flatMap(AgentThinkingMode.init(rawValue:)) ?? .serverDefault) : nil
        return AgentBackendSelection(
            scope: scope,
            kind: kind,
            backend: backend,
            requiresAPIKey: kind == .deepseek && (ModelConfigurationBridge.profile(.agent)?.requiresKey
                ?? !ModelConfigurationBridge.hasDefault(.agent)),
            supportsCanvasReadTools: true,
            gatewayConfiguration: gatewayConfig,
            gatewayBaseURL: resolvedURL,
            modelProfile: kind == .deepseek ? ModelConfigurationBridge.profile(.agent) : nil)
    }

    static func injected(_ backend: any AgentBackend,
                         scope: AgentBackendScope,
                         kind preferredKind: AgentBackendKind? = nil) -> AgentBackendSelection {
        let kind = preferredKind ?? inferredKind(of: backend) ?? self.kind(for: scope)
        return AgentBackendSelection(
            scope: scope,
            kind: kind,
            backend: backend,
            requiresAPIKey: backend is AgentService,
            supportsCanvasReadTools: true)
    }

    static func kind(for scope: AgentBackendScope,
                     defaults: UserDefaults = .standard) -> AgentBackendKind {
        defaults.string(forKey: scope.preferenceKey)
            .flatMap(AgentBackendKind.init(rawValue:)) ?? .deepseek
    }

    static func setKind(_ kind: AgentBackendKind,
                        for scope: AgentBackendScope,
                        defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: scope.preferenceKey)
        broadcastChange(for: scope)
    }

    private static func makeBackend(kind: AgentBackendKind,
                                    defaults: UserDefaults,
                                    binding: AgentRunBinding?,
                                    journalRoot: URL?,
                                    gatewayURL: URL?) -> any AgentBackend {
        switch kind {
        case .deepseek:
            if let profile = ModelConfigurationBridge.profile(.agent), !profile.isCLI,
               profile.contract.isText, (try? profile.validate()) != nil {
                let secret: AgentSecretStore = profile.requiresKey
                    ? AgentKeychain(service: profile.keyService, account: profile.keyAccount)
                    : AgentInMemorySecretStore(key: "unauthenticated")
                return AgentService(transport: ModelAgentTransport(profile: profile), secretStore: secret)
            }
            if ModelConfigurationBridge.hasDefault(.agent) { return UnavailableModelAgentBackend() }
            return AgentService()
        case .tika:
            let cliPath = defaults.string(forKey: TikaBackendPreferences.tikaCLIPathKey)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "tikacli"
            let agentId = defaults.string(forKey: TikaBackendPreferences.tikaAgentIdKey)
                .flatMap { $0.isEmpty ? nil : $0 }
            let supplementalPrompt = defaults.string(forKey: TikaBackendPreferences.tikaSystemPromptKey) ?? ""
            return TikaCLIService(config: TikaBackendConfig(
                cliPath: cliPath,
                agentId: agentId,
                supplementalSystemPrompt: supplementalPrompt))
        case .gateway:
            guard let binding, let url = gatewayURL,
                  AgentGatewayPreferences.credentialOrigin(url: url) != nil else {
                return AgentGatewayUnavailableBackend()
            }
            let credentials = AgentGatewayPreferences.keychain(url: url)
            return AgentGatewayBackend(baseURL: url, binding: binding,
                journalRoot: journalRoot ?? AgentGatewayPreferences.defaultJournalRoot,
                apiKeyProvider: { credentials.readAPIKey() })
        }
    }

    private static func inferredKind(of backend: any AgentBackend) -> AgentBackendKind? {
        if backend is AgentService { return .deepseek }
        if backend is TikaCLIService { return .tika }
        if backend is AgentGatewayResuming || backend is AgentGatewayUnavailableBackend { return .gateway }
        return nil
    }

    static let backendChangedNotification = Notification.Name("com.clipslots.agent.backendChanged")

    static func broadcastChange(for scope: AgentBackendScope? = nil) {
        NotificationCenter.default.post(name: backendChangedNotification, object: scope?.rawValue)
    }

    static func scope(from notification: Notification) -> AgentBackendScope? {
        (notification.object as? String).flatMap(AgentBackendScope.init(rawValue:))
    }

    // Compatibility shims for older tests and call sites. New production code
    // should keep the full selection instead of reading kind/backend separately.
    static var currentKind: AgentBackendKind { kind(for: .sidebar) }

    static func kind(workspace: Bool = false) -> AgentBackendKind {
        kind(for: workspace ? .workspace : .sidebar)
    }

    static func currentBackend(workspace: Bool = false) -> any AgentBackend {
        selection(for: workspace ? .workspace : .sidebar).backend
    }
}

private final class UnavailableModelAgentBackend: AgentBackend, Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        throw ModelWorkspaceError.invalid("默认 Agent LLM 不可用，请在模型配置中心重新选择。")
    }
}

private struct ModelAgentTransport: AgentTransport {
    let profile: ModelProfile
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        var modified = request
        let modelID = profile.model.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        modified.url = URL(string: profile.endpoint.replacingOccurrences(of: "{model}", with: modelID))
        let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
        modified.setValue(nil, forHTTPHeaderField: "Authorization")
        if profile.requiresKey {
            let key = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
            modified.setValue(profile.authPrefix + key, forHTTPHeaderField: profile.authHeader)
        }
        if let body = modified.httpBody, case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: body) {
            for (name, value) in profile.parameters where !["messages", "model", "stream", "tools", "tool_choice"].contains(name) {
                fields[name] = value
            }
            // Native Gemini tool result messages require the original function name.
            if profile.contract == .geminiContent, let messages = fields["messages"]?.arrayValue {
                var names: [String: JSONValue] = [:]
                fields["messages"] = .array(messages.map { message in
                    for call in message["tool_calls"]?.arrayValue ?? [] {
                        if let id = call["id"]?.stringValue { names[id] = call["function"]?["name"] }
                    }
                    if let id = message["tool_call_id"]?.stringValue, let name = names[id], var value = message.objectValue {
                        value["name"] = name; return .object(value)
                    }
                    return message
                })
            }
            modified.httpBody = try JSONEncoder().encode(ModelTextWire.body(fields, contract: profile.contract))
        }
        for (name, value) in profile.headers ?? [:] { modified.setValue(value, forHTTPHeaderField: name) }
        if profile.contract == .anthropicMessages { modified.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if profile.contract != .chatCompletions {
            modified.setValue("application/json", forHTTPHeaderField: "Accept")
            let frozenRequest = modified
            let (data, status) = try await ModelRequestBudget.shared.withPermit(profile: profile) { try await ModelURLSessionTransport().send(frozenRequest) }
            guard (200...299).contains(status) else { return .init(statusCode: status, chunks: .init { $0.finish() }) }
            let root = try JSONDecoder().decode(JSONValue.self, from: data)
            let assistant = try ModelTextWire.assistant(root, contract: profile.contract)
            var delta = assistant.objectValue ?? [:]
            if let calls = delta["tool_calls"]?.arrayValue {
                delta["tool_calls"] = .array(calls.enumerated().map { index, call in
                    var value = call.objectValue ?? [:]; value["index"] = .number(Double(index)); return .object(value)
                })
            }
            let chunk: JSONValue = ["choices": [["index": 0, "delta": .object(delta), "finish_reason": assistant["tool_calls"] == nil ? "stop" : "tool_calls"]]]
            let text = "data: " + (try chunk.encodedText()) + "\n\ndata: [DONE]\n\n"
            return .init(statusCode: status, chunks: .init { $0.yield(Data(text.utf8)); $0.finish() })
        }
        // Keep the permit until the stream completes, including Agent tool rounds.
        let frozenRequest = modified
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    try await ModelRequestBudget.shared.withPermit(profile: profile) {
                        let response = try await URLSessionAgentTransport(timeout: profile.timeout).stream(request: frozenRequest)
                        guard (200...299).contains(response.statusCode) else { throw ModelWorkspaceError.http(response.statusCode) }
                        for try await data in response.chunks { continuation.yield(data) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(statusCode: 200, chunks: chunks)
    }
}
