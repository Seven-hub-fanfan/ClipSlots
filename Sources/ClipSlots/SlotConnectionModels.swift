import SwiftUI
import Foundation

// MARK: - Slot Port

enum SlotPort: String, Codable, CaseIterable, Identifiable {
    case top
    case right
    case bottom
    case left

    var id: String { rawValue }

    var direction: CGVector {
        switch self {
        case .top:    return CGVector(dx: 0, dy: -1)
        case .right:  return CGVector(dx: 1, dy: 0)
        case .bottom: return CGVector(dx: 0, dy: 1)
        case .left:   return CGVector(dx: -1, dy: 0)
        }
    }

    var opposite: SlotPort {
        switch self {
        case .top:    return .bottom
        case .right:  return .left
        case .bottom: return .top
        case .left:   return .right
        }
    }
}

// MARK: - Slot Connection Edge

struct SlotConnectionEdge: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var fromSlot: Int
    var fromPort: SlotPort
    var toSlot: Int
    var toPort: SlotPort
    var colorId: Int
}

// MARK: - Slot Connection Map

struct SlotConnectionMap: Codable, Equatable {
    var edges: [SlotConnectionEdge] = []

    static let empty = SlotConnectionMap()

    var isEmpty: Bool { edges.isEmpty }

    // MARK: Edge Lookup

    func edgeFrom(slot: Int) -> SlotConnectionEdge? {
        edges.first { $0.fromSlot == slot }
    }

    func edgeTo(slot: Int) -> SlotConnectionEdge? {
        edges.first { $0.toSlot == slot }
    }

    func downstreamSlot(of slot: Int) -> Int? {
        edgeFrom(slot: slot)?.toSlot
    }

    func upstreamSlot(of slot: Int) -> Int? {
        edgeTo(slot: slot)?.fromSlot
    }

    // MARK: Chain Traversal

    func chainStart(for slot: Int) -> Int {
        var current = slot
        var visited = Set<Int>()
        while let upstream = upstreamSlot(of: current), !visited.contains(upstream) {
            visited.insert(upstream)
            current = upstream
        }
        return current
    }

    func chainSlots(startingAt slot: Int) -> [Int] {
        var result: [Int] = []
        var visited = Set<Int>()
        var current: Int? = slot
        while let value = current, (1...10).contains(value), !visited.contains(value) {
            visited.insert(value)
            result.append(value)
            current = downstreamSlot(of: value)
        }
        return result
    }

    func fullChain(containing slot: Int) -> [Int] {
        chainSlots(startingAt: chainStart(for: slot))
    }

    func chainEdges(containing slot: Int) -> [SlotConnectionEdge] {
        let slots = fullChain(containing: slot)
        return edges.filter { edge in
            slots.contains(edge.fromSlot) && slots.contains(edge.toSlot)
        }
    }

    // MARK: Cycle Detection

    func wouldCreateCycle(fromSlot: Int, toSlot: Int) -> Bool {
        var visited = Set<Int>()
        var current: Int? = toSlot
        while let value = current {
            if value == fromSlot { return true }
            if visited.contains(value) { return true }
            visited.insert(value)
            current = downstreamSlot(of: value)
        }
        return false
    }

    // MARK: Color

    func colorId(for slot: Int) -> Int? {
        if let outgoing = edgeFrom(slot: slot) { return outgoing.colorId }
        if let incoming = edgeTo(slot: slot) { return incoming.colorId }
        return nil
    }

    func usedColorIds() -> Set<Int> {
        Set(edges.map(\.colorId))
    }

    func nextAvailableColorId() -> Int {
        let used = usedColorIds()
        let count = SlotConnectionColor.allCases.count
        for index in 0..<count {
            if !used.contains(index) { return index }
        }
        return edges.count % max(count, 1)
    }

    // MARK: Chain Starts

    func chainStarts() -> [Int] {
        let fromSlots = Set(edges.map(\.fromSlot))
        let toSlots = Set(edges.map(\.toSlot))
        return Array(fromSlots.subtracting(toSlots)).sorted()
    }

    // MARK: Mutating Operations

    mutating func connect(
        fromSlot: Int,
        fromPort: SlotPort,
        toSlot: Int,
        toPort: SlotPort
    ) throws {
        guard (1...10).contains(fromSlot), (1...10).contains(toSlot) else {
            throw SlotConnectionError.invalidSlot
        }
        guard fromSlot != toSlot else {
            throw SlotConnectionError.selfConnection
        }
        if let existing = edgeFrom(slot: fromSlot) {
            throw SlotConnectionError.fromAlreadyConnected(existing: existing.toSlot)
        }
        if let existing = edgeTo(slot: toSlot) {
            throw SlotConnectionError.toAlreadyHasUpstream(existing: existing.fromSlot)
        }
        guard !wouldCreateCycle(fromSlot: fromSlot, toSlot: toSlot) else {
            throw SlotConnectionError.cycle
        }

        let colorId = self.colorId(for: fromSlot) ?? nextAvailableColorId()

        edges.append(SlotConnectionEdge(
            fromSlot: fromSlot,
            fromPort: fromPort,
            toSlot: toSlot,
            toPort: toPort,
            colorId: colorId
        ))

        normalizeChainColors()
    }

    mutating func disconnect(edgeId: UUID) {
        edges.removeAll { $0.id == edgeId }
        normalizeChainColors()
    }

    mutating func disconnectOutgoing(from slot: Int) {
        edges.removeAll { $0.fromSlot == slot }
        normalizeChainColors()
    }

    mutating func disconnectIncoming(to slot: Int) {
        edges.removeAll { $0.toSlot == slot }
        normalizeChainColors()
    }

    mutating func disconnectInvolving(slot: Int, port: SlotPort) {
        edges.removeAll { edge in
            (edge.fromSlot == slot && edge.fromPort == port)
            || (edge.toSlot == slot && edge.toPort == port)
        }
        normalizeChainColors()
    }

    mutating func clearAll() {
        edges.removeAll()
    }

    mutating func normalizeChainColors() {
        let starts = chainStarts()
        for start in starts {
            let chain = chainSlots(startingAt: start)
            let chainEdges = edges.filter { edge in
                chain.contains(edge.fromSlot) && chain.contains(edge.toSlot)
            }
            guard let baseColor = chainEdges.first?.colorId else { continue }
            for edge in chainEdges {
                if let index = edges.firstIndex(where: { $0.id == edge.id }) {
                    edges[index].colorId = baseColor
                }
            }
        }
    }
}

// MARK: - Slot Connection Error

enum SlotConnectionError: LocalizedError, Equatable {
    case invalidSlot
    case selfConnection
    case fromAlreadyConnected(existing: Int)
    case toAlreadyHasUpstream(existing: Int)
    case cycle
    case invalidTemplate
    case unsupportedTemplateVersion

    var errorDescription: String? {
        switch self {
        case .invalidSlot:                    return "槽位编号无效"
        case .selfConnection:                 return "不能连接到自身"
        case .fromAlreadyConnected(let e):    return "该槽位已连接到槽位 \(e)"
        case .toAlreadyHasUpstream(let e):    return "目标槽位已连接在槽位 \(e) 后"
        case .cycle:                          return "不能创建循环连接"
        case .invalidTemplate:                return "模板连接结构无效"
        case .unsupportedTemplateVersion:     return "模板版本过新，请升级 ClipSlots"
        }
    }

    var noticeTitle: String {
        switch self {
        case .invalidSlot:                return "连接失败"
        case .selfConnection:             return "不能连接到自身"
        case .fromAlreadyConnected:       return "该槽位已有下游连接"
        case .toAlreadyHasUpstream:       return "目标槽位已有上游连接"
        case .cycle:                      return "不能创建循环连接"
        case .invalidTemplate:            return "导入失败"
        case .unsupportedTemplateVersion: return "导入失败"
        }
    }
}

// MARK: - Slot Connection Color

enum SlotConnectionColor: Int, CaseIterable, Codable {
    case blue
    case green
    case orange
    case purple
    case pink
    case cyan
    case yellow
    case red

    var swiftUIColor: Color {
        switch self {
        case .blue:    return Color(red: 0.20, green: 0.48, blue: 0.95)
        case .green:   return Color(red: 0.18, green: 0.72, blue: 0.38)
        case .orange:  return Color(red: 0.95, green: 0.55, blue: 0.16)
        case .purple:  return Color(red: 0.58, green: 0.36, blue: 0.95)
        case .pink:    return Color(red: 0.95, green: 0.32, blue: 0.62)
        case .cyan:    return Color(red: 0.12, green: 0.68, blue: 0.86)
        case .yellow:  return Color(red: 0.95, green: 0.78, blue: 0.20)
        case .red:     return Color(red: 0.92, green: 0.24, blue: 0.24)
        }
    }

    static func color(for id: Int?) -> Color {
        guard let id = id else { return .clear }
        let colors = Self.allCases
        guard !colors.isEmpty else { return .accentColor }
        return colors[abs(id) % colors.count].swiftUIColor
    }
}

// MARK: - Active Drag Connection

struct ActiveDragConnection: Equatable {
    let fromSlot: Int
    let fromPort: SlotPort
    var currentPoint: CGPoint
    var hoverTarget: SlotPortTarget?
}

// MARK: - Slot Port Target

struct SlotPortTarget: Equatable {
    let slot: Int
    let port: SlotPort
}

// MARK: - Chain Paste Payload

struct ChainPastePayload {
    var sourceSlot: Int
    var text: String?
    var fileURLs: [URL]
    var isImage: Bool
    var isEmpty: Bool
}

// MARK: - Chain Paste Kind

enum ChainPasteKind {
    case text
    case files
    case unsupported
    case empty
}

// MARK: - Slot Connection Map Extensions

extension SlotConnectionMap {
    /// v2.7.2: Returns the set of ports currently connected for a given slot.
    func connectedPorts(for slot: Int) -> Set<SlotPort> {
        var result = Set<SlotPort>()
        if let edge = edgeFrom(slot: slot) { result.insert(edge.fromPort) }
        if let edge = edgeTo(slot: slot) { result.insert(edge.toPort) }
        return result
    }
}

// MARK: - Slot Connection Template

struct SlotConnectionTemplate: Codable, Identifiable {
    static let currentVersion = 1

    let id: UUID
    let name: String
    let description: String
    let version: Int
    let appVersion: String
    let createdAt: Date
    let tags: [String]
    let slotCount: Int
    let edges: [SlotConnectionEdge]

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        version: Int = SlotConnectionTemplate.currentVersion,
        appVersion: String,
        createdAt: Date = Date(),
        tags: [String] = [],
        slotCount: Int = 10,
        edges: [SlotConnectionEdge]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.tags = tags
        self.slotCount = slotCount
        self.edges = edges
    }
}

// MARK: - Global Helpers

func compactChainDescription(_ slots: [Int]) -> String {
    guard !slots.isEmpty else { return "" }
    if slots.count <= 5 {
        return slots.map(String.init).joined(separator: " → ")
    }
    guard let last = slots.last else { return "" }
    let prefix = slots.prefix(3).map(String.init).joined(separator: " → ")
    return "\(prefix) → … → \(last)"
}

func validateConnectionMap(_ map: SlotConnectionMap) throws {
    var outgoing = [Int: SlotConnectionEdge]()
    var incoming = [Int: SlotConnectionEdge]()

    for edge in map.edges {
        guard (1...10).contains(edge.fromSlot),
              (1...10).contains(edge.toSlot),
              edge.fromSlot != edge.toSlot else {
            throw SlotConnectionError.invalidTemplate
        }
        if outgoing[edge.fromSlot] != nil { throw SlotConnectionError.invalidTemplate }
        if incoming[edge.toSlot] != nil { throw SlotConnectionError.invalidTemplate }
        outgoing[edge.fromSlot] = edge
        incoming[edge.toSlot] = edge
    }

    // Cycle detection via DFS
    for slot in 1...10 {
        var visited = Set<Int>()
        var current: Int? = slot
        while let value = current {
            if visited.contains(value) { throw SlotConnectionError.cycle }
            visited.insert(value)
            current = outgoing[value]?.toSlot
        }
    }
}

func anchorPoint(for port: SlotPort, in rect: CGRect) -> CGPoint {
    switch port {
    case .top:    return CGPoint(x: rect.midX, y: rect.minY)
    case .right:  return CGPoint(x: rect.maxX, y: rect.midY)
    case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
    case .left:   return CGPoint(x: rect.minX, y: rect.midY)
    }
}

func connectionPath(
    start: CGPoint,
    startPort: SlotPort,
    end: CGPoint,
    endPort: SlotPort
) -> Path {
    var path = Path()
    path.move(to: start)

    let dx = abs(end.x - start.x)
    let dy = abs(end.y - start.y)
    let distance = max(60, min(180, max(dx, dy) * 0.45))

    let s = startPort.direction
    let e = endPort.direction

    let c1 = CGPoint(x: start.x + s.dx * distance, y: start.y + s.dy * distance)
    let c2 = CGPoint(x: end.x + e.dx * distance, y: end.y + e.dy * distance)

    path.addCurve(to: end, control1: c1, control2: c2)
    return path
}

func nearestPortTarget(
    to point: CGPoint,
    slotFrames: [Int: CGRect],
    excluding fromSlot: Int,
    threshold: CGFloat = 32
) -> SlotPortTarget? {
    var best: (target: SlotPortTarget, distance: CGFloat)?

    for (slot, rect) in slotFrames where slot != fromSlot {
        for port in SlotPort.allCases {
            let anchor = anchorPoint(for: port, in: rect)
            let distance = hypot(anchor.x - point.x, anchor.y - point.y)

            if distance <= threshold {
                if let current = best {
                    if distance < current.distance {
                        best = (SlotPortTarget(slot: slot, port: port), distance)
                    }
                } else {
                    best = (SlotPortTarget(slot: slot, port: port), distance)
                }
            }
        }
    }

    return best?.target
}
