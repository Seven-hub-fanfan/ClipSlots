import AppKit
import ClipSlotsKit
import QuickLookThumbnailing
import SwiftUI

/// 缩略图渲染状态。`.loaded` 直接携带已解码的 NSImage。
/// v2.10.73 (方案③): 从 SlotThumbnailView 移到此处，作为 ThumbnailProvider 状态查询的返回类型。
enum ThumbnailState {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

/// v2.10.73（方案③：缩略图渲染解耦）：ThumbnailProvider 升级为「以 key 为维度的共享可观察缓存」，
/// 成为缩略图状态的**单一数据源**。SlotThumbnailView 不再各自持有 @StateObject 解码态，而是
/// `@ObservedObject` 观察本单例、按 `currentKey` 纯函数式渲染。
///
/// 为什么这样能根治历史回归「切到含主体图片的组，缩略图卡旧图、需切走切回才刷新」：
/// - 旧实现把解码结果放在每个 SlotThumbnailView 自己的 @StateObject 里；卡壳复用（.id(slot)）时
///   该 @StateObject 不销毁，而切组是「两段跳」（先 specialSlotId 变、slots 仍旧内容 → 再异步提交
///   新内容），SwiftUI 常只发一次 onAppear，第二跳 reload 漏触发 → 卡旧图。
/// - 新实现里缓存以 `key`（specialSlotId::slot::contentId::updatedAt / ::empty）为维度、外置于视图。
///   视图渲染只是 `state(for: currentKey)` 的纯函数：currentKey 一变即读新 key，命中秒出、未命中
///   loading 后异步填充。**late 的旧 key 解码结果只写到它自己的 key，不会污染当前视图**，因此无需
///   per-view token 守卫。
final class ThumbnailProvider: ObservableObject {
    static let shared = ThumbnailProvider()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    // P2-15 (v2.10.6): cache 此前无上限，文件类槽位很多时内存持续增长。改为 LRU：
    // accessOrder 记录访问顺序（末尾 = 最近使用），超过 maxCacheCount 时淘汰最旧项。
    // 所有 cache/accessOrder 变更均在既有 lock（NSLock）保护下进行，保持顺序一致。
    private var accessOrder: [String] = []
    private let maxCacheCount = 200

    // v2.10.73 (方案③): 以 key 为维度的「进行中 / 失败」态。
    // - loaded：`cache[key] != nil`（命中即已解码）。
    // - loading：`inFlight.contains(key)`（正在后台解码；同一 key 不重复解码 = in-flight 去重）。
    // - failed：`failedKeys.contains(key)`（解码失败/不支持，记录以避免无限重试）。
    // - idle：三者都不命中（尚未触发过解码）。
    // 读写均在既有 lock（NSLock）保护下进行，保持与 cache/accessOrder 一致。
    private var inFlight: Set<String> = []
    private var failedKeys: Set<String> = []

    // PERF-2 (v2.10.84): 变更通知合并。`notifyPending` 表示「已有一次合并通知在途」，
    // 在窗口内到达的后续通知请求直接被它覆盖，不再各自触发一次全网格重绘。
    // 读写均在既有 lock（NSLock）保护下进行，与 cache/inFlight 等状态保持一致。
    private var notifyPending = false
    /// 合并窗口：一帧（约 16ms）。低于一帧、肉眼不可察，却能把一屏缩略图回填的数十次
    /// objectWillChange 压成 1~2 次。
    private static let notifyCoalesceWindow: TimeInterval = 1.0 / 60.0
    /// Callback queue for in-flight requests. Multiple callers waiting on the same
    /// key all get notified when the single QLThumbnailGenerator request completes.
    private var pendingCompletions: [String: [(NSImage?, String) -> Void]] = [:]

    // P2-7 (v2.10.16): 看门狗代次隔离。此前每个请求挂 10s 看门狗但未绑定该请求的代次，
    // 若某 key 被 LRU 逐出后 10s 内被再次请求，旧看门狗到点会取消「新的」挂起请求 → 缩略图空白。
    // 修复：为每次「新建」挂起请求分配单调递增 token 记录到 pendingGeneration[key]；看门狗闭包捕获
    // 其对应 token，回调时先比对「当前 key 的挂起 token 是否仍等于本看门狗 token」，相等才执行超时
    // 取消，否则说明已被新请求替换，直接忽略，绝不取消新请求。读写均在既有 lock（NSLock）保护下进行。
    private var pendingGeneration: [String: UInt64] = [:]
    private var generationCounter: UInt64 = 0

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
        // P2-7 (v2.10.16): 为本次「新建」挂起请求分配代次 token 并记录，供看门狗回调比对。
        generationCounter &+= 1
        let requestToken = generationCounter
        pendingGeneration[cacheKey] = requestToken
        lock.unlock()

        // P2-1: QuickLook can hang and never call back; force-fire nil after 10s so waiters
        // are released and captured views aren't leaked. If the normal path already
        // removed the key, this is a safe no-op.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // P2-7 (v2.10.16): 仅当当前 key 的挂起 token 仍等于本看门狗捕获的 token 时才超时取消。
            // 若不相等（或已无记录），说明原请求已完成/被逐出并被新请求替换，本看门狗必须忽略，
            // 绝不能取消新请求，否则会造成新缩略图空白。
            guard self.pendingGeneration[cacheKey] == requestToken else {
                self.lock.unlock()
                return
            }
            self.pendingGeneration.removeValue(forKey: cacheKey)  // P2-7 (v2.10.16): 本次超时，清理代次记录
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
            self.pendingGeneration.removeValue(forKey: cacheKey)  // P2-7 (v2.10.16): 正常完成，清理本次代次记录
            self.lock.unlock()

            // Fire all queued completions so no caller is left hanging.
            for completion in completions {
                DispatchQueue.main.async {
                    completion(image, cacheKey)
                }
            }
        }
    }

    // MARK: - v2.10.73 (方案③) keyed observable API

    /// 同步查询：命中缓存返回已解码图片，否则 nil。供视图 body 直接读取（主线程）。
    func image(for key: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = cache[key] {
            markAccessedLocked(key)  // 命中即视为最近使用，更新 LRU
            return img
        }
        return nil
    }

    /// 同步查询该 key 的渲染状态：loaded(命中缓存) / loading(解码中) / failed(失败) / idle(未触发)。
    func state(for key: String) -> ThumbnailState {
        lock.lock(); defer { lock.unlock() }
        if let img = cache[key] {
            markAccessedLocked(key)
            return .loaded(img)
        }
        if inFlight.contains(key) { return .loading }
        if failedKeys.contains(key) { return .failed }
        return .idle
    }

    /// 触发（或跳过）某 key 的解码。
    /// - in-flight 去重：若该 key 已在缓存 / 已在解码中 / 已知失败，则直接返回，绝不重复解码。
    /// - 否则标记 inFlight（状态转为 .loading 并通知），在后台按内容类型解码，完成后回主线程
    ///   写入缓存并 `objectWillChange.send()`。因为缓存以 key 为维度，late 的旧 key 结果只写到它
    ///   自己的 key，不会污染当前视图，故无需 per-view token 守卫。
    func load(key: String, content: SlotContent, specialSlotId: String, slot: Int) {
        lock.lock()
        if cache[key] != nil || inFlight.contains(key) || failedKeys.contains(key) {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()
        notifyChangeOnMain()  // 状态转为 .loading

        // 空槽（理论上网格用 EmptySlotThumbnailView 兜住，此处为防御）：无缩略图。
        guard !content.isEmpty else {
            finish(key: key, image: nil)
            return
        }

        // 内联图片：走全局 ThumbnailDecodeLimiter 限流 + Task.detached 后台降采样解码，
        // 避免一屏图片卡同时触发数百次全分辨率 ImageIO 解码而卡主线程（沿用原 SlotThumbnailView 逻辑）。
        if content.hasImage {
            let snapshot = content
            Task {
                let decoded = await ThumbnailDecodeLimiter.shared.run {
                    await Task.detached(priority: .userInitiated) { () -> NSImage? in
                        snapshot.decodedInlineThumbnail(maxPixel: 512) ?? snapshot.decodedInlineImage()
                    }.value
                }
                self.finish(key: key, image: decoded)
            }
            return
        }

        // HTML 文档：卡片走 WebView，不出缩略图。
        if content.isHTMLDocument {
            finish(key: key, image: nil)
            return
        }

        // 文件（图片文件 / 其它文件如 PDF/压缩包）：复用既有 QuickLook 路径（含 scale 缓存、
        // 10s 看门狗、代次隔离），完成/超时后回调到 finish。
        guard let url = content.primaryFileURL, content.isImageFile || content.isFileContent else {
            finish(key: key, image: nil)
            return
        }
        thumbnail(for: url, cacheKey: key) { [weak self] image, _ in
            self?.finish(key: key, image: image)
        }
    }

    /// 解码收尾：清 in-flight，写入缓存（成功）或记录失败态，然后发出合并后的变更通知。
    ///
    /// PERF-2 (v2.10.84): 此前本方法整体（含缓存写入）被 hop 到主线程执行，并在每次完成时无条件
    /// `objectWillChange.send()`。因为 `ThumbnailProvider` 是**单例**、所有 SlotThumbnailView 都以
    /// `@ObservedObject` 观察它，每一次 send 都会让整个槽位网格重新求值。一屏 10 张图 = 10 次
    /// 「开始加载」+ 10 次「完成」通知，且这些回调分散在不同 runloop tick（SwiftUI 只合并同一 tick 内
    /// 的多次变更），于是切组瞬间产生约 20 次全网格重绘 —— 这是切组/滚动掉帧的直接来源。
    ///
    /// 现在：
    /// 1. 缓存写入不再 hop 主线程。它本就由 `lock` 保护，在解码线程直接落盘更快，且能让随后的 body
    ///    求值立刻读到结果（少一次「先 loading 再 loaded」的中间态重绘）。
    /// 2. 通知走 `scheduleCoalescedChangeNotification()`，把一个合并窗口内的多次变更压成 1 次 send。
    private func finish(key: String, image: NSImage?) {
        lock.lock()
        inFlight.remove(key)
        if let image = image {
            cache[key] = image
            markAccessedLocked(key)  // P2-15: 记录访问顺序
            evictIfNeededLocked()     // P2-15: 超上限淘汰最旧项
            failedKeys.remove(key)
        } else {
            failedKeys.insert(key)   // 记录失败，避免无限重试
        }
        lock.unlock()
        scheduleCoalescedChangeNotification()
    }

    /// 在主线程发出**合并后**的 objectWillChange（ObservableObject 通知须在主线程）。
    ///
    /// PERF-2 (v2.10.84): 合并窗口 = 一帧（约 16ms）。窗口内到达的任意多次通知请求只会触发一次
    /// `objectWillChange.send()`，从而把「一屏缩略图逐张回填」造成的数十次全网格重绘压到 1~2 次。
    /// 16ms 的延迟低于一帧、肉眼不可察，但对主线程的解放非常显著。
    ///
    /// 正确性说明：本方法只影响「何时通知」，不影响「通知什么」。视图渲染始终是
    /// `state(for: currentKey)` 的纯函数，合并后的那一次 send 会让所有视图重新读取自己最新的 key
    /// 状态，因此不会丢更新（最后一次请求必然被那次 send 覆盖）。
    /// 异步派发同时避开了「在视图更新中发布变更」的运行时告警。
    private func scheduleCoalescedChangeNotification() {
        lock.lock()
        if notifyPending {
            lock.unlock()
            return  // 已有一次合并通知在途，本次请求被它覆盖
        }
        notifyPending = true
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notifyCoalesceWindow) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.notifyPending = false
            self.lock.unlock()
            self.objectWillChange.send()
        }
    }

    /// 兼容旧调用点的别名（.loading 过渡 / 失效后重渲染），行为统一为「合并通知」。
    private func notifyChangeOnMain() {
        scheduleCoalescedChangeNotification()
    }

    // MARK: - Invalidation

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
        pendingGeneration = pendingGeneration.filter { !$0.key.hasPrefix(prefix) }  // P2-7 (v2.10.16): 同步剔除代次记录
        inFlight = inFlight.filter { !$0.hasPrefix(prefix) }     // v2.10.73 (方案③): 同步剔除进行中标记
        failedKeys = failedKeys.filter { !$0.hasPrefix(prefix) } // v2.10.73 (方案③): 同步剔除失败态，允许重新解码
        lock.unlock()
        notifyCancelled(dropped)
        notifyChangeOnMain()  // v2.10.73 (方案③): 通知观察者按新 key 重渲染
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
        pendingGeneration = pendingGeneration.filter { !$0.key.hasPrefix(prefix) }  // P2-7 (v2.10.16): 同步剔除代次记录
        inFlight = inFlight.filter { !$0.hasPrefix(prefix) }     // v2.10.73 (方案③): 同步剔除进行中标记
        failedKeys = failedKeys.filter { !$0.hasPrefix(prefix) } // v2.10.73 (方案③): 同步剔除失败态，允许重新解码
        lock.unlock()
        notifyCancelled(dropped)
        notifyChangeOnMain()  // v2.10.73 (方案③): 通知观察者按新 key 重渲染
        NSLog("[ClipSlots] ThumbnailProvider invalidateSpecialSlot prefix=\(prefix)")
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        accessOrder.removeAll()  // P2-15 (v2.10.6): 一并清空 LRU 访问顺序
        let dropped = pendingCompletions
        pendingCompletions.removeAll()
        pendingGeneration.removeAll()  // P2-7 (v2.10.16): 一并清空代次记录
        inFlight.removeAll()     // v2.10.73 (方案③): 一并清空进行中标记
        failedKeys.removeAll()   // v2.10.73 (方案③): 一并清空失败态
        lock.unlock()
        notifyCancelled(dropped)
        notifyChangeOnMain()  // v2.10.73 (方案③): 通知观察者重渲染
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
