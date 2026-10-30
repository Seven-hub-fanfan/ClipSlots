import Foundation
import Network
import ClipSlotsKit

/// A loopback HTTP server exercises URLSession, request framing, SSE, session
/// headers and tools/call. No cloud credentials or paid APIs are involved.
private final class MCPWireServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "clipslots.mcp-wire-fixture")
    private let listener: NWListener
    private let lock = NSLock()
    private var requests: [(String, String, JSONValue)] = []
    private var pending: [NWConnection] = []
    var mode = "normal"
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
                    continuation.resume(returning: URL(string:"http://127.0.0.1:\(self.listener.port!.rawValue)/mcp")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing:error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue:self?.queue ?? .global())
                self?.receive(connection, buffer:Data())
            }
            listener.start(queue:queue)
        }
    }
    func stop() {
        lock.lock(); let connections = pending; pending = []; lock.unlock()
        connections.forEach { $0.cancel() }
        listener.cancel()
    }
    func setMode(_ value: String) { lock.lock(); mode = value; lock.unlock() }
    func recorded() -> [(String,String,JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var data = buffer
            if let bytes { data.append(bytes) }
            if let boundary = data.range(of:Data("\r\n\r\n".utf8)) {
                let headers = String(decoding:data[..<boundary.lowerBound],as:UTF8.self)
                let count = headers.components(separatedBy:"\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }.flatMap { Int($0.split(separator:":",maxSplits:1)[1].trimmingCharacters(in:.whitespaces)) } ?? 0
                if data.count - boundary.upperBound >= count {
                    self.respond(connection,headers:headers,body:Data(data[boundary.upperBound..<(boundary.upperBound + count)]))
                    return
                }
            }
            if error == nil && !complete { self.receive(connection,buffer:data) }
            else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, headers: String, body: Data) {
        guard let input = try? JSONDecoder().decode(JSONValue.self,from:body) else { connection.cancel(); return }
        let method = input["method"]?.stringValue ?? ""
        lock.lock(); requests.append((method,headers,input)); let mode = self.mode; lock.unlock()
        if (mode == "hang-initialize" && method == "initialize")
            || (mode == "hang-call" && method == "tools/call") {
            lock.lock(); pending.append(connection); lock.unlock()
            return
        }
        let result: JSONValue
        switch method {
        case "initialize": result = ["protocolVersion":"2025-03-26","capabilities":["tools":[:]]]
        case "tools/list":
            let tool: JSONValue = ["name":"document_read","description":"Read fixture document",
                "inputSchema":["type":"object","properties":["id":["type":"string"]],"required":["id"]],
                "annotations":["readOnlyHint":true]]
            result = mode == "empty" ? ["tools":[]] : ["tools":[tool]]
        case "tools/call":
            result = ["content":[["type":"text","text":input["params"]?["arguments"]?["id"] ?? "missing"]],
                      "isError":.bool(mode == "tool-error")]
        default: result = [:]
        }
        let status = mode == "unauthorized" ? 401 : (method == "notifications/initialized" ? 202 : 200)
        let payload = JSONValue.object(["jsonrpc":"2.0","id":mode == "wrong-id" ? "wrong" : input["id"] ?? .null,"result":result])
        let json = (try? payload.encodedText()) ?? "{}"
        let sse = method == "tools/call"
        let responseBody = status == 202 ? "" : (sse ? "event: message\ndata: \(json)\n\n" : json)
        let response = "HTTP/1.1 \(status) OK\r\nContent-Type: \(sse ? "text/event-stream" : "application/json")\r\nContent-Length: \(responseBody.utf8.count)\r\nMcp-Session-Id: wire-session\r\nConnection: close\r\n\r\n" + responseBody
        connection.send(content:Data(response.utf8),completion:.contentProcessed { _ in connection.cancel() })
    }
}

enum MCPWireRegression {
    @MainActor static func run(check: (Bool,String) -> Void) async throws {
        let server = try MCPWireServer(), endpoint = try await server.start()
        defer { server.stop() }
        let client = AgentMCPClient(endpoint:endpoint)
        let tools = try await client.listTools()
        check(tools.count == 1,"loopback HTTP tools/list uses real URLSession transport")
        let binding = AgentMCPBinding(scope:"fixture-account",applicationID:"app:documents",endpoint:endpoint,tools:tools)
        let adapter = AgentMCPApplicationTools(binding:binding,title:"Documents",client:client,readOnly:true,
            isCurrent:{true},approve:{ _,_ in true })
        let name = adapter.specs()[0].name
        let result = await adapter.execute(call:.init(id:"wire",name:name,argumentsJSON:"{\"id\":\"document-42\"}"))
        check(!result.isFailure && result.content.contains("document-42"),"actual HTTP tools/call decodes SSE response")
        let requests = server.recorded()
        check(requests.first?.0 == "initialize" && requests.dropFirst().first?.0 == "notifications/initialized",
              "MCP initialization and notification precede tools")
        check(requests.filter { $0.0 != "initialize" }.allSatisfy {
            $0.1.lowercased().contains("mcp-session-id: wire-session")
                && $0.1.lowercased().contains("mcp-protocol-version: 2025-03-26")
        },"HTTP session and protocol headers propagate")
        check(requests.last?.2["params"]?["name"] == "document_read",
              "namespaced tool dispatch resolves exact remote name")
        let stale = AgentMCPApplicationTools(binding:binding,title:"Documents",client:client,readOnly:false,
            isCurrent:{false},approve:{ _,_ in true })
        let before = server.recorded().count
        let staleResult = await stale.execute(call:.init(id:"stale",name:name,argumentsJSON:"{\"id\":\"document-42\"}"))
        check(staleResult.isFailure && server.recorded().count == before,"changed account blocks network access")
        let denied = AgentMCPApplicationTools(binding:binding,title:"Documents",client:client,readOnly:false,
            isCurrent:{true},approve:{ _,_ in false })
        let callsBefore = server.recorded().filter { $0.0 == "tools/call" }.count
        let deniedResult = await denied.execute(call:.init(id:"denied",name:name,argumentsJSON:"{\"id\":\"document-42\"}"))
        check(deniedResult.isFailure && server.recorded().filter { $0.0 == "tools/call" }.count == callsBefore,
              "declined approval never calls remote tool")
        server.setMode("tool-error")
        let failure = await adapter.execute(call:.init(id:"error",name:name,argumentsJSON:"{\"id\":\"document-42\"}"))
        check(failure.isFailure,"remote isError is preserved")
        server.setMode("wrong-id")
        do { _ = try await client.listTools(); check(false,"mismatched JSON-RPC response rejected") }
        catch { check(true,"mismatched JSON-RPC response rejected") }
        server.setMode("empty")
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:emptyRoot) }
        let service = AgentMarketSyncService(root:emptyRoot)
        do {
            _ = try await service.bind(.init(["kind":"app","name":"documents"]),snapshot:.init(catalog:[:]),
                client:client,selectedNames:["document_read"])
            check(false,"empty inventory cannot become installed")
        } catch { check(true,"empty inventory cannot become installed") }
        check(try await service.installations(scope:"public").isEmpty,"failed binding does not persist success")
        server.setMode("unauthorized")
        let countBefore = server.recorded().count
        do { _ = try await client.call("document_write",arguments:[:]); check(false,"401 requires authorization") }
        catch { check(true,"401 requires authorization") }
        check(server.recorded().count == countBefore + 1,"failed tool call is never automatically replayed")
        let writer = AgentMCPTool(name:"document_write",description:"Write",inputSchema:["type":"object","properties":[:]])
        let writeBinding = AgentMCPBinding(scope:"fixture",applicationID:"app:docs",endpoint:endpoint,tools:[writer])
        let readOnly = AgentMCPApplicationTools(binding:writeBinding,title:"Docs",client:client,readOnly:true,
            isCurrent:{true},approve:{ _,_ in true })
        check(readOnly.specs().isEmpty,"unannotated tools are unavailable in read-only mode")
        let writeResult = await readOnly.execute(call:.init(id:"write",name:writeBinding.toolName(writer),argumentsJSON:"{}"))
        check(writeResult.isFailure,"read-only enforcement also guards dispatch")
        for mode in ["hang-initialize", "hang-call"] {
            let hanging = try MCPWireServer(), endpoint = try await hanging.start()
            let cancellable = AgentMCPClient(endpoint: endpoint)
            if mode == "hang-call" { _ = try await cancellable.listTools() }
            hanging.setMode(mode)
            let task = Task { try await cancellable.call("document_read", arguments: ["id": "cancel"]) }
            for _ in 0..<100 {
                if hanging.recorded().last?.0 == (mode == "hang-call" ? "tools/call" : "initialize") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            check(hanging.recorded().last?.0 == (mode == "hang-call" ? "tools/call" : "initialize"),
                  "\(mode) reaches the real HTTP boundary")
            let started = Date()
            task.cancel()
            do { _ = try await task.value; check(false, "\(mode) cancellation must throw") }
            catch {
                check(error is CancellationError || (error as? URLError)?.code == .cancelled,
                      "\(mode) cancellation stops URLSession without replay")
            }
            check(Date().timeIntervalSince(started) < 1, "\(mode) cancellation is promptly propagated")
            check(hanging.recorded().filter { $0.0 == "tools/call" }.count == (mode == "hang-call" ? 1 : 0),
                  "\(mode) cancellation never repeats a remote operation")
            hanging.stop()
        }
    }
}
