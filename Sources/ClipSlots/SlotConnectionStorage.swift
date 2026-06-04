import Foundation

// MARK: - Slot Connection Storage

final class SlotConnectionStorage {
    static let shared = SlotConnectionStorage()

    private let baseDir: URL
    private let queue = DispatchQueue(label: "com.clipslots.connection-storage", qos: .utility)
    private var cache: [String: SlotConnectionMap] = [:]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".local/share/clipslots/special_slots", isDirectory: true)
        loadAll()
    }

    // MARK: - Keys

    private func key(pageId: String, groupId: String) -> String {
        "\(pageId)::\(groupId)"
    }

    private func fileURL(for groupId: String) -> URL {
        baseDir.appendingPathComponent(groupId, isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    // MARK: - Public API

    func load(pageId: String, groupId: String) -> SlotConnectionMap {
        let k = key(pageId: pageId, groupId: groupId)
        if let cached = cache[k] { return cached }
        return .empty
    }

    func save(_ map: SlotConnectionMap, pageId: String, groupId: String) {
        let k = key(pageId: pageId, groupId: groupId)
        cache[k] = map
        persistMap(map, groupId: groupId)
    }

    func delete(pageId: String, groupId: String) {
        let k = key(pageId: pageId, groupId: groupId)
        cache.removeValue(forKey: k)
        let url = fileURL(for: groupId)
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Persistence

    private func loadAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let ids = try? FileManager.default.contentsOfDirectory(atPath: self.baseDir.path) else { return }
            for id in ids {
                let url = self.fileURL(for: id)
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url),
                      let map = try? JSONDecoder().decode(SlotConnectionMap.self, from: data) else {
                    continue
                }
                // Cache with empty pageId — will be overridden on explicit load
                let k = self.key(pageId: "", groupId: id)
                DispatchQueue.main.async {
                    self.cache[k] = map
                }
            }
        }
    }

    private func persistMap(_ map: SlotConnectionMap, groupId: String) {
        let url = fileURL(for: groupId)
        queue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            if map.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(map) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
