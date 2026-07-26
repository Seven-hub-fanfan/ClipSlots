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
        let suffix = "::\(groupId)"

        // Fast path: in-memory hit under the lock (exact key, or a stale suffix key).
        // P1-2 (v2.10.5): loadAll() 只能从磁盘目录名拿到 groupId，故以空 pageId 段
        // ("::groupId") 建键写入缓存；而 UI 用真实 pageId 查询，键永远不匹配——导致
        // 每次启动后已持久化的连线都读不回来（NSLog edges=0），直到用户重新 save() 一次
        // 才以正确键回填。连线以「组」为单位存盘（fileURL 只用 groupId），因此任意
        // "*::groupId" 条目即为同一份 map。未命中时按 groupId 兜底匹配，并提升为真实键，
        // 使后续查询直接命中、替换掉陈旧的空 pageId 条目。
        cacheLock.lock()
        if let cached = cache[k] {
            cacheLock.unlock()
            return cached
        }
        if let match = cache.first(where: { $0.key.hasSuffix(suffix) }) {
            cache.removeValue(forKey: match.key)
            cache[k] = match.value
            let value = match.value
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()

        // P2-2 (v2.10.9): cache miss — do the (often main-thread) disk read + JSON
        // decode WITHOUT holding cacheLock, so synchronous IO can never block other
        // threads (previously load() held cacheLock across Data(contentsOf:) +
        // JSONDecoder). After the read, RE-ACQUIRE the lock, DOUBLE-CHECK the cache
        // (another thread may have filled it during the IO), then store and return.
        // P2-16 (v2.10.8): the disk fallback itself — loadAll() runs asynchronously on
        // the background queue, so an early load() at launch (before loadAll finished)
        // — or any genuine cache miss — previously returned .empty even though the
        // group's connections.json existed on disk, making persisted connections look
        // lost until a later save(). (Connections are stored per-group; fileURL only
        // uses groupId.)
        let url = fileURL(for: groupId)
        var loaded: SlotConnectionMap? = nil
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let map = try? JSONDecoder().decode(SlotConnectionMap.self, from: data) {
            loaded = map
        }

        cacheLock.lock(); defer { cacheLock.unlock() }
        // Double-check: another thread may have populated the cache during the IO.
        if let cached = cache[k] { return cached }
        if let match = cache.first(where: { $0.key.hasSuffix(suffix) }) {
            cache.removeValue(forKey: match.key)
            cache[k] = match.value
            return match.value
        }
        if let map = loaded {
            cache[k] = map
            return map
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
        let suffix = "::\(groupId)"
        cacheLock.lock()
        cache.removeValue(forKey: k)
        // P2-1 (v2.10.9): also drop EVERY stale "*::groupId" key (loadAll writes an
        // empty-pageId "::groupId" entry). load() re-matches such a key by suffix,
        // which would REVIVE a just-deleted connection on the next load(). Sweep all.
        for cacheKey in cache.keys where cacheKey.hasSuffix(suffix) {
            cache.removeValue(forKey: cacheKey)
        }
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
        // P1-3 (v2.10.6): 键格式为 "pageId::groupId"，连线以「组」为单位存盘（fileURL 只用
        // groupId），故取最后一个 "::" 之后的段作为 groupId。提前算出受影响的 groupId，既用于
        // 删磁盘文件，也用于 P2-1 的缓存清扫。
        let groupIds = Set(targetKeys.compactMap { key -> String? in
            guard let range = key.range(of: "::", options: .backwards) else { return nil }
            let gid = String(key[range.upperBound...])
            return gid.isEmpty ? nil : gid
        })
        for k in targetKeys { cache.removeValue(forKey: k) }
        // P2-1 (v2.10.9): sweep any remaining stale "*::groupId" entry (e.g. the
        // empty-pageId key loadAll writes) for every affected group, so a deleted
        // connection cannot be revived by a suffix match on the next load().
        for gid in groupIds {
            let suffix = "::\(gid)"
            for cacheKey in cache.keys where cacheKey.hasSuffix(suffix) {
                cache.removeValue(forKey: cacheKey)
            }
        }
        cacheLock.unlock()

        // P1-3 (v2.10.6): 此前 deleteAll 只清内存缓存、不删磁盘文件，下次启动 loadAll() 会把
        // 这些连线从磁盘重新读回——「清除全部连接」弹「已清除」但重启后连接全部复活。这里在清缓存
        // 的同时删除每个目标 group 的 connections.json。
        guard !groupIds.isEmpty else { return }
        let urls = groupIds.map { fileURL(for: $0) }
        queue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
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
