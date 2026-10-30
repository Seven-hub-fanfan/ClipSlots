import Foundation
import Network
import ClipSlotsKit

private final class ManagementServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "market-management-http")
    let lock = NSLock()
    var requests: [(String, String, JSONValue)] = []
    var installed = true
    var enabled = false
    var skills: [JSONValue] = [["name":"personal","description":"描述","instructions":"完整指令","source":"personal","status":"enabled"]]
    var authID = 0
    var authStatus = "pending"
    var fail = false
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string:"http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing:error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global()); self?.receive(connection, Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    func recorded() -> [(String, String, JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
    func failure(_ value: Bool) { lock.lock(); fail = value; lock.unlock() }
    func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var data = previous; if let bytes { data.append(bytes) }
            if let boundary = data.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
                let count = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count >= boundary.upperBound + count {
                    self.respond(connection, header, Data(data[boundary.upperBound..<(boundary.upperBound + count)])); return
                }
            }
            if !complete && error == nil { self.receive(connection, data) } else { connection.cancel() }
        }
    }
    func respond(_ connection: NWConnection, _ header: String, _ bytes: Data) {
        let parts = header.split(separator: "\r\n").first!.split(separator: " ")
        let method = String(parts[0]), path = String(parts[1])
        let body = (try? JSONDecoder().decode(JSONValue.self, from: bytes)) ?? [:]
        lock.lock(); defer { lock.unlock() }
        requests.append((method, path, body))
        var result: JSONValue = [:]
        if path.contains("/plugins") {
            if method == "PUT" { installed = true; enabled = true }
            if method == "PATCH" { enabled = body["status"] == "enabled" }
            if method == "DELETE" && !fail { installed = false }
            let plugin: JSONValue = ["plugin_name":"documents", "display_name":"Documents", "status":"published",
                "installation":["installed":.bool(installed),"status":.string(enabled ? "enabled" : "disabled")],
                "install_mode":"user","connectors":[["name":"lark"]],"skills":[["name":"embedded"]]]
            if path.hasSuffix("/plugins") || path.contains("installed_only") {
                result = ["plugins": .array(path.contains("installed_only") && !installed ? [] : [plugin])]
            } else { result = plugin }
        } else if path.hasSuffix("/auth-sessions") {
            authID += 1; authStatus = "pending"
            result = ["session_id": .string("auth-\(authID)"),"status":"pending","stage":"create_app","challenge_kind":"redirect",
                "redirect_url":"https://connector.example.com/create","poll_interval_ms":200]
        } else if path.contains("/auth-sessions/") {
            if method == "POST" { authStatus = "authenticated" }
            result = ["session_id":.string("auth-\(authID)"),"status":.string(authStatus), "stage":"authorize",
                "challenge_kind":"form","form_fields":[["name":"client_secret","label":"Secret","secret":true,"required":true]]]
        } else if path.contains("/connectors") {
            if method == "DELETE" { authStatus = "cancelled" }
            result = path.hasSuffix("/connectors") ? ["connectors":[["id":"lark","status":"disconnected"]]] : [:]
        } else if path.contains("/skills") {
            if method == "POST" && !path.hasSuffix("import-folder") { skills.append(body) }
            if method == "PATCH" && !path.hasSuffix("/status") {
                let old = path.split(separator: "/").last.map(String.init)
                skills.removeAll { $0["name"]?.stringValue == old }; skills.append(body)
            }
            if method == "DELETE" {
                let old = path.split(separator: "/").last.map(String.init); skills.removeAll { $0["name"]?.stringValue == old }
            }
            result = path.hasSuffix("/skills") && method == "GET" ? ["skills":.array(skills)] : body
        }
        let data = (try? JSONEncoder().encode(JSONValue.object(["code":200,"data":result]))) ?? Data()
        let response = "HTTP/1.1 \(fail ? 500 : 200) OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
private struct LoopbackManagementHTTP: AgentMarketHTTP {
    let endpoint: URL
    func send(_ original: URLRequest) async throws -> (Data, Int) {
        var request = original
        var components = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)!
        components.scheme = endpoint.scheme; components.host = endpoint.host; components.port = endpoint.port
        request.url = components.url
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
enum MarketManagementWireRegression {
    static func run(root: URL, session: AgentMarketDesktopSession, check: (Bool, String) -> Void) async throws {
        let server = try ManagementServer(), endpoint = try await server.start()
        defer { server.stop() }
        let service = AgentMarketSyncService(root: root, http: LoopbackManagementHTTP(endpoint: endpoint))
        let first = try await service.refreshManager(session: session, previous: nil)
        let app = first.managerItems.first { $0.kind == "app" }!
        check(app.name == "documents" && app.sourceAdded && !app.sourceEnabled,
              "real HTTP normalizes nested installation separately from published runtime")
        check(first.managerItems.count == 2 && first.connectors?.count == 1,
              "manager uses plugin and skill endpoints with independent connector state")
        let paths = server.recorded().map { $0.1 }
        check(paths.contains("/api/agent-gateway/v1/plugins?installed_only=true"), "installed-only query survives URL construction")
        try await service.setInstallation(app, action: "enabled", session: session)
        let enabled = try await service.refreshManager(session: session, previous: first)
        check(enabled.managerItems.first!.sourceEnabled, "enable PATCH is verified by actual GET readback")
        try await service.setInstallation(app, action: "disabled", session: session)
        let disabled = try await service.refreshManager(session: session, previous: enabled)
        check(!disabled.managerItems.first!.sourceEnabled, "disable PATCH persists through reload")
        _ = try await service.saveSkill(original: nil, name: "created", description: "description", instructions: "instructions", session: session)
        var changed = try await service.refreshManager(session: session, previous: disabled)
        check(changed.skills["created"]?["instructions"] == "instructions", "create POST stores all three fields through real HTTP")
        _ = try await service.saveSkill(original: "created", name: "renamed", description: "updated", instructions: "new body", session: session)
        changed = try await service.refreshManager(session: session, previous: changed)
        check(changed.skills["created"] == nil && changed.skills["renamed"]?["instructions"] == "new body", "rename PATCH replaces skill key and body")
        try await service.mutateSkill(AgentMarketItem(["kind":"skill","name":"renamed","source":"personal"]), status: nil, session: session)
        changed = try await service.refreshManager(session: session, previous: changed)
        check(changed.skills["renamed"] == nil, "skill DELETE survives readback")
        var auth = try await service.startConnector("lark", capabilityIDs: ["gather"], session: session)
        check(auth.stage == "create_app" && auth.externalURL != nil, "connector POST starts observed create-app stage")
        auth = try await service.pollConnector("lark", auth: auth, session: session)
        check(auth.stage == "authorize" && auth.fields.first?["secret"] == true, "poll merges server challenge schema into second stage")
        let before = server.recorded().count
        do { _ = try await service.submitConnector("lark", auth: auth, values: [:], session: session); check(false, "required secret blocks empty submit") }
        catch { check(server.recorded().count == before, "required secret blocks empty submit") }
        auth = try await service.submitConnector("lark", auth: auth, values: ["client_secret":"fixture-only"], session: session)
        check(auth.status == "authenticated" && auth.terminal, "form POST reaches authenticated terminal state")
        let retried = try await service.startConnector("lark", capabilityIDs: [], session: session)
        check(retried.id != auth.id, "retry starts a fresh authorization session")
        try await service.disconnectConnector("lark", reset: true, session: session)
        check(server.recorded().last?.1.hasSuffix("?reset=true") == true, "cancel create-app resets connector through DELETE")
        server.failure(true)
        let failedBefore = server.recorded().count
        do { try await service.setInstallation(app, action: "remove", session: session); check(false, "failed mutation throws without replay") }
        catch { check(server.recorded().count == failedBefore + 1, "failed mutation throws without replay") }
        server.failure(false)
        try await service.setInstallation(app, action: "remove", session: session)
        changed = try await service.refreshManager(session: session, previous: changed)
        check(!changed.managerItems.first!.sourceAdded, "application uninstall verified through installed-only readback")
        let invalidBefore = server.recorded().count
        do { try await service.setInstallation(AgentMarketItem(["kind":"app","name":"../private"]), action: "add", session: session); check(false,"invalid path blocks network") }
        catch { check(server.recorded().count == invalidBefore, "invalid path blocks network") }
        let system = AgentMarketItem(["kind":"skill","name":"system","source":"system"])
        do { try await service.mutateSkill(system, status: nil, session: session); check(false,"system skill rejects delete") }
        catch { check(server.recorded().count == invalidBefore, "system skill rejects delete") }
        try await service.commit(changed)
        let cache = try String(contentsOf: root.appendingPathComponent("scopes/" + AgentMarketSyncService.hash(session.scope) + "/snapshot.json"))
        check(!cache.contains("fixture-only") && !cache.contains("auth-"), "authorization sessions and secrets never enter persisted snapshot")
    }
}
