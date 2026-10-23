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

    func normalized(_ base: AgentConfig) -> AgentConfig {
        var config = base
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
            requiresAPIKey: kind == .deepseek,
            supportsCanvasReadTools: true,
            gatewayConfiguration: gatewayConfig,
            gatewayBaseURL: resolvedURL)
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
