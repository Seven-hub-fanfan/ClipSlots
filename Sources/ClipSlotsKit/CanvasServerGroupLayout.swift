import Foundation
import CoreGraphics

/// Self-owned layout receipts, not a private service position-persist protocol.
public enum CanvasServerGroupLayout {
    public enum State: String { case waitingForMeasurements, nestedServer, unchanged, applied, disabled, blockedByPile }
    public struct Result {
        public let document: CanvasDocument
        public let states: [String: State]
        public let appliedGroupIDs: [String]
    }
    private struct MeasuredMember: Encodable {
        let id: String
        let width: CGFloat
        let height: CGFloat
    }

    public static func signature(_ id: String, document: CanvasDocument,
                                 measurements: [String: CGSize]) -> String? {
        let members = CanvasGroupHierarchy.memberIDs(id, groups: document.groups)
        guard !members.isEmpty else { return nil }
        var parts: [MeasuredMember] = []
        for node in document.nodes.filter({ members.contains($0.id) }).sorted(by: { $0.id < $1.id }) {
            guard let size = measurements[node.id], size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0,
                  abs(size.width - node.width) < 0.01, abs(size.height - node.height) < 0.01 else { return nil }
            parts.append(MeasuredMember(id: node.id, width: node.width, height: node.height))
        }
        guard parts.count == members.count, let data = try? CanvasWorkflowSnapshot.jsonData(parts) else { return nil }
        return CanvasWorkflowSnapshot.digest(data)
    }

    private static func hasServerAncestor(_ group: CanvasNodeGroup, groups: [CanvasNodeGroup]) -> Bool {
        var parent = group.parentGroupID, seen = Set<String>()
        while let id = parent, seen.insert(id).inserted,
              let ancestor = groups.first(where: { $0.id == id }) {
            if ancestor.provenance == .server { return true }
            parent = ancestor.parentGroupID
        }
        return false
    }

    public static func reconcile(_ document: CanvasDocument, measurements: [String: CGSize],
                                 suppressedGroupIDs: Set<String> = []) throws -> Result {
        try CanvasGroupHierarchy.validate(document.groups, nodeIDs: Set(document.nodes.map(\.id)))
        var next = document, states: [String: State] = [:], applied: [String] = []
        for group in CanvasGroupHierarchy.parentFirst(document.groups) where group.provenance == .server {
            if hasServerAncestor(group, groups: document.groups) { states[group.id] = .nestedServer; continue }
            if group.autoLayoutEnabled == false || suppressedGroupIDs.contains(group.id) {
                states[group.id] = .disabled; continue
            }
            let members = CanvasGroupHierarchy.memberIDs(group.id, groups: next.groups)
            if next.piles.contains(where: { !members.isDisjoint(with: $0.memberIDs) }) {
                states[group.id] = .blockedByPile; continue
            }
            guard let value = signature(group.id, document: next, measurements: measurements) else {
                states[group.id] = .waitingForMeasurements; continue
            }
            if group.measuredLayoutSignature == value { states[group.id] = .unchanged; continue }
            next = try arranging(group.id, layout: group.layoutType ?? .horizontal, in: next)
            if let index = next.groups.firstIndex(where: { $0.id == group.id }) {
                next.groups[index].measuredLayoutSignature = value
            }
            states[group.id] = .applied
            applied.append(group.id)
        }
        try CanvasGroupHierarchy.validate(next.groups, nodeIDs: Set(next.nodes.map(\.id)))
        return Result(document: next, states: states, appliedGroupIDs: applied)
    }

    /// Immediate child containers are atomic layout units. Their descendants
    /// move once with the container; their internal layout is not recomputed.
    public static func arranging(_ id: String, layout: CanvasGroupLayoutType,
                                 in document: CanvasDocument) throws -> CanvasDocument {
        guard let group = document.groups.first(where: { $0.id == id }),
              let frame = CanvasGroupGeometry.frame(group, nodes: document.nodes) else {
            throw AgentOperationError("编组没有可布局的容器边界。")
        }
        let members = CanvasGroupHierarchy.memberIDs(id, groups: document.groups)
        guard !document.piles.contains(where: { !members.isDisjoint(with: $0.memberIDs) }) else {
            throw AgentOperationError("多层布局暂不重排 Pile；仍可移动和缩放整组。")
        }
        let children = document.groups.filter { $0.parentGroupID == id }
        var units = document.nodes.filter { group.nodeIDs.contains($0.id) }
        var childUnits: [String: String] = [:], projected: [String: String] = [:]
        for node in units { projected[node.id] = node.id }
        for child in children {
            guard let bounds = child.containerFrame else { throw AgentOperationError("子容器缺少布局边界。") }
            let unit = CanvasNode(pageId: "__layout__", groupId: "__container_layout__" + child.id, slot: 1,
                                  x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
            guard !units.contains(where: { $0.id == unit.id }) else {
                throw AgentOperationError("临时布局单元身份冲突。")
            }
            units.append(unit)
            childUnits[unit.id] = child.id
            for member in CanvasGroupHierarchy.memberIDs(child.id, groups: document.groups) { projected[member] = unit.id }
        }
        guard !units.isEmpty else { return document }
        var pairs = Set<String>()
        let edges = document.edges.compactMap { edge -> CanvasEdge? in
            guard let from = projected[edge.fromNodeId], let to = projected[edge.toNodeId], from != to,
                  pairs.insert(from + "\u{0}" + to).inserted else { return nil }
            return CanvasEdge(fromNodeId: from, toNodeId: to)
        }
        let origins: [String: CGPoint], bounds: CGRect
        if layout == .grid {
            let result = CanvasGroupGeometry.grid(nodes: units, at: frame.origin)
            origins = result.origins; bounds = result.frame
        } else {
            guard let result = CanvasDagreLayout.layout(nodes: units, edges: edges, at: frame.origin) else {
                throw AgentOperationError("横向布局引擎加载失败，未回写编组。")
            }
            origins = result.origins; bounds = result.frame
        }
        guard CanvasGroupHierarchy.validWorldFrame(bounds) else {
            throw AgentOperationError("编组布局结果超出坐标上限。")
        }
        var next = document
        for unit in units {
            guard let origin = origins[unit.id] else { throw AgentOperationError("编组布局结果不完整。") }
            if let childID = childUnits[unit.id] {
                next = try CanvasGroupHierarchy.moving(childID,
                    by: CGSize(width: origin.x - unit.x, height: origin.y - unit.y), in: next, disableAutoLayout: false)
            } else if let index = next.nodes.firstIndex(where: { $0.id == unit.id }) {
                next.nodes[index].setFrameOrigin(origin)
            }
        }
        if let index = next.groups.firstIndex(where: { $0.id == id }) {
            next.groups[index].containerFrame = bounds
            next.groups[index].layoutType = layout
        }
        try CanvasGroupHierarchy.validate(next.groups, nodeIDs: Set(next.nodes.map(\.id)))
        guard next.nodes.allSatisfy({ CanvasGroupHierarchy.validWorldFrame($0.frame) }) else {
            throw AgentOperationError("编组布局后的成员坐标非法。")
        }
        return next
    }
}
