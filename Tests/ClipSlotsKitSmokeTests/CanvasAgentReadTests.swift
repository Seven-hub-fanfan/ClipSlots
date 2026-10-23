import Foundation
import ClipSlotsKit

func runCanvasAgentReadTests(_ t: TestRunner) {
    runCanvasAgentActionTests(t)
    do {
        let prompt = CanvasNode(pageId: "p", groupId: "batch", slot: 1, kind: .text, x: 0, y: 0)
        let image = CanvasNode(pageId: "p", groupId: "batch", slot: 2, kind: .image, x: 400, y: 0)
        var sibling = CanvasNode(pageId: "p", groupId: "batch", slot: 3, kind: .image, x: 800, y: 0)
        sibling.parentNodeId = image.id
        sibling.generationSourceID = image.id
        let inputs = [
            CanvasEdge(fromNodeId: prompt.id, toNodeId: image.id, role: .prompt),
            CanvasEdge(fromNodeId: prompt.id, toNodeId: sibling.id, role: .prompt)
        ]
        let graph = CanvasDocument(nodes: [prompt, image, sibling], edges: inputs)
        let reloaded = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(graph))
        t.equal(reloaded.edges, inputs, "batch reload preserves identical original upstream inputs")
        t.check(!reloaded.edges.contains { $0.fromNodeId == image.id && $0.toNodeId == sibling.id },
                "batch membership cannot invent first output as sibling reference")
        let explicit = CanvasEdge(fromNodeId: image.id, toNodeId: sibling.id, role: .auto)
        let connected = CanvasDocument(nodes: [prompt, image, sibling], edges: inputs + [explicit])
        t.equal(try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(connected)).edges,
                inputs + [explicit], "batch migration retains deliberately connected reference")
        sibling.generationSourceID = nil
        t.check(CanvasEdgeGraph.migratedFromParentLinks(nodes: [prompt, image, sibling], edges: inputs)
            .contains { $0.fromNodeId == image.id && $0.toNodeId == sibling.id },
                "legacy real parent link still migrates without batch membership")
    } catch { t.check(false, "batch reload regression: \(error)") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-reader-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let text = String(repeating: "镜头🙂e\u{301}", count: 2100)
    let nodes = (1...85).map { slot in
        CanvasNode(pageId: "p", groupId: "g", slot: slot, kind: .text, x: 0, y: 0)
    }
    var facts = nodes.enumerated().map {
        CanvasWorkflowFacts(node: $0.element, title: "节点\($0.offset)", body: $0.offset == 0 ? text : "小段正文",
                            bodyRevision: "v1")
    }
    facts[2].bodyAvailable = false
    let edges = (1..<nodes.count).map {
        CanvasEdge(fromNodeId: nodes[$0 - 1].id, toNodeId: nodes[$0].id, role: .prompt)
    }
    let graph = CanvasWorkflowSnapshot(projectID: "reader-A", facts: facts, edges: edges,
                                        selectionIDs: [nodes[1].id])
    let snapshot = CanvasAgentSnapshot(graph: graph, runs: [])
    let tools = CanvasAgentReadTools(snapshot: snapshot)
    func call(_ name: String, _ fields: [String: JSONValue] = [:]) -> AgentToolResult {
        var fields = fields
        if fields["snapshot_id"] == nil { fields["snapshot_id"] = .string(graph.snapshotID.uuidString) }
        let arguments = (try? JSONValue.object(fields).encodedText()) ?? "{}"
        return smokeAwait { await tools.execute(call: .init(id: UUID().uuidString, name: name, argumentsJSON: arguments)) }
    }
    func json(_ result: AgentToolResult) -> JSONValue { (try? JSONValue.decode(jsonText: result.content)) ?? .null }
    t.check(AgentPreviewTools.restricted(tools) === tools, "preview gate accepts immutable concrete reader")
    t.check(AgentPreviewTools.restricted(SmokeToolExecutor()).specs().isEmpty, "preview gate cannot admit general executor")
    t.check(call("write_slot").isFailure && call("shell").isFailure, "canvas reader refuses mutation and shell")
    t.check(call("canvas_overview", ["snapshot_id": "other"]).isFailure, "reader rejects stale snapshot ID")
    t.check(call("canvas_overview", ["path": "/etc/passwd"]).isFailure, "reader rejects filesystem parameter")
    t.equal(json(call("canvas_overview"))["node_count"]?.intValue, 85, "overview sees beyond three explicit references")
    let first = call("canvas_nodes", ["limit": 40])
    t.equal(json(first)["nodes"]?.arrayValue?.count, 40, "directory has bounded page")
    t.equal(json(first)["next_offset"]?.intValue, 40, "directory continuation explicit")
    t.check(!first.content.contains("小段正文") && !first.content.contains("镜头"), "directory never silently embeds full body")
    let last = call("canvas_nodes", ["offset": 80, "limit": 40])
    t.equal(json(last)["nodes"]?.arrayValue?.count, 5, "large graph last page has remainder")
    t.check(json(last)["next_offset"] == .null, "last directory page terminates")
    t.check(call("canvas_nodes", ["offset": -1]).isFailure
            && call("canvas_nodes", ["limit": 41]).isFailure
            && call("canvas_nodes", ["offset": .number(1e100)]).isFailure, "pagination rejects negative excessive and overflowing values")
    let upstream = json(call("canvas_nodes", ["scope": "upstream"]))
    t.equal(Set(upstream["nodes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []),
            Set(nodes.prefix(2).map(\.id)), "dependency read uses frozen selection and excludes unrelated nodes")
    t.check(call("canvas_nodes", ["scope": "upstream", "node_ids": ["foreign"]]).isFailure, "unknown dependency roots rejected")
    let selectedEdges = json(call("canvas_edges", ["scope": "selection"]))
    t.equal(selectedEdges["edges"]?.arrayValue?.count, 2, "selected graph exposes both cross-boundary edges")
    t.check(selectedEdges["edges"]?.arrayValue?.allSatisfy { $0["boundary"]?.boolValue == true } == true,
            "cross-boundary edges explicitly marked")
    let edgePage = call("canvas_edges", ["offset": 80])
    t.equal(json(edgePage)["edges"]?.arrayValue?.count, 4, "edge pagination preserves complete graph")
    var offset = 0, restored = "", receipts: [CanvasReadReceipt] = []
    repeat {
        let page = call("canvas_read_node", ["node_id": .string(nodes[0].id), "field": "body",
                                            "offset": .number(Double(offset)), "limit": 4000])
        restored += json(page)["chunk"]?.stringValue ?? ""
        if let receipt = CanvasReadReceipt.decode(result: page.content) { receipts.append(receipt) }
        guard let next = json(page)["next_offset"]?.intValue, next > offset else { break }
        offset = next
    } while offset < 50_000
    t.equal(restored, text, "long Chinese emoji and combining characters roundtrip across chunks")
    t.check(CanvasReadReceipt.isComplete(receipts), "contiguous receipts prove full body delivery")
    t.check(!CanvasReadReceipt.isComplete(Array(receipts.dropFirst())), "tail read alone cannot claim full coverage")
    t.check(!CanvasReadReceipt.isComplete(Array(receipts.prefix(1))), "partial prefix cannot claim complete body")
    t.check(call("canvas_read_node", ["node_id": .string(nodes[2].id), "field": "body"]).isFailure,
            "missing body remains distinct from empty")
    t.check(call("canvas_read_node", ["node_id": "foreign", "field": "body"]).isFailure, "foreign node rejected")
    t.check(call("canvas_read_node", ["node_id": .string(nodes[0].id), "field": "file"]).isFailure, "arbitrary fields rejected")
    let noRun = call("canvas_read_run", ["node_id": .string(nodes[0].id)])
    t.check(!noRun.isFailure && json(noRun)["available"]?.boolValue == false, "unrecorded history explicitly unavailable")
    let turn = CanvasAgentTurn(snapshot: graph, supportsTools: true)
    let message = AgentMessage(role: .user, content: "总结工作流", canvasTurn: turn)
    t.check(message.wireContent.contains(graph.snapshotID.uuidString) && !message.wireContent.contains(text),
            "wire includes snapshot identity and bounded directory without full graph dump")
    var fallback = turn
    fallback.supportsTools = false
    t.check(fallback.wireText.contains("不支持画布读取工具"), "limited backend states actual context capability")
    do {
        let storage = CanvasAgentSnapshotStore(root: root)
        try storage.save(snapshot)
        let loaded = try CanvasAgentSnapshotStore(root: root).load(project: graph.projectID, id: graph.snapshotID)
        t.equal(loaded.graph, graph, "snapshot survives restart for exact retry")
        t.expectThrows("snapshot cannot load across project boundary") {
            _ = try storage.load(project: "reader-B", id: graph.snapshotID)
        }
        let roundtrip = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(message))
        t.equal(roundtrip.canvasTurn, turn, "turn metadata persists in older compatible message model")
        let old = AgentMessage(role: .user, content: "legacy")
        t.check(try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(old)).canvasTurn == nil,
                "legacy messages remain readable without a snapshot")
        let runStore = GenerationRunStore(root: root)
        let context = GenerationRunContext(snapshot: graph, node: nodes[0], resourceIDs: [:])
        let request = GenerationRequestRecord(CrateImageRequest(model: "fixture", prompt: "实际请求", ratio: "1:1"), resourceIDs: [:])
        let attempt = try runStore.beginAttempt(context: context, requested: request, effective: request)
        try runStore.finishAttempt(context: context, attemptID: attempt, status: .accepted, taskID: "fixture-task")
        let frozen = CanvasAgentSnapshot(graph: graph, runs: runStore.runs(project: graph.projectID))
        try runStore.updateTask(project: graph.projectID, taskID: "fixture-task", outcome: "succeeded")
        let frozenTools = CanvasAgentReadTools(snapshot: frozen)
        let args = try JSONValue.object(["snapshot_id": .string(graph.snapshotID.uuidString),
            "node_id": .string(nodes[0].id)]).encodedText()
        let result = smokeAwait { await frozenTools.execute(call: .init(id: "run", name: "canvas_read_run", argumentsJSON: args)) }
        t.check(json(result)["chunk"]?.stringValue?.contains("\"outcome\":\"accepted\"") == true,
                "later live run transitions cannot change frozen history")
        t.check(CanvasAgentSnapshot(graph: CanvasWorkflowSnapshot(projectID: "other", facts: facts, edges: edges,
            selectionIDs: []), runs: frozen.runs).runs.isEmpty, "snapshot filters foreign run records")
        let blocked = root.appendingPathComponent("file")
        try Data([1]).write(to: blocked)
        t.expectThrows("snapshot disk failure surfaced before send") {
            try CanvasAgentSnapshotStore(root: blocked).save(snapshot)
        }
    } catch { t.check(false, "canvas read persistence: \(error)") }

    // Actual DeepSeek loop must retain the reader while rejecting an invented write.
    let args = #"{"snapshot_id":"\#(graph.snapshotID.uuidString)","node_id":"\#(nodes[1].id)","field":"body"}"#
    let callData: JSONValue = ["choices": [["delta": ["tool_calls": [[
        "index": 0, "id": "read", "type": "function",
        "function": ["name": "canvas_read_node", "arguments": .string(args)]
    ]]], "finish_reason": "tool_calls"]]]
    let transport = AgentScriptedTransport(steps: [
        .sse("data: \((try? callData.encodedText()) ?? "{}")\n\ndata: [DONE]\n\n"),
        .sse("data: {\"choices\":[{\"delta\":{\"content\":\"基于节点正文的总结\"}}]}\n\ndata: [DONE]\n\n")
    ])
    let service = AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture"))
    let result: [AgentMessage] = smokeAwait {
        var config = AgentConfig(); config.canvasPreviewOnly = true
        return (try? await service.run(history: [message], config: config, tools: tools, onEvent: { _ in })) ?? []
    }
    t.check(result.contains { $0.role == .tool && !$0.isFailure && $0.content.contains("小段正文") },
            "DeepSeek preview runs only immutable canvas tool")
    t.equal(transport.requestJSON(at: 0)?["tools"]?.arrayValue?.count, 8, "DeepSeek request advertises exact read catalog")
    runCanvasStructureCopyTests(t)
    do {
        let child = CanvasNodeGroup(id: "child", name: "子组", nodeIDs: [nodes[0].id],
            containerFrame: CGRect(x: 0, y: 0, width: 400, height: 300), parentGroupID: "root")
        let parent = CanvasNodeGroup(id: "root", name: "父组", nodeIDs: [nodes[1].id],
            containerFrame: CGRect(x: -30, y: -30, width: 800, height: 500))
        let pile = CanvasPile(id: "pile", memberIDs: [nodes[0].id, nodes[1].id], at: .zero, groupID: "root")
        let grouped = CanvasWorkflowSnapshot(projectID: "reader-A", facts: facts, edges: edges,
            selectionIDs: ["root"], groups: [parent, child], piles: [pile])
        let reader = CanvasAgentReadTools(snapshot: .init(graph: grouped, runs: []))
        func read(_ name: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
            var args = fields; args["snapshot_id"] = .string(grouped.snapshotID.uuidString)
            let response = smokeAwait { await reader.execute(call: .init(id: "group",
                name: name, argumentsJSON: (try? JSONValue.object(args).encodedText()) ?? "{}")) }
            return json(response)
        }
        t.equal(read("canvas_overview")["group_count"]?.intValue, 2, "overview exposes actual container count")
        t.equal(read("canvas_groups", ["limit": 1])["next_offset"]?.intValue, 1, "group directory pages with receipts")
        t.equal(read("canvas_piles")["piles"]?.arrayValue?.first?["memberIDs"], try JSONValue.decode(jsonText:
            String(decoding: JSONEncoder().encode(pile.memberIDs), as: UTF8.self)), "pile order remains bottom to top")
        t.equal(read("canvas_read_group", ["group_id": "root"])["nodes"]?.arrayValue?.count, 2,
                "group read expands nested members without dumping body")
        t.equal(read("canvas_nodes", ["scope": "selection"])["nodes"]?.arrayValue?.count, 2,
                "container selection expands in dependency tools")
        t.check(read("canvas_read_group", ["group_id": "foreign"])["ok"]?.boolValue != true,
                "group reader rejects foreign identity")
        var moved = parent; moved.containerFrame = parent.containerFrame?.offsetBy(dx: 200, dy: 100)
        let layoutOnly = CanvasWorkflowSnapshot(projectID: "reader-A", facts: facts, edges: edges,
            selectionIDs: [], groups: [moved, child], piles: [pile])
        t.equal(grouped.graphRevision, layoutOnly.graphRevision, "container movement preserves semantic revision")
        var reordered = pile; reordered.memberIDs.reverse()
        let structural = CanvasWorkflowSnapshot(projectID: "reader-A", facts: facts, edges: edges,
            selectionIDs: [], groups: [parent, child], piles: [reordered])
        t.check(grouped.graphRevision != structural.graphRevision, "pile ordering invalidates semantic context")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grouped)) as! [String: Any]
        oldJSON.removeValue(forKey: "groups"); oldJSON.removeValue(forKey: "piles"); oldJSON["schemaVersion"] = 1
        let old = try JSONDecoder().decode(CanvasWorkflowSnapshot.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        t.check(old.groups.isEmpty && old.piles.isEmpty && old.graphRevision == grouped.graphRevision,
                "legacy snapshot loads without changing its captured revision")
    } catch { t.check(false, "container reader tests: \(error)") }
}
