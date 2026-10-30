import Foundation

/// Native identity is never selected by page parameters.
public struct AgentArtifactPageIdentity: Hashable, Sendable {
    public let key: AgentArtifactKey
    public let conversationID: UUID
    public let revision: UInt64
    /// Ephemeral native authority; these tokens never become page-selected parameters or storage keys.
    public let runtimeEpoch: UUID?
    public let canvasEpoch: UUID?

    public init(key: AgentArtifactKey, conversationID: UUID, revision: UInt64,
                runtimeEpoch: UUID? = nil, canvasEpoch: UUID? = nil) {
        self.key = key; self.conversationID = conversationID; self.revision = revision
        self.runtimeEpoch = runtimeEpoch; self.canvasEpoch = canvasEpoch
    }
}

public struct AgentArtifactRPCError: Error, Sendable {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    public var value: JSONValue { ["code": .number(Double(code)), "message": .string(message)] }
    public static let invalid = Self(-32602, "invalid parameters")
    public static let unsupported = Self(-32601, "method not supported")
    public static let notReady = Self(-32000, "page not initialized")
    public static let closed = Self(-32000, "page closed or replaced")
    public static let failed = Self(-32000, "request failed")
}

/// Versioned JSON-RPC adapter for the local, network-disabled WebKit document.
/// Cloud resource resolution and App reply submission require separate capabilities.
public enum AgentArtifactPageProtocol {
    public static let version = "2026-01-26"
    public static let maximumPayload = 64 * 1024

    public struct Request: Sendable {
        public let id: JSONValue?
        public let method: String
        public let params: JSONValue
        public var cacheKey: String? {
            guard let id else { return nil }
            return "rpc:" + ((try? id.encodedText()) ?? "")
        }
    }

    public static func parse(_ value: JSONValue, nonce: String, revision: String) throws -> Request {
        guard let fields = value.objectValue, value["jsonrpc"]?.stringValue == "2.0",
              Set(fields.keys).isSubset(of: ["jsonrpc", "id", "method", "params", "nonce", "revision"]),
              value["nonce"]?.stringValue == nonce else {
            throw AgentArtifactRPCError(-32600, "invalid request or instance")
        }
        guard value["revision"]?.stringValue == revision else {
            throw AgentArtifactRPCError(-32602, "stale resource revision")
        }
        guard let method = value["method"]?.stringValue, !method.isEmpty, method.utf8.count <= 128 else {
            throw AgentArtifactRPCError(-32600, "invalid method")
        }
        let params = value["params"] ?? .object([:])
        guard params.objectValue != nil,
              try params.encodedText().utf8.count <= maximumPayload else { throw AgentArtifactRPCError.invalid }
        var id = value["id"]
        if id == .null { id = nil }
        if let id {
            switch id {
            case .string(let text):
                guard !text.isEmpty, text.utf8.count <= 128 else { throw AgentArtifactRPCError.invalid }
            case .number(let number):
                guard number.isFinite, number == number.rounded(), abs(number) < 9_007_199_254_740_992 else {
                    throw AgentArtifactRPCError.invalid
                }
            default: throw AgentArtifactRPCError.invalid
            }
        }
        return Request(id: id, method: method, params: params)
    }

    public static func nativeOperation(_ request: Request) throws -> (String, String, JSONValue) {
        let params = request.params
        switch request.method {
        case "tools/list": return ("tools_list", "", [:])
        case "tools/call":
            guard let name = params["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.utf8.count <= 128,
                  (params["arguments"] ?? .object([:])).objectValue != nil else {
                throw AgentArtifactRPCError.invalid
            }
            return ("tools_call", name, params["arguments"] ?? [:])
        case "tapnow/getWidgetState": return ("get_state", "", [:])
        case "tapnow/setWidgetState":
            guard let state = params["state"], state.objectValue != nil else { throw AgentArtifactRPCError.invalid }
            return ("set_state", "", state)
        case "tapnow/validateAppReply":
            return ("app_reply_validate", "", try appReplyProjection(params))
        case "tapnow/getAppReplyRunStatus":
            guard Set(params.objectValue?.keys.map { $0 } ?? []) == ["run_id"],
                  let run = params["run_id"]?.stringValue, !run.isEmpty, run.utf8.count <= 128 else {
                throw AgentArtifactRPCError.invalid
            }
            return ("app_reply_status", "", params)
        case "ui/message":
            guard let details = params["details"], details["type"] == "app_reply" else {
                throw AgentArtifactRPCError.unsupported
            }
            return ("app_reply", "", try appReplyProjection(details))
        case "ui/update-model-context":
            guard let content = params["content"]?.arrayValue, !content.isEmpty,
                  content.allSatisfy({ $0["type"]?.stringValue == "text" && $0["text"]?.stringValue != nil }) else {
                throw AgentArtifactRPCError.invalid
            }
            let text = content.compactMap { $0["text"]?.stringValue }.joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentArtifactRPCError.invalid
            }
            return ("model_context", "", ["content": .array(content)])
        default: throw AgentArtifactRPCError.unsupported
        }
    }

    /// The native host supplies manifest/origin authority. Page fields only describe the reply.
    private static func appReplyProjection(_ value: JSONValue) throws -> JSONValue {
        guard let fields = value.objectValue,
              Set(fields.keys).isSubset(of: ["type", "reply_id", "action", "payload", "expected_manifest_revision"]),
              value["type"] == "app_reply", value["action"] == "previs_reply",
              let id = value["reply_id"]?.stringValue, id.utf8.count == 36,
              let uuid = UUID(uuidString: id), id.lowercased() == uuid.uuidString.lowercased(),
              value["payload"]?.objectValue != nil,
              value["expected_manifest_revision"].map({ $0.stringValue != nil }) ?? true else {
            throw AgentArtifactRPCError.invalid
        }
        var reply = fields
        reply.removeValue(forKey: "type")
        guard try JSONValue.object(reply).encodedText().utf8.count <= 32768 else {
            throw AgentArtifactRPCError.invalid
        }
        return .object(reply)
    }

    public static func result(_ result: JSONValue, method: String) throws -> JSONValue {
        if method == "tools/list" {
            let tools = result["tools"]?.arrayValue ?? []
            return ["tools": .array(tools.compactMap { tool in
                guard let function = tool["function"], let name = function["name"]?.stringValue else { return nil }
                return ["name": .string(name), "description": function["description"] ?? "",
                        "inputSchema": function["parameters"] ?? ["type": "object"]]
            })]
        }
        if method == "tools/call" {
            let content = result["result"] ?? result
            return ["content": [["type": "text", "text": .string(try content.encodedText())]],
                    "structuredContent": content.objectValue == nil ? ["result": content] : content,
                    "isError": .bool(result["status"]?.stringValue == "failed")]
        }
        if ["tapnow/setWidgetState", "ui/update-model-context"].contains(method) { return [:] }
        return result
    }
}
