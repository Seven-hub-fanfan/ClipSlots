import Foundation
import CoreServices

/// Hints only. Even after FlushSync, FSEvents may not yet contain an immediate
/// raw write. Every complete query still reconciles the authoritative stamps.
final class SlotSearchChangeMonitor {
    static let shared = SlotSearchChangeMonitor()
    private final class Library {
        let path: String
        let queue = DispatchQueue(label: "com.clipslots.search-events", qos: .utility)
        var stream: FSEventStreamRef?
        var dirty: [String: Set<Int>] = [:]
        var requiresReconcile = false

        init(path: String) {
            self.path = path
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            stream = FSEventStreamCreate(nil, { _, info, count, raw, flags, _ in
                guard let info else { return }
                let owner = Unmanaged<Library>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(raw, to: NSArray.self)
                let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
                for index in 0..<count {
                    if flags[index] & dropped != 0 { owner.requiresReconcile = true }
                    guard let changed = paths[index] as? String, changed.hasPrefix(owner.path + "/") else { continue }
                    let parts = changed.dropFirst(owner.path.count + 1).split(separator: "/")
                    guard let group = parts.first else { continue }
                    if parts.count >= 2, let slot = Int(parts[1]), slot > 0 {
                        if owner.dirty.count >= 8192 { owner.dirty.removeAll(); owner.requiresReconcile = true }
                        if owner.dirty[String(group), default: []].count >= 4096 {
                            owner.dirty.removeAll(); owner.requiresReconcile = true
                        } else { owner.dirty[String(group), default: []].insert(slot) }
                    }
                }
            }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
            if let stream {
                FSEventStreamSetDispatchQueue(stream, queue)
                if !FSEventStreamStart(stream) { requiresReconcile = true }
            } else { requiresReconcile = true }
        }
        func hints(group: String) -> Set<Int> {
            queue.sync { dirty.removeValue(forKey: group) ?? [] }
        }
        func mark(group: String, slot: Int) {
            queue.sync {
                if dirty.count >= 8192 { dirty.removeAll(); requiresReconcile = true }
                if dirty[group, default: []].count >= 4096 {
                    dirty.removeAll(); requiresReconcile = true
                } else { dirty[group, default: []].insert(slot) }
            }
        }
        deinit {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                queue.sync {}
                FSEventStreamRelease(stream)
            }
        }
    }
    private let lock = NSLock()
    private var libraries: [String: Library] = [:]
    private var order: [String] = []
    private var revisions: [String: UInt64] = [:]

    /// Call only during explicit search, never to prewarm the entire library.
    func hints(group: URL) -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        let path = group.deletingLastPathComponent().path
        let library: Library
        if let existing = libraries[path] { library = existing }
        else {
            if order.count >= 8 { libraries.removeValue(forKey: order.removeFirst()) }
            library = Library(path: path)
            libraries[path] = library
            order.append(path)
        }
        return library.hints(group: group.lastPathComponent)
    }

    func didWrite(group: URL, slot: Int) {
        lock.lock(); defer { lock.unlock() }
        if revisions.count >= 8192 { revisions.removeAll(keepingCapacity: true) }
        revisions[group.path, default: 0] &+= 1
        libraries[group.deletingLastPathComponent().path]?.mark(group: group.lastPathComponent, slot: slot)
    }

    func revision(group: URL) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revisions[group.path, default: 0]
    }
}
