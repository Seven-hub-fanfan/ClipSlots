import Foundation

// MARK: - Slot Connection Map (v2.6.8)

/// Represents a set of directed slot-to-slot connections within a single slot group.
/// Each slot can have at most one downstream slot and at most one upstream slot.
/// Stored per-group at ~/.local/share/clipslots/special_slots/<id>/connections.json.
struct SlotConnectionMap: Codable, Equatable {
    /// downstream[sourceSlot] = targetSlot
    var downstream: [Int: Int] = [:]

    /// Walk from `slot` downstream to the end of the chain.
    /// Returns the full chain including `slot` as the first element.
    /// Example: 1→2→4 returns [1, 2, 4].
    func chainStarting(from slot: Int) -> [Int] {
        var result: [Int] = []
        var current: Int? = slot
        var visited = Set<Int>()

        while let s = current, !visited.contains(s) {
            visited.insert(s)
            result.append(s)
            current = downstream[s]
        }
        return result
    }

    /// Whether this slot appears in any connection (as source or target).
    func isSlotInAnyChain(_ slot: Int) -> Bool {
        downstream[slot] != nil || upstream(of: slot) != nil
    }

    /// Find the slot that points TO `slot`. Returns nil if `slot` has no upstream.
    func upstream(of slot: Int) -> Int? {
        downstream.first(where: { $0.value == slot })?.key
    }

    /// Check whether adding from→to would create a cycle.
    func wouldCreateCycle(from source: Int, to target: Int) -> Bool {
        if source == target { return true }
        var current: Int? = target
        var visited = Set<Int>()
        while let s = current, !visited.contains(s) {
            if s == source { return true }
            visited.insert(s)
            current = downstream[s]
        }
        return false
    }

    var hasAnyConnections: Bool { !downstream.isEmpty }
}

// MARK: - Slot Connection Storage (v2.6.8)

/// Persists SlotConnectionMap per special-slot group to disk.
final class SlotConnectionStorage {
    static let shared = SlotConnectionStorage()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        return e
    }()
    private let decoder = JSONDecoder()

    private init() {}

    private func connectionURL(for specialSlotId: String) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/clipslots/special_slots")
            .appendingPathComponent(specialSlotId)
        return base.appendingPathComponent("connections.json")
    }

    func load(for specialSlotId: String) -> SlotConnectionMap {
        let url = connectionURL(for: specialSlotId)
        guard let data = try? Data(contentsOf: url),
              let map = try? decoder.decode(SlotConnectionMap.self, from: data) else {
            return SlotConnectionMap()
        }
        return map
    }

    func save(_ map: SlotConnectionMap, for specialSlotId: String) {
        let url = connectionURL(for: specialSlotId)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? encoder.encode(map).write(to: url, options: .atomic)
    }

    func delete(for specialSlotId: String) {
        let url = connectionURL(for: specialSlotId)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Slot Content Type Classification (v2.6.8)

enum SlotContentType {
    case empty
    case textOnly
    case filesOnly
    case image
    case mixed
}

extension SlotContent {
    /// Classify this slot's content for chain paste merge decisions.
    var contentType: SlotContentType {
        if items.isEmpty { return .empty }
        if hasImage { return .image }

        let hasText = plainText != nil
        let files = detectedRegularFileURLs
        let hasFiles = !files.isEmpty

        if hasText && !hasFiles { return .textOnly }
        if !hasText && hasFiles { return .filesOnly }

        // Both present or neither
        if hasText || hasFiles { return .mixed }
        return .empty
    }
}
