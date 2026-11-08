#if DEBUG
import AppKit
import SwiftUI
import CryptoKit
import ClipSlotsKit

private final class OAuthFixtureStorage: AgentMarketGrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func save(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = data }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private actor OAuthFixtureHTTP: AgentMCPHTTP {
    var requests: [URLRequest] = []
    var invalidResource = false
    var blockPath: String?
    var blocked = false
    var waiter: CheckedContinuation<Void, Never>?
    func configure(invalidResource: Bool = false, blockPath: String? = nil) {
        self.invalidResource = invalidResource; self.blockPath = blockPath
    }
    func release() { waiter?.resume(); waiter = nil; blockPath = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!, path = url.path
        if path == blockPath {
            blocked = true
            await withCheckedContinuation { waiter = $0 }
        }
        let issuer = "https://oauth.tapnow.media"
        let value: JSONValue
        if path.hasPrefix("/.well-known/oauth-protected-resource") {
            value = ["resource": .string(invalidResource ? "https://wrong.example/mcp" : AgentMCPClient.officialEndpoint.absoluteString),
                     "authorization_servers": [.string(issuer)]]
        } else if path.hasSuffix("oauth-authorization-server") {
            value = ["issuer": .string(issuer), "authorization_endpoint": .string(issuer + "/authorize"),
                     "token_endpoint": .string(issuer + "/token"), "registration_endpoint": .string(issuer + "/oauth/register"),
                     "code_challenge_methods_supported": ["S256"]]
        } else if path == "/oauth/register" { value = ["client_id": "fixture-client"] }
        else { value = ["access_token": "fixture-token", "refresh_token": "fixture-refresh",
                        "token_type": "Bearer", "expires_in": 3600] }
        return (try JSONEncoder().encode(value), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class OAuthFixtureSession: AgentMarketWebSession {
    let url: URL
    let completion: (URL?, Error?) -> Void
    var starts = true
    var cancelled = false
    init(url: URL, completion: @escaping (URL?, Error?) -> Void) { self.url = url; self.completion = completion }
    func start() -> Bool { starts }
    func cancel() { cancelled = true }
    func succeed() {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: "com.clipslots.app:/oauth/callback")!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "iss", value: "https://oauth.tapnow.media"),
                               .init(name: "code", value: "fixture+code&")]
        completion(callback.url!, nil)
    }
}

@MainActor enum AgentMarketOAuthRegression {
    static func run(root: URL, check: (Bool, String) -> Void) async throws {
        func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
        func wait(_ condition: () async -> Bool) async {
            for _ in 0..<100 { if await condition() { return }; await settle() }
        }
        let http = OAuthFixtureHTTP(), storage = OAuthFixtureStorage()
        let credentials = AgentMarketCredentials(http: http, storage: storage)
        let authorization = AgentMarketAuthorization(credentials: credentials)
        var sessions: [OAuthFixtureSession] = []
        authorization.sessionFactory = { url, completion in
            let session = OAuthFixtureSession(url: url, completion: completion); sessions.append(session); return session
        }
        check(AgentMCPClient.officialEndpoint.host == "mcp.tapnow.media", "MCP default uses reachable CN contract")
        check(try AgentMarketCredentials.issuer(for: AgentMCPClient.globalEndpoint).host == "oauth.tapnow.ai",
              "explicit global binding retains its own issuer")
        let first = Task { try await authorization.connect(scope: "fixture") }
        await wait { !sessions.isEmpty }
        check(sessions.count == 1, "OAuth starts one browser session after metadata validation")
        let firstSession = sessions[0]
        let query = URLComponents(url: firstSession.url, resolvingAgainstBaseURL: false)!.queryItems!
        check(firstSession.url.host == "oauth.tapnow.media" &&
              query.first { $0.name == "resource" }?.value == AgentMCPClient.officialEndpoint.absoluteString,
              "authorization resource and issuer both use CN")
        check(query.first { $0.name == "code_challenge_method" }?.value == "S256" &&
              (query.first { $0.name == "code_challenge" }?.value?.count ?? 0) == 43,
              "native authorization uses S256 PKCE")
        authorization.cancel(); authorization.cancel()
        firstSession.succeed(); firstSession.succeed()
        do { try await first.value; check(false, "cancelled OAuth returns cancellation") }
        catch { check(error is CancellationError && firstSession.cancelled, "cancelled OAuth resumes exactly once") }
        await settle()
        let cancelledRequests = await http.requests
        check(storage.count == 0 && cancelledRequests.filter { $0.url?.path == "/token" }.isEmpty,
              "late callbacks after cancellation never exchange or store credentials")
        let retry = Task { try await authorization.connect(scope: "fixture") }
        await wait { sessions.count == 2 }
        sessions[1].succeed()
        try await retry.value
        check(storage.count == 1, "retry after cancellation can complete and save grant")
        check(try await credentials.token(scope: "fixture") == "fixture-token", "saved grant belongs to matching account and CN resource")
        let tokenRequest = await http.requests.first { $0.url?.path == "/token" }!
        check(String(data: tokenRequest.httpBody!, encoding: .utf8)!.contains("code=fixture%2Bcode%26"),
              "authorization code form escapes plus and delimiters")
        for (scope, endpoint) in [("other", AgentMCPClient.officialEndpoint), ("fixture", AgentMCPClient.globalEndpoint)] {
            do { _ = try await credentials.token(scope: scope, endpoint: endpoint); check(false, "foreign grant rejected") }
            catch { check(storage.count == 1, "account or region change cannot reuse existing grant") }
        }
        let wrongHTTP = OAuthFixtureHTTP()
        await wrongHTTP.configure(invalidResource: true)
        do { _ = try await AgentMarketCredentials(http: wrongHTTP, storage: storage).begin(); check(false, "wrong resource rejected") }
        catch { check(await wrongHTTP.requests.count == 1, "invalid resource metadata rejected before client registration") }
        let beginHTTP = OAuthFixtureHTTP()
        await beginHTTP.configure(blockPath: "/.well-known/oauth-authorization-server")
        let beginAuth = AgentMarketAuthorization(credentials: AgentMarketCredentials(http: beginHTTP, storage: storage))
        var beginStarts = 0
        beginAuth.sessionFactory = { url, completion in beginStarts += 1; return OAuthFixtureSession(url: url, completion: completion) }
        let beginTask = Task { try await beginAuth.connect(scope: "begin-cancel") }
        await wait { await beginHTTP.blocked }
        beginAuth.cancel(); await beginHTTP.release()
        do { try await beginTask.value; check(false, "cancel during discovery rejected") }
        catch { check(error is CancellationError && beginStarts == 0, "cancel during discovery never opens browser") }
        check(await beginHTTP.requests.allSatisfy { $0.httpMethod != "POST" },
              "cancel during discovery never registers a client")

        let exchangeHTTP = OAuthFixtureHTTP(), exchangeStorage = OAuthFixtureStorage()
        await exchangeHTTP.configure(blockPath: "/token")
        let exchangeAuth = AgentMarketAuthorization(credentials: AgentMarketCredentials(http: exchangeHTTP, storage: exchangeStorage))
        var exchangeSession: OAuthFixtureSession?
        exchangeAuth.sessionFactory = { url, completion in
            let session = OAuthFixtureSession(url: url, completion: completion); exchangeSession = session; return session
        }
        let exchange = Task { try await exchangeAuth.connect(scope: "exchange-cancel") }
        await wait { exchangeSession != nil }; exchangeSession?.succeed()
        await wait { await exchangeHTTP.blocked }
        exchangeAuth.cancel(); await exchangeHTTP.release()
        do { try await exchange.value; check(false, "cancel during exchange rejected") }
        catch { check(error is CancellationError && exchangeStorage.count == 0, "late token response after cancel never saves grant") }

        let failedAuth = AgentMarketAuthorization(credentials: credentials)
        failedAuth.sessionFactory = { url, completion in
            let session = OAuthFixtureSession(url: url, completion: completion); session.starts = false; return session
        }
        do { try await failedAuth.connect(scope: "start-failure"); check(false, "browser start failure rejected") }
        catch { check(error is AgentMCPError, "browser start failure completes without pending continuation") }
        failedAuth.cancel()

        // Exercise real AppKit panels with two competing presenters, using no
        // browser session, Keychain writes or live account requests.
        let item = AgentMarketItem(["kind": "app", "name": "feishu", "display_name": "飞书"])
        let sync = AgentMarketSyncStore(service: .init(root: root.appendingPathComponent("oauth-panel-cache")),
            fixture: AgentMarketSnapshot(scope: "panel-fixture", catalog: ["items": [item.raw]]), readsDesktop: false)
        sync.clientFactory = { endpoint, _ in AgentMCPClient(endpoint: endpoint) { throw AgentMCPError.authorization } }
        let owner = NSWindow(contentRect: .init(x: 200, y: 200, width: 720, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.makeKeyAndOrderFront(nil)
        defer { owner.close() }
        let one = AgentApplicationConnectionPresenter.Coordinator(sync: sync)
        let two = AgentApplicationConnectionPresenter.Coordinator(sync: sync)
        defer { one.close(); two.close() }
        sync.connectingItem = item
        let intermediate = NSPanel(contentRect: owner.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        intermediate.isReleasedWhenClosed = false
        owner.addChildWindow(intermediate, ordered: .above); intermediate.orderFront(nil)
        two.update(owner: intermediate)
        check(two.panel == nil && sync.connectingItem != nil, "transient wizard window cannot claim tool authorization")
        owner.removeChildWindow(intermediate); intermediate.close()
        one.update(owner: owner); two.update(owner: owner)
        await settle()
        check(one.panel != nil && two.panel == nil && owner.childWindows?.count == 1,
              "competing views present only one connection panel")
        check(one.panel?.isSheet == false && NSApp.modalWindow == nil, "connection panel leaves application quit menu available")
        let view = one.panel!.contentView!
        check(NativeAccessibilityProbe.elements(view).first { $0.accessibilityIdentifier?() == "market-connect-close" }?
              .accessibilityPerformPress?() == true, "visible X invokes explicit connection close")
        await settle()
        one.update(owner: owner)
        check(one.panel == nil && sync.connectingItem == nil && (owner.childWindows ?? []).isEmpty,
              "X releases connection state and native child window")
        sync.connectingItem = item; two.update(owner: owner)
        two.panel?.cancelOperation(nil)
        check(two.panel == nil && sync.connectingItem == nil, "Escape cancels panel and permits reopening")
        sync.connectingItem = item; one.update(owner: owner)
        one.panel?.performClose(nil)
        check(one.panel == nil && sync.connectingItem == nil, "native close command cancels connection")
        sync.connectingItem = item; one.update(owner: owner)
        let oldGeneration = sync.connectionGeneration
        sync.connectingItem = item
        sync.closeConnection(generation: oldGeneration)
        check(sync.connectingItem != nil, "stale completion cannot close newer connection for same app")
        one.update(owner: owner)
        owner.close()
        check(one.panel == nil && sync.connectingItem == nil, "closing owner also clears connection panel")
    }
}
#endif
