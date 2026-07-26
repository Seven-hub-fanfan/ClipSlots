import AppKit
import ClipSlotsKit
import QuickLookThumbnailing

final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    // P2-15 (v2.10.6): cache 此前无上限，文件类槽位很多时内存持续增长。改为 LRU：
    // accessOrder 记录访问顺序（末尾 = 最近使用），超过 maxCacheCount 时淘汰最旧项。
    // 所有 cache/accessOrder 变更均在既有 lock（NSLock）保护下进行，保持顺序一致。
    private var accessOrder: [String] = []
    private let maxCacheCount = 200
    /// Callback queue for in-flight requests. Multiple callers waiting on the same
    /// key all get notified when the single QLThumbnailGenerator request completes.
    private var pendingCompletions: [String: [(NSImage?, String) -> Void]] = [:]

    /// Generate (or return cached) thumbnail for the given URL.
    ///
    /// - Parameters:
    ///   - url: The file URL to thumbnail.
    ///   - cacheKey: Composite key (`specialSlotId::slot::contentId::updatedAt`) that
    ///     uniquely identifies this slot version. The same key is returned in the
    ///     completion so callers can discard stale results.
    ///   - size: Target thumbnail size (points).
    ///   - completion: Called on the main queue with `(image?, returnedKey)`.
    func thumbnail(
        for url: URL,
        cacheKey: String,
        size: CGSize = CGSize(width: 240, height: 160),
        completion: @escaping (NSImage?, _ returnedKey: String) -> Void
    ) {
        // Fast path: cache hit
        lock.lock()
        if let cached = cache[cacheKey] {
            markAccessedLocked(cacheKey)  // P2-15 (v2.10.6): 命中后更新 LRU 访问顺序
            lock.unlock()
            DispatchQueue.main.async { completion(cached, cacheKey) }
            return
        }

        // Already loading — queue this caller instead of silently dropping.
        if pendingCompletions[cacheKey] != nil {
            pendingCompletions[cacheKey]?.append(completion)
            lock.unlock()
            return
        }

        pendingCompletions[cacheKey] = [completion]
        lock.unlock()

        // P2-1: QuickLook can hang and never call back; force-fire nil after 10s so waiters
        // are released and captured views aren't leaked. If the normal path already
        // removed the key, this is a safe no-op.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let pending = self.pendingCompletions.removeValue(forKey: cacheKey)
            self.lock.unlock()
            pending?.forEach { $0(nil, cacheKey) }
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[ClipSlots] ThumbnailProvider failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }

            let image = thumbnail?.nsImage

            self.lock.lock()
            if let image = image {
                self.cache[cacheKey] = image
                self.markAccessedLocked(cacheKey)  // P2-15 (v2.10.6): 记录访问顺序
                self.evictIfNeededLocked()          // P2-15 (v2.10.6): 超上限淘汰最旧项
            }
            let completions = self.pendingCompletions.removeValue(forKey: cacheKey) ?? []
            self.lock.unlock()

            // Fire all queued completions so no caller is left hanging.
            for completion in completions {
                DispatchQueue.main.async {
                    completion(image, cacheKey)
                }
            }
        }
    }

    /// Invalidate all cached thumbnails and in-flight requests for a specific slot.
    func invalidateSlot(specialSlotId: String, slot: Int) {
        let prefix = "\(specialSlotId)::\(slot)::"
        lock.lock()
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        accessOrder.removeAll { $0.hasPrefix(prefix) }  // P2-15 (v2.10.6): 同步剔除访问顺序
        // v2.10.3 (P1 fix): fire (not drop) queued completions for invalidated keys,
        // otherwise callers awaiting a thumbnail hang forever (leaking spinners/tasks).
        let dropped = pendingCompletions.filter { $0.key.hasPrefix(prefix) }
        pendingCompletions = pendingCompletions.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
        notifyCancelled(dropped)
        NSLog("[ClipSlots] ThumbnailProvider invalidateSlot prefix=\(prefix)")
    }

    /// Invalidate all cached thumbnails and in-flight requests for an entire special slot.
    func invalidateSpecialSlot(specialSlotId: String) {
        let prefix = "\(specialSlotId)::"
        lock.lock()
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        accessOrder.removeAll { $0.hasPrefix(prefix) }  // P2-15 (v2.10.6): 同步剔除访问顺序
        let dropped = pendingCompletions.filter { $0.key.hasPrefix(prefix) }
        pendingCompletions = pendingCompletions.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
        notifyCancelled(dropped)
        NSLog("[ClipSlots] ThumbnailProvider invalidateSpecialSlot prefix=\(prefix)")
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        accessOrder.removeAll()  // P2-15 (v2.10.6): 一并清空 LRU 访问顺序
        let dropped = pendingCompletions
        pendingCompletions.removeAll()
        lock.unlock()
        notifyCancelled(dropped)
    }

    // P2-15 (v2.10.6): 更新访问顺序——把 key 移到末尾（最近使用）。调用方必须已持 lock。
    private func markAccessedLocked(_ key: String) {
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
    }

    // P2-15 (v2.10.6): 超过上限时从最旧端淘汰，保持 cache 与 accessOrder 一致。调用方必须已持 lock。
    private func evictIfNeededLocked() {
        while cache.count > maxCacheCount, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Fire dropped/queued completions with a nil image so no caller is left hanging
    /// when its in-flight request is invalidated before QuickLook returns.
    private func notifyCancelled(_ dropped: [String: [(NSImage?, String) -> Void]]) {
        for (key, completions) in dropped {
            for completion in completions {
                DispatchQueue.main.async { completion(nil, key) }
            }
        }
    }
}
