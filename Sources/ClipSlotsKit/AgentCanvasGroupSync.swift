import Foundation
import CoreGraphics

enum AgentCanvasGroupSync {
    struct Prepared {
        let groups: [CanvasNodeGroup]
        let groupDeltas: [String: CGSize]
        let nodeDeltas: [String: CGSize]
        let changedGroupIDs: [String]
        let preservedGroupIDs: [String]
    }

    private static func withoutFrame(_ group: CanvasNodeGroup) -> CanvasNodeGroup {
        var copy = group
        copy.containerFrame = nil
        copy.autoLayoutEnabled = nil
        copy.measuredLayoutSignature = nil
        return copy
    }

    static func prepare(_ mutation: AgentCanvasMutation, current: CanvasDocument) throws -> Prepared {
        guard Set(current.nodes.map(\.id)).count == current.nodes.count else {
            throw AgentOperationError("当前画布节点身份不唯一。")
        }
        try CanvasGroupHierarchy.validate(current.groups, nodeIDs: Set(current.nodes.map(\.id)))
        var groups = current.groups, claims = Set<String>(), afterIDs = Set<String>()
        var preserved: [String] = []
        let deletedNodes = Set(mutation.changes.filter { $0.after == nil }.compactMap { $0.before?.id })
        let alive = Set(current.nodes.map(\.id)).subtracting(deletedNodes)
            .union(mutation.changes.compactMap { $0.after?.id })
        for change in mutation.groupChanges {
            guard let reference = change.after ?? change.before,
                  claims.insert(reference.id).inserted,
                  change.before == nil || change.after == nil || change.before?.id == change.after?.id else {
                throw AgentOperationError("编组 proposal 包含重复、改写或缺失身份。")
            }
            if let before = change.before, let frame = before.containerFrame,
               !CanvasGroupHierarchy.validWorldFrame(frame) {
                throw AgentOperationError("编组原快照包含非法边界。")
            }
            let index = groups.firstIndex { $0.id == reference.id }
            if let before = change.before {
                guard let index else { throw AgentOperationError("编组已经删除，未重建过期身份。") }
                let live = groups[index]
                if var after = change.after {
                    guard live.provenance == before.provenance, after.provenance == before.provenance else {
                        throw AgentOperationError("编组来源身份不能由更新改写。")
                    }
                    // Measurement receipts are client-owned, never gateway authority.
                    after.measuredLayoutSignature = live.measuredLayoutSignature
                    if live != before {
                        guard mutation.coordinateSpace == .world,
                              withoutFrame(live) == withoutFrame(before),
                              before.containerFrame == after.containerFrame,
                              before.parentGroupID == after.parentGroupID,
                              before.autoLayoutEnabled == after.autoLayoutEnabled else {
                            throw AgentOperationError("编组已有本地修改，与服务端 proposal 冲突。")
                        }
                        after.containerFrame = live.containerFrame
                        after.autoLayoutEnabled = live.autoLayoutEnabled
                        preserved.append(after.id)
                    }
                    groups[index] = after
                    afterIDs.insert(after.id)
                } else {
                    guard live == before else { throw AgentOperationError("编组已有后续修改，未解除容器。") }
                    groups.remove(at: index)
                }
            } else {
                guard index == nil, var after = change.after else {
                    throw AgentOperationError("新增编组身份已存在，未覆盖。")
                }
                after.measuredLayoutSignature = nil
                groups.append(after)
                afterIDs.insert(after.id)
            }
        }
        // Deleting a node may prune unchanged membership. Explicit after
        // snapshots must be complete; they are not silently repaired.
        for i in groups.indices where !afterIDs.contains(groups[i].id) {
            groups[i].nodeIDs.removeAll { deletedNodes.contains($0) }
        }
        if !deletedNodes.isEmpty {
            var pruning = true
            while pruning {
                let parents = Set(groups.compactMap(\.parentGroupID))
                let count = groups.count
                groups.removeAll { !afterIDs.contains($0.id) && $0.nodeIDs.isEmpty
                    && $0.provenance != .server && !parents.contains($0.id) }
                pruning = groups.count != count
            }
        }
        try CanvasGroupHierarchy.validate(groups, nodeIDs: alive)
        var deltas: [String: CGSize] = [:]
        for group in CanvasGroupHierarchy.parentFirst(groups) {
            guard let index = groups.firstIndex(where: { $0.id == group.id }),
                  let frame = groups[index].containerFrame else { continue }
            if let parentID = group.parentGroupID {
                if afterIDs.contains(group.id), mutation.coordinateSpace == .parentLocal {
                    guard let parent = groups.first(where: { $0.id == parentID })?.containerFrame else {
                        throw AgentOperationError("无法解析编组父容器的世界边界。")
                    }
                    groups[index].containerFrame = frame.offsetBy(dx: parent.minX, dy: parent.minY)
                } else if !afterIDs.contains(group.id), let delta = deltas[parentID] {
                    groups[index].containerFrame = frame.offsetBy(dx: delta.width, dy: delta.height)
                }
            }
            if let old = current.groups.first(where: { $0.id == group.id })?.containerFrame,
               let new = groups[index].containerFrame {
                deltas[group.id] = CGSize(width: new.minX - old.minX, height: new.minY - old.minY)
            }
        }
        try CanvasGroupHierarchy.validate(groups, nodeIDs: alive)
        var nodeDeltas: [String: CGSize] = [:]
        for node in current.nodes {
            // A reparent retains world position unless an explicit after node
            // declares otherwise. An unchanged owner follows its moved parent.
            let old = CanvasGroupHierarchy.owner(of: node.id, groups: current.groups)?.id
            let new = CanvasGroupHierarchy.owner(of: node.id, groups: groups)?.id
            if old == new, let id = new, let delta = deltas[id], delta != .zero { nodeDeltas[node.id] = delta }
        }
        let changed = groups.filter { group in current.groups.first(where: { $0.id == group.id }) != group }.map(\.id)
        let removed = current.groups.filter { group in !groups.contains(where: { $0.id == group.id }) }.map(\.id)
        return Prepared(groups: groups, groupDeltas: deltas, nodeDeltas: nodeDeltas,
                        changedGroupIDs: changed + removed, preservedGroupIDs: preserved)
    }

    static func worldChange(_ change: AgentCanvasMutation.NodeChange,
                            space: AgentCanvasMutation.CoordinateSpace,
                            groups: [CanvasNodeGroup]) throws -> AgentCanvasMutation.NodeChange {
        guard space == .parentLocal, var after = change.after,
              let owner = CanvasGroupHierarchy.owner(of: after.id, groups: groups) else { return change }
        guard let frame = owner.containerFrame else { throw AgentOperationError("节点父容器没有明确坐标。") }
        after.x += frame.minX; after.y += frame.minY
        guard CanvasGroupHierarchy.validWorldFrame(after.frame) else {
            throw AgentOperationError("节点 parent-local 转换结果非法。")
        }
        return .init(before: change.before, after: after)
    }
}
