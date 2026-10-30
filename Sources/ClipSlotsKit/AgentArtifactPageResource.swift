import Foundation

/// Source proxy paths are independent of the channel's release JSON path.
public struct AgentArtifactPageResourceEndpoint: Equatable, Sendable {
    public let channelURL: URL?
    public let appsURL: URL
    public init?(channelURL: URL?, proxyURL: URL, allowsLoopback: Bool = false) {
        guard AgentArtifactResourceHTTPClient.allowed(proxyURL, allowsLoopback: allowsLoopback),
              channelURL.map({ AgentArtifactResourceHTTPClient.allowed($0, allowsLoopback: allowsLoopback) }) ?? true,
              proxyURL.query == nil else { return nil }
        self.channelURL = channelURL
        let parent = proxyURL.deletingLastPathComponent()
        if AgentArtifactResourceContract.matches(parent.lastPathComponent, #"^[a-f0-9]{10}$"#) {
            guard var parts = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else { return nil }
            parts.path = "/apps/"; parts.query = nil
            guard let url = parts.url else { return nil }
            appsURL = url
        } else {
            appsURL = parent.appendingPathComponent("apps", isDirectory: true)
        }
    }
    public static let production = Self(
        channelURL: URL(string: "https://usercontent.tapnow.art/mcp-apps/channels/prod.json"),
        proxyURL: URL(string: "https://usercontent.tapnow.art/82b3c69f76/mcp-app-proxy.html")!
    )!
}

public struct AgentArtifactPageTemplate: Equatable, Sendable {
    public let identity: AgentArtifactResourceIdentity
    public let hash: String
    public let releaseID: String?
    public let source: String
    public let csp: JSONValue
    public let presentation: AgentArtifactPresentationPolicy
    public var resourceDescription: JSONValue {
        ["name": .string(identity.name), "version": .string(identity.version), "hash": .string(hash)]
    }
}

public enum AgentArtifactPageResourceError: Error {
    case invalidIdentity, invalidManifest
}

/// Fetches only prebuilt HTML. It never executes a cloud tool or treats a build ID as a content digest.
/// Template bytes are not retained in a global cache; pages own their individual bounded content.
public struct AgentArtifactPageResourceLoader: Sendable {
    public typealias FetchJSON = @Sendable (URL, TimeInterval) async throws -> JSONValue
    public typealias FetchHTML = @Sendable (URL, TimeInterval) async throws -> String
    private let resolver: AgentArtifactResourceResolver
    private let fetchJSON: FetchJSON
    private let fetchHTML: FetchHTML
    private let timeout: TimeInterval
    private let maximumHTMLBytes: Int

    public init(resolver: AgentArtifactResourceResolver? = nil, allowsLoopback: Bool = false,
                maximumHTMLBytes: Int = 8 * 1024 * 1024, timeout: TimeInterval = 5,
                fetchJSON: FetchJSON? = nil, fetchHTML: FetchHTML? = nil) {
        let jsonClient = AgentArtifactResourceHTTPClient(allowsLoopback: allowsLoopback)
        let htmlClient = AgentArtifactResourceHTTPClient(allowsLoopback: allowsLoopback, maximumBytes: maximumHTMLBytes)
        self.resolver = resolver ?? .init(client: jsonClient)
        self.fetchJSON = fetchJSON ?? { try await jsonClient.fetch($0, timeout: $1) }
        self.fetchHTML = fetchHTML ?? { try await htmlClient.fetchHTML($0, timeout: $1) }
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 5
        self.maximumHTMLBytes = max(1, maximumHTMLBytes)
    }

    public func load(resourceURI: String, endpoint: AgentArtifactPageResourceEndpoint = .production) async throws -> AgentArtifactPageTemplate {
        guard let identity = AgentArtifactResourceIdentity(uri: resourceURI) else {
            throw AgentArtifactPageResourceError.invalidIdentity
        }
        try Task.checkCancellation()
        let resolved = await resolver.resolve(resourceURI: resourceURI, channelURL: endpoint.channelURL)
        try Task.checkCancellation()
        let hash: String
        if let resolved { hash = resolved.hash }
        else {
            let manifest = try await fetchJSON(endpoint.appsURL.appendingPathComponent("manifest.json"), timeout)
            try Task.checkCancellation()
            guard let value = manifest["widgets"]?["\(identity.name)@\(identity.version)"]?.stringValue else {
                throw AgentArtifactPageResourceError.invalidManifest
            }
            hash = value
        }
        guard hash.utf8.count == 8, AgentArtifactResourceContract.matches(hash, #"^[a-f0-9]{8}$"#) else {
            throw AgentArtifactPageResourceError.invalidManifest
        }
        let url = endpoint.appsURL.appendingPathComponent("\(identity.name)@\(identity.version).\(hash).html")
        let source = try await fetchHTML(url, timeout)
        try Task.checkCancellation()
        guard source.utf8.count <= maximumHTMLBytes else { throw AgentArtifactResourceFetchError.responseLimit }
        guard !source.isEmpty else { throw AgentArtifactResourceFetchError.invalidResponse }
        return .init(identity: identity, hash: hash, releaseID: resolved?.releaseID, source: source,
                     csp: resolved?.csp ?? Self.sourceDefaultCSP(name: identity.name),
                     presentation: resolved?.presentation ?? .sourceDefault(resourceURI: resourceURI))
    }

    public static func sourceDefaultCSP(name: String) -> JSONValue {
        let files = ["https://tap-testing.tamaredge.top", "https://tap-testing2.tamaredge.top",
                     "https://files-testing.tapnow.art", "https://files-testing.tapnow.media",
                     "https://files-testing.tapnow.top", "https://files.tapnow.art",
                     "https://files.tapnow.media", "https://files.tapnow.ai", "https://files.tapnow.top"]
        func array(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        switch name {
        case "library-picker":
            return ["imgDomains": array(files + ["https://app.tapnow.ai", "https://storage.googleapis.com",
                         "https://conversation-service-131786869360.asia-northeast1.run.app"])]
        case "interactive-learning", "actor-emotion", "product-kit": return ["imgDomains": array(files)]
        case "animatic", "previs": return ["imgDomains": array(files + ["https://files.tamaredge.top"])]
        case "cutlist-review": return ["mediaDomains": array(files)]
        case "ad-review": return ["imgDomains": array(files), "mediaDomains": array(files)]
        default: return [:]
        }
    }

    /// Exact source proxy directives; origin filtering also occurs before release CSP reaches this layer.
    public static func cspPolicy(_ csp: JSONValue) -> String {
        func domains(_ key: String) -> String {
            (csp[key]?.arrayValue ?? []).compactMap { item in
                guard let text = item.stringValue,
                      let match = text.range(of: #"^https://[a-z0-9.-]+(:[0-9]+)?$"#, options: .regularExpression),
                      match == text.startIndex..<text.endIndex else { return nil }
                return text
            }.map { " " + $0 }.joined()
        }
        return "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; "
            + "img-src data: blob:" + domains("imgDomains") + "; media-src blob:" + domains("mediaDomains") + "; "
            + "connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
    }
}
