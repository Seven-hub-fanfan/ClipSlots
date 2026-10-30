import Foundation

public enum AgentMCPError: LocalizedError {
    case authorization, transport(Int), invalidResponse, remote, unavailable, invalidBinding
    public var errorDescription: String? {
        switch self {
        case .authorization: return "请连接并授权此应用的工具服务"
        case .transport(let status): return "工具服务请求失败（HTTP \(status)），请重试连接"
        case .invalidResponse: return "工具服务返回了无效响应"
        case .remote: return "工具服务拒绝了请求"
        case .unavailable: return "服务没有提供可绑定的工具"
        case .invalidBinding: return "应用工具绑定已失效，请重新连接"
        }
    }
}

public struct AgentMCPTool: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: JSONValue?
    public var id: String { name }
    public var readOnly: Bool { annotations?["readOnlyHint"] == .bool(true) }
    public init(name: String, description: String, inputSchema: JSONValue, annotations: JSONValue? = nil) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations
    }
    public init(raw: JSONValue) throws {
        guard let name = raw["name"]?.stringValue, !name.isEmpty, name.count <= 256,
              let schema = raw["inputSchema"], schema["type"] == .string("object") else {
            throw AgentMCPError.invalidResponse
        }
        self.init(name: name, description: raw["description"]?.stringValue ?? name,
                  inputSchema: schema, annotations: raw["annotations"])
    }
}

/// Persisted capabilities contain no credentials. A binding is tied to one
/// account, application, endpoint and explicitly chosen tool schema set.
public struct AgentMCPBinding: Codable, Equatable, Sendable {
    public let version: Int
    public let scope: String
    public let applicationID: String
    public let endpoint: URL
    public let tools: [AgentMCPTool]
    public let verifiedAt: Date
    public init(scope: String, applicationID: String, endpoint: URL, tools: [AgentMCPTool]) {
        version = 1; self.scope = scope; self.applicationID = applicationID
        self.endpoint = endpoint; self.tools = tools; verifiedAt = Date()
    }
    public func toolName(_ tool: AgentMCPTool) -> String {
        "app_" + String(AgentMarketSyncService.hash(scope + "|" + applicationID + "|" + endpoint.absoluteString).prefix(12))
            + "_" + String(AgentMarketSyncService.hash(tool.name).prefix(20))
    }
    public var isValid: Bool {
        version == 1 && !scope.isEmpty && !applicationID.isEmpty && !tools.isEmpty
            && Set(tools.map(\.name)).count == tools.count && AgentMCPClient.validEndpoint(endpoint)
    }
}

public protocol AgentMCPHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct AgentMCPURLSessionHTTP: AgentMCPHTTP {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: MCPRedirectPolicy(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentMCPError.invalidResponse
        }
        defer { bytes.task.cancel() }
        var data = Data()
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            let requestID = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?["id"]
            var event = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                data.append(contentsOf: (line + "\n").utf8)
                guard data.count <= 8 * 1024 * 1024 else { throw AgentMCPError.invalidResponse }
                if line.isEmpty {
                    let payload = event.split(separator: "\n").filter { $0.hasPrefix("data:") }
                        .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                    if let reply = try? JSONValue.decode(jsonText: payload), reply["id"] == requestID,
                       reply["result"] != nil || reply["error"] != nil { return (data, http) }
                    event = ""
                } else { event += line + "\n" }
            }
        } else {
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 8 * 1024 * 1024 else { throw AgentMCPError.invalidResponse }
            }
        }
        return (data, http)
    }
}

/// Streamable HTTP JSON-RPC client. Each write is sent once; a timeout or
/// dropped response is never retried automatically.
public actor AgentMCPClient {
    public static let officialEndpoint = URL(string: "https://mcp.tapnow.ai/api/agent-gateway/mcp/general/mcp")!
    public static func validEndpoint(_ url: URL) -> Bool {
        url.user == nil && url.password == nil && url.fragment == nil && url.query == nil
            && (url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? "")))
    }
    public let endpoint: URL
    private let http: any AgentMCPHTTP
    private let token: @Sendable () async throws -> String?
    private var sessionID: String?
    private var protocolVersion = "2025-03-26"
    private var initialization: Task<Void, Error>?
    public init(endpoint: URL, http: any AgentMCPHTTP = AgentMCPURLSessionHTTP(),
                token: @escaping @Sendable () async throws -> String? = { nil }) {
        self.endpoint = endpoint; self.http = http; self.token = token
    }
    private func rpc(_ method: String, params: JSONValue, notification: Bool = false) async throws -> JSONValue {
        guard Self.validEndpoint(endpoint) else { throw AgentMCPError.invalidBinding }
        try Task.checkCancellation()
        let id = UUID().uuidString
        var envelope: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        if !notification { envelope["id"] = .string(id) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(JSONValue.object(envelope))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if method != "initialize" {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        }
        if let credential = try await token() { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        try Task.checkCancellation()
        let (data, response) = try await http.send(request)
        try Task.checkCancellation()
        if [401, 403].contains(response.statusCode) { throw AgentMCPError.authorization }
        guard (200..<300).contains(response.statusCode) else { throw AgentMCPError.transport(response.statusCode) }
        if notification { return .null }
        if method == "initialize" { sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") }
        let reply: JSONValue?
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            reply = text.components(separatedBy: "\n\n").compactMap { event -> JSONValue? in
                let payload = event.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                return try? JSONValue.decode(jsonText: payload)
            }.first { $0["id"] == .string(id) }
        } else { reply = try? JSONDecoder().decode(JSONValue.self, from: data) }
        guard let reply, reply["jsonrpc"] == "2.0", reply["id"] == .string(id) else { throw AgentMCPError.invalidResponse }
        if reply["error"] != nil { throw AgentMCPError.remote }
        guard let result = reply["result"] else { throw AgentMCPError.invalidResponse }
        return result
    }
    public func initialize() async throws {
        try Task.checkCancellation()
        if let initialization {
            return try await withTaskCancellationHandler {
                try await initialization.value
                try Task.checkCancellation()
            } onCancel: { initialization.cancel() }
        }
        let task = Task {
            let response = try await self.rpc("initialize", params: [
                "protocolVersion": "2025-03-26", "capabilities": [:],
                "clientInfo": ["name": "ClipSlots", "version": "1.0"]
            ])
            guard let version = response["protocolVersion"]?.stringValue,
                  ["2024-11-05", "2025-03-26", "2025-06-18"].contains(version),
                  response["capabilities"]?["tools"] != nil else { throw AgentMCPError.invalidResponse }
            self.protocolVersion = version
            _ = try await self.rpc("notifications/initialized", params: [:], notification: true)
        }
        initialization = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: { task.cancel() }
        } catch {
            initialization = nil; sessionID = nil; throw error
        }
    }
    public func listTools() async throws -> [AgentMCPTool] {
        try await initialize()
        var output: [AgentMCPTool] = [], cursor: String?, cursors = Set<String>(), names = Set<String>()
        for _ in 0..<100 {
            let result = try await rpc("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
            guard let tools = result["tools"]?.arrayValue else { throw AgentMCPError.invalidResponse }
            for raw in tools {
                let tool = try AgentMCPTool(raw: raw)
                guard names.insert(tool.name).inserted, output.count < 2000 else { throw AgentMCPError.invalidResponse }
                output.append(tool)
            }
            guard let next = result["nextCursor"]?.stringValue, !next.isEmpty else { return output }
            guard cursors.insert(next).inserted else { throw AgentMCPError.invalidResponse }
            cursor = next
        }
        throw AgentMCPError.invalidResponse
    }
    public func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await initialize()
        guard arguments.objectValue != nil else { throw AgentMCPError.invalidResponse }
        return try await rpc("tools/call", params: ["name": .string(name), "arguments": arguments])
    }
}

public final class AgentMCPApplicationTools: AgentToolExecuting {
    private let binding: AgentMCPBinding
    private let title: String
    private let client: AgentMCPClient
    private let readOnly: Bool
    private let isCurrent: @Sendable () async -> Bool
    private let approve: @Sendable (AgentMCPTool, AgentToolCall) async -> Bool
    public init(binding: AgentMCPBinding, title: String, client: AgentMCPClient, readOnly: Bool,
                isCurrent: @escaping @Sendable () async -> Bool,
                approve: @escaping @Sendable (AgentMCPTool, AgentToolCall) async -> Bool) {
        self.binding = binding; self.title = title; self.client = client; self.readOnly = readOnly
        self.isCurrent = isCurrent; self.approve = approve
    }
    public func specs() -> [AgentToolSpec] {
        guard binding.isValid else { return [] }
        return binding.tools.filter { !readOnly || $0.readOnly }.map {
            AgentToolSpec(name: binding.toolName($0), description: title + " · " + $0.name + "\n" + $0.description,
                          parameters: $0.inputSchema, originLabel: title)
        }
    }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard binding.isValid, let tool = binding.tools.first(where: { binding.toolName($0) == call.name }),
              !readOnly || tool.readOnly else { return .failure("本轮未开放此应用工具", code: "ACCESS_MODE_DENIED") }
        guard !Task.isCancelled, await isCurrent() else { return .failure("应用账号或会话已改变", code: "STALE_TARGET") }
        do {
            let arguments = try JSONValue.decode(jsonText: call.argumentsJSON)
            try ByteArtistContract.validateField(call.argumentsJSON, schema: tool.inputSchema)
            // Revalidate exact schemas before a call; new/changed tools require a
            // deliberate rebind and never broaden a running turn.
            let live = try await client.listTools()
            guard live.contains(tool) else { throw AgentMCPError.invalidBinding }
            guard await approve(tool, call) else { return .failure("未允许本次应用操作", code: "DECLINED") }
            try Task.checkCancellation()
            guard await isCurrent() else { throw AgentMCPError.invalidBinding }
            let result = try await client.call(tool.name, arguments: arguments)
            return AgentToolResult(content: try result.encodedText(), isFailure: result["isError"] == .bool(true),
                                   summary: title + " · " + tool.name)
        } catch {
            return .failure(error.localizedDescription, code: error is CancellationError ? "CANCELLED" : "APPLICATION_TOOL_FAILED")
        }
    }
}

public final class AgentCombinedTools: AgentToolExecuting {
    private let bases: [AgentToolExecuting]
    public init(_ bases: [AgentToolExecuting]) { self.bases = bases }
    public func specs() -> [AgentToolSpec] {
        var names = Set<String>()
        return bases.flatMap { $0.specs() }.filter { names.insert($0.name).inserted }
    }
    public func execute(call: AgentToolCall) async -> AgentToolResult {
        guard let base = bases.first(where: { $0.specs().contains(where: { $0.name == call.name }) }) else {
            return .failure("本轮未开放此工具", code: "ACCESS_MODE_DENIED")
        }
        return await base.execute(call: call)
    }
}
