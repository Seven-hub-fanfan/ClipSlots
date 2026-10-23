import Foundation
import ClipSlotsKit

private final class CanvasActionEmptyTools: AgentToolExecuting {
    func specs() -> [AgentToolSpec] { [] }
    func execute(call: AgentToolCall) async -> AgentToolResult { .failure("undeclared") }
}

private actor CanvasActionHostFixture {
    var calls: [String] = []
    func perform(_ call: AgentToolCall, _ input: JSONValue) -> JSONValue {
        calls.append(call.name)
        if call.name == "canvas_generate" {
            return ["ok": false, "summary": "服务失败，未生成产物"]
        }
        return ["ok": true, "node_id": "native-node", "node_revision": "v1",
                "graph_revision": "graph-v1", "history_id": "undo-v1",
                "summary": "CANVAS_NATIVE_BODY_ACK", "body_text": input["text"] ?? ""]
    }
    func snapshot() -> [String] { calls }
}

private actor CanvasLayoutApprovalFixture {
    var request: AgentInteraction?
    func receive(_ value: AgentInteraction) { request = value }
    func current() -> AgentInteraction? { request }
}

func runCanvasAgentActionTests(_ t: TestRunner) {
    let checks: [(Bool, String)] = smokeAwait {
        var checks: [(Bool, String)] = []
        func call(_ name: String, _ input: JSONValue) throws -> AgentToolCall {
            .init(id: UUID().uuidString, name: name, argumentsJSON: try input.encodedText())
        }
        let create: JSONValue = ["kind": "text", "text": "海边灯塔", "x": 100, "y": 120]
        let layout: JSONValue = ["node_ids": ["first", "second"], "layout": "grid",
                                 "expected_graph_revision": "graph-v1"]
        do {
            for mode in AgentAccessMode.allCases {
                for automatic in [false, true] {
                    let host = CanvasActionHostFixture()
                    let tools = CanvasAgentActionTools(base: CanvasActionEmptyTools(), mode: mode,
                        automaticApproval: automatic, onInteraction: { request in
                            _ = try? await request.respond(["decision": "decline"])
                        }, perform: { call, input in await host.perform(call, input) })
                    let result = await tools.execute(call: try call("canvas_create_node", create))
                    let arranged = await tools.execute(call: try call("canvas_layout_nodes", layout))
                    let allowed = mode != .allDirectoriesReadOnly && automatic
                    let calls = await host.snapshot()
                    checks.append((tools.specs().contains { $0.name == "canvas_create_node" }
                        == (mode != .allDirectoriesReadOnly),
                        "canvas schema \(mode.rawValue) approval=\(automatic)"))
                    checks.append((result.isFailure != allowed && arranged.isFailure != allowed
                        && calls.count == (allowed ? 2 : 0),
                        "canvas actual dispatch \(mode.rawValue) approval=\(automatic)"))
                    checks.append((tools.specs().contains { $0.name == "canvas_layout_nodes" }
                        == (mode != .allDirectoriesReadOnly),
                        "canvas layout schema \(mode.rawValue) approval=\(automatic)"))
                    let catalog = await tools.execute(call: try call("canvas_list_models", [:]))
                    let readerCalls = await host.snapshot()
                    checks.append((!catalog.isFailure && readerCalls.last == "canvas_list_models"
                        && readerCalls.count == calls.count + 1,
                        "canvas model catalog is read-only \(mode.rawValue) approval=\(automatic)"))
                }
            }
            let host = CanvasActionHostFixture()
            let tools = CanvasAgentActionTools(base: CanvasActionEmptyTools(), mode: .fullAccess,
                onInteraction: { _ in }, perform: { call, input in await host.perform(call, input) })
            let invalid = await tools.execute(call: try call("canvas_create_node",
                ["kind": "image", "text": "", "x": 100001, "y": 0]))
            let invalidCalls = await host.snapshot()
            checks.append((invalid.isFailure && invalidCalls.isEmpty,
                           "canvas invalid schema never reaches host"))
            let malformedLayouts: [JSONValue] = [
                ["node_ids": [], "layout": "grid", "expected_graph_revision": "g"],
                ["node_ids": ["a"], "layout": "grid", "expected_graph_revision": "g"],
                ["node_ids": ["a", "a"], "layout": "grid", "expected_graph_revision": "g"],
                ["node_ids": .array((0..<51).map { .string("n\($0)") }), "layout": "grid", "expected_graph_revision": "g"],
                ["node_ids": ["a", "b"], "layout": "diagonal", "expected_graph_revision": "g"],
                ["node_ids": ["a", "b"], "layout": "grid"],
                ["node_ids": ["a", "b"], "layout": "grid", "expected_graph_revision": "g", "shell": "unused"]
            ]
            var invalidLayoutsDenied = true
            for input in malformedLayouts {
                let result = await tools.execute(call: try call("canvas_layout_nodes", input))
                invalidLayoutsDenied = invalidLayoutsDenied && result.isFailure
            }
            let afterMalformed = await host.snapshot()
            checks.append((invalidLayoutsDenied && afterMalformed.isEmpty,
                           "layout invalid count mode missing revision and extra fields never dispatch"))
            let approvalHost = CanvasActionHostFixture()
            let accepted = CanvasAgentActionTools(base: CanvasActionEmptyTools(), mode: .selectedDirectories,
                onInteraction: { request in _ = try? await request.respond(["decision": "accept"]) },
                perform: { call, input in await approvalHost.perform(call, input) })
            let acceptedLayout = await accepted.execute(call: try call("canvas_layout_nodes", layout))
            let acceptedCalls = await approvalHost.snapshot()
            checks.append((!acceptedLayout.isFailure && acceptedCalls == ["canvas_layout_nodes"],
                           "accepted layout approval dispatches once"))
            let pending = CanvasLayoutApprovalFixture(), cancelHost = CanvasActionHostFixture()
            let cancellable = CanvasAgentActionTools(base: CanvasActionEmptyTools(), mode: .selectedDirectories,
                onInteraction: { request in await pending.receive(request) },
                perform: { call, input in await cancelHost.perform(call, input) })
            let cancelCall = try call("canvas_layout_nodes", layout)
            let task = Task { await cancellable.execute(call: cancelCall) }
            for _ in 0..<100 {
                if await pending.current() != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let request = await pending.current()
            task.cancel()
            let cancelled = await task.value
            let cancelCalls = await cancelHost.snapshot()
            checks.append((request?.params["title"] == "整理节点布局" && request?.isPending == false
                && cancelled.isFailure && cancelled.content.contains("CANCELLED") && cancelCalls.isEmpty,
                           "cancelled layout invalidates pending approval and never dispatches"))
            let generation = await tools.execute(call: try call("canvas_generate",
                ["node_ids": ["native-node"], "expected_graph_revision": "graph-v1"]))
            checks.append((generation.isFailure && generation.content.contains("未生成"),
                           "canvas provider failure remains a failed tool result"))

            let sseCall: JSONValue = ["choices": [["delta": ["tool_calls": [[
                "index": 0, "id": "create-native", "type": "function",
                "function": ["name": "canvas_create_node", "arguments": .string(try create.encodedText())]
            ]]], "finish_reason": "tool_calls"]]]
            let transport = AgentScriptedTransport(steps: [
                .sse("data: \(try sseCall.encodedText())\n\ndata: [DONE]\n\n"),
                .sse("data: {\"choices\":[{\"delta\":{\"content\":\"已创建节点\"}}]}\n\ndata: [DONE]\n\n")
            ])
            let service = AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture"))
            let messages = try await service.run(history: [.init(role: .user, content: "创建灯塔文本节点")],
                config: AgentConfig(), tools: tools, onEvent: { _ in })
            let published = transport.requestJSON(at: 0)?["tools"]?.arrayValue ?? []
            checks.append((published.contains { $0["function"]?["name"] == "canvas_create_node" },
                           "actual AgentService SSE request publishes canvas writers"))
            checks.append((published.contains { $0["function"]?["name"] == "canvas_layout_nodes" },
                           "actual AgentService SSE request publishes native batch layout"))
            checks.append((messages.contains { $0.role == .tool && !$0.isFailure
                && $0.toolCallId == "create-native" && $0.content.contains("CANVAS_NATIVE_BODY_ACK") },
                           "actual AgentService SSE loop dispatches and returns host receipt"))
            checks.append((transport.requestJSON(at: 1)?["messages"]?.arrayValue?.contains {
                $0["role"] == "tool" && $0["content"]?.stringValue?.contains("CANVAS_NATIVE_BODY_ACK") == true
            } == true, "actual AgentService next request receives genuine tool result"))

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-tika-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let binary = root.appendingPathComponent("fixture")
            try Data(#"""
            #!/bin/sh
            case "$*" in
              *CANVAS_NATIVE_BODY_ACK*)
                printf '%s\n' '{"type":"text-delta","text":"真实画布工具已执行"}' '{"type":"finish"}' ;;
              *)
                printf '%s\n' '{"type":"text-delta","text":"<clipslots-workspace-call>{\"name\":\"canvas_create_node\",\"arguments\":{\"kind\":\"text\",\"text\":\"灯塔\",\"x\":100,\"y\":120}}</clipslots-workspace-call>"}' '{"type":"finish"}' ;;
            esac
            """#.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let tikaHost = CanvasActionHostFixture()
            let tikaTools = CanvasAgentActionTools(base: CanvasActionEmptyTools(), mode: .fullAccess,
                onInteraction: { _ in }, perform: { call, input in await tikaHost.perform(call, input) })
            let backend = TikaCLIService(config: .init(cliPath: binary.path, maxToolTurns: 3),
                localRunner: { _, _ in .init(exitCode: 99, stdout: "CLI_BYPASS", stderr: "", timedOut: false) })
            let output = try await backend.run(history: [.init(role: .user, content: "新建画布节点")],
                config: AgentConfig(), tools: tikaTools, onEvent: { _ in })
            let tikaCalls = await tikaHost.snapshot()
            checks.append((tikaCalls == ["canvas_create_node"] && output.last?.content == "真实画布工具已执行",
                           "actual Tika subprocess canvas bridge works without working directory"))
            checks.append((output.contains { $0.role == .tool && !$0.isFailure
                && $0.toolName == "canvas_create_node" && $0.content.contains("CANVAS_NATIVE_BODY_ACK") },
                           "actual Tika canvas call has paired host receipt"))
            checks.append((!output.filter { $0.role == .assistant }.contains {
                $0.content.contains("clipslots-workspace-call") || $0.content.contains("CLI_BYPASS")
            }, "actual Tika canvas payload stays out of assistant bubbles and CLI"))
            let undeclared = AgentDirectoryToolBridge.calls(in:
                #"<clipslots-workspace-call>{"name":"canvas_unknown","arguments":{}}</clipslots-workspace-call>"#)
            let refused = await tikaTools.execute(call: undeclared[0])
            let finalTikaCalls = await tikaHost.snapshot()
            checks.append((refused.isFailure && finalTikaCalls == tikaCalls,
                           "undeclared canvas bridge cannot dispatch arbitrary host operations"))
        } catch { checks.append((false, "canvas backend integration: \(error)")) }
        return checks
    }
    for (passed, name) in checks { t.check(passed, name) }
}
