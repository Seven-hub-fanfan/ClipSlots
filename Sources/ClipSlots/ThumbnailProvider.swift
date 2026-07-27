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

    // P2-14 (v2.10.9): NSScreen.main 是主线程 AppKit API，而 thumbnail(for:) 可能在后台线程
    // 被调用，直接在后台读 NSScreen.main 属于误用。改为在 init 时于主线程读取一次
    // backingScaleFactor 缓存到此属性，后台路径改用该缓存值。读写都在既有 lock 保护下进行。
    private var cachedScale: CGFloat = 2.0
    // P2 (v2.10.13): 标记 cachedScale 是否已从主线程真实 backingScaleFactor 解析过。
    // 若首个缩略图请求在 init 的主线程回调就绪前从后台发起，会用兜底 2.0；解析完成后
    // 后续请求即改用真实值。所有读写仍在既有 lock 保护下进行。
    private var scaleResolved = false

    private init() {
        let apply: () -> Void = { [weak self] in
            guard let self = self else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            self.lock.lock(); self.cachedScale = scale; self.scaleResolved = true; self.lock.unlock()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // P2 (v2.10.13): 读取当前缩放因子。若尚未解析到真实 backingScaleFactor：在主线程可
    // 立即解析并缓存；在后台线程则触发一次主线程刷新（本次先用兜底 2.0，后续请求即用真实值）。
    // bootstrap 兜底仍为 2.0，但一旦真实值可用即被纠正。线程安全在既有 lock 下保证。
    private func currentScale() -> CGFloat {
        lock.lock()
        let resolved = scaleResolved
        let scale = cachedScale
        lock.unlock()
        if resolved { return scale }
        if Thread.isMainThread {
            let real = NSScreen.main?.backingScaleFactor ?? 2.0
            lock.lock(); cachedScale = real; scaleResolved = true; lock.unlock()
            return real
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let real = NSScreen.main?.backingScaleFactor ?? 2.0
                self.lock.lock(); self.cachedScale = real; self.scaleResolved = true; self.lock.unlock()
            }
            return scale
        }
    }

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
            // P1 (v2.10.13): completion 的契约是「在主队列回调」。此前 10s 超时兜底直接在
            // 后台队列触发 completion，回调里常有 UI 更新（更新 @State / NSImage 显示），
            // 违反主线程契约、可能崩溃或渲染异常。统一切回主队列触发。
            if let pending = pending {
                DispatchQueue.main.async {
                    pending.forEach { $0(nil, cacheKey) }
                }
            }
        }

        // P2-14 (v2.10.9): 使用 init 时在主线程缓存的 scale，避免在后台线程读 NSScreen.main。
        // P2 (v2.10.13): 经 currentScale() 读取——若真实 scale 尚未解析则触发刷新，后续请求用真实值。
        let scale = currentScale()
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
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
