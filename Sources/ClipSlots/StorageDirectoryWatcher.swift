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
    private var stream: FSEventStreamRef?
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
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            guard let info = info else { return }
            let watcher = Unmanaged<StorageDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
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
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        if FSEventStreamStart(created) {
            stream = created
            NSLog("[ClipSlots] StorageDirectoryWatcher started on \(path)")
        } else {
            NSLog("[ClipSlots] StorageDirectoryWatcher: FSEventStreamStart failed for \(path)")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        NSLog("[ClipSlots] StorageDirectoryWatcher stopped")
    }

    deinit { stop() }
}
