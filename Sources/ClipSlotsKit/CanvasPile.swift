import Foundation

/// A presentation entity, separate from both slot groups and canvas Groups.
/// Members continue to own their original slot IDs, content, and graph edges.
public struct CanvasPile: Codable, Identifiable, Equatable {
    public var id: String
    public var memberIDs: [String] // bottom to top (TapNow Ky/gAe)
    public var x: CGFloat
    public var y: CGFloat
    public var groupID: String?

    public init(id: String = "PILE-" + UUID().uuidString, memberIDs: [String],
                at point: CGPoint, groupID: String? = nil) {
        self.id = id; self.memberIDs = memberIDs
        x = point.x; y = point.y; self.groupID = groupID
    }

    public static func normalized(_ piles: [CanvasPile], nodes: [CanvasNode]) -> [CanvasPile] {
        let alive = Set(nodes.filter(CanvasPileGeometry.isEligible).map(\.id))
        var claimed = Set<String>(), identities = Set<String>()
        return piles.compactMap { pile in
            guard !pile.id.isEmpty, !alive.contains(pile.id),
                  pile.x.isFinite, pile.y.isFinite, identities.insert(pile.id).inserted else { return nil }
            var next = pile, seen = Set<String>()
            next.memberIDs = pile.memberIDs.filter {
                alive.contains($0) && !claimed.contains($0) && seen.insert($0).inserted
            }
            guard (2...50).contains(next.memberIDs.count) else { return nil }
            claimed.formUnion(next.memberIDs)
            return next
        }
    }
}

public enum CanvasPileGeometry {
    public static let maxMembers = 50
    public static let unstackGap: CGFloat = 128
    public static let reflowDuration = 0.34
    public static let entryDuration = 0.46
    public static let unstackDuration = 0.44
    public static let galleryDuration = 0.5
    public static let galleryInitialZoom: CGFloat = 0.6

    public struct Layer: Equatable {
        public var offset: CGPoint
        public var rotation: Double
        public var shade: Double
    }
    // Recovered uP and hb; order is bottom to top.
    private static let layouts: [[(CGFloat, CGFloat, Double)]] = [
        [(0, 0, 0)],
        [(-14, 5, -3.5), (0, 0, 0)],
        [(-18, 6, -4), (18, 7, 4), (0, 0, 0)],
        [(-24, 9, -5), (24, 10, 5), (-11, 4, -2.5), (0, 0, 0)],
        [(-28, 11, -5.5), (28, 12, 5.5), (-14, 5, -3), (14, 6, 3), (0, 0, 0)]
    ]
    private static let shades = [0.0, 0.18, 0.3, 0.42, 0.54]

    public static func isEligible(_ node: CanvasNode) -> Bool {
        [.text, .image, .video].contains(node.kind)
    }

    public static func displaySize(_ node: CanvasNode) -> CGSize {
        let width = max(node.width, 1), height = max(node.height, 1)
        let scale = node.kind == .text ? min(320 / width, 320 / height, 1) : 1
        return CGSize(width: width * scale, height: height * scale)
    }

    public static func members(_ pile: CanvasPile, nodes: [CanvasNode]) -> [CanvasNode] {
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return pile.memberIDs.compactMap { lookup[$0] }
    }

    public static func frame(_ pile: CanvasPile, nodes: [CanvasNode]) -> CGRect {
        let visible = members(pile, nodes: nodes).suffix(5).map(displaySize)
        return CGRect(x: pile.x, y: pile.y, width: visible.map(\.width).max() ?? 320,
                      height: visible.map(\.height).max() ?? 240)
    }

    public static func layer(index: Int, count: Int, expansion: CGFloat) -> Layer {
        let count = min(max(count, 1), 5), index = min(max(index, 0), count - 1)
        let spec = layouts[count - 1][index]
        let lift: CGFloat = index == count - 1 ? -8 * max(expansion - 1, 0) : 0
        return Layer(offset: CGPoint(x: spec.0 * expansion, y: spec.1 * expansion + lift),
                     rotation: spec.2 * Double(expansion), shade: shades[count - index - 1])
    }

    /// dAe/uAe/hAe/fAe: nearest grid cell receives the topmost member.
    /// Rows are centered independently and use actual render dimensions.
    public static func unstackOrigins(_ pile: CanvasPile, nodes: [CanvasNode]) -> [String: CGPoint] {
        let members = members(pile, nodes: nodes)
        guard !members.isEmpty else { return [:] }
        let rowCount = max(1, Int(Double(members.count).squareRoot().rounded()))
        var counts = Array(repeating: members.count / rowCount, count: rowCount)
        let center = Double(rowCount - 1) / 2
        let rowsByDistance = counts.indices.sorted {
            let a = abs(Double($0) - center), b = abs(Double($1) - center)
            return a == b ? $0 < $1 : a < b
        }
        for index in 0..<(members.count % rowCount) { counts[rowsByDistance[index]] += 1 }
        var cells: [(row: Int, column: Int, distance: Double)] = []
        for row in counts.indices {
            for column in 0..<counts[row] {
                let dx = Double(column) - Double(counts[row] - 1) / 2
                let dy = Double(row) - center
                cells.append((row, column, dx * dx + dy * dy))
            }
        }
        cells.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.column < $1.column
        }
        let assigned = Array(zip(cells, members.reversed()))
        let rows = counts.indices.map { row in
            assigned.filter { $0.0.row == row }.sorted { $0.0.column < $1.0.column }.map { $0.1 }
        }
        let heights = rows.map { $0.map(\.height).max() ?? 0 }
        let totalHeight = heights.reduce(0, +) + CGFloat(max(rowCount - 1, 0)) * unstackGap
        let frame = frame(pile, nodes: nodes)
        var y = frame.midY - totalHeight / 2, result: [String: CGPoint] = [:]
        for row in rows.indices {
            let width = rows[row].map(\.width).reduce(0, +) + CGFloat(max(rows[row].count - 1, 0)) * unstackGap
            var x = frame.midX - width / 2
            for member in rows[row] {
                result[member.id] = CGPoint(x: x, y: y + (heights[row] - member.height) / 2)
                x += member.width + unstackGap
            }
            y += heights[row] + unstackGap
        }
        return result
    }

    /// IPe/MPe: wrap at 1872, gap 56, with a 40pt label band per row.
    public static func galleryFrames(_ members: [CanvasNode]) -> [String: CGRect] {
        var rows: [[CanvasNode]] = [], widths: [CGFloat] = [], heights: [CGFloat] = []
        for member in members {
            let size = displaySize(member)
            if let last = rows.indices.last, widths[last] + 56 + size.width <= 1872 {
                rows[last].append(member); widths[last] += 56 + size.width
                heights[last] = max(heights[last], 40 + size.height)
            } else {
                rows.append([member]); widths.append(size.width); heights.append(40 + size.height)
            }
        }
        var y = -(heights.reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * 56) / 2
        var result: [String: CGRect] = [:]
        for row in rows.indices {
            var x = -widths[row] / 2
            for member in rows[row] {
                let size = displaySize(member)
                result[member.id] = CGRect(x: x, y: y + 40, width: size.width, height: size.height)
                x += size.width + 56
            }
            y += heights[row] + 56
        }
        return result
    }

    public static func creation(sourceIDs: [String], nodes: [CanvasNode], piles: [CanvasPile],
                                groups: [CanvasNodeGroup]) -> CanvasPile? {
        var seen = Set<String>()
        let sources = sourceIDs.filter { seen.insert($0).inserted }
        let owners = Dictionary(piles.flatMap { pile in pile.memberIDs.map { ($0, pile.id) } },
                                uniquingKeysWith: { a, _ in a })
        var members: [String] = [], frames: [CGRect] = [], parents: [String?] = []
        for id in sources {
            if let pile = piles.first(where: { $0.id == id }) {
                members += pile.memberIDs; frames.append(frame(pile, nodes: nodes)); parents.append(pile.groupID)
            } else if let node = nodes.first(where: { $0.id == id }), isEligible(node), owners[id] == nil {
                members.append(id); frames.append(node.frame)
                parents.append(groups.first { $0.nodeIDs.contains(id) }?.id)
            } else { return nil }
        }
        seen = []
        members = members.filter { seen.insert($0).inserted }
        guard sources.count >= 2, (2...maxMembers).contains(members.count) else { return nil }
        let bounds = CanvasGeometry.bounds(of: frames)
        let parent = parents.first ?? nil
        var pile = CanvasPile(memberIDs: members, at: .zero,
                              groupID: parents.allSatisfy { $0 == parent } ? parent : nil)
        let size = frame(pile, nodes: nodes).size
        pile.x = bounds.midX - size.width / 2; pile.y = bounds.midY - size.height / 2
        return pile
    }
}
