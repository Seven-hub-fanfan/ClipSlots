import Foundation
import ClipSlotsKit

// MARK: - Slot Connection Storage

final class SlotConnectionStorage {
    static let shared = SlotConnectionStorage()

    private let baseDir: URL
    private let queue = DispatchQueue(label: "com.clipslots.connection-storage", qos: .utility)
    private var cache: [String: SlotConnectionMap] = [:]
    /// v2.10.3 (P1 fix): guards `cache`. It is read on the main thread (load/save/
    /// delete/export) but also written from the background `loadAll` hop; a plain
    /// `Dictionary` under concurrent access can crash/corrupt.
    private let cacheLock = NSLock()

    private init() {
        baseDir = ClipSlotsPaths.specialSlots
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
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[k] { return cached }
        // P1-2 (v2.10.5): loadAll() 只能从磁盘目录名拿到 groupId，故以空 pageId 段
        // ("::groupId") 建键写入缓存；而 UI 用真实 pageId 查询，键永远不匹配——导致
        // 每次启动后已持久化的连线都读不回来（NSLog edges=0），直到用户重新 save() 一次
        // 才以正确键回填。连线以「组」为单位存盘（fileURL 只用 groupId），因此任意
        // "*::groupId" 条目即为同一份 map。未命中时按 groupId 兜底匹配，并提升为真实键，
        // 使后续查询直接命中、替换掉陈旧的空 pageId 条目。
        let suffix = "::\(groupId)"
        if let match = cache.first(where: { $0.key.hasSuffix(suffix) }) {
            cache.removeValue(forKey: match.key)
            cache[k] = match.value
            return match.value
        }
        return .empty
    }

    func save(_ map: SlotConnectionMap, pageId: String, groupId: String) {
        let k = key(pageId: pageId, groupId: groupId)
        cacheLock.lock()
        cache[k] = map
        cacheLock.unlock()
        persistMap(map, groupId: groupId)
    }

    func delete(pageId: String, groupId: String) {
        let k = key(pageId: pageId, groupId: groupId)
        cacheLock.lock()
        cache.removeValue(forKey: k)
        cacheLock.unlock()
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
                self.cacheLock.lock()
                self.cache[k] = map
                self.cacheLock.unlock()
            }
        }
    }

    // v2.7.7: Bulk access helpers for page/all export and clear.
    func allCachedMaps() -> [String: SlotConnectionMap] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache
    }

    func deleteAll(where shouldDelete: @escaping (_ key: String, _ map: SlotConnectionMap) -> Bool) {
        cacheLock.lock()
        let targetKeys = cache.filter { shouldDelete($0.key, $0.value) }.map(\.key)
        for k in targetKeys { cache.removeValue(forKey: k) }
        cacheLock.unlock()
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
