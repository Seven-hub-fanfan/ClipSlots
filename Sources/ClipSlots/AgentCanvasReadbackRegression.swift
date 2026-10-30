#if DEBUG
import Foundation
import AppKit
import ClipSlotsKit

private actor NativeReadbackGate: AgentCanvasSnapshotReading {
    let snapshot: AgentCanvasReadbackSnapshot
    private var started = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ snapshot: AgentCanvasReadbackSnapshot) { self.snapshot = snapshot }
    var hasStarted: Bool { started }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        started = true
        if !open { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        return snapshot
    }
    func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        .init(projectID: projectID, edges: snapshot.edges)
    }
    func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot { snapshot }
}

@MainActor
func runCanvasReadbackRegression(directory: URL) async -> [String: Any] {
    _ = NSApplication.shared
    var passed: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) { if value { passed.append(name) } else { failures.append(name) } }
    do {
        let target = directory.appendingPathComponent("target"), authority = directory.appendingPathComponent("authority")
        let storage = CanvasStorage(rootOverride: target)
        let projects = CanvasProjectStorage(rootOverride: target), project = projects.load().activeProjectId
        let node = CanvasNode(pageId: "page", groupId: "slots", slot: 1, kind: .video, x: 12, y: 24)
        let other = CanvasNode(pageId: "page", groupId: "slots", slot: 2, kind: .text, x: 500, y: 20)
        let original = CanvasDocument(nodes: [node, other])
        check(storage.save(original, projectId: project), "native target baseline saved")
        let canvas = CanvasStore(storage: storage, projectStorage: projects)
        let source = CanvasStorage(rootOverride: authority)
        var remote = node; remote.width = 640; remote.height = 360; remote.ratio = "16:9"
        check(source.save(.init(nodes: [remote, other]), projectId: project), "separate native authority saved")
        let context = CanvasAgentContext(canvas: canvas, store: nil, projectID: project,
            readbackSource: CanvasStorageReadbackSource(storage: source))
        let conversation = UUID(), run = "native-readback-run"
        func request(_ key: String) throws -> AgentCanvasReadbackRequest {
            try .init(projectID: project, conversationID: conversation.uuidString, runID: run,
                      key: key, nodeIDs: [node.id], edgeIDs: [])
        }
        let initial = try await context.submitReadback(request("first"), isCurrent: { true })
        check(initial == "pending" && context.pendingGraphPreviews.count == 1, "production context produces typed preview")
        var conflictRejected = false
        do {
            _ = try await context.submitReadback(.init(projectID: project, conversationID: conversation.uuidString,
                runID: run, key: "first", nodeIDs: [other.id], edgeIDs: []), isCurrent: { true })
        } catch { conflictRejected = error as? AgentGatewayError == .malformedPayload }
        check(conflictRejected && context.pendingGraphPreviews.count == 1,
              "same pending readback identity with changed expected IDs is rejected")
        check(canvas.nodes == original.nodes && canvas.history.entries.isEmpty, "readback performs no unconfirmed native write")
        let preview = context.pendingGraphPreviews[0]
        let applied = try canvas.applyGatewayMutation(preview.mutation, conversationID: conversation.uuidString,
                                                     runID: run, contentAvailable: { _ in true })
        check(applied.changedNodeIDs == [node.id] && canvas.nodes[0].width == 640 && canvas.nodes[0].height == 360,
              "confirmed readback reaches real Store and retains video ratio")
        check(canvas.nodes[1] == other && canvas.history.entries.count == 1, "confirmed readback preserves unrelated node and records one undo")
        check(canvas.undo() != nil && canvas.nodes == original.nodes, "real Store undo restores readback baseline")
        check(try await context.submitReadback(request("first"), isCurrent: { true }) == "applied",
              "readback receipt prevents replay after undo")
        context.dismissPreview()

        func awaitStart(_ gate: NativeReadbackGate) async throws {
            for _ in 0..<20_000 {
                if await gate.hasStarted { return }
                await Task.yield()
            }
            throw AgentGatewayError.interrupted
        }
        let movement = NativeReadbackGate(.init(projectID: project, nodes: [remote]))
        context.configureReadbackSource(movement)
        let movingTask = Task { @MainActor in try await context.submitReadback(request("movement"), isCurrent: { true }) }
        // The default 100ms batching window is part of this production test.
        try await Task.sleep(nanoseconds: 110_000_000)
        try await awaitStart(movement)
        canvas.updateNode(id: node.id) { $0.x += 200 }
        let moved = canvas.nodes[0]
        await movement.release()
        check(try await movingTask.value == "no_change" && canvas.nodes[0] == moved
              && context.pendingGraphPreviews.isEmpty, "local move during actual async read is preserved without preview")

        let deletion = NativeReadbackGate(.init(projectID: project, nodes: [remote]))
        context.configureReadbackSource(deletion)
        let deletingTask = Task { @MainActor in try await context.submitReadback(request("deletion"), isCurrent: { true }) }
        try await Task.sleep(nanoseconds: 110_000_000)
        try await awaitStart(deletion)
        let remove = AgentCanvasMutation(projectID: project, conversationID: conversation.uuidString,
            runID: run, mutationID: "delete-native", changes: [.init(before: moved, after: nil)])
        _ = try canvas.applyGatewayMutation(remove, conversationID: conversation.uuidString,
                                            runID: run, contentAvailable: { _ in true })
        await deletion.release()
        check(try await deletingTask.value == "deleted_during_readback" && canvas.nodes == [other]
              && context.pendingGraphPreviews.isEmpty, "local deletion during actual async read never resurrects node")

        let extendedRoot = directory.appendingPathComponent("extended")
        let extendedStorage = CanvasStorage(rootOverride: extendedRoot)
        let extendedProjects = CanvasProjectStorage(rootOverride: extendedRoot)
        let extendedProject = extendedProjects.load().activeProjectId
        var privateNode = node
        privateNode.groupId = SpecialSlotStorage.canvasGroupId(forProject: extendedProject)
        privateNode.slot = SpecialSlotStorage.unfiledCapacity
        let base = CanvasDocument(nodes: [privateNode, other])
        check(extendedStorage.save(base, projectId: extendedProject), "private slot 60 native baseline saved")
        let extendedCanvas = CanvasStore(storage: extendedStorage, projectStorage: extendedProjects)
        var privateRemote = privateNode; privateRemote.width = 640; privateRemote.height = 360
        let privateGate = NativeReadbackGate(.init(projectID: extendedProject, nodes: [privateRemote]))
        let extendedContext = CanvasAgentContext(canvas: extendedCanvas, store: nil, projectID: extendedProject,
                                                readbackSource: privateGate)
        func extendedRequest(_ key: String, conversation: UUID = conversation,
                             source: AgentCanvasReadbackRequest.Source? = nil,
                             nodeIDs: [String]? = nil, edgeIDs: [String] = []) throws -> AgentCanvasReadbackRequest {
            try .init(projectID: extendedProject, conversationID: conversation.uuidString, runID: run,
                key: key, nodeIDs: nodeIDs ?? [privateNode.id], edgeIDs: edgeIDs, source: source)
        }
        let privateTask = Task { @MainActor in
            try await extendedContext.submitReadback(extendedRequest("slot60"), isCurrent: { true })
        }
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitStart(privateGate)
        await privateGate.release()
        check(try await privateTask.value == "pending", "actual context accepts private slot 60")
        guard let privatePreview = extendedContext.pendingGraphPreviews.first else { throw AgentGatewayError.interrupted }
        _ = try extendedCanvas.applyGatewayMutation(privatePreview.mutation,
            conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
        check(extendedCanvas.nodes[0].width == 640 && extendedCanvas.nodes[0].slot == 60,
              "actual Store commits private slot 60 readback")
        check(extendedCanvas.undo() != nil && extendedCanvas.nodes == base.nodes, "private slot 60 undo retains exact baseline")
        extendedContext.dismissPreview()

        let revertGate = NativeReadbackGate(.init(projectID: extendedProject, nodes: [privateRemote]))
        extendedContext.configureReadbackSource(revertGate)
        let reverting = Task { @MainActor in
            try await extendedContext.submitReadback(extendedRequest("reverted"), isCurrent: { true })
        }
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitStart(revertGate)
        let localMutation = AgentCanvasMutation(projectID: extendedProject, conversationID: conversation.uuidString,
            runID: run, mutationID: "user-edit", changes: [.init(before: privateNode, after: {
                var changed = privateNode; changed.x += 200; return changed
            }())])
        _ = try extendedCanvas.applyGatewayMutation(localMutation, conversationID: conversation.uuidString,
            runID: run, contentAvailable: { _ in true })
        check(extendedCanvas.undo() != nil && extendedCanvas.nodes == base.nodes,
              "local edit then undo returns byte-equivalent node values")
        await revertGate.release()
        check(try await reverting.value == "no_change" && extendedCanvas.nodes == base.nodes
            && extendedContext.pendingGraphPreviews.isEmpty, "native observation protects edit then undo during readback")

        let localEdge = CanvasEdge(fromNodeId: privateNode.id, toNodeId: other.id)
        _ = try extendedCanvas.applyGatewayMutation(.init(projectID: extendedProject,
            conversationID: conversation.uuidString, runID: run, mutationID: "user-connect", changes: [],
            addedEdges: [localEdge]), conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
        var remoteEdge = localEdge; remoteEdge.animated = true
        let edgeGate = NativeReadbackGate(.init(projectID: extendedProject, edges: [remoteEdge]))
        extendedContext.configureReadbackSource(edgeGate)
        let edgeRead = Task { @MainActor in
            try await extendedContext.submitReadback(extendedRequest("edge-reverted", nodeIDs: [], edgeIDs: [localEdge.id]),
                                                    isCurrent: { true })
        }
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitStart(edgeGate)
        _ = try extendedCanvas.applyGatewayMutation(.init(projectID: extendedProject,
            conversationID: conversation.uuidString, runID: run, mutationID: "user-edge-edit", changes: [],
            addedEdges: [remoteEdge], removedEdges: [localEdge]), conversationID: conversation.uuidString,
            runID: run, contentAvailable: { _ in true })
        check(extendedCanvas.undo() != nil && extendedCanvas.edges == [localEdge],
              "native edge edit and immediate undo restore exact edge")
        await edgeGate.release()
        check(try await edgeRead.value == "no_change" && extendedCanvas.edges == [localEdge]
            && extendedContext.pendingGraphPreviews.isEmpty, "native synchronous edge observation protects reverted edits")
        _ = try extendedCanvas.applyGatewayMutation(.init(projectID: extendedProject,
            conversationID: conversation.uuidString, runID: run, mutationID: "user-disconnect", changes: [],
            removedEdges: [localEdge]), conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })

        let transientNode = CanvasNode(pageId: "page", groupId: "slots", slot: 3, kind: .text, x: 10, y: 500)
        let transientGate = NativeReadbackGate(.init(projectID: extendedProject, nodes: [transientNode]))
        extendedContext.configureReadbackSource(transientGate)
        let transientRead = Task { @MainActor in
            try await extendedContext.submitReadback(extendedRequest("transient", nodeIDs: [transientNode.id]), isCurrent: { true })
        }
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitStart(transientGate)
        _ = try extendedCanvas.applyGatewayMutation(.init(projectID: extendedProject,
            conversationID: conversation.uuidString, runID: run, mutationID: "user-create",
            changes: [.init(before: nil, after: transientNode)]), conversationID: conversation.uuidString,
            runID: run, contentAvailable: { _ in true })
        _ = try extendedCanvas.applyGatewayMutation(.init(projectID: extendedProject,
            conversationID: conversation.uuidString, runID: run, mutationID: "user-remove",
            changes: [.init(before: transientNode, after: nil)]), conversationID: conversation.uuidString,
            runID: run, contentAvailable: { _ in true })
        await transientGate.release()
        check(try await transientRead.value == "deleted_during_readback" && extendedCanvas.nodes == base.nodes
            && extendedContext.pendingGraphPreviews.isEmpty, "native create then delete cannot be revived by readback")

        let collisionGate = NativeReadbackGate(.init(projectID: extendedProject, nodes: [privateRemote]))
        extendedContext.configureReadbackSource(collisionGate)
        let siblingConversation = UUID()
        let firstSource = AgentCanvasReadbackRequest.Source(tool: "gen_image", toolCallID: "same-call",
                                                          subagentID: "child", parentToolCallID: "parent-one")
        let secondSource = AgentCanvasReadbackRequest.Source(tool: "gen_image", toolCallID: "same-call",
                                                           subagentID: "child", parentToolCallID: "parent-two")
        extendedContext.prepareReadback(try extendedRequest("same-key", source: firstSource), isCurrent: { true })
        extendedContext.prepareReadback(try extendedRequest("same-key", source: secondSource), isCurrent: { true })
        extendedContext.prepareReadback(try extendedRequest("same-key", conversation: siblingConversation), isCurrent: { true })
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitStart(collisionGate)
        await collisionGate.release()
        for _ in 0..<20_000 {
            if extendedContext.pendingGraphPreviews.count == 3 { break }; await Task.yield()
        }
        let siblings = extendedContext.pendingGraphPreviews
        check(siblings.count == 3 && Set(siblings.map(\.id)).count == 3,
              "prepareReadback retains identical raw keys across parent and conversation scopes")
        if let childPreview = siblings.first(where: { $0.id == (try? extendedRequest("same-key", source: firstSource).mutationID) }) {
            _ = try extendedCanvas.applyGatewayMutation(childPreview.mutation,
                conversationID: conversation.uuidString, runID: run, contentAvailable: { _ in true })
            check(extendedCanvas.undo() != nil, "child readback mutation has real undo")
            check(try await extendedContext.submitReadback(extendedRequest("same-key", source: firstSource),
                isCurrent: { true }) == "applied", "child receipt prevents replay after native undo")
        } else { check(false, "child preview identity available") }
        extendedContext.dismissPreview()

        let cancelledGate = NativeReadbackGate(.init(projectID: extendedProject, nodes: [privateRemote]))
        extendedContext.configureReadbackSource(cancelledGate)
        var currentScope = true
        let cancelledRead = Task { @MainActor in
            try await extendedContext.submitReadback(extendedRequest("old-conversation"), isCurrent: { currentScope })
        }
        try await Task.sleep(nanoseconds: 110_000_000); try await awaitStart(cancelledGate)
        currentScope = false
        await cancelledGate.release()
        var rejectedScope = false
        do { _ = try await cancelledRead.value } catch { rejectedScope = error is CancellationError }
        check(rejectedScope && extendedContext.pendingGraphPreviews.isEmpty && extendedCanvas.nodes == base.nodes,
              "late old conversation readback creates no preview or native write")

        let scope = NativeReadbackGate(.init(projectID: project, nodes: [remote]))
        context.configureReadbackSource(scope)
        let old = Task { @MainActor in try await context.submitReadback(request("old-project"), isCurrent: { true }) }
        try await Task.sleep(nanoseconds: 110_000_000)
        try await awaitStart(scope)
        _ = canvas.createProject(name: "后续项目")
        await scope.release()
        var cancelled = false
        do { _ = try await old.value } catch { cancelled = error is CancellationError }
        check(cancelled && context.pendingGraphPreviews.isEmpty && canvas.nodes.isEmpty,
              "project switch disposes in-flight source and prevents cross-project preview")
        check(try source.readbackSnapshot(projectId: project).nodes == [remote, other],
              "readback and target operations preserve separate authoritative source")
    } catch { check(false, "native readback fixture: \(error.localizedDescription)") }
    let full = await runCanvasFullReadbackRegression(directory: directory)
    passed += full.checks; failures += full.failures
    check(NSApplication.shared.windows.isEmpty, "headless native tests opened no AppKit windows")
    return ["passed": passed.count, "checks": passed, "failures": failures,
            "instrument": "production CanvasAgentContext + CanvasStore + separate disk authority",
            "foregroundRequired": false, "providerRequests": 0]
}
#endif
