import Foundation

/// A self-owned gateway delivers typed changes against the exact turn snapshot.
/// A complete proposal is validated before any live graph is written.
public struct AgentCanvasMutation: Codable, Sendable {
    public struct NodeChange: Codable, Sendable {
        public var before: CanvasNode?
        public var after: CanvasNode?
        public init(before: CanvasNode?, after: CanvasNode?) { self.before = before; self.after = after }
    }
    public struct GroupChange: Codable, Sendable {
        /// before is always the persisted world-space snapshot.
        public var before: CanvasNodeGroup?
        public var after: CanvasNodeGroup?
        public init(before: CanvasNodeGroup?, after: CanvasNodeGroup?) { self.before = before; self.after = after }
    }
    public enum CoordinateSpace: String, Codable, Sendable { case world, parentLocal = "parent_local" }
    public let projectID: String
    public let conversationID: String
    public let runID: String
    public let mutationID: String
    public let changes: [NodeChange]
    public let addedEdges: [CanvasEdge]
    public let removedEdges: [CanvasEdge]
    public let groupChanges: [GroupChange]
    /// Applies to after group rectangles and after node positions only.
    public let coordinateSpace: CoordinateSpace
    public init(projectID: String, conversationID: String, runID: String, mutationID: String,
                changes: [NodeChange], addedEdges: [CanvasEdge] = [], removedEdges: [CanvasEdge] = [],
                groupChanges: [GroupChange] = [], coordinateSpace: CoordinateSpace = .world) {
        self.projectID = projectID; self.conversationID = conversationID; self.runID = runID
        self.mutationID = mutationID; self.changes = changes
        self.addedEdges = addedEdges; self.removedEdges = removedEdges
        self.groupChanges = groupChanges; self.coordinateSpace = coordinateSpace
    }
    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id", conversationID = "conversation_id", runID = "run_id"
        case mutationID = "mutation_id", changes, addedEdges = "added_edges", removedEdges = "removed_edges"
        case groupChanges = "group_changes", coordinateSpace = "coordinate_space"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(String.self, forKey: .projectID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        runID = try c.decode(String.self, forKey: .runID)
        mutationID = try c.decode(String.self, forKey: .mutationID)
        changes = try c.decode([NodeChange].self, forKey: .changes)
        addedEdges = try c.decodeIfPresent([CanvasEdge].self, forKey: .addedEdges) ?? []
        removedEdges = try c.decodeIfPresent([CanvasEdge].self, forKey: .removedEdges) ?? []
        groupChanges = try c.decodeIfPresent([GroupChange].self, forKey: .groupChanges) ?? []
        coordinateSpace = try c.decodeIfPresent(CoordinateSpace.self, forKey: .coordinateSpace) ?? .world
    }
}

public enum AgentCanvasSync {
    public struct Plan {
        public let document: CanvasDocument
        public let changedNodeIDs: [String]
        public let preservedLocalPositions: [String]
        public let changedGroupIDs: [String]
        public let preservedLocalGroupPositions: [String]
        public let alreadyApplied: Bool
    }
    private static func configuration(_ node: CanvasNode, ignoringPosition: Bool = false) -> CanvasNode {
        var node = node
        node.updatedAt = Date(timeIntervalSinceReferenceDate: 0)
        if ignoringPosition { node.x = 0; node.y = 0 }
        return node
    }
    public static func revision(_ document: CanvasDocument) -> String {
        var semantic = document
        semantic.updatedAt = Date(timeIntervalSinceReferenceDate: 0)
        semantic.panX = 0; semantic.panY = 0; semantic.zoom = 1
        return CanvasWorkflowSnapshot.digest((try? CanvasWorkflowSnapshot.jsonData(semantic)) ?? Data())
    }
    public static func plan(_ mutation: AgentCanvasMutation, current: CanvasDocument,
                            expectedProject: String, expectedConversation: String,
                            expectedRun: String) throws -> Plan {
        guard mutation.projectID == expectedProject, mutation.conversationID == expectedConversation,
              mutation.runID == expectedRun, !mutation.mutationID.isEmpty,
              mutation.mutationID.utf8.count <= 256,
              mutation.changes.count <= 1000, mutation.addedEdges.count <= 2000,
              mutation.removedEdges.count <= 2000,
              mutation.groupChanges.count <= CanvasGroupHierarchy.maximumGroups else {
            throw AgentOperationError("画布变更不属于此会话与运行，或超出同步上限。")
        }
        let key = CanvasWorkflowSnapshot.digest(Data(
            "\(mutation.conversationID)\u{0}\(mutation.runID)\u{0}\(mutation.mutationID)".utf8))
        if current.appliedAgentMutationIDs.contains(key) {
            return .init(document: current, changedNodeIDs: [], preservedLocalPositions: [],
                         changedGroupIDs: [], preservedLocalGroupPositions: [], alreadyApplied: true)
        }
        var next = current, changed: [String] = [], preserved: [String] = []
        let groupPlan = try AgentCanvasGroupSync.prepare(mutation, current: current)
        next.groups = groupPlan.groups
        let explicitNodes = Set(mutation.changes.compactMap { ($0.after ?? $0.before)?.id })
        for i in next.nodes.indices where !explicitNodes.contains(next.nodes[i].id) {
            if let delta = groupPlan.nodeDeltas[next.nodes[i].id] {
                next.nodes[i].x += delta.width; next.nodes[i].y += delta.height
                changed.append(next.nodes[i].id)
            }
        }
        for i in next.piles.indices {
            if let id = next.piles[i].groupID, let delta = groupPlan.groupDeltas[id] {
                next.piles[i].x += delta.width; next.piles[i].y += delta.height
            }
        }
        var claims = Set<String>()
        for rawChange in mutation.changes {
            let change = try AgentCanvasGroupSync.worldChange(rawChange, space: mutation.coordinateSpace, groups: next.groups)
            guard let reference = change.after ?? change.before,
                  claims.insert(reference.id).inserted,
                  change.before?.id == nil || change.after?.id == nil || change.before?.id == change.after?.id else {
                throw AgentOperationError("画布快照包含重复或不完整的节点身份。")
            }
            for node in [change.before, change.after].compactMap({ $0 }) {
                guard node.x.isFinite, node.y.isFinite, node.width.isFinite, node.height.isFinite,
                      abs(node.x) <= 10_000_000, abs(node.y) <= 10_000_000,
                      node.width > 0, node.height > 0, node.width <= 1_000_000, node.height <= 1_000_000,
                      !node.id.isEmpty, node.id.utf8.count <= 512,
                      !node.groupId.isEmpty, node.groupId.utf8.count <= 256,
                      !node.pageId.isEmpty, node.pageId.utf8.count <= 256,
                      (1...10).contains(node.slot), node.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw AgentOperationError("节点快照包含非法坐标或内容绑定。")
                }
            }
            let index = next.nodes.firstIndex { $0.id == reference.id }
            if let before = change.before {
                guard let index, let original = current.nodes.first(where: { $0.id == reference.id }),
                      original.createdAt == before.createdAt,
                      change.after?.createdAt == nil || change.after?.createdAt == before.createdAt else {
                    throw AgentOperationError("节点已删除或重新绑定，未应用过期变更。")
                }
                if let after = change.after {
                    if configuration(original) == configuration(before) { next.nodes[index] = after }
                    else {
                        let liveConfig = configuration(original, ignoringPosition: true)
                        let baseConfig = configuration(before, ignoringPosition: true)
                        let remoteConfig = configuration(after, ignoringPosition: true)
                        if liveConfig == baseConfig && after.x == before.x && after.y == before.y {
                            var merged = after
                            merged.x = original.x; merged.y = original.y
                            merged.updatedAt = max(original.updatedAt, after.updatedAt)
                            next.nodes[index] = merged
                            preserved.append(reference.id)
                        } else if remoteConfig == baseConfig && original.x == before.x && original.y == before.y {
                            var merged = original
                            merged.x = after.x; merged.y = after.y
                            merged.updatedAt = max(original.updatedAt, after.updatedAt)
                            next.nodes[index] = merged
                        } else { throw AgentOperationError("节点已被本地编辑，与远端变更冲突，请重新生成预览。") }
                    }
                } else {
                    guard configuration(original) == configuration(before) else {
                        throw AgentOperationError("节点已有后续修改，未删除。")
                    }
                    next.nodes.remove(at: index)
                }
            } else {
                guard index == nil, let after = change.after else {
                    throw AgentOperationError("新增节点身份已存在，未覆盖当前内容。")
                }
                next.nodes.append(after)
            }
            changed.append(reference.id)
        }
        guard Set(mutation.removedEdges.map(\.id)).count == mutation.removedEdges.count,
              Set(mutation.addedEdges.map(\.id)).count == mutation.addedEdges.count else {
            throw AgentOperationError("同步连线包含重复身份。")
        }
        for edge in mutation.removedEdges {
            guard let index = next.edges.firstIndex(of: edge) else {
                throw AgentOperationError("待移除连线已改变，未提交不完整图。")
            }
            next.edges.remove(at: index)
        }
        for edge in mutation.addedEdges {
            guard !next.edges.contains(where: { $0.id == edge.id }) else {
                throw AgentOperationError("新增连线身份与当前图冲突。")
            }
            next.edges.append(edge)
        }
        let alive = Set(next.nodes.map(\.id))
        guard next.edges.allSatisfy({ alive.contains($0.fromNodeId) && alive.contains($0.toNodeId) }),
              CanvasEdgeGraph.normalized(next.edges, nodeIds: alive) == next.edges else {
            throw AgentOperationError("同步快照缺少连线端点或包含非法连线，未提交半份图。")
        }
        // Deletions are explicit and user-confirmed. Only the affected group
        // memberships change; unrelated entities keep their original identity.
        for i in next.groups.indices { next.groups[i].nodeIDs.removeAll { !alive.contains($0) } }
        next.groups = CanvasNodeGroup.normalized(next.groups, nodeIDs: alive)
        try CanvasGroupHierarchy.validate(next.groups, nodeIDs: alive)
        guard next.nodes.allSatisfy({ CanvasGroupHierarchy.validWorldFrame($0.frame) }) else {
            throw AgentOperationError("父链转换后节点超出画布坐标上限。")
        }
        next.piles = CanvasPile.normalized(next.piles, nodes: next.nodes)
        next.appliedAgentMutationIDs = Array((next.appliedAgentMutationIDs + [key]).suffix(1000))
        return .init(document: next, changedNodeIDs: changed,
                     preservedLocalPositions: preserved, changedGroupIDs: groupPlan.changedGroupIDs,
                     preservedLocalGroupPositions: groupPlan.preservedGroupIDs, alreadyApplied: false)
    }
}
