import Foundation

public enum AgentGatewayPreferences {
    public static let endpointKey = "agent.gateway.endpoint"
    public static let modelKey = "agent.gateway.model"
    public static let systemPromptKey = "agent.gateway.systemPrompt"
    public static let thinkingModeKey = "agent.gateway.thinkingMode"
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8787/v1")!
    public static let defaultModel = "default"
    public static let keychainService = "com.clipslots.agent.gateway"
    public static var defaultJournalRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/clipslots/agent-runs", isDirectory: true)
    }
    private static let lock = NSLock()
    private static var stores: [String: AgentKeychain] = [:]

    /// Only explicit gateway preferences are read. DeepSeek endpoint/key never
    /// participate in gateway configuration or credential lookup.
    public static func endpoint(defaults: UserDefaults = .standard) -> URL? {
        let text = defaults.string(forKey: endpointKey) ?? defaultEndpoint.absoluteString
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              credentialOrigin(url: url) != nil else { return nil }
        return url
    }

    public static func credentialOrigin(url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        if scheme == "http", !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return nil }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        // Brackets preserve IPv6 origin identity without an ambiguous colon.
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(authority):\(port)"
    }

    public static func credentialAccount(url: URL) -> String {
        let origin = credentialOrigin(url: url) ?? "invalid:" + url.absoluteString
        return "gateway_" + AgentGatewayJournalStore.digest(Data(origin.utf8))
    }

    public static func keychain(url: URL) -> AgentKeychain {
        let account = credentialAccount(url: url)
        return lock.withLock {
            if let store = stores[account] { return store }
            let store = AgentKeychain(service: keychainService, account: account,
                                      label: "ClipSlots Agent · 自建网关凭据")
            stores[account] = store
            return store
        }
    }

    public static func keyState(url: URL, retryAfterFailure: Bool = false) async -> AgentKeychainState {
        let store = keychain(url: url)
        return await store.keyStateAsync(retryAfterFailure: retryAfterFailure)
    }
}

/// Missing immutable binding is an error, not a license to invent a session or
/// fall back to a provider that could receive the user's prompt unexpectedly.
public final class AgentGatewayUnavailableBackend: AgentBackend, Sendable {
    public init() {}
    public func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
                    onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        throw AgentGatewayError.invalidConfiguration
    }
}
