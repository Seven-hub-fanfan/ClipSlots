import Foundation
import CoreServices

/// v2.9.4 (Feature #2): watches the ClipSlots storage base directory subtree via
/// FSEvents so the GUI can auto-reflect on-disk changes made by the `clipslots`
/// CLI (or another GUI instance) without a manual group switch / restart.
///
/// Why FSEvents (not a vnode `DispatchSource`): slot writes are delete-and-recreate
/// and `index.json` is atomically replaced (rename), so a directory-vnode watcher
/// bound to a single fd can miss these. FSEvents reports changes across the whole
/// subtree reliably, including creates/renames/deletes of nested files.
final class StorageDirectoryWatcher {
    /// v2.10.3 (P0 fix): the FSEvents callback runs on `queue` and can still be
    /// dispatched by the system AFTER `stop()`/`deinit` (queued events). Passing
    /// `Unmanaged.passUnretained(self)` and calling `takeUnretainedValue()` in the
    /// callback would then dereference a freed `self` → wild-pointer crash. Instead
    /// we hand the C context a retained box holding a `weak` back-reference; the
    /// callback checks it for nil and safely no-ops once the watcher is gone.
    private final class WeakBox {
        weak var watcher: StorageDirectoryWatcher?
        init(_ watcher: StorageDirectoryWatcher) { self.watcher = watcher }
    }

    private var stream: FSEventStreamRef?
    /// Retained reference to the context box; released in `stop()`.
    private var boxRef: Unmanaged<WeakBox>?
    // P2-13 (v2.10.9): 串行化 start()/stop() 对 stream/boxRef 的检查与赋值，避免并发调用
    // （如快速 stop→start，或 stop() 与 deinit 同时触发）导致重复创建 stream 或漏 release
    // 已 retain 的 box。所有对 stream/boxRef 的读改都在此锁保护下进行。
    private let stateLock = NSLock()
    private let path: String
    private let onChange: () -> Void
    /// ★ v2.10.91 (第六轮): 「本流收到过任何事件」的心跳回调，在**过滤之前**调用。
    /// GUI 侧用它区分「流活着但这批事件不值得刷新」与「流已经聋了」——后者才需要重建流。
    private let onAnyEvent: (() -> Void)?
    /// Dedicated serial queue the FSEvents callback is delivered on. The callback
    /// hops to the main queue itself (debounced) via `onChange`.
    private let queue = DispatchQueue(label: "com.clipslots.fswatcher", qos: .utility)

    /// v2.10.91 (第六轮): 被监听根目录的等价写法集合，用于把 FSEvents 回调里的绝对路径正确剥成
    /// 「相对根目录」。FSEvents 给的是内核真实路径（`/tmp/x` 会被报成 `/private/tmp/x`），而
    /// `URL.resolvingSymlinksInPath()` 的行为恰好相反（它去掉 `/private` 而不是补上），所以额外用
    /// POSIX `realpath(3)` 拿物理路径，三种写法都参与前缀匹配。
    private let baseCandidates: [String]

    init(path: String, onChange: @escaping () -> Void, onAnyEvent: (() -> Void)? = nil) {
        self.path = path
        self.onAnyEvent = onAnyEvent
        var candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil {
            candidates.append(String(cString: buf))
        }
        var seen = Set<String>()
        self.baseCandidates = candidates
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        self.onChange = onChange
    }

    /// v2.10.91 (第六轮): 该 FSEvents 路径是否属于「存储层内部记账 / 回收站」路径 —— 即相对被监听
    /// 根目录的任意一个路径分量以 `.` 开头（`.storage.lock` / `.tmp_slot_*` / `.trash/**` /
    /// `.undo/**` / 原子写留下的 `.dat.nosync*`）。
    ///
    /// 关键安全点：**只在能确定相对路径时才按分量判定**。默认数据目录本身位于
    /// `~/.local/share/clipslots/…`（含隐藏分量 `.local`），若拿绝对路径直接切分会把所有事件误判为
    /// 内部路径而整体丢弃。前缀剥不掉时退回「只看叶子名是否隐藏」的保守口径，最坏情况也不会吞掉外部写。
    ///
    /// 语义安全性（第六轮实测复核）：一次 CLI `write`/`clear` 的事件批里必定含非隐藏路径
    /// （`<group>/<slot>`、`<group>/<slot>/content.json`、`index.json`），因此过滤只会吃掉
    /// 「纯内部记账」的批次；且即便未来某条写路径被过滤过头，GUI 侧还有 ≤2s 的 sentinel 轮询兜底
    /// （见 SlotStoreObservable.pollExternalStorageChange），契约不依赖本过滤器的完备性。
    fileprivate func isInternalBookkeepingPath(_ eventPath: String) -> Bool {
        for base in baseCandidates {
            let withSlash = base.hasSuffix("/") ? base : base + "/"
            if eventPath == base || eventPath == withSlash {
                return false // 根目录自身的事件：保守上报
            }
            guard eventPath.hasPrefix(withSlash) else { continue }
            let rel = eventPath.dropFirst(withSlash.count)
            guard !rel.isEmpty else { return false }
            return rel.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        // 兜底：无法确定相对路径 → 只看叶子名是否隐藏。
        return (eventPath as NSString).lastPathComponent.hasPrefix(".")
    }

    /// v2.10.91 (第六轮 · 契约兜底): 停止并重新创建 FSEvents 流。
    /// 供 GUI 侧「磁盘明明变了、流却一声不响」的自愈路径调用（实测遇到过进程存活但 FSEvents
    /// 回调长时间不再投递的状态）。`stop()`/`start()` 本身受 `stateLock` 串行保护，重复调用安全。
    func restart() {
        stop()
        start()
    }

    func start() {
        // P2-13 (v2.10.9): 整个「检查 stream==nil → 创建 → 赋值 stream/boxRef」在锁内完成，
        // 保证并发 start() 只会创建一个 stream。
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil else { return }

        let box = WeakBox(self)
        let boxRef = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: boxRef.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, info, _, eventPaths, _, _) in
            guard let info = info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            // weak back-reference: nil once the watcher has been deallocated → skip.
            guard let watcher = box.watcher else { return }
            // ★ v2.10.91 (第六轮): 心跳先记，再过滤。衡量的是「FSEvents 通道是否还活着」，
            // 与这批事件是否值得刷新无关。
            watcher.onAnyEvent?()
            // ★ v2.10.91 (第六轮): 丢掉「纯内部记账」事件批 —— 一批里全是隐藏分量路径
            // （`.storage.lock` / `.tmp_slot_*` / `.trash/**` / `.undo/**` / `.dat.nosync*`）才丢弃，
            // 只要含任意一个非隐藏路径就照旧上报。这些子树从不显示在界面上，且 GUI 的自写指纹
            // （storageDirFingerprint 用 `.skipsHiddenFiles`）对它们天然不敏感，必然被误判成外部写 →
            // 每批换来一次 140~180ms 的全量重载。外部写的检测能力不受影响：原子写最终的 rename
            // 一定产生非隐藏路径事件（实测 CLI write/clear 的事件批都含 `<group>/<slot>` 与 `index.json`），
            // 并且还有 sentinel 轮询兜底。
            if let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String],
               !paths.isEmpty,
               paths.allSatisfy({ watcher.isInternalBookkeepingPath($0) }) {
                return
            }
            watcher.onChange()
        }

        let pathsToWatch = [path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer      // deliver the first event quickly, then coalesce
            | kFSEventStreamCreateFlagFileEvents // report file-level (not just dir-level) events
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // latency (s) — coarse coalescing at the FSEvents layer
            flags
        ) else {
            NSLog("[ClipSlots] StorageDirectoryWatcher: FSEventStreamCreate failed for \(path)")
            boxRef.release() // balance passRetained on the failure path
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        if FSEventStreamStart(created) {
            stream = created
            self.boxRef = boxRef // keep the box alive for the stream's lifetime
            NSLog("[ClipSlots] StorageDirectoryWatcher started on \(path)")
            // ★ v2.10.91 (第六轮): 新流刚建好就先记一次心跳，避免「刚启动、还没有任何事件」被
            // sentinel 轮询误判成聋掉而立刻重建流。
            onAnyEvent?()
        } else {
            NSLog("[ClipSlots] StorageDirectoryWatcher: FSEventStreamStart failed for \(path)")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            boxRef.release() // balance passRetained on the failure path
        }
    }

    func stop() {
        // P2-13 (v2.10.9): 在锁内做「取出并清空 stream/boxRef」，保证并发 stop()/deinit 只有
        // 一次真正 teardown，不会重复 release 已 retain 的 box，也不会与 start() 交错。
        stateLock.lock()
        guard let stream = stream else { stateLock.unlock(); return }
        let boxRef = self.boxRef
        self.stream = nil
        self.boxRef = nil
        stateLock.unlock()
        let q = queue
        q.async {                                   // P2-3: tear down off the caller/main thread
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            boxRef?.release()
        }
        NSLog("[ClipSlots] StorageDirectoryWatcher stopped")
    }

    deinit { stop() }
}
