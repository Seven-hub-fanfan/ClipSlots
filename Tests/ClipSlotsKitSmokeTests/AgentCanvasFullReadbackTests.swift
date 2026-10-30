import Foundation
@testable import ClipSlotsKit

private actor FullReadGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
private actor FullReader: AgentCanvasSavingSnapshotReading {
    let node: CanvasNode
    let gate: FullReadGate?
    let block: String?
    let outcome: AgentCanvasSaveOutcome
    let failSave: Bool
    private(set) var calls: [String] = []
    init(node: CanvasNode, gate: FullReadGate? = nil, block: String? = nil,
         outcome: AgentCanvasSaveOutcome = .saved, failSave: Bool = false) {
        self.node = node; self.gate = gate; self.block = block
        self.outcome = outcome; self.failSave = failSave
    }
    func saveBeforeSnapshot(projectID: String) async throws -> AgentCanvasSaveOutcome {
        calls.append("save:\(projectID)")
        if block == "save:\(projectID)" { await gate?.wait() }
        if failSave { throw AgentGatewayError.interrupted }
        return outcome
    }
    func snapshot(projectID: String, nodeIDs: [String], edgeIDs: [String]) async throws -> AgentCanvasReadbackSnapshot {
        calls.append("ids:\(projectID)")
        if block == "ids:\(projectID)" && calls.filter({ $0 == block }).count == 1 { await gate?.wait() }
        try Task.checkCancellation()
        return .init(projectID: projectID, nodes: [node])
    }
    func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        throw AgentGatewayError.malformedPayload
    }
    func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        throw AgentGatewayError.malformedPayload
    }
    func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot {
        calls.append("full:\(projectID)")
        return .init(projectID: projectID, nodes: [node])
    }
}
private actor FullStartCounter {
    private(set) var count = 0
    func start() { count += 1 }
}
private func fullRequest(_ key: String, project: String = "project", parent: String = "parent") throws -> AgentCanvasReadbackRequest {
    try .init(projectID: project, conversationID: "conversation", runID: "run", key: key,
              nodeIDs: [], edgeIDs: [],
              source: .init(tool: "subagent_event", subagentID: "child", parentToolCallID: parent), scope: .subagentCanvas)
}
private func fullCase(_ t: TestRunner, _ name: String,
                      _ body: @escaping @Sendable () async throws -> [(Bool, String)]) {
    let values: [(Bool, String)] = smokeAwait {
        do { return try await body() }
        catch { return [(false, "fixture: \(type(of: error))")] }
    }
    values.forEach { t.check($0.0, "FULL READBACK \(name): \($0.1)") }
}
private func waitFullCall(_ reader: FullReader, _ call: String) async throws {
    for _ in 0..<20_000 { if await reader.calls.contains(call) { return }; await Task.yield() }
    throw AgentGatewayError.interrupted
}

func runAgentCanvasFullReadbackTests(_ t: TestRunner) {
    let a = CanvasNode(pageId: "page", groupId: "slots", slot: 1, kind: .video, x: 12, y: 40)
    let b = CanvasNode(pageId: "page", groupId: "slots", slot: 2, kind: .text, x: 500, y: 20)
    do {
        let request = try fullRequest("full")
        t.equal(try JSONDecoder().decode(AgentCanvasReadbackRequest.self, from: JSONEncoder().encode(request)), request,
                "FULL READBACK full scope and child provenance survive replay")
        t.expectThrows("FULL READBACK generic empty request cannot acquire full scope") {
            _ = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
                runID: "run", key: "bad", nodeIDs: [], edgeIDs: [], scope: .subagentCanvas)
        }
        var projection = AgentSubagentCanvasProjection()
        func event(_ phase: String, parent: String = "parent", schema: String = "subagent_event.v1") -> JSONValue {
            ["schema_version": .string(schema), "phase": .string(phase),
             "subagent_id": "child", "parent_tool_call_id": .string(parent)]
        }
        func receive(_ phase: String, _ key: String, parent: String = "parent") throws -> AgentSubagentCanvasProjection.Update? {
            try projection.receive(event(phase, parent: parent), eventID: key, projectID: "project",
                conversationID: "conversation", runID: "run")
        }
        t.check(try receive("started", "start")?.request == nil, "FULL READBACK start marks dirty without premature full query")
        let durable = try JSONDecoder().decode(AgentSubagentCanvasProjection.self, from: JSONEncoder().encode(projection))
        var recovered = durable
        t.check(recovered.finish()?.key == "start" && recovered.finish() == nil,
                "FULL READBACK dirty intent survives restart and finish consumes it once")
        let stopped = try receive("stopped", "stopped")?.request
        t.check(stopped?.isFullSnapshot == true && stopped?.source?.parentToolCallID == "parent",
                "FULL READBACK stopped triggers saved full readback without claiming completed")
        t.check(try receive("tool_completed", "late") == nil && receive("completed", "duplicate") == nil,
                "FULL READBACK terminal instance is not reopened by late tools or another terminal")
        _ = try receive("started", "next-start", parent: "next-parent")
        t.check(try receive("completed", "old-parent") == nil,
                "FULL READBACK earlier parent terminal cannot replace successor scope")
        let next = try receive("failed", "failed", parent: "next-parent")?.request
        t.check(next?.subagentInstanceKey != stopped?.subagentInstanceKey,
                "FULL READBACK changed parent creates a separate instance")
        t.check(try projection.receive(event("started", schema: "future.v2"), eventID: "unknown",
            projectID: "project", conversationID: "conversation", runID: "run") == nil,
            "FULL READBACK unsupported schema cannot trigger nested synchronization")

        var remote = a; remote.width = 640; remote.height = 360; remote.ratio = "16:9"
        let original = CanvasDocument(nodes: [a, b])
        let snapshot = AgentCanvasReadbackSnapshot(projectID: "project", nodes: [remote])
        let plan = try AgentCanvasReadbackSync.plan(request: request, snapshot: snapshot,
            before: original, current: original, activeProject: "project", conversation: "conversation", run: "run")
        t.check(plan.document.nodes == [remote, b], "FULL READBACK merges incoming values without deleting absent local node")
        let empty = try AgentCanvasReadbackSync.plan(request: request, snapshot: .init(projectID: "project"),
            before: original, current: original, activeProject: "project", conversation: "conversation", run: "run")
        t.check(empty.document == original, "FULL READBACK empty snapshot is no change and never deletion authority")
        let deleted = try AgentCanvasReadbackSync.plan(request: request, snapshot: snapshot,
            before: original, current: .init(nodes: [b]), activeProject: "project", conversation: "conversation", run: "run")
        t.check(deleted.document.nodes == [b], "FULL READBACK preserves local deletion")
        let reverted = try AgentCanvasReadbackSync.plan(request: request, snapshot: snapshot,
            before: original, current: original, activeProject: "project", conversation: "conversation", run: "run",
            locallyChangedNodeIDs: [a.id])
        t.check(reverted.document == original, "FULL READBACK preserves edit then undo even with equal final values")
        let dangling = CanvasEdge(fromNodeId: a.id, toNodeId: "missing")
        let edgePlan = try AgentCanvasReadbackSync.plan(request: request,
            snapshot: .init(projectID: "project", nodes: [remote], edges: [dangling]),
            before: original, current: original, activeProject: "project", conversation: "conversation", run: "run")
        t.check(edgePlan.document.nodes[0] == remote && edgePlan.document.edges.isEmpty,
                "FULL READBACK orphan connection is skipped while valid node stays eligible")
        t.expectThrows("FULL READBACK duplicate authoritative IDs fail closed") {
            _ = try AgentCanvasReadbackSync.plan(request: request,
                snapshot: .init(projectID: "project", nodes: [remote, remote]),
                before: original, current: original, activeProject: "project", conversation: "conversation", run: "run")
        }
    } catch { t.check(false, "FULL READBACK synchronous fixture: \(type(of: error))") }

    fullCase(t, "shared project queue") {
        let gate = FullReadGate(), starts = FullStartCounter()
        let reader = FullReader(node: a, gate: gate, block: "ids:project")
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await Task.yield() })
        let partial = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
            runID: "run", key: "partial", nodeIDs: [a.id], edgeIDs: [])
        let first = Task { try await batcher.read(partial) }
        try await waitFullCall(reader, "ids:project")
        let full = Task { try await batcher.read(fullRequest("full"), beforeRead: { await starts.start() }) }
        for _ in 0..<20_000 { if await batcher.pendingCount == 2 { break }; await Task.yield() }
        let after = Task { try await batcher.read(partial) }
        for _ in 0..<20_000 { if await batcher.pendingCount == 3 { break }; await Task.yield() }
        _ = try await batcher.read(fullRequest("other", project: "other"))
        let before = await reader.calls, earlyStarts = await starts.count
        await gate.release()
        _ = try await first.value; _ = try await full.value; _ = try await after.value
        let calls = await reader.calls.filter { $0.hasSuffix(":project") }
        let startCount = await starts.count, pendingCount = await batcher.pendingCount
        return [(before.filter { $0.hasSuffix(":project") } == ["ids:project"] && earlyStarts == 0,
                 "full capture and save wait for earlier same-project ID read"),
                (before.contains("full:other"), "another project completes independently"),
                (calls == ["ids:project", "save:project", "full:project", "ids:project"],
                 "ID, saved full, and later ID reads retain serial order"),
                (startCount == 1 && pendingCount == 0, "capture occurs once at actual operation start")]
    }
    for failure in [false, true] {
        fullCase(t, failure ? "save failure" : "save deferred") {
            let reader = FullReader(node: a, outcome: .deferred, failSave: failure)
            let batcher = AgentCanvasReadbackBatcher(reader: reader)
            var rejected = false
            do { _ = try await batcher.read(fullRequest("save")) } catch { rejected = true }
            let calls = await reader.calls
            return [(rejected && calls == ["save:project"], "save without success never queries a full snapshot"),
                    (await batcher.pendingCount == 0, "save failure settles the continuation")]
        }
    }
    fullCase(t, "cancelled slow save") {
        let gate = FullReadGate(), reader = FullReader(node: a, gate: gate, block: "save:project")
        let batcher = AgentCanvasReadbackBatcher(reader: reader, sleep: { await Task.yield() })
        let first = Task { try await batcher.read(fullRequest("cancel")) }
        try await waitFullCall(reader, "save:project")
        first.cancel()
        var cancelled = false
        do { _ = try await first.value } catch { cancelled = error is CancellationError }
        let partial = try AgentCanvasReadbackRequest(projectID: "project", conversationID: "conversation",
            runID: "run", key: "next", nodeIDs: [a.id], edgeIDs: [])
        let next = Task { try await batcher.read(partial) }
        for _ in 0..<20_000 { if await batcher.pendingCount == 1 { break }; await Task.yield() }
        let before = await reader.calls
        await gate.release(); _ = try await next.value
        return [(cancelled, "cancellation resolves before the uncooperative save exits"),
                (before == ["save:project"], "project lease remains held by the slow cancelled save"),
                ((await reader.calls) == ["save:project", "ids:project"], "cancelled save never proceeds to full snapshot")]
    }
    fullCase(t, "source replacement retains project lease") {
        let gate = FullReadGate(), lease = AgentCanvasReadbackSerialGate()
        let oldReader = FullReader(node: a, gate: gate, block: "save:project")
        let newReader = FullReader(node: b)
        let oldBatcher = AgentCanvasReadbackBatcher(reader: oldReader, serialGate: lease)
        let newBatcher = AgentCanvasReadbackBatcher(reader: newReader, serialGate: lease)
        let old = Task { try await oldBatcher.read(fullRequest("old")) }
        try await waitFullCall(oldReader, "save:project")
        await oldBatcher.cancelAll()
        var cancelled = false
        do { _ = try await old.value } catch { cancelled = error is CancellationError }
        let replacement = Task { try await newBatcher.read(fullRequest("replacement")) }
        for _ in 0..<20_000 { if await lease.waitingCount == 1 { break }; await Task.yield() }
        let premature = await newReader.calls
        let independent = try await newBatcher.read(fullRequest("other", project: "other"))
        await gate.release()
        let value = try await replacement.value
        let remaining = await lease.waitingCount
        return [(cancelled && premature.isEmpty, "new source cannot save while disposed old reader is still active"),
                (independent.projectID == "other", "replacement serialization does not block another project"),
                (value.nodes == [b] && remaining == 0, "new authority runs after old save exits and leaves no lease waiter")]
    }
}
