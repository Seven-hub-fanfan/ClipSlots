import Foundation
import ClipSlotsKit

func runAgentCanvasSyncTests(_ t: TestRunner) {
    let node = CanvasNode(pageId: "page", groupId: "group", slot: 1, kind: .text, x: 12, y: -20)
    let other = CanvasNode(pageId: "page", groupId: "group", slot: 2, kind: .text, x: 480, y: 30)
    let original = CanvasDocument(nodes: [node, other])
    func mutation(before: CanvasNode? = node, after: CanvasNode?, added: [CanvasEdge] = [],
                  removed: [CanvasEdge] = [], project: String = "project") -> AgentCanvasMutation {
        .init(projectID: project, conversationID: "conversation", runID: "run", mutationID: "mutation",
              changes: [.init(before: before, after: after)], addedEdges: added, removedEdges: removed)
    }
    func plan(_ mutation: AgentCanvasMutation, _ current: CanvasDocument = original) throws -> AgentCanvasSync.Plan {
        try AgentCanvasSync.plan(mutation, current: current, expectedProject: "project",
                                 expectedConversation: "conversation", expectedRun: "run")
    }
    do {
        var resized = node
        resized.width += 40
        let change = mutation(after: resized)
        let first = try plan(change)
        t.equal(first.document.nodes[0], resized, "SYNC confirmed graph proposal changes only its intended node")
        t.equal(first.document.nodes[1], other, "SYNC unrelated media identity is preserved")
        let restored = try JSONDecoder().decode(CanvasDocument.self,
            from: JSONEncoder().encode(first.document))
        t.check(try plan(change, restored).alreadyApplied, "SYNC duplicate mutation survives restart without reapplying")
        var moved = original
        moved.nodes[0].setFrameOrigin(CGPoint(x: 210, y: 700))
        let merge = try plan(change, moved)
        t.equal(merge.document.nodes[0].x, 210, "SYNC remote parameter change preserves concurrent local x")
        t.equal(merge.document.nodes[0].y, 700, "SYNC remote parameter change preserves concurrent local y")
        t.equal(merge.document.nodes[0].width, resized.width, "SYNC non-conflicting remote parameter is merged")
        t.equal(merge.preservedLocalPositions, [node.id], "SYNC records preserved local position")
        var remoteMoved = node
        remoteMoved.x = 44
        t.expectThrows("SYNC two conflicting moves are rejected") { _ = try plan(mutation(after: remoteMoved), moved) }
        t.expectThrows("SYNC wrong project cannot change graph") { _ = try plan(mutation(after: resized, project: "wrong")) }
        t.expectThrows("SYNC deleted identity cannot be recreated by an update") {
            _ = try plan(change, CanvasDocument(nodes: [other]))
        }
        var rebound = resized
        rebound.createdAt = Date().addingTimeInterval(100)
        t.expectThrows("SYNC node creation identity cannot be rebound by remote update") { _ = try plan(mutation(after: rebound)) }
        let dangling = CanvasEdge(fromNodeId: node.id, toNodeId: "missing")
        t.expectThrows("SYNC incomplete edge snapshot never commits half a graph") {
            _ = try plan(mutation(after: resized, added: [dangling]))
        }
        let edge = CanvasEdge(fromNodeId: node.id, toNodeId: other.id)
        let connected = try plan(mutation(after: resized, added: [edge]))
        t.equal(connected.document.edges, [edge], "SYNC complete node and edge update is one proposal")
        var existing = original
        existing.edges = [edge]
        t.expectThrows("SYNC deletion must explicitly account for incident edges") { _ = try plan(mutation(after: nil), existing) }
        let removed = try plan(mutation(after: nil, removed: [edge]), existing)
        t.equal(removed.document.nodes.map(\.id), [other.id], "SYNC explicit deletion keeps unrelated nodes")
        t.check(removed.document.edges.isEmpty, "SYNC explicit deletion includes its edges")
        var invalid = node
        invalid.x = .infinity
        t.expectThrows("SYNC non-finite geometry rejected") { _ = try plan(mutation(after: invalid)) }
        invalid.x = Double.greatestFiniteMagnitude
        t.expectThrows("SYNC finite coordinates beyond renderable range rejected") { _ = try plan(mutation(after: invalid)) }
        invalid = node
        invalid.width = Double.greatestFiniteMagnitude
        t.expectThrows("SYNC oversized geometry cannot overflow native previews") { _ = try plan(mutation(after: invalid)) }
        var viewport = original
        viewport.panX = 999; viewport.panY = -500; viewport.zoom = 2
        viewport.updatedAt = Date().addingTimeInterval(50)
        t.equal(AgentCanvasSync.revision(original), AgentCanvasSync.revision(viewport),
                "SYNC viewport and save time do not create false graph conflicts")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CanvasStorage(rootOverride: root)
        t.check(storage.save(original, projectId: "project"), "SYNC baseline document saved")
        try storage.saveComparingGraph(first.document, expectedRevision: AgentCanvasSync.revision(original), projectId: "project")
        storage.invalidateCache()
        t.equal(storage.load(projectId: "project").nodes[0].width, resized.width,
                "SYNC cross-process compare and save persists graph change")
        t.expectThrows("SYNC stale disk revision cannot overwrite a newer command") {
            try storage.saveComparingGraph(original, expectedRevision: AgentCanvasSync.revision(original), projectId: "project")
        }
        t.equal(storage.load(projectId: "project").appliedAgentMutationIDs.count, 1,
                "SYNC receipt identity persisted atomically with graph")
    } catch { t.check(false, "SYNC setup \(error)") }
}
