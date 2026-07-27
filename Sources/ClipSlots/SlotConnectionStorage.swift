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
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let map = try? JSONDecoder().decode(SlotConnectionMap.self, from: data) {
                loaded = map
            } else {
                // P2 (v2.10.13): 文件「存在但读取/解码失败」= 真实损坏（区别于「文件缺失」的
                // 正常空态）。此前一律 try? 静默回退 .empty，随后一次 save(.empty) 会经 persistMap
                // 把损坏文件 removeItem 掉，令有效但位翻转的连线永久丢失。这里在返回 .empty 前
                // 先把损坏文件备份到 .corrupt 兄弟文件，与 index.json 的 poison+backup 对齐，
                // 保证后续即便被空态覆盖也能从备份恢复。
                backupCorruptConnectionFile(at: url)
            }
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
        // ST-3 (v2.10.15): route the disk delete through the SAME cross-process
        // StorageLock RMW used by persistMap. Previously the delete removed the file
        // without the lock, so a concurrent write (persistMap) from another process
        // could interleave and corrupt/resurrect connection data. Mirror persistMap:
        // acquire the lock inside the serial queue hop.
        queue.async {
            try? StorageLock.shared.withLock {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Persistence

    private func loadAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let ids = try? FileManager.default.contentsOfDirectory(atPath: self.baseDir.path) else { return }
            // ST-6 (v2.10.15): the data dir holds non-group entries alongside group
            // subdirectories (index.json, .trash, .storage.lock, .DS_Store,
            // .migration_v2_done, index.json.corrupt.bak, etc). Trying to parse them as
            // connection dirs is wasted IO. Only iterate legitimate group-id entries:
            // skip dotfiles and known system files, and require the entry to actually
            // be a directory (connections live at <groupId>/connections.json).
            let skipNames: Set<String> = [
                "index.json", "index.json.corrupt.bak",
                ".trash", ".storage.lock", ".DS_Store", ".migration_v2_done"
            ]
            for id in ids {
                if id.hasPrefix(".") || skipNames.contains(id) { continue }
                let groupDir = self.baseDir.appendingPathComponent(id, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: groupDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
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
        // ST-3 (v2.10.15): as with delete(), perform the disk removals under the same
        // cross-process StorageLock used by persistMap so a concurrent write from
        // another process cannot interleave and corrupt connection data.
        queue.async {
            try? StorageLock.shared.withLock {
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func persistMap(_ map: SlotConnectionMap, groupId: String) {
        let url = fileURL(for: groupId)
        queue.async {
            // P2 (v2.10.13): 连接写入复用跨进程 StorageLock + 原子写，与槽位存储层（SlotStorage/
            // SpecialSlotStorage）对齐。此前仅靠进程内 serial queue 串行化，双 GUI 实例并发写
            // connections.json 时仍可能相互覆盖/半写损坏。.atomic 本身即「写临时文件再原子替换」，
            // 满足 staging + 原子替换语义。
            try? StorageLock.shared.withLock {
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

    // P2 (v2.10.13): 把「存在但损坏」的 connections.json 备份到带时间戳的 .corrupt 兄弟文件，
    // 避免随后一次空态 save 经 persistMap 把它删除，从而丢失可恢复的原始字节。
    private func backupCorruptConnectionFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("connections.json.corrupt-\(ts)")
        do {
            try Data(contentsOf: url).write(to: backupURL, options: .atomic)
            NSLog("[ClipSlots] ERROR: connections.json at \(url.path) failed to decode; "
                + "backed up corrupt bytes to \(backupURL.path) before falling back to empty.")
        } catch {
            NSLog("[ClipSlots] ERROR: connections.json at \(url.path) failed to decode AND "
                + "the corrupt backup failed: \(error).")
        }
    }

    // P2 (v2.10.13): 外部进程（CLI）或另一 GUI 实例改动磁盘后，SpecialSlotStorage 的
    // 文件监听回调会调用此方法，丢弃内存里可能已陈旧的连接缓存并从磁盘重新读取，
    // 避免删组/删页后 GUI 仍显示已删除组的陈旧连线。
    func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
        loadAll()
    }
}
