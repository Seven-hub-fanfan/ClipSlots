import Foundation

/// Identity grammar and presentation defaults frozen from the shipped MCP host.
public struct AgentArtifactResourceIdentity: Equatable, Sendable {
    public let name: String
    public let version: String
    public init?(uri: String) {
        guard uri.utf8.count <= 256,
              let match = uri.range(of: #"^ui://tapnow/([a-z0-9-]+)@(v[0-9]+)$"#, options: .regularExpression),
              match == uri.startIndex..<uri.endIndex else { return nil }
        let parts = uri.dropFirst("ui://tapnow/".count).split(separator: "@")
        guard parts.count == 2 else { return nil }
        name = String(parts[0]); version = String(parts[1])
    }
}

public struct AgentArtifactPresentationPolicy: Equatable, Sendable {
    public let allowExpanded: Bool
    public let autoExpandOnReady: Bool
    public let maxInlineHeight: Double?
    public init(allowExpanded: Bool = false, autoExpandOnReady: Bool = false, maxInlineHeight: Double? = nil) {
        self.allowExpanded = allowExpanded; self.autoExpandOnReady = autoExpandOnReady
        self.maxInlineHeight = maxInlineHeight.flatMap { $0.isFinite && $0 >= 100 ? $0 : nil }
    }
    public static func sourceDefault(resourceURI: String?) -> Self {
        guard let resourceURI, let identity = AgentArtifactResourceIdentity(uri: resourceURI) else { return .init() }
        switch identity.name {
        case "motion-picker", "creative-picker", "website-design-picker":
            return .init(allowExpanded: true, maxInlineHeight: 520)
        case "actor-emotion": return .init(allowExpanded: true)
        case "animatic", "previs": return .init(allowExpanded: true, autoExpandOnReady: true)
        default: return .init()
        }
    }
    public static func release(_ value: JSONValue?) -> Self {
        let height = AgentArtifactResourceContract.finiteNumber(value?["max_inline_height"])
        return .init(allowExpanded: value?["allow_expanded"] == true,
                     autoExpandOnReady: value?["auto_expand_on_ready"] == true,
                     maxInlineHeight: height.flatMap { $0.isFinite && $0.rounded() == $0 && $0 >= 100 ? $0 : nil })
    }
    public func inlineHeight(_ height: Double) -> Double {
        min(max(height.isFinite ? height : 100, 100), min(maxInlineHeight ?? 8192, 8192))
    }
}

public struct AgentArtifactResolvedResource: Equatable, Sendable {
    public let releaseID: String
    /// The source's eight-character widget build identifier, not a content-integrity digest.
    public let hash: String
    public let csp: JSONValue
    public let presentation: AgentArtifactPresentationPolicy
}

public enum AgentArtifactResourceContract {
    public static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }
    public static let allowedDomains: Set<String> = [
        "https://tap-testing.tamaredge.top", "https://tap-testing2.tamaredge.top",
        "https://files-testing.tapnow.art", "https://files-testing.tapnow.media", "https://files-testing.tapnow.top",
        "https://files.tapnow.art", "https://files.tapnow.media", "https://files.tapnow.ai", "https://files.tapnow.top",
        "https://files.tamaredge.top", "https://app.tapnow.ai", "https://storage.googleapis.com",
        "https://conversation-service-131786869360.asia-northeast1.run.app"
    ]
    public static func csp(_ value: JSONValue?) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (wire, publicKey) in [("img_domains", "imgDomains"), ("media_domains", "mediaDomains")] {
            var seen: Set<String> = []
            let domains = (value?[wire]?.arrayValue ?? []).compactMap { item -> JSONValue? in
                guard let domain = item.stringValue, allowedDomains.contains(domain), seen.insert(domain).inserted else { return nil }
                return .string(domain)
            }
            if !domains.isEmpty { result[publicKey] = .array(domains) }
        }
        return .object(result)
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum AgentArtifactResourceFetchError: Error {
    case http(Int), invalidEndpoint, responseLimit, invalidResponse
}

/// Public JSON GETs never use cookies, credential storage, custom headers or redirects.
public final class AgentArtifactResourceHTTPClient: @unchecked Sendable {
    private final class RequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var rejectedStatus: Int?
        var authenticationStatus: Int? { lock.lock(); defer { lock.unlock() }; return rejectedStatus }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                // Cancelling avoids Foundation's anonymous authentication retry. Retain only the
                // actual failure response status, never credentials or an inferred HTTP status.
                lock.lock(); rejectedStatus = (challenge.failureResponse as? HTTPURLResponse)?.statusCode; lock.unlock()
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
    private let allowsLoopback: Bool
    private let maximumBytes: Int
    public init(allowsLoopback: Bool = false, maximumBytes: Int = 1024 * 1024) {
        self.allowsLoopback = allowsLoopback; self.maximumBytes = max(1, maximumBytes)
    }
    public static func allowed(_ url: URL, allowsLoopback: Bool = false) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil,
              parts.password == nil, parts.fragment == nil, let host = parts.host, !host.isEmpty,
              url.absoluteString.utf8.count <= 8192 else { return false }
        return parts.scheme == "https" || (allowsLoopback && parts.scheme == "http"
            && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host))
    }
    public func fetch(_ url: URL, timeout: TimeInterval = 5) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await fetchData(url, timeout: timeout, accept: "application/json"))
    }
    public func fetchHTML(_ url: URL, timeout: TimeInterval = 5) async throws -> String {
        let data = try await fetchData(url, timeout: timeout, accept: "text/html")
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentArtifactResourceFetchError.invalidResponse
        }
        return text
    }
    private func fetchData(_ url: URL, timeout: TimeInterval, accept: String) async throws -> Data {
        guard Self.allowed(url, allowsLoopback: allowsLoopback), timeout.isFinite, timeout > 0 else {
            throw AgentArtifactResourceFetchError.invalidEndpoint
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let delegate = RequestDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else {
                throw AgentArtifactResourceFetchError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else { throw AgentArtifactResourceFetchError.http(http.statusCode) }
            guard response.expectedContentLength <= maximumBytes else { throw AgentArtifactResourceFetchError.responseLimit }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw AgentArtifactResourceFetchError.responseLimit }
                data.append(byte)
            }
            return data
        } catch {
            try Task.checkCancellation()
            if let status = delegate.authenticationStatus { throw AgentArtifactResourceFetchError.http(status) }
            throw error
        }
    }
}

/// Channel and release caches share in-flight work. Page cancellation never cancels another consumer.
/// Successful releases keep the source's infinite TTL; native storage bounds retained entries.
public actor AgentArtifactResourceResolver {
    public typealias Fetch = @Sendable (URL, TimeInterval) async throws -> JSONValue
    private struct Channel: Sendable { let id: String; let url: URL }
    private struct Result<Value: Sendable>: Sendable { let value: Value?; let ttl: Double }
    private struct Entry<Value: Sendable> {
        let token: UUID
        let at: Double
        var ttl: Double
        let task: Task<Result<Value>, Never>
    }
    private let fetch: Fetch
    private let now: @Sendable () -> Double
    private let channelTTL: Double, transientTTL: Double, timeout: Double
    private let capacity: Int
    private var channelURL: URL?
    private var channel: Entry<Channel>?
    private var releases: [URL: Entry<JSONValue>] = [:]

    public init(client: AgentArtifactResourceHTTPClient = .init(), channelTTL: Double = 60,
                transientTTL: Double = 5, timeout: Double = 5, capacity: Int = 64,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                fetch: Fetch? = nil) {
        self.fetch = fetch ?? { try await client.fetch($0, timeout: $1) }
        self.now = now; self.channelTTL = channelTTL.isFinite && channelTTL > 0 ? channelTTL : 60
        self.transientTTL = transientTTL.isFinite && transientTTL > 0 ? transientTTL : 5
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 5
        self.capacity = max(1, capacity)
    }
    public func resolve(resourceURI: String, channelURL: URL?) async -> AgentArtifactResolvedResource? {
        guard !Task.isCancelled, let identity = AgentArtifactResourceIdentity(uri: resourceURI), let channelURL,
              let channel = await getChannel(channelURL), !Task.isCancelled,
              let release = await getRelease(channel), !Task.isCancelled,
              let widget = release["widgets"]?["\(identity.name)@\(identity.version)"],
              let hash = widget["hash"]?.stringValue, AgentArtifactResourceContract.matches(hash, #"^[a-f0-9]{8}$"#) else { return nil }
        return .init(releaseID: channel.id, hash: hash, csp: AgentArtifactResourceContract.csp(widget["csp"]),
                     presentation: .release(widget["presentation"]))
    }
    public func prefetch(channelURL: URL?) async {
        guard let channelURL, let channel = await getChannel(channelURL) else { return }
        _ = await getRelease(channel)
    }
    private func getChannel(_ url: URL) async -> Channel? {
        guard AgentArtifactResourceHTTPClient.allowed(url, allowsLoopback: true),
              url.path.hasPrefix("/mcp-apps/channels/") else { return nil }
        let entry: Entry<Channel>
        if self.channelURL == url, let cached = channel, now() - cached.at <= cached.ttl {
            entry = cached
        } else {
            let fetch = fetch, ttl = channelTTL, retry = transientTTL, timeout = timeout
            entry = Entry(token: UUID(), at: now(), ttl: ttl, task: Task {
                do {
                    let value = try await fetch(url, timeout)
                    guard value["schema_version"] == "mcp_app_channel.v1",
                          let id = value["release_id"]?.stringValue,
                          AgentArtifactResourceContract.matches(id, #"^r-[a-f0-9]{16}$"#),
                          var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                        return Result(value: nil, ttl: ttl)
                    }
                    parts.path = "/mcp-apps/releases/\(id).json"; parts.query = nil; parts.fragment = nil
                    guard let releaseURL = parts.url else { return Result(value: nil, ttl: ttl) }
                    return Result(value: Channel(id: id, url: releaseURL), ttl: ttl)
                } catch {
                    return Result(value: nil, ttl: (error as? AgentArtifactResourceFetchError).map {
                        if case .http(404) = $0 { return ttl }; return retry
                    } ?? retry)
                }
            })
            self.channelURL = url; channel = entry
        }
        let result = await entry.task.value
        if self.channelURL == url, channel?.token == entry.token { channel?.ttl = result.ttl }
        return result.value
    }
    private func getRelease(_ channel: Channel) async -> JSONValue? {
        let entry: Entry<JSONValue>
        if let cached = releases[channel.url], now() - cached.at <= cached.ttl { entry = cached }
        else {
            let fetch = fetch, ttl = channelTTL, retry = transientTTL, timeout = timeout
            entry = Entry(token: UUID(), at: now(), ttl: .infinity, task: Task {
                do {
                    let value = try await fetch(channel.url, timeout)
                    guard value["schema_version"] == "mcp_app_release.v1", value["release_id"] == .string(channel.id),
                          value["widgets"]?.objectValue != nil else { return Result(value: nil, ttl: ttl) }
                    return Result(value: value, ttl: .infinity)
                } catch {
                    return Result(value: nil, ttl: (error as? AgentArtifactResourceFetchError).map {
                        if case .http(404) = $0 { return ttl }; return retry
                    } ?? retry)
                }
            })
            if releases.count >= capacity, let oldest = releases.min(by: { $0.value.at < $1.value.at })?.key {
                releases.removeValue(forKey: oldest)
            }
            releases[channel.url] = entry
        }
        let result = await entry.task.value
        if releases[channel.url]?.token == entry.token { releases[channel.url]?.ttl = result.ttl }
        return result.value
    }
}
