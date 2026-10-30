import AppKit
import AuthenticationServices
import CryptoKit
import Security
import ClipSlotsKit

/// OAuth grants belong to ClipSlots and stay in Keychain. The catalog's
/// desktop session token is never reused as a tool-service credential.
actor AgentMarketCredentials {
    static let shared = AgentMarketCredentials()
    private struct Grant: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var clientID: String
    }
    private let http = AgentMCPURLSessionHTTP()
    private var refreshes: [String: Task<String, Error>] = [:]
    private let issuer = URL(string: "https://oauth.tapnow.ai")!
    private func key(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.clipslots.app.market-mcp-oauth",
         kSecAttrAccount as String: AgentMarketSyncService.hash(scope)]
    }
    private func read(_ scope: String) throws -> Grant? {
        var query = key(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw AgentMCPError.authorization }
        return try JSONDecoder().decode(Grant.self, from: data)
    }
    private func save(_ grant: Grant, scope: String) throws {
        let data = try JSONEncoder().encode(grant), query = key(scope)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AgentMCPError.authorization }
        } else if update != errSecSuccess { throw AgentMCPError.authorization }
    }
    private func json(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AgentMCPError.authorization
        }
        return json
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> JSONValue {
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
    private func grant(_ value: JSONValue, clientID: String, previousRefresh: String? = nil) throws -> Grant {
        guard let token = value["access_token"]?.stringValue, !token.isEmpty,
              value["token_type"]?.stringValue?.lowercased() == "bearer",
              let expires = value["expires_in"]?.intValue, expires > 0 else { throw AgentMCPError.authorization }
        return Grant(accessToken: token, refreshToken: value["refresh_token"]?.stringValue ?? previousRefresh,
                     expiresAt: Date().addingTimeInterval(Double(expires)), clientID: clientID)
    }
    func token(scope: String) async throws -> String? {
        if let refresh = refreshes[scope] { return try await refresh.value }
        guard var existing = try read(scope) else { throw AgentMCPError.authorization }
        if existing.expiresAt.timeIntervalSinceNow > 60 { return existing.accessToken }
        guard let refresh = existing.refreshToken else { throw AgentMCPError.authorization }
        let task = Task {
            let value = try await self.tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh,
                "client_id": existing.clientID, "resource": AgentMCPClient.officialEndpoint.absoluteString])
            existing = try self.grant(value, clientID: existing.clientID, previousRefresh: refresh)
            try self.save(existing, scope: scope)
            return existing.accessToken
        }
        refreshes[scope] = task
        defer { refreshes[scope] = nil }
        return try await task.value
    }
    struct Authorization: Sendable {
        let url: URL
        let state: String
        let verifier: String
        let clientID: String
        let redirect: String
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
    func begin() async throws -> Authorization {
        let metadata = try await json(URLRequest(url: issuer.appendingPathComponent(".well-known/oauth-authorization-server")))
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
        guard let clientID = registration["client_id"]?.stringValue, !clientID.isEmpty else { throw AgentMCPError.authorization }
        let verifier = try random(), state = try random()
        let challenge = Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: issuer.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "mcp.tools.invoke mcp.tools.read"),
            .init(name: "resource", value: AgentMCPClient.officialEndpoint.absoluteString)
        ]
        return Authorization(url: components.url!, state: state, verifier: verifier, clientID: clientID, redirect: redirect)
    }
    func finish(_ callback: URL, authorization: Authorization, scope: String) async throws {
        guard callback.scheme == "com.clipslots.app", callback.path == "/oauth/callback",
              let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              values.filter({ $0.name == "state" }).count == 1,
              values.first(where: { $0.name == "state" })?.value == authorization.state,
              values.first(where: { $0.name == "iss" })?.value == issuer.absoluteString,
              values.filter({ $0.name == "code" }).count == 1,
              let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AgentMCPError.authorization
        }
        let response = try await tokenRequest(["grant_type": "authorization_code", "client_id": authorization.clientID,
            "code": code, "redirect_uri": authorization.redirect, "code_verifier": authorization.verifier,
            "resource": AgentMCPClient.officialEndpoint.absoluteString])
        try save(try grant(response, clientID: authorization.clientID), scope: scope)
    }
}

@MainActor final class AgentMarketAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
    func connect(scope: String) async throws {
        let request = try await AgentMarketCredentials.shared.begin()
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: request.url, callbackURLScheme: "com.clipslots.app") { url, error in
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? AgentMCPError.authorization) }
                }
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { self.session = nil; continuation.resume(throwing: AgentMCPError.authorization) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.session?.cancel() } }
        session = nil
        try await AgentMarketCredentials.shared.finish(callback, authorization: request, scope: scope)
    }
    func cancel() { session?.cancel(); session = nil }
}
