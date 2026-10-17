import Foundation
import CoreGraphics

/// Nodes keep world coordinates and their original storage identities. Optional
/// container fields allow older membership-only documents to decode unchanged.
public struct CanvasNodeGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var nodeIDs: [String]
    public var containerFrame: CGRect?
    public var color: CanvasGroupColor?
    public var layoutType: CanvasGroupLayoutType?
    public var workflowSkillID: UUID?
    /// Container ancestry only; nodeIDs are direct, uniquely owned members.
    public var parentGroupID: String?
    public var createdBy: CanvasGroupProvenance?
    public var autoLayoutEnabled: Bool?
    public var measuredLayoutSignature: String?

    public var provenance: CanvasGroupProvenance { createdBy ?? .client }

    public init(id: String = UUID().uuidString, name: String = "新建组", nodeIDs: [String],
                containerFrame: CGRect? = nil, color: CanvasGroupColor? = nil,
                layoutType: CanvasGroupLayoutType? = nil, parentGroupID: String? = nil,
                createdBy: CanvasGroupProvenance? = nil, autoLayoutEnabled: Bool? = nil) {
        self.id = id
        self.name = name
        self.nodeIDs = nodeIDs
        self.containerFrame = containerFrame
        self.color = color
        self.layoutType = layoutType
        self.parentGroupID = parentGroupID
        self.createdBy = createdBy
        self.autoLayoutEnabled = autoLayoutEnabled
    }

    public static func normalized(_ groups: [Self], nodeIDs: Set<String>) -> [Self] {
        var members = Set<String>(), identities = Set<String>()
        var result = groups.compactMap { group -> Self? in
            guard identities.insert(group.id).inserted else { return nil }
            var copy = group
            copy.nodeIDs = group.nodeIDs.filter { nodeIDs.contains($0) && members.insert($0).inserted }
            if let frame = copy.containerFrame, !CanvasGroupGeometry.isValid(frame) { copy.containerFrame = nil }
            return copy
        }
        let allIDs = Set(result.map(\.id))
        // Disk recovery is lenient; gateway proposals use strict validation.
        for i in result.indices {
            var seen: Set<String> = [result[i].id]
            var parent = result[i].parentGroupID
            var depth = 0
            while let id = parent {
                depth += 1
                guard allIDs.contains(id), seen.insert(id).inserted,
                      depth < CanvasGroupHierarchy.maximumDepth else {
                    result[i].parentGroupID = nil
                    break
                }
                parent = result.first(where: { $0.id == id })?.parentGroupID
            }
        }
        // Retain structural ancestors and explicit server containers, including
        // empty snapshots awaiting their members. Empty legacy flat groups drop.
        var changed = true
        while changed {
            let parents = Set(result.compactMap(\.parentGroupID))
            let oldCount = result.count
            result.removeAll { $0.nodeIDs.isEmpty && !parents.contains($0.id) && $0.provenance != .server }
            changed = oldCount != result.count
        }
        return result
    }
}

public enum CanvasGroupProvenance: String, Codable, Sendable { case client, server }

public enum CanvasGroupLayout {
    /// Left-to-right dependency layers, deterministic grid for disconnected nodes.
    /// Cycles remain visible in a final column; the execution path rejects cycles.
    public static func origins(nodes: [CanvasNode], edges: [CanvasEdge], at anchor: CGPoint) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let ids = Set(nodes.map(\.id))
        let links = edges.filter { ids.contains($0.fromNodeId) && ids.contains($0.toNodeId) }
        let sorted = nodes.sorted { $0.y == $1.y ? ($0.x == $1.x ? $0.id < $1.id : $0.x < $1.x) : $0.y < $1.y }
        var columns: [[CanvasNode]] = []
        if links.isEmpty {
            let rows = max(1, Int(ceil(sqrt(Double(nodes.count)))))
            for start in stride(from: 0, to: sorted.count, by: rows) {
                columns.append(Array(sorted[start..<min(start + rows, sorted.count)]))
            }
        } else {
            var remaining = ids
            while !remaining.isEmpty {
                let layer = sorted.filter { node in
                    remaining.contains(node.id) && !links.contains { $0.toNodeId == node.id && remaining.contains($0.fromNodeId) }
                }
                if layer.isEmpty {
                    columns.append(sorted.filter { remaining.contains($0.id) })
                    break
                }
                columns.append(layer)
                remaining.subtract(layer.map(\.id))
            }
        }
        var result: [String: CGPoint] = [:], x = anchor.x
        for column in columns {
            var y = anchor.y
            for node in column {
                result[node.id] = CGPoint(x: x, y: y)
                y += node.height + 200
            }
            x += (column.map(\.width).max() ?? 320) + 200
        }
        return result
    }
}
