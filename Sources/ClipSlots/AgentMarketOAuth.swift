import AppKit
import AuthenticationServices
import CryptoKit
import Security
import ClipSlotsKit

protocol AgentMarketGrantStorage: Sendable {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
}

struct AgentMarketKeychainGrants: AgentMarketGrantStorage {
    private func key(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.clipslots.app.market-mcp-oauth.v2",
         kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> Data? {
        var query = key(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw AgentMCPError.authorization }
        return data
    }
    func save(_ data: Data, account: String) throws {
        let query = key(account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AgentMCPError.authorization }
        } else if update != errSecSuccess { throw AgentMCPError.authorization }
    }
}

/// OAuth grants belong to ClipSlots and stay in Keychain. The catalog's
/// desktop session token is never reused as a tool-service credential.
actor AgentMarketCredentials {
    static let shared = AgentMarketCredentials()
    private struct Grant: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var clientID: String
        var resource: URL
        var issuer: URL
    }
    private let http: AgentMCPHTTP
    private let storage: AgentMarketGrantStorage
    private var refreshes: [String: Task<String, Error>] = [:]
    init(http: AgentMCPHTTP = AgentMCPURLSessionHTTP(), storage: AgentMarketGrantStorage = AgentMarketKeychainGrants()) {
        self.http = http; self.storage = storage
    }
    static func issuer(for endpoint: URL) throws -> URL {
        if endpoint == AgentMCPClient.officialEndpoint { return URL(string: "https://oauth.tapnow.media")! }
        if endpoint == AgentMCPClient.globalEndpoint { return URL(string: "https://oauth.tapnow.ai")! }
        throw AgentMCPError.invalidBinding
    }
    static func account(scope: String, endpoint: URL) -> String {
        AgentMarketSyncService.hash(scope + "\n" + endpoint.absoluteString)
    }
    private func read(_ account: String) throws -> Grant? {
        guard let data = try storage.read(account: account) else { return nil }
        return try JSONDecoder().decode(Grant.self, from: data)
    }
    private func save(_ grant: Grant, account: String) throws {
        try storage.save(JSONEncoder().encode(grant), account: account)
    }
    private func json(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await http.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AgentMCPError.authorization
        }
        return json
    }
    private func tokenRequest(_ fields: [String: String], issuer: URL) async throws -> JSONValue {
        var request = URLRequest(url: issuer.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Form encoding must escape '+' as well as query delimiters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
                + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        return try await json(request)
    }
    private func grant(_ value: JSONValue, clientID: String, endpoint: URL, issuer: URL,
                       previousRefresh: String? = nil) throws -> Grant {
        guard let token = value["access_token"]?.stringValue, !token.isEmpty,
              value["token_type"]?.stringValue?.lowercased() == "bearer",
              let expires = value["expires_in"]?.intValue, expires > 0 else { throw AgentMCPError.authorization }
        return Grant(accessToken: token, refreshToken: value["refresh_token"]?.stringValue ?? previousRefresh,
                     expiresAt: Date().addingTimeInterval(Double(expires)), clientID: clientID,
                     resource: endpoint, issuer: issuer)
    }
    func token(scope: String, endpoint: URL = AgentMCPClient.officialEndpoint) async throws -> String? {
        try Task.checkCancellation()
        let issuer = try Self.issuer(for: endpoint), account = Self.account(scope: scope, endpoint: endpoint)
        if let refresh = refreshes[account] { return try await refresh.value }
        guard var existing = try read(account), existing.resource == endpoint, existing.issuer == issuer else {
            throw AgentMCPError.authorization
        }
        if existing.expiresAt.timeIntervalSinceNow > 60 { return existing.accessToken }
        guard let refresh = existing.refreshToken else { throw AgentMCPError.authorization }
        let task = Task {
            let value = try await self.tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh,
                "client_id": existing.clientID, "resource": endpoint.absoluteString], issuer: issuer)
            existing = try self.grant(value, clientID: existing.clientID, endpoint: endpoint, issuer: issuer, previousRefresh: refresh)
            try self.save(existing, account: account)
            return existing.accessToken
        }
        refreshes[account] = task
        defer { refreshes[account] = nil }
        return try await task.value
    }
    struct Authorization: Sendable {
        let url: URL
        let state: String
        let verifier: String
        let clientID: String
        let redirect: String
        let endpoint: URL
        let issuer: URL
    }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AgentMCPError.authorization
        }
        return Self.base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func begin(endpoint: URL = AgentMCPClient.officialEndpoint,
               operation: AgentMarketOperation? = nil) async throws -> Authorization {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard operation?.isCurrent != false else { throw CancellationError() }
        }
        try checkCurrent()
        let issuer = try Self.issuer(for: endpoint)
        var resourceMetadata = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        resourceMetadata.path = "/.well-known/oauth-protected-resource" + endpoint.path
        let resource = try await json(URLRequest(url: resourceMetadata.url!))
        try checkCurrent()
        guard resource["resource"] == .string(endpoint.absoluteString),
              resource["authorization_servers"]?.arrayValue?.contains(.string(issuer.absoluteString)) == true else {
            throw AgentMCPError.authorization
        }
        let metadata = try await json(URLRequest(url: issuer.appendingPathComponent(".well-known/oauth-authorization-server")))
        try checkCurrent()
        guard metadata["issuer"] == .string(issuer.absoluteString),
              metadata["authorization_endpoint"] == .string(issuer.appendingPathComponent("authorize").absoluteString),
              metadata["token_endpoint"] == .string(issuer.appendingPathComponent("token").absoluteString),
              metadata["registration_endpoint"] == .string(issuer.appendingPathComponent("oauth/register").absoluteString),
              metadata["code_challenge_methods_supported"]?.arrayValue?.contains("S256") == true else {
            throw AgentMCPError.authorization
        }
        let redirect = "com.clipslots.app:/oauth/callback"
        var request = URLRequest(url: issuer.appendingPathComponent("oauth/register"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "client_name": "ClipSlots", "redirect_uris": [.string(redirect)],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none", "application_type": "native"
        ]))
        let registration = try await json(request)
        try checkCurrent()
        guard let clientID = registration["client_id"]?.stringValue, !clientID.isEmpty else { throw AgentMCPError.authorization }
        let verifier = try random(), state = try random()
        let challenge = Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: issuer.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "mcp.tools.invoke mcp.tools.read"),
            .init(name: "resource", value: endpoint.absoluteString)
        ]
        return Authorization(url: components.url!, state: state, verifier: verifier, clientID: clientID, redirect: redirect,
                             endpoint: endpoint, issuer: issuer)
    }
    func finish(_ callback: URL, authorization: Authorization, scope: String,
                operation: AgentMarketOperation) async throws {
        try Task.checkCancellation()
        guard operation.isCurrent else { throw CancellationError() }
        let issuer = try Self.issuer(for: authorization.endpoint)
        guard issuer == authorization.issuer, callback.scheme == "com.clipslots.app",
              callback.host == nil, callback.path == "/oauth/callback", callback.fragment == nil,
              let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              !values.contains(where: { $0.name == "error" }),
              values.filter({ $0.name == "state" }).count == 1,
              values.first(where: { $0.name == "state" })?.value == authorization.state,
              values.filter({ $0.name == "iss" }).count == 1,
              values.first(where: { $0.name == "iss" })?.value == issuer.absoluteString,
              values.filter({ $0.name == "code" }).count == 1,
              let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AgentMCPError.authorization
        }
        let response = try await tokenRequest(["grant_type": "authorization_code", "client_id": authorization.clientID,
            "code": code, "redirect_uri": authorization.redirect, "code_verifier": authorization.verifier,
            "resource": authorization.endpoint.absoluteString], issuer: issuer)
        try Task.checkCancellation()
        try operation.withCurrent {
            try save(try grant(response, clientID: authorization.clientID, endpoint: authorization.endpoint, issuer: issuer),
                     account: Self.account(scope: scope, endpoint: authorization.endpoint))
        }
    }
}

@MainActor protocol AgentMarketWebSession: AnyObject {
    func start() -> Bool
    func cancel()
}
extension ASWebAuthenticationSession: AgentMarketWebSession {}

@MainActor final class AgentMarketAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias SessionFactory = (URL, @escaping (URL?, Error?) -> Void) -> AgentMarketWebSession
    private var session: AgentMarketWebSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attempt: UUID?
    private var operation: AgentMarketOperation?
    private let credentials: AgentMarketCredentials
    var sessionFactory: SessionFactory?
    init(credentials: AgentMarketCredentials = .shared) { self.credentials = credentials }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
    func connect(scope: String, endpoint: URL = AgentMCPClient.officialEndpoint) async throws {
        cancel()
        let id = UUID(), operation = AgentMarketOperation()
        attempt = id; self.operation = operation
        defer {
            operation.invalidate()
            if attempt == id { session = nil; continuation = nil; attempt = nil; self.operation = nil }
        }
        try await withTaskCancellationHandler {
            let request = try await credentials.begin(endpoint: endpoint, operation: operation)
            try Task.checkCancellation()
            guard attempt == id, operation.isCurrent else { throw CancellationError() }
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let completion: (URL?, Error?) -> Void = { [weak self] url, error in
                    Task { @MainActor in
                        if let url { self?.complete(.success(url), id: id) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self?.complete(.failure(CancellationError()), id: id)
                        } else { self?.complete(.failure(error ?? AgentMCPError.authorization), id: id) }
                    }
                }
                let session: AgentMarketWebSession
                if let sessionFactory { session = sessionFactory(request.url, completion) }
                else {
                    let web = ASWebAuthenticationSession(url: request.url, callbackURLScheme: "com.clipslots.app",
                                                         completionHandler: completion)
                    web.presentationContextProvider = self
                    session = web
                }
                self.session = session
                if !session.start() { complete(.failure(AgentMCPError.authorization), id: id) }
            }
            try Task.checkCancellation()
            guard attempt == id, operation.isCurrent else { throw CancellationError() }
            try await credentials.finish(callback, authorization: request, scope: scope, operation: operation)
        } onCancel: {
            operation.invalidate()
            Task { @MainActor [weak self] in if self?.attempt == id { self?.cancel() } }
        }
    }
    private func complete(_ result: Result<URL, Error>, id: UUID) {
        guard attempt == id, let continuation else { return }
        self.continuation = nil; session = nil
        continuation.resume(with: result)
    }
    func cancel() {
        operation?.invalidate()
        let session = self.session, continuation = self.continuation
        self.session = nil; self.continuation = nil; attempt = nil; operation = nil
        continuation?.resume(throwing: CancellationError())
        session?.cancel()
    }
}
