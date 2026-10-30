import Foundation
import ClipSlotsKit

func runAgentArtifactPageProtocolTests(_ t: TestRunner) {
    let nonce = UUID().uuidString, revision = String(UInt64.max)
    func request(_ method: String, _ params: JSONValue = [:], id: JSONValue = "call") -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params,
         "nonce": .string(nonce), "revision": .string(revision)]
    }
    func parse(_ value: JSONValue) throws -> AgentArtifactPageProtocol.Request {
        try AgentArtifactPageProtocol.parse(value, nonce: nonce, revision: revision)
    }
    do {
        let key = try AgentArtifactKey(projectID: "project", canvasID: "canvas", path: "page.html")
        let conversation = UUID(), epoch = UUID(), activation = UUID()
        let identity = AgentArtifactPageIdentity(key: key, conversationID: conversation, revision: UInt64.max,
                                                runtimeEpoch: epoch, canvasEpoch: activation)
        t.check(identity != .init(key: key, conversationID: conversation, revision: UInt64.max,
                                  runtimeEpoch: UUID(), canvasEpoch: activation),
                "native page identity changes on conversation or permission reactivation")
        t.check(identity != .init(key: key, conversationID: conversation, revision: UInt64.max,
                                  runtimeEpoch: epoch, canvasEpoch: UUID()),
                "native page identity changes on canvas reactivation")
        t.equal(identity.revision, UInt64.max, "ephemeral page authority preserves full native revision")
        let parsed = try parse(request("tools/call", ["name": " canvas_overview ", "arguments": ["x": 1]]))
        let native = try AgentArtifactPageProtocol.nativeOperation(parsed)
        t.equal(native.0, "tools_call", "page RPC maps native operation")
        t.equal(native.1, "canvas_overview", "page RPC trims tool name")
        t.equal(native.2, ["x": 1], "page RPC preserves typed arguments")
        t.equal(parsed.cacheKey, "rpc:\"call\"", "page RPC string id uses typed cache identity")
        t.equal(try parse(request("ping", id: 1)).cacheKey, "rpc:1", "page numeric id cannot alias string id")
        let numeric = try parse(request("ping", id: .number(9_007_199_254_740_991)))
        t.check(numeric.id != nil, "page largest safe numeric id roundtrips")
        let invalidIDs: [JSONValue] = [true, [], [:], "", .number(0.5), .number(9_007_199_254_740_992)]
        for id in invalidIDs {
            t.expectThrows("page malformed id rejected") { _ = try parse(request("ping", id: id)) }
        }
        let patches: [[String: JSONValue]] = [
            ["nonce": .string(UUID().uuidString)], ["revision": "18446744073709551614"],
            ["revision": .number(Double(UInt64.max))], ["jsonrpc": "1.0"], ["authority": "another-session"]
        ]
        for patch in patches {
            var fields = request("ping").objectValue ?? [:]
            fields.merge(patch, uniquingKeysWith: { _, next in next })
            t.expectThrows("page stale instance, exact revision or envelope rejected") { _ = try parse(.object(fields)) }
        }
        let text: JSONValue = ["content": [["type": "text", "text": "文🙂\n"], ["type": "text", "text": "尾"]]]
        let context = try AgentArtifactPageProtocol.nativeOperation(parse(request("ui/update-model-context", text)))
        t.equal(context.2, text, "page context preserves complete UTF-8 text blocks")
        let invalidContexts: [JSONValue] = [[:], ["content": [["type": "image", "text": "x"]]],
                                          ["content": [["type": "text", "text": "  "]]], ["content": "text"]]
        for params in invalidContexts {
            t.expectThrows("page context requires text content") {
                _ = try AgentArtifactPageProtocol.nativeOperation(parse(request("ui/update-model-context", params)))
            }
        }
        let size = JSONValue.object(["text": .string(String(repeating: "🙂", count: 16_384))])
        t.expectThrows("page payload limit counts UTF-8 bytes") { _ = try parse(request("tapnow/setWidgetState", size)) }
        t.expectThrows("page tool args cannot be an array") {
            _ = try AgentArtifactPageProtocol.nativeOperation(parse(request("tools/call", ["name": "tool", "arguments": []])))
        }
        t.expectThrows("page source state cannot be an array") {
            _ = try AgentArtifactPageProtocol.nativeOperation(parse(request("tapnow/setWidgetState", ["state": []])))
        }
        t.expectThrows("page does not invent unsupported methods") {
            _ = try AgentArtifactPageProtocol.nativeOperation(parse(request("tapnow/estimateGenerationCost")))
        }
        let result = try AgentArtifactPageProtocol.result(["status": "failed", "result": ["text": "错误🙂"]], method: "tools/call")
        t.equal(result["isError"], true, "page MCP result retains tool failure")
        t.equal(result["structuredContent"], ["text": "错误🙂"], "page MCP result retains structured content")
        let array = try AgentArtifactPageProtocol.result(["result": [1, 2]], method: "tools/call")
        t.equal(array["structuredContent"], ["result": [1, 2]], "page nonobject results retain data in MCP object")
        t.check(try parse(request("ping", id: .null)).id == nil, "page notification has no request cache identity")
        let projection: JSONValue = ["type": "app_reply", "reply_id": .string(UUID().uuidString),
                                    "action": "previs_reply", "payload": ["choice": "原始🙂"]]
        let reply = try AgentArtifactPageProtocol.nativeOperation(parse(request("ui/message", ["details": projection])))
        t.equal(reply.0, "app_reply", "structured page reply reaches dedicated operation")
        t.equal(reply.2["payload"], projection["payload"], "structured projection preserves typed reply payload")
        t.check(reply.2["type"] == nil, "transport reply body omits page projection tag")
        for patch in [["originRunID": "page-selected"], ["reply_id": "------------------------------------"],
                      ["payload": .array([])], ["action": "chat"]] as [[String: JSONValue]] {
            var fields = projection.objectValue ?? [:]
            fields.merge(patch, uniquingKeysWith: { _, next in next })
            t.expectThrows("page cannot select origin or send malformed app reply") {
                _ = try AgentArtifactPageProtocol.nativeOperation(parse(request("ui/message", ["details": .object(fields)])))
            }
        }
    } catch { t.check(false, "page protocol fixtures: \(error)") }
}
