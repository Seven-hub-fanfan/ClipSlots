#if DEBUG
import AppKit
import Foundation
import ClipSlotsKit

private actor NativeFullGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
private actor NativeFullSource: AgentCanvasSavingSnapshotReading {
    let authority: CanvasStorage
    let save: @Sendable () async throws -> AgentCanvasSaveOutcome
    let partialGate: NativeFullGate?
    let fullGate: NativeFullGate?
    private(set) var partialQueries = 0
    private(set) var fullQueries = 0
    private(set) var saves = 0
    init(authority: CanvasStorage, partialGate: NativeFullGate? = nil, fullGate: NativeFullGate? = nil,
         save: @escaping @Sendable () async throws -> AgentCanvasSaveOutcome) {
        self.authority = authority; self.partialGate = partialGate; self.fullGate = fullGate; self.save = save
    }
    func saveBeforeSnapshot(projectID: String) async throws -> AgentCanvasSaveOutcome {
        saves += 1
        return try await save()
    }
    func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot {
        fullQueries += 1; await fullGate?.wait()
        try Task.checkCancellation()
        return try authority.readbackSnapshot(projectId: projectID)
    }
    func snapshot(projectID: String, nodeIDs: [String], edgeIDs: [String]) async throws -> AgentCanvasReadbackSnapshot {
        partialQueries += 1; await partialGate?.wait()
        try Task.checkCancellation()
        let value = try authority.readbackSnapshot(projectId: projectID)
        return .init(projectID: projectID, nodes: value.nodes.filter { nodeIDs.contains($0.id) },
                     edges: value.edges.filter { edgeIDs.contains($0.id) })
    }
    func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        try await snapshot(projectID: projectID, nodeIDs: ids, edgeIDs: [])
    }
    func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        try await snapshot(projectID: projectID, nodeIDs: [], edgeIDs: ids)
    }
}

@MainActor
func runCanvasFullReadbackRegression(directory: URL) async -> (checks: [String], failures: [String]) {
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) { if value { checks.append(name) } else { failures.append(name) } }
    do {
        let target = CanvasStorage(rootOverride: directory.appendingPathComponent("full-target"))
        let projects = CanvasProjectStorage(rootOverride: directory.appendingPathComponent("full-target"))
        let project = projects.load().activeProjectId, conversation = UUID(), run = "full-native"
        let a = CanvasNode(pageId: "page", groupId: "slots", slot: 1, kind: .video, x: 12, y: 24)
        let b = CanvasNode(pageId: "page", groupId: "slots", slot: 2, kind: .text, x: 500, y: 20)
        let original = CanvasDocument(nodes: [a, b])
        check(target.save(original, projectId: project), "full readback target baseline saved")
        let canvas = CanvasStore(storage: target, projectStorage: projects)
        var remote = a; remote.width = 640; remote.height = 360; remote.ratio = "16:9"
        let authority = CanvasStorage(rootOverride: directory.appendingPathComponent("full-authority"))
        check(authority.save(.init(nodes: [remote, b]), projectId: project), "full readback separate authority saved")
        let context = CanvasAgentContext(canvas: canvas, store: nil, projectID: project)
        func full(_ key: String, parent: String = "parent") throws -> AgentCanvasReadbackRequest {
            try .init(projectID: project, conversationID: conversation.uuidString, runID: run, key: key,
                nodeIDs: [], edgeIDs: [],
                source: .init(tool: "subagent_event", subagentID: "child", parentToolCallID: parent),
                scope: .subagentCanvas)
        }
        func source(partial: NativeFullGate? = nil, snapshot: NativeFullGate? = nil) -> NativeFullSource {
            NativeFullSource(authority: authority, partialGate: partial, fullGate: snapshot) {
                try await MainActor.run {
                    guard canvas.activeProjectId == project else { throw AgentGatewayError.originMismatch }
                    return canvas.flushSave() ? .saved : .deferred
                }
            }
        }
        func awaitQuery(_ reader: NativeFullSource, partial: Bool = false) async throws {
            for _ in 0..<20_000 {
                if partial ? await reader.partialQueries > 0 : await reader.fullQueries > 0 { return }
                await Task.yield()
            }
            throw AgentGatewayError.interrupted
        }
        var missing = false
        do { _ = try await context.submitReadback(full("unavailable"), isCurrent: { true }) }
        catch { missing = error as? AgentCanvasError == .unavailable }
        check(missing && context.pendingGraphPreviews.isEmpty && canvas.nodes == original.nodes,
              "full readback without configured authority preserves unavailable and local graph")
        let normal = source()
        context.configureReadbackSource(normal)
        check(try await context.submitReadback(full("normal"), isCurrent: { true }) == "pending",
              "full readback reaches production context and creates confirmation preview")
        let normalSaves = await normal.saves, normalQueries = await normal.fullQueries
        check(normalSaves == 1 && normalQueries == 1,
              "native full readback saves before one separate authoritative snapshot")
        let preview = context.pendingGraphPreviews[0]
        check(canvas.nodes == original.nodes && canvas.history.entries.isEmpty,
              "full readback never writes an unconfirmed native result")
        _ = try canvas.applyGatewayMutation(preview.mutation, conversationID: conversation.uuidString,
                                            runID: run, contentAvailable: { _ in true })
        check(canvas.nodes == [remote, b] && canvas.history.entries.count == 1,
              "confirmed native full readback retains ratio and one undo")
        check(canvas.undo() != nil && canvas.nodes == original.nodes, "native full readback undo restores exact baseline")
        check(try await context.submitReadback(full("normal"), isCurrent: { true }) == "applied",
              "full readback receipt survives undo and rejects replay")
        context.dismissPreview()

        let partialGate = NativeFullGate(), queued = source(partial: partialGate)
        context.configureReadbackSource(queued)
        let partial = try AgentCanvasReadbackRequest(projectID: project, conversationID: conversation.uuidString,
            runID: run, key: "partial-first", nodeIDs: [a.id], edgeIDs: [])
        let first = Task { @MainActor in try await context.submitReadback(partial, isCurrent: { true }) }
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitQuery(queued, partial: true)
        let second = Task { @MainActor in try await context.submitReadback(full("queued"), isCurrent: { true }) }
        await Task.yield()
        canvas.updateNode(id: a.id) { $0.x += 200 }
        let queuedEdit = canvas.nodes[0]
        check(await queued.saves == 0, "full native save waits behind in-flight ID read")
        await partialGate.release()
        check(try await first.value == "no_change", "earlier native ID read preserves queued local edit")
        check(try await second.value == "pending", "full native capture starts when queued operation actually begins")
        check(context.pendingGraphPreviews[0].mutation.changes[0].before == queuedEdit,
              "full native preview uses the document captured at queue start")
        context.dismissPreview()

        let fullGate = NativeFullGate(), editing = source(snapshot: fullGate)
        context.configureReadbackSource(editing)
        let reverting = Task { @MainActor in try await context.submitReadback(full("reverted"), isCurrent: { true }) }
        try await awaitQuery(editing)
        var local = queuedEdit; local.x += 123
        _ = try canvas.applyGatewayMutation(.init(projectID: project, conversationID: conversation.uuidString,
            runID: run, mutationID: "full-user-edit", changes: [.init(before: queuedEdit, after: local)]),
            conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
        check(canvas.undo() != nil && canvas.nodes[0] == queuedEdit, "native edit then undo returns exact full-readback baseline")
        await fullGate.release()
        check(try await reverting.value == "no_change" && context.pendingGraphPreviews.isEmpty,
              "full native synchronous observation preserves edits reverted during snapshot")

        let failed = NativeFullSource(authority: authority) { .deferred }
        context.configureReadbackSource(failed)
        var deferred = false
        do { _ = try await context.submitReadback(full("deferred"), isCurrent: { true }) } catch { deferred = true }
        let failedQueries = await failed.fullQueries
        check(deferred && failedQueries == 0 && context.pendingGraphPreviews.isEmpty,
              "native deferred save performs no full snapshot or preview")

        let staleGate = NativeFullGate(), stale = source(snapshot: staleGate)
        context.configureReadbackSource(stale)
        var parent = "parent"
        let staleRead = Task { @MainActor in
            try await context.submitReadback(full("old-parent"), isCurrent: { parent == "parent" })
        }
        try await awaitQuery(stale)
        parent = "replacement"
        await staleGate.release()
        var rejected = false
        do { _ = try await staleRead.value } catch { rejected = error is CancellationError }
        check(rejected && context.pendingGraphPreviews.isEmpty && canvas.nodes[0] == queuedEdit,
              "late full snapshot from replaced parent has no native side effect")

        let replacementGate = NativeFullGate(), retiring = source(snapshot: replacementGate)
        context.configureReadbackSource(retiring)
        let retired = Task { @MainActor in try await context.submitReadback(full("retired-source"), isCurrent: { true }) }
        try await awaitQuery(retiring)
        let replacement = source()
        context.configureReadbackSource(replacement)
        var retiredCancelled = false
        do { _ = try await retired.value } catch { retiredCancelled = error is CancellationError }
        let replacementRead = Task { @MainActor in
            try await context.submitReadback(full("replacement-source"), isCurrent: { true })
        }
        for _ in 0..<20_000 {
            if await AgentCanvasReadbackSerialGate.shared.waitingCount > 0 { break }
            await Task.yield()
        }
        let replacementSaves = await replacement.saves
        check(retiredCancelled && replacementSaves == 0,
              "actual Context source replacement waits for cancelled old query to exit")
        await replacementGate.release()
        check(try await replacementRead.value == "pending", "actual replacement source completes after old query exits")
        context.dismissPreview()

        let deleteGate = NativeFullGate(), deleting = source(snapshot: deleteGate)
        let connection = CanvasEdge(fromNodeId: a.id, toNodeId: b.id)
        check(authority.save(.init(nodes: [remote, b], edges: [connection]), projectId: project),
              "full deletion fixture includes remote connection")
        context.configureReadbackSource(deleting)
        let deletedRead = Task { @MainActor in
            try await context.submitReadback(full("deleted-node"), isCurrent: { true })
        }
        try await awaitQuery(deleting)
        _ = try canvas.applyGatewayMutation(.init(projectID: project, conversationID: conversation.uuidString,
            runID: run, mutationID: "full-user-delete", changes: [.init(before: queuedEdit, after: nil)]),
            conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
        await deleteGate.release()
        check(try await deletedRead.value == "deleted_during_readback" && canvas.nodes == [b]
            && canvas.edges.isEmpty && context.pendingGraphPreviews.isEmpty,
              "actual full snapshot cannot revive deleted node or its remote connection")
        check(canvas.undo() != nil && canvas.nodes == [queuedEdit, b], "native deletion undo restores latest local values")

        let transient = CanvasNode(pageId: "page", groupId: "slots", slot: 3, kind: .text, x: 10, y: 500)
        let transientEdge = CanvasEdge(fromNodeId: a.id, toNodeId: transient.id)
        check(authority.save(.init(nodes: [queuedEdit, b, transient], edges: [transientEdge]), projectId: project),
              "full transient fixture includes new remote node and connection")
        let transientGate = NativeFullGate(), transientSource = source(snapshot: transientGate)
        context.configureReadbackSource(transientSource)
        let transientRead = Task { @MainActor in
            try await context.submitReadback(full("transient-node"), isCurrent: { true })
        }
        try await awaitQuery(transientSource)
        _ = try canvas.applyGatewayMutation(.init(projectID: project, conversationID: conversation.uuidString,
            runID: run, mutationID: "full-user-create", changes: [.init(before: nil, after: transient)]),
            conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
        _ = try canvas.applyGatewayMutation(.init(projectID: project, conversationID: conversation.uuidString,
            runID: run, mutationID: "full-user-remove", changes: [.init(before: transient, after: nil)]),
            conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
        await transientGate.release()
        check(try await transientRead.value == "deleted_during_readback" && canvas.nodes == [queuedEdit, b]
            && canvas.edges.isEmpty && context.pendingGraphPreviews.isEmpty,
              "full native observer protects newly created then deleted entities absent at capture")
        check(authority.save(.init(nodes: [remote, b]), projectId: project), "separate full authority restored after transient fixture")
        check(try authority.readbackSnapshot(projectId: project).nodes == [remote, b],
              "full readback save never overwrites separate authority with local graph")
    } catch { check(false, "native full readback fixture: \(type(of: error))") }
    return (checks, failures)
}
#endif
