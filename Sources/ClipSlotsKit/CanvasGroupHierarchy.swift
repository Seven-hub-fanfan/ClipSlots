import Foundation
import CoreGraphics

/// All persisted rectangles are world-space. Only the gateway's after snapshots
/// may be parent-local; conversion is performed once, before graph publication.
public enum CanvasGroupHierarchy {
    public static let maximumDepth = 64
    public static let maximumGroups = 1000

    public static func validate(_ groups: [CanvasNodeGroup], nodeIDs: Set<String>) throws {
        guard groups.count <= maximumGroups, Set(groups.map(\.id)).count == groups.count else {
            throw AgentOperationError("编组身份重复或数量超出上限。")
        }
        let ids = Set(groups.map(\.id))
        var owners = Set<String>()
        for group in groups {
            guard !group.id.isEmpty, group.id.utf8.count <= 512, !nodeIDs.contains(group.id),
                  group.name.utf8.count <= 4096,
                  (group.measuredLayoutSignature?.utf8.count ?? 0) <= 262_144,
                  group.nodeIDs.allSatisfy({ nodeIDs.contains($0) && owners.insert($0).inserted }),
                  group.parentGroupID.map(ids.contains) ?? true else {
                throw AgentOperationError("编组包含重复归属、缺失成员或缺失父容器。")
            }
            if let frame = group.containerFrame {
                guard validWorldFrame(frame) else { throw AgentOperationError("编组坐标或尺寸非法。") }
            } else if group.parentGroupID != nil || group.provenance == .server {
                throw AgentOperationError("嵌套或服务端容器必须提供明确边界。")
            }
            guard !group.nodeIDs.isEmpty || group.provenance == .server
                    || groups.contains(where: { $0.parentGroupID == group.id }) else {
                throw AgentOperationError("空 client 编组必须显式解除，不能提交被静默丢弃的容器。")
            }
            var seen: Set<String> = [group.id], parent = group.parentGroupID, depth = 1
            while let id = parent {
                depth += 1
                guard seen.insert(id).inserted, depth <= maximumDepth,
                      let ancestor = groups.first(where: { $0.id == id }) else {
                    throw AgentOperationError("编组父链包含环或超出深度上限。")
                }
                guard ancestor.containerFrame != nil else {
                    throw AgentOperationError("父容器没有可用于坐标转换的边界。")
                }
                parent = ancestor.parentGroupID
            }
        }
    }

    public static func validWorldFrame(_ frame: CGRect) -> Bool {
        CanvasGroupGeometry.isValid(frame) &&
            abs(frame.minX) <= 10_000_000 && abs(frame.minY) <= 10_000_000 &&
            abs(frame.maxX) <= 10_000_000 && abs(frame.maxY) <= 10_000_000 &&
            frame.width <= 1_000_000 && frame.height <= 1_000_000
    }

    public static func depth(_ id: String, groups: [CanvasNodeGroup]) -> Int {
        var seen = Set<String>(), next: String? = id, result = -1
        while let value = next, seen.insert(value).inserted, result < maximumDepth {
            result += 1
            next = groups.first(where: { $0.id == value })?.parentGroupID
        }
        return max(0, result)
    }

    public static func parentFirst(_ groups: [CanvasNodeGroup]) -> [CanvasNodeGroup] {
        groups.enumerated().sorted {
            let a = depth($0.element.id, groups: groups), b = depth($1.element.id, groups: groups)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    public static func subtreeIDs(_ id: String, groups: [CanvasNodeGroup]) -> Set<String> {
        var result: Set<String> = [id]
        for _ in 0..<maximumDepth {
            let children = Set(groups.filter { $0.parentGroupID.map(result.contains) == true }.map(\.id))
            let next = result.union(children)
            if next == result { break }
            result = next
        }
        return result
    }

    public static func memberIDs(_ id: String, groups: [CanvasNodeGroup]) -> Set<String> {
        let containers = subtreeIDs(id, groups: groups)
        return Set(groups.filter { containers.contains($0.id) }.flatMap(\.nodeIDs))
    }

    public static func owner(of nodeID: String, groups: [CanvasNodeGroup]) -> CanvasNodeGroup? {
        groups.first { $0.nodeIDs.contains(nodeID) }
    }

    public static func localOrigin(of node: CanvasNode, groups: [CanvasNodeGroup]) -> CGPoint {
        guard let origin = owner(of: node.id, groups: groups)?.containerFrame?.origin else { return node.frame.origin }
        return CGPoint(x: node.x - origin.x, y: node.y - origin.y)
    }

    public static func localFrame(of group: CanvasNodeGroup, groups: [CanvasNodeGroup]) -> CGRect? {
        guard let frame = group.containerFrame else { return nil }
        guard let parent = groups.first(where: { $0.id == group.parentGroupID })?.containerFrame else { return frame }
        return frame.offsetBy(dx: -parent.minX, dy: -parent.minY)
    }

    /// Reparents children and releases direct members without changing world geometry.
    public static func dissolving(_ ids: Set<String>, groups: [CanvasNodeGroup]) -> [CanvasNodeGroup] {
        groups.filter { !ids.contains($0.id) }.map { group in
            var copy = group, parent = copy.parentGroupID, seen = Set<String>()
            while let id = parent, ids.contains(id), seen.insert(id).inserted {
                parent = groups.first(where: { $0.id == id })?.parentGroupID
            }
            copy.parentGroupID = parent
            return copy
        }
    }

    /// Parent moves and left/top resize shifts preserve every descendant's local
    /// position. Each entity is translated once, regardless of nesting depth.
    public static func moving(_ id: String, by delta: CGSize, in document: CanvasDocument,
                              disableAutoLayout: Bool = true) throws -> CanvasDocument {
        guard delta.width.isFinite, delta.height.isFinite,
              let root = document.groups.first(where: { $0.id == id }),
              let rootFrame = CanvasGroupGeometry.frame(root, nodes: document.nodes) else {
            throw AgentOperationError("编组移动目标或位移非法。")
        }
        var next = document
        let containers = subtreeIDs(id, groups: next.groups)
        let members = memberIDs(id, groups: next.groups)
        for i in next.groups.indices where containers.contains(next.groups[i].id) {
            let frame = next.groups[i].containerFrame ?? (next.groups[i].id == id ? rootFrame : nil)
            next.groups[i].containerFrame = frame?.offsetBy(dx: delta.width, dy: delta.height)
            if disableAutoLayout { next.groups[i].autoLayoutEnabled = false }
        }
        for i in next.nodes.indices where members.contains(next.nodes[i].id) {
            next.nodes[i].x += delta.width; next.nodes[i].y += delta.height
            guard validWorldFrame(next.nodes[i].frame) else { throw AgentOperationError("移动超出画布坐标上限。") }
        }
        for i in next.piles.indices where next.piles[i].groupID.map(containers.contains) == true {
            next.piles[i].x += delta.width; next.piles[i].y += delta.height
        }
        try validate(next.groups, nodeIDs: Set(next.nodes.map(\.id)))
        return next
    }

    public static func resizing(_ id: String, to frame: CGRect, in document: CanvasDocument) throws -> CanvasDocument {
        guard validWorldFrame(frame), let group = document.groups.first(where: { $0.id == id }),
              let old = CanvasGroupGeometry.frame(group, nodes: document.nodes) else {
            throw AgentOperationError("编组缩放边界非法。")
        }
        var next = try moving(id, by: CGSize(width: frame.minX - old.minX, height: frame.minY - old.minY), in: document)
        if let index = next.groups.firstIndex(where: { $0.id == id }) { next.groups[index].containerFrame = frame }
        return next
    }

    /// Local edits of old flat groups keep the historical frame-only resize.
    public static func hasHierarchy(_ id: String, groups: [CanvasNodeGroup]) -> Bool {
        groups.contains { $0.id == id && $0.parentGroupID != nil } ||
            groups.contains { $0.parentGroupID == id }
    }
}
