import Foundation
@testable import ClipSlotsKit

private actor ReadbackGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
private actor ReadbackReader: AgentCanvasSnapshotReading {
    let partial: AgentCanvasReadbackSnapshot
    let full: AgentCanvasReadbackSnapshot
    let gate: ReadbackGate?
    private(set) var nodeQueries: [[String]] = []
    private(set) var edgeQueries: [[String]] = []
    private(set) var fullQueries = 0
    init(partial: AgentCanvasReadbackSnapshot, full: AgentCanvasReadbackSnapshot? = nil, gate: ReadbackGate? = nil) {
        self.partial = partial; self.full = full ?? partial; self.gate = gate
    }
    func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        nodeQueries.append(ids)
        await gate?.wait()
        try Task.checkCancellation()
        return partial
    }
    func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        edgeQueries.append(ids)
        await gate?.wait()
        try Task.checkCancellation()
        return partial
    }
    func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot {
        fullQueries += 1; return full
    }
}
private actor SerialReadbackReader: AgentCanvasSnapshotReading {
    let node: CanvasNode
    let gate: ReadbackGate
    private(set) var starts: [String: Int] = [:]
    private var active: [String: Int] = [:]
    private(set) var maximum: [String: Int] = [:]
    init(node: CanvasNode, gate: ReadbackGate) { self.node = node; self.gate = gate }
    func snapshot(projectID: String, nodeIDs: [String], edgeIDs: [String]) async throws -> AgentCanvasReadbackSnapshot {
        starts[projectID, default: 0] += 1
        let sequence = starts[projectID]!
        active[projectID, default: 0] += 1
        maximum[projectID] = max(maximum[projectID] ?? 0, active[projectID]!)
        defer { active[projectID, default: 0] -= 1 }
        if projectID == "project" && sequence == 1 { await gate.wait() }
        try Task.checkCancellation()
        var value = node; value.width = Double(sequence) * 100
        return .init(projectID: projectID, nodes: [value])
    }
    func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        throw AgentGatewayError.malformedPayload
    }
    func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        throw AgentGatewayError.malformedPayload
    }
    func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot {
        throw AgentGatewayError.malformedPayload
    }
}
private func readbackCase(_ t: TestRunner, _ name: String,
                          _ body: @escaping @Sendable () async throws -> [(Bool, String)]) {
    let result: [(Bool, String)] = smokeAwait {
        do { return try await body() }
        catch { return [(false, "\(name) fixture: \(type(of: error))")] }
    }
    for (pass, assertion) in result { t.check(pass, "READBACK \(name): \(assertion)") }
}
private func awaitReadbacks(_ batcher: AgentCanvasReadbackBatcher, _ count: Int) async throws {
    for _ in 0..<20_000 {
        if await batcher.pendingCount == count { return }
        await Task.yield()
    }
    throw AgentGatewayError.interrupted
}

func runAgentCanvasReadbackTests(_ t: TestRunner) {
    runAgentCanvasFullReadbackTests(t)
    let a = CanvasNode(pageId: "page", groupId: "slots", slot: 1, kind: .video, x: 12, y: 40)
    let b = CanvasNode(pageId: "page", groupId: "slots", slot: 2, kind: .text, x: 500, y: 20)
    let edge = CanvasEdge(fromNodeId: a.id, toNodeId: b.id)
    @Sendable func request(_ nodes: [String], _ edges: [String] = [], fallback: Bool = false) throws -> AgentCanvasReadbackRequest {
        try .init(projectID: "project", conversationID: "conversation", runID: "run", key: UUID().uuidString,
                  nodeIDs: nodes, edgeIDs: edges, allowsFallback: fallback)
    }
    func notice(tool: String, response: JSONValue, status: String = "completed") throws -> AgentCanvasReadbackRequest? {
        try AgentCanvasChangeNotice.request(event: ["tool": .string(tool), "status": .string(status),
            "tool_call_id": "call", "response": response], projectID: "project", conversationID: "conversation", runID: "run")
    }
    var stage = "notice"
    do {
        t.equal(AgentCanvasChangeNotice.snapshotTools.count, 26, "READBACK source list has 26 verified tools")
        let ordinary = try notice(tool: "update_canvas_node", response: [
            "node_id": .string(a.id), "connection_ids": [.string(edge.id)]])!
        t.equal(ordinary.nodeIDs, [a.id], "READBACK ordinary completed tool extracts node ID")
        t.equal(ordinary.edgeIDs, [edge.id], "READBACK ordinary completed tool extracts edge ID")
        t.check(!ordinary.allowsFallback, "READBACK ordinary tools do not acquire full-canvas fallback")
        t.check(try notice(tool: "update_canvas_node", response: ["node_id": .string(a.id)], status: "failed") == nil,
                "READBACK failed ordinary tool does not trigger readback")
        t.check(try notice(tool: "canvas_operator_edit", response: ["action": "delete", "node_ids": [.string(a.id)]]) == nil,
                "READBACK delete notice does not pretend deletion was synchronized")
        t.check(try notice(tool: "canvas_operator_connect", response: ["action": "disconnect", "edge_id": .string(edge.id)]) == nil,
                "READBACK disconnect notice is reserved for explicit mutation")
        t.check(try notice(tool: "unlisted_tool", response: ["node_id": .string(a.id)]) == nil,
                "READBACK unlisted tools cannot request canvas authority")
        let cli = try notice(tool: "Bash", response: ["canvas_changed": [
            "canvasRef": "canvas/project", "nodeIds": [.string(a.id), .string(a.id)],
            "edgeId": .string(edge.id)]], status: "failed")!
        t.check(cli.allowsFallback && cli.nodeIDs == [a.id] && cli.edgeIDs == [edge.id],
                "READBACK failed CLI may read partial effects; aliases are deduplicated")
        let escaped = #"output "_notice": {"canvas_changed":{"canvas_id":"project","node_ids":["first"],"text":"escaped \" } [ brace"}} end "_notice": {"canvas_changed":{"nodeId":"second"}}"#
        let fromText = try notice(tool: "tapnow_cli", response: ["text": .string(escaped)])!
        t.equal(fromText.nodeIDs, ["first", "second"], "READBACK balanced escaped text notices merge correctly")
        t.expectThrows("READBACK conflicting canvas notices fail closed") {
            _ = try notice(tool: "Bash", response: ["text":
                #""_notice":{"canvas_changed":{"canvas_id":"project","node_id":"one"}} "_notice":{"canvas_changed":{"canvas_id":"other","node_id":"two"}}"#])
        }
        t.expectThrows("READBACK conflicting aliases inside one notice fail closed") {
            _ = try notice(tool: "Bash", response: ["canvas_changed": [
                "canvas_id": "project", "canvasId": "other", "node_id": .string(a.id)]])
        }
        t.expectThrows("READBACK ecommerce requires explicit canvas identity") {
            _ = try notice(tool: "ecommerce_photoset_generate", response: ["items": [["node_id": .string(a.id)]]])
        }
        let bounded = (0..<300).map { #""_notice":{"canvas_changed":{"node_id":"n"# + String($0) + #""}}"# }.joined()
        t.equal(try notice(tool: "Bash", response: ["text": .string(bounded)])?.nodeIDs.count, 32,
                "READBACK text parser caps valid notices at 32")
        t.expectThrows("READBACK total text budget rejects huge notice input") {
            _ = try notice(tool: "Bash", response: ["text": .string(String(repeating: "x", count: 2 * 1024 * 1024 + 1))])
        }
        t.expectThrows("READBACK oversized identity union is rejected") {
            _ = try request((0...1000).map { "node-\($0)" })
        }
        t.expectThrows("READBACK empty request cannot declare complete graph") { _ = try request([]) }
        stage = "provenance"
        let source = AgentCanvasReadbackRequest.Source(tool: "gen_image", toolCallID: "call",
            subagentID: "child", parentToolCallID: "parent-one")
        let sourced = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
            runID: "run", key: "shared-key", nodeIDs: [a.id], edgeIDs: [], source: source)
        let nextParent = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
            runID: "run", key: "shared-key", nodeIDs: [a.id], edgeIDs: [],
            source: .init(tool: "gen_image", toolCallID: "call", subagentID: "child", parentToolCallID: "parent-two"))
        t.check(sourced.coordinationKey != nextParent.coordinationKey && sourced.mutationID != nextParent.mutationID,
                "READBACK same child and call under a new parent retain separate identities")
        t.equal(try JSONDecoder().decode(AgentCanvasReadbackRequest.self, from: JSONEncoder().encode(sourced)), sourced,
                "READBACK parent child and tool identities survive durable replay")
        let legacy = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
            runID: "run", key: "old", nodeIDs: [a.id], edgeIDs: [])
        t.check(try JSONDecoder().decode(AgentCanvasReadbackRequest.self, from: JSONEncoder().encode(legacy)).source == nil
                && legacy.mutationID == "readback-old", "READBACK absent legacy provenance and receipts remain compatible")
        let otherConversation = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "other",
            runID: "run", key: "old", nodeIDs: [a.id], edgeIDs: [])
        t.check(otherConversation.coordinationKey != legacy.coordinationKey,
                "READBACK raw key is namespaced by conversation")
        let longKey = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
            runID: "run", key: String(repeating: "k", count: 1024), nodeIDs: [a.id], edgeIDs: [])
        t.check(longKey.mutationID.utf8.count <= 256, "READBACK maximum request key fits mutation identity budget")
        let childNotice = try AgentCanvasChangeNotice.request(event: [
            "tool": "gen_image", "status": "completed", "tool_call_id": "call", "tool_use_id": "use",
            "subagent_id": "child", "parent_tool_call_id": "parent", "response": ["node_id": .string(a.id)]],
            projectID: "project", conversationID: "conversation", runID: "run")!
        t.check(childNotice.source?.subagentID == "child" && childNotice.source?.parentToolCallID == "parent"
                && childNotice.source?.toolUseID == "use", "READBACK explicitly supplied source fields are retained without inference")
        t.check(ordinary.source?.subagentID == nil && ordinary.source?.parentToolCallID == nil,
                "READBACK ordinary tool name never invents child or parent")
        t.expectThrows("READBACK malformed explicit child identity fails closed") {
            _ = try AgentCanvasChangeNotice.request(event: ["tool": "gen_image", "status": "completed",
                "subagent_id": 3, "response": ["node_id": .string(a.id)]],
                projectID: "project", conversationID: "conversation", runID: "run")
        }

        stage = "merge"
        var remote = a; remote.width = 640; remote.height = 360; remote.ratio = "16:9"
        let before = CanvasDocument(nodes: [a, b], edges: [edge])
        let expected = try request([a.id], [edge.id])
        let snapshot = AgentCanvasReadbackSnapshot(projectID: "project", nodes: [remote], edges: [edge])
        func plan(_ current: CanvasDocument, _ value: AgentCanvasReadbackSnapshot = snapshot,
                  project: String = "project") throws -> AgentCanvasReadbackSync.Plan {
            try AgentCanvasReadbackSync.plan(request: expected, snapshot: value, before: before, current: current,
                activeProject: project, conversation: "conversation", run: "run")
        }
        let merged = try plan(before)
        t.equal(merged.document.nodes[0].width / merged.document.nodes[0].height, 16.0 / 9,
                "READBACK video retains authoritative original aspect ratio")
        t.equal(merged.document.nodes[1], b, "READBACK unrelated node retains exact value")
        var local = before; local.nodes[0].x = 900; local.nodes[0].width = 420
        let concurrent = try plan(local)
        t.equal(concurrent.document.nodes[0], local.nodes[0], "READBACK concurrent local move and configuration win")
        t.equal(concurrent.preservedNodeIDs, [a.id], "READBACK preserved edit is reported")
        let reverted = try AgentCanvasReadbackSync.plan(request: expected, snapshot: snapshot,
            before: before, current: before, activeProject: "project", conversation: "conversation", run: "run",
            locallyChangedNodeIDs: [a.id], locallyChangedEdgeIDs: [edge.id])
        t.check(reverted.document == before && reverted.preservedNodeIDs == [a.id],
                "READBACK changed then reverted local objects are still protected")
        let deleted = try plan(CanvasDocument(nodes: [b]))
        t.equal(deleted.document.nodes, [b], "READBACK node deleted during read is not resurrected")
        t.check(deleted.document.edges.isEmpty, "READBACK edge cannot reference deleted endpoint")
        t.equal(deleted.deletedNodeIDs, [a.id], "READBACK deletion produces a skipped identity")
        let transient = try AgentCanvasReadbackSync.plan(request: try request([a.id]),
            snapshot: .init(projectID: "project", nodes: [remote]), before: .init(nodes: [b]),
            current: .init(nodes: [b]), activeProject: "project", conversation: "conversation", run: "run",
            locallyChangedNodeIDs: [a.id], locallyDeletedNodeIDs: [a.id])
        t.check(transient.document.nodes == [b] && transient.deletedNodeIDs == [a.id],
                "READBACK node created and deleted during read cannot be resurrected")
        stage = "private capacity"
        for group in [SpecialSlotStorage.unfiledGroupId, SpecialSlotStorage.canvasGroupId(forProject: "project")] {
            for slot in [11, SpecialSlotStorage.unfiledCapacity] {
                var privateNode = remote; privateNode.groupId = group; privateNode.slot = slot
                let privatePlan = try AgentCanvasReadbackSync.plan(request: try request([privateNode.id]),
                    snapshot: .init(projectID: "project", nodes: [privateNode]), before: .init(), current: .init(),
                    activeProject: "project", conversation: "conversation", run: "run")
                let mutation = AgentCanvasMutation(projectID: "project", conversationID: "conversation",
                    runID: "run", mutationID: "private-\(group)-\(slot)",
                    changes: [.init(before: nil, after: privateNode)])
                let mutationPlan = try AgentCanvasSync.plan(mutation, current: .init(), expectedProject: "project",
                    expectedConversation: "conversation", expectedRun: "run")
                t.check(privatePlan.document.nodes == [privateNode]
                    && mutationPlan.document.nodes == [privateNode],
                    "READBACK and mutation accept authoritative private capacity \(group) \(slot)")
            }
        }
        for (group, slot) in [("slots", 11), (SpecialSlotStorage.unfiledGroupId, 61), ("slots", 0)] {
            var invalid = remote; invalid.groupId = group; invalid.slot = slot
            t.expectThrows("READBACK invalid slot binding \(group) \(slot) rejected") {
                _ = try AgentCanvasReadbackSync.plan(request: request([invalid.id]),
                    snapshot: .init(projectID: "project", nodes: [invalid]), before: .init(), current: .init(),
                    activeProject: "project", conversation: "conversation", run: "run")
            }
            t.expectThrows("READBACK mutation rejects invalid slot binding \(group) \(slot)") {
                _ = try AgentCanvasSync.plan(.init(projectID: "project", conversationID: "conversation",
                    runID: "run", mutationID: "invalid", changes: [.init(before: nil, after: invalid)]),
                    current: .init(), expectedProject: "project", expectedConversation: "conversation", expectedRun: "run")
            }
        }
        var changedEdge = before; changedEdge.edges[0].animated = true
        t.equal(try plan(changedEdge).document.edges[0], changedEdge.edges[0], "READBACK concurrent edge edit wins")
        t.expectThrows("READBACK missing expected node rejects entire snapshot") {
            _ = try plan(before, .init(projectID: "project", edges: [edge]))
        }
        t.expectThrows("READBACK missing expected edge rejects entire snapshot") {
            _ = try plan(before, .init(projectID: "project", nodes: [remote]))
        }
        t.expectThrows("READBACK wrong project never yields a write plan") { _ = try plan(before, project: "other") }
        t.expectThrows("READBACK duplicate identity rejects entire snapshot") {
            _ = try plan(before, .init(projectID: "project", nodes: [remote, remote], edges: [edge]))
        }
        let unknownEdge = CanvasEdge(fromNodeId: "unknown", toNodeId: b.id)
        let edgeRequest = try request([], [unknownEdge.id])
        t.expectThrows("READBACK unknown endpoints cannot be normalized away") {
            _ = try AgentCanvasReadbackSync.plan(request: edgeRequest,
                snapshot: .init(projectID: "project", edges: [unknownEdge]), before: before, current: before,
                activeProject: "project", conversation: "conversation", run: "run")
        }
        stage = "disk"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readback-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CanvasStorage(rootOverride: root)
        t.check(storage.save(before, projectId: "project"), "READBACK real native source fixture saved")
        _ = storage.load(projectId: "project")
        let file = root.appendingPathComponent("canvas/projects/project/canvas.json")
        var external = before; external.nodes[0].width = 777
        try JSONEncoder().encode(external).write(to: file, options: .atomic)
        t.equal(try storage.readbackSnapshot(projectId: "project").nodes[0].width, 777,
                "READBACK authoritative read bypasses stale storage cache after external write")
        t.check(storage.save(.init(nodes: [a]), projectId: "project"), "READBACK native node-only document saved")
        t.check(try storage.readbackSnapshot(projectId: "project").edges.isEmpty,
                "READBACK v2 omission of empty edges remains compatible")
        t.expectThrows("READBACK absent source is unknown rather than empty") { _ = try storage.readbackSnapshot(projectId: "missing") }
        t.expectThrows("READBACK source project path cannot escape configured root") { _ = try storage.readbackSnapshot(projectId: "../project") }
        let corrupt = Data("corrupt-source".utf8); try corrupt.write(to: file)
        t.expectThrows("READBACK corrupt source cannot produce empty authority") { _ = try storage.readbackSnapshot(projectId: "project") }
        t.equal(try Data(contentsOf: file), corrupt, "READBACK strict failure preserves corrupt evidence bytes")
        t.check(!FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path),
                "READBACK strict source read performs no migration or file moves")
    } catch { t.check(false, "READBACK setup \(stage): \(error)") }

    readbackCase(t, "coalescing and per-request clipping") {
        let gate = ReadbackGate()
        let reader = ReadbackReader(partial: .init(projectID: "project", nodes: [a, b], edges: [edge]))
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await gate.wait() })
        let first = Task { try await batcher.read(request([a.id], [edge.id])) }
        let second = Task { try await batcher.read(request([b.id])) }
        try await awaitReadbacks(batcher, 2); await gate.release()
        let one = try await first.value, two = try await second.value
        let nodeQueries = await reader.nodeQueries, edgeQueries = await reader.edgeQueries
        return [(nodeQueries == [[a.id, b.id].sorted()] && edgeQueries == [[edge.id]], "one union read for each entity type"),
                (one.nodes == [a] && one.edges == [edge], "first requester receives only its requested identities"),
                (two.nodes == [b] && two.edges.isEmpty, "second requester receives no unrelated edge or node")]
    }
    readbackCase(t, "fallback fills only missing identities") {
        let gate = ReadbackGate()
        var fullA = a; fullA.width += 100
        let reader = ReadbackReader(partial: .init(projectID: "project", nodes: [a]),
                                   full: .init(projectID: "project", nodes: [fullA, b], edges: [edge]))
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await gate.wait() })
        let first = Task { try await batcher.read(request([a.id])) }
        let second = Task { try await batcher.read(request([b.id], fallback: true)) }
        try await awaitReadbacks(batcher, 2); await gate.release()
        let one = try await first.value, two = try await second.value
        return [(await reader.fullQueries == 1, "eligible CLI request permits one fallback for shared union"),
                (one.nodes == [a] && two.nodes == [b], "fallback never replaces fulfilled values or broadens requests")]
    }
    readbackCase(t, "incomplete request does not poison complete sibling") {
        let gate = ReadbackGate()
        let reader = ReadbackReader(partial: .init(projectID: "project", nodes: [a]))
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await gate.wait() })
        let first = Task { try await batcher.read(request([a.id])) }
        let second = Task { try await batcher.read(request([b.id])) }
        try await awaitReadbacks(batcher, 2); await gate.release()
        let one = try await first.value
        var rejected = false
        do { _ = try await second.value } catch { rejected = error as? AgentGatewayError == .malformedPayload }
        return [(one.nodes == [a] && rejected, "missing expected ID fails only its clipped request"),
                (await reader.fullQueries == 0, "ordinary request never falls back to full canvas")]
    }
    readbackCase(t, "valid large requests partition without rejection") {
        let nodes = (0..<1500).map { CanvasNode(pageId: "page", groupId: "wide-\($0)", slot: 1,
                                                kind: .text, x: 1, y: 1) }
        let gate = ReadbackGate(), reader = ReadbackReader(partial: .init(projectID: "project", nodes: nodes))
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await gate.wait() })
        let first = Task { try await batcher.read(request(Array(nodes.prefix(1000)).map(\.id))) }
        let second = Task { try await batcher.read(request(Array(nodes.suffix(1000)).map(\.id))) }
        try await awaitReadbacks(batcher, 2); await gate.release()
        let one = try await first.value, two = try await second.value
        return [(one.nodes.count == 1000 && two.nodes.count == 1000, "both individually valid requests retain every requested node"),
                (await reader.nodeQueries.map(\.count) == [1000, 1000], "oversized union splits into bounded serial batches"),
                (await batcher.pendingCount == 0, "large cohort settles all continuations")]
    }
    readbackCase(t, "cancelling one coalesced sibling preserves another") {
        let timer = ReadbackGate(), gate = ReadbackGate()
        let reader = ReadbackReader(partial: .init(projectID: "project", nodes: [a, b]), gate: gate)
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await timer.wait() })
        let first = Task { try await batcher.read(request([a.id])) }
        let second = Task { try await batcher.read(request([b.id])) }
        try await awaitReadbacks(batcher, 2); await timer.release()
        for _ in 0..<20_000 { if await !reader.nodeQueries.isEmpty { break }; await Task.yield() }
        first.cancel()
        var cancelled = false
        do { _ = try await first.value } catch { cancelled = error is CancellationError }
        await gate.release()
        let remaining = try await second.value
        return [(cancelled && remaining.nodes == [b], "one cancellation never cancels a live sibling"),
                (await batcher.pendingCount == 0, "coalesced cancellation leaves no pending continuation")]
    }
    readbackCase(t, "cleanup and subsequent scope") {
        let gate = ReadbackGate()
        let reader = ReadbackReader(partial: .init(projectID: "project", nodes: [a]), gate: gate)
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await Task.yield() })
        let old = Task { try await batcher.read(request([a.id])) }
        try await awaitReadbacks(batcher, 1)
        for _ in 0..<20_000 { if await !reader.nodeQueries.isEmpty { break }; await Task.yield() }
        await batcher.cancelAll()
        var cancelled = false
        do { _ = try await old.value } catch { cancelled = error is CancellationError }
        await gate.release()
        let next = try await batcher.read(request([a.id]))
        return [(cancelled, "cleanup cancels pending/in-flight continuation"),
                (next.nodes == [a], "late old read cannot cancel or replace a new request"),
                (await batcher.pendingCount == 0, "cleanup leaves no unresolved request")]
    }
    for cancel in [false, true] {
        readbackCase(t, cancel ? "cancelled slow reader keeps project lease" : "successive batches serialize per project") {
            let gate = ReadbackGate(), reader = SerialReadbackReader(node: a, gate: gate)
            let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await Task.yield() })
            let first = Task { try await batcher.read(request([a.id])) }
            for _ in 0..<20_000 {
                if await reader.starts["project"] == 1 { break }; await Task.yield()
            }
            if cancel { await batcher.cancelAll() }
            let second = Task { try await batcher.read(request([a.id])) }
            try await awaitReadbacks(batcher, cancel ? 1 : 2)
            let cross = try AgentCanvasReadbackRequest(projectID: "other-project", conversationID: "conversation",
                runID: "run", key: "cross", nodeIDs: [a.id], edgeIDs: [])
            let crossResult = try await batcher.read(cross)
            let startsBeforeRelease = await reader.starts["project"]
            await gate.release()
            var firstCancelled = false, firstWidth: CGFloat?
            do { firstWidth = try await first.value.nodes.first?.width }
            catch { firstCancelled = error is CancellationError }
            let next = try await second.value
            return [(startsBeforeRelease == 1, "second same-project batch waits while independent project finishes"),
                    (crossResult.projectID == "other-project", "independent project remains responsive"),
                    (await reader.maximum["project"] == 1, "same project has at most one active snapshot"),
                    (next.nodes.first?.width == 200, "second batch reads after first finishes"),
                    (cancel ? firstCancelled : firstWidth == 100, "first result has correct completion or cancellation"),
                    (await batcher.pendingCount == 0, "all continuations are settled")]
        }
    }
}
