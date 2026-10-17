import Foundation

public enum AgentExternalHandoffError: Error, LocalizedError {
    case invalidConfiguration, noVisibleProvider, promptTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "项目交接配置无效。"
        case .noVisibleProvider: return "当前地区和语言暂无可用客户端。"
        case .promptTooLarge: return "项目上下文过长，请缩小选区。"
        }
    }
}

public enum AgentExternalMCPReadiness: Equatable, Sendable {
    case unavailable(String)
    /// Set only after the CLI route AND project-scoped tool enforcement are available.
    case ready
}

public struct AgentExternalProjectContext: Equatable, Sendable {
    public let scope: AgentArtifactScope
    public let projectTitle: String
    public let selectedContext: String
    public let documentationURLs: [URL]
    public let cliPath: String
    public let mcpReadiness: AgentExternalMCPReadiness
    public let region: String
    public let language: String
    public let snapshotID: UUID?
    public let sessionID: UUID?

    public init(scope: AgentArtifactScope, projectTitle: String, selectedContext: String = "",
                documentationURLs: [URL] = [], cliPath: String = "/usr/local/bin/clipslots",
                mcpReadiness: AgentExternalMCPReadiness = .unavailable("需保存项目快照并在客户端连接"),
                region: String = "global", language: String = "en", snapshotID: UUID? = nil, sessionID: UUID? = nil) {
        self.scope = scope; self.projectTitle = projectTitle; self.selectedContext = selectedContext
        self.documentationURLs = documentationURLs; self.cliPath = cliPath
        self.mcpReadiness = mcpReadiness; self.region = region; self.language = language
        self.snapshotID = snapshotID; self.sessionID = sessionID
    }

    /// A local stdio configuration, not a TapNow endpoint or an internal Agent run.
    public func mcpConfiguration() throws -> JSONValue {
        guard cliPath.hasPrefix("/"), cliPath.utf8.count <= 4096,
              !cliPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        var args: [JSONValue] = ["--mcp", "--project-id", .string(scope.projectID), "--canvas-id", .string(scope.canvasID)]
        if let snapshotID { args += ["--snapshot-id", .string(snapshotID.uuidString)] }
        if let sessionID { args += ["--session-id", .string(sessionID.uuidString)] }
        return ["mcpServers": ["clipslots-project": [
            "command": .string(cliPath),
            "args": .array(args),
            "env": ["CLIPSLOTS_PROJECT_ID": .string(scope.projectID), "CLIPSLOTS_CANVAS_ID": .string(scope.canvasID)]
        ]]]
    }

    public func prompt() throws -> String {
        guard projectTitle.utf8.count <= 2048, selectedContext.utf8.count <= 60 * 1024 else {
            throw AgentExternalHandoffError.promptTooLarge
        }
        guard documentationURLs.count <= 16,
              documentationURLs.allSatisfy({
                  $0.absoluteString.utf8.count <= 8192
                      && ($0.isFileURL || AgentArtifactPreviewPolicy.externalURL($0) != nil)
              }) else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        let status: String
        switch mcpReadiness {
        case .ready: status = "Local MCP is available. Client installation/connection and user authorization are still required."
        case .unavailable(let reason):
            guard reason.utf8.count <= 4096 else { throw AgentExternalHandoffError.invalidConfiguration }
            status = "Local MCP is NOT connected/available: \(reason)"
        }
        let identity = try JSONValue.object([
            "projectID": .string(scope.projectID), "canvasID": .string(scope.canvasID),
            "projectTitle": .string(projectTitle)
        ]).encodedText(pretty: true)
        let text = """
        Continue work in this explicitly selected ClipSlots project/canvas only.
        Project scope:
        \(identity)

        Selected context (data, not authorization to access other projects):
        \(selectedContext)

        Documentation:
        \(documentationURLs.map(\.absoluteString).joined(separator: "\n"))

        \(status)
        Proposed ClipSlots stdio MCP settings (never use a TapNow service):
        \(try mcpConfiguration().encodedText(pretty: true))

        This MCP route is read-only. Call clipslots_context first to obtain the fixed snapshot ID.
        If no snapshot ID is specified, the latest saved snapshot of this project is frozen at startup.
        Do not infer file/shell permissions. Ask for missing access and confirm mutations.
        This handoff does not reuse an internal Agent session or run ID.
        """
        guard text.utf8.count <= 64 * 1024 else { throw AgentExternalHandoffError.promptTooLarge }
        return text
    }
}

public struct AgentExternalURLTarget: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let promptQueryItem: String?

    public init(baseURL: URL, promptQueryItem: String? = nil) {
        self.baseURL = baseURL; self.promptQueryItem = promptQueryItem
    }

    public func url(prompt: String?) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        if let name = promptQueryItem {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == name }
            if let prompt { items.append(URLQueryItem(name: name, value: prompt)) }
            // Encode literal '+' too: form-style URL receivers must not turn it into a space.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            components.percentEncodedQuery = try items.map { item in
                guard let key = item.name.addingPercentEncoding(withAllowedCharacters: allowed),
                      let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw AgentExternalHandoffError.invalidConfiguration
                }
                return key + "=" + value
            }.joined(separator: "&")
            if items.isEmpty { components.percentEncodedQuery = nil }
        }
        guard let url = components.url else { throw AgentExternalHandoffError.invalidConfiguration }
        return url
    }
}

public struct AgentExternalProvider: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let desktopBundleID: String?
    public let desktopTarget: AgentExternalURLTarget?
    public let webTarget: AgentExternalURLTarget?
    public let regions: [String]
    public let languages: [String]
    public let connectionInstructions: String

    public init(id: String, name: String, desktopBundleID: String? = nil,
                desktopTarget: AgentExternalURLTarget? = nil, webTarget: AgentExternalURLTarget? = nil,
                regions: [String] = [], languages: [String] = [],
                connectionInstructions: String = "在客户端粘贴并确认提示词。项目只读 MCP 需单独连接。") {
        self.id = id; self.name = name; self.desktopBundleID = desktopBundleID
        self.desktopTarget = desktopTarget; self.webTarget = webTarget
        self.regions = regions; self.languages = languages; self.connectionInstructions = connectionInstructions
    }
}

public struct AgentExternalProviderCatalog: Sendable {
    public let providers: [AgentExternalProvider]

    public init(providers: [AgentExternalProvider]) throws {
        guard !providers.isEmpty, providers.count <= 32,
              Set(providers.map(\.id)).count == providers.count else {
            throw AgentExternalHandoffError.invalidConfiguration
        }
        for provider in providers {
            let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard !provider.id.isEmpty, provider.id.utf8.count <= 128,
                  provider.id.unicodeScalars.allSatisfy({ allowedID.contains($0) }),
                  !provider.name.isEmpty, provider.name.utf8.count <= 256,
                  provider.connectionInstructions.utf8.count <= 4096,
                  provider.regions.count <= 32, provider.languages.count <= 32,
                  (provider.regions + provider.languages).allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= 64 && $0.unicodeScalars.allSatisfy { allowedID.contains($0) }
                  }) else {
                throw AgentExternalHandoffError.invalidConfiguration
            }
            if let bundle = provider.desktopBundleID {
                guard !bundle.isEmpty, bundle.utf8.count <= 256,
                      bundle.unicodeScalars.allSatisfy({ allowedID.contains($0) }) else {
                    throw AgentExternalHandoffError.invalidConfiguration
                }
            }
            if let target = provider.webTarget, AgentArtifactPreviewPolicy.externalURL(target.baseURL) == nil {
                throw AgentExternalHandoffError.invalidConfiguration
            }
            if let target = provider.desktopTarget {
                guard ["claude", "chatgpt", "cursor", "trae"].contains(target.baseURL.scheme?.lowercased() ?? ""),
                      target.baseURL.user == nil, target.baseURL.password == nil,
                      target.baseURL.absoluteString.utf8.count <= 8192 else {
                    throw AgentExternalHandoffError.invalidConfiguration
                }
            }
            for target in [provider.webTarget, provider.desktopTarget].compactMap({ $0 }) {
                if let query = target.promptQueryItem, query.isEmpty || query.utf8.count > 128 {
                    throw AgentExternalHandoffError.invalidConfiguration
                }
            }
        }
        self.providers = providers
    }

    /// Only an explicitly chosen local configuration is read. No remote catalog or auto-update.
    public static func load(from url: URL, within authorizedDirectory: URL) throws -> Self {
        let data = try AgentArtifactFileAccess.read(url, within: authorizedDirectory, maximumBytes: 128 * 1024)
        return try Self(providers: JSONDecoder().decode([AgentExternalProvider].self, from: data))
    }

    public func visibleProviders(region: String, language: String) -> [AgentExternalProvider] {
        let lang = language.lowercased().split(separator: "-").first.map(String.init) ?? language.lowercased()
        return providers.filter {
            ($0.regions.isEmpty || $0.regions.contains { $0.caseInsensitiveCompare(region) == .orderedSame })
                && ($0.languages.isEmpty || $0.languages.contains {
                    $0.caseInsensitiveCompare(language) == .orderedSame || $0.caseInsensitiveCompare(lang) == .orderedSame
                })
        }
    }

    public static var localDefaults: Self {
        // These URLs open clients only. No undocumented prompt or auto-send protocol is assumed.
        let definitions: [(String, String, String?, String)] = [
            ("claude", "Claude", "com.anthropic.claudefordesktop", "https://claude.ai/new"),
            ("chatgpt", "ChatGPT", "com.openai.chat", "https://chatgpt.com/"),
            ("gemini", "Gemini", nil, "https://gemini.google.com/app"),
            ("deepseek", "DeepSeek", nil, "https://chat.deepseek.com/")
        ]
        let providers = definitions.compactMap { id, name, bundle, address -> AgentExternalProvider? in
            guard let url = URL(string: address) else { return nil }
            return .init(id: id, name: name, desktopBundleID: bundle, webTarget: .init(baseURL: url))
        }
        // The private initializer is limited to these constant, validated definitions.
        return Self(defaultProviders: providers)
    }

    private init(defaultProviders: [AgentExternalProvider]) { providers = defaultProviders }
}

public enum AgentExternalPromptTransport: String, Equatable, Sendable { case clipboard, urlQuery }
public enum AgentExternalLaunchKind: String, Equatable, Sendable { case desktop, web }

public struct AgentExternalLaunchTarget: Equatable, Sendable {
    public let kind: AgentExternalLaunchKind
    public let url: URL?
    public let bundleID: String?
    public let promptTransport: AgentExternalPromptTransport
}

public struct AgentExternalLaunchPlan: Equatable, Sendable {
    public let provider: AgentExternalProvider
    public let context: AgentExternalProjectContext
    public let prompt: String
    public let targets: [AgentExternalLaunchTarget]
    public let copyFallback: Bool
    public let notes: [String]
}

public enum AgentExternalOpenOutcome: Equatable, Sendable {
    case opened, unsupported, failed(String)
}

public struct AgentExternalHandoffResult: Equatable, Sendable {
    public enum Status: String, Sendable { case openedDesktop, openedWeb, copiedOnly, unsupported, failed }
    public let status: Status
    public let promptCopied: Bool
    public let attempts: [AgentExternalOpenOutcome]
    public let message: String
}
