import Foundation
import CoreGraphics

public enum CanvasGroupLayoutType: String, Codable, CaseIterable, Sendable { case horizontal, grid }
public enum CanvasGroupColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple
    public var title: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .cyan: return "青色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        }
    }
    public var rgb: UInt32 {
        switch self {
        case .red: return 0x372626
        case .orange: return 0x33281D
        case .yellow: return 0x363323
        case .green: return 0x253027
        case .cyan: return 0x233033
        case .blue: return 0x222933
        case .purple: return 0x312434
        }
    }
    public var swatch: UInt32 {
        switch self {
        case .red: return 0x964243
        case .orange: return 0x834915
        case .yellow: return 0x8F8030
        case .green: return 0x3D7344
        case .cyan: return 0x337282
        case .blue: return 0x2B5284
        case .purple: return 0x763886
        }
    }
}

public enum CanvasGroupResizeHandle: String, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    public func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }
}

public enum CanvasGroupGeometry {
    public static func isValid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(\.isFinite)
            && r.size.width > 0 && r.size.height > 0
    }
    public static func enclosing(_ nodes: [CanvasNode], padding: CGFloat = 20) -> CGRect? {
        guard let first = nodes.first else { return nil }
        return nodes.dropFirst().reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -padding, dy: -padding)
    }
    public static func frame(_ group: CanvasNodeGroup, nodes: [CanvasNode]) -> CGRect? {
        group.containerFrame ?? enclosing(nodes.filter { group.nodeIDs.contains($0.id) })
    }
    /// TapNow Dbe uses strict separation: touching the boundary retains membership.
    public static func completelyOutside(_ node: CGRect, container: CGRect) -> Bool {
        node.maxX < container.minX || node.minX > container.maxX ||
            node.maxY < container.minY || node.minY > container.maxY
    }
    public static func resized(_ frame: CGRect, handle: CanvasGroupResizeHandle, delta: CGSize) -> CGRect {
        var left = frame.minX, top = frame.minY, right = frame.maxX, bottom = frame.maxY
        if [.topLeft, .left, .bottomLeft].contains(handle) { left = min(left + delta.width, right - 10) }
        if [.topRight, .right, .bottomRight].contains(handle) { right = max(right + delta.width, left + 10) }
        if [.topLeft, .top, .topRight].contains(handle) { top = min(top + delta.height, bottom - 10) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(bottom + delta.height, top + 10) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    /// TapNow Bzl: row-major cells, maximum media dimensions, padding 100, gap 200.
    public static func grid(nodes: [CanvasNode], at anchor: CGPoint) -> (origins: [String: CGPoint], frame: CGRect) {
        guard !nodes.isEmpty else { return ([:], CGRect(origin: anchor, size: CGSize(width: 200, height: 200))) }
        let rows = Int(ceil(sqrt(Double(nodes.count))))
        let columns = Int(ceil(Double(nodes.count) / Double(rows)))
        let width = nodes.map(\.width).max() ?? 320, height = nodes.map(\.height).max() ?? 320
        var origins: [String: CGPoint] = [:]
        for (index, node) in nodes.enumerated() {
            let x = anchor.x + 100 + CGFloat(index % columns) * (width + 200)
            let y = anchor.y + 100 + CGFloat(index / columns) * (height + 200)
            origins[node.id] = CGPoint(x: x + (width - node.width) / 2, y: y + (height - node.height) / 2)
        }
        return (origins, CGRect(x: anchor.x, y: anchor.y,
            width: 200 + CGFloat(columns) * width + CGFloat(columns - 1) * 200,
            height: 200 + CGFloat(rows) * height + CGFloat(rows - 1) * 200))
    }
}
