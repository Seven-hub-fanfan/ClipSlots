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
    /// Dedicated serial queue the FSEvents callback is delivered on. The callback
    /// hops to the main queue itself (debounced) via `onChange`.
    private let queue = DispatchQueue(label: "com.clipslots.fswatcher", qos: .utility)

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
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

        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            guard let info = info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            // weak back-reference: nil once the watcher has been deallocated → skip.
            guard let watcher = box.watcher else { return }
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
