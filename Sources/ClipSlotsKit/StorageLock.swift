import Foundation

// MARK: - Storage Lock Error

public enum StorageLockError: Error, LocalizedError {
    /// The cross-process lock could not be acquired within the allotted time.
    case timeout

    public var errorDescription: String? {
        switch self {
        case .timeout: return "storage is busy (lock timeout)"
        }
    }
}

/// Cross-process advisory lock backed by `flock()` on a dedicated lock file at
/// `~/.local/share/clipslots/special_slots/.storage.lock`.
///
/// Why this exists (round 2, Feature #4): the ClipSlots GUI and the `clipslots`
/// CLI are SEPARATE processes that share the same on-disk index/slot data. The
/// existing `DispatchQueue.sync` only serializes writers WITHIN a process, so a
/// CLI write and a GUI write could interleave and clobber each other
/// (last-writer-wins). `flock` on a shared lock file serializes the two
/// processes.
///
/// ## Reentrancy (avoids self-deadlock)
/// `flock` locks are associated with the open file *description*, not the
/// thread — so two threads in the SAME process sharing one fd do NOT serialize
/// via `flock` alone, and a naive `flock(LOCK_EX)` around a mutator that calls
/// another locked mutator would still deadlock a second *thread*. We therefore
/// guard everything with an in-process `NSRecursiveLock` held for the whole
/// critical section, plus a depth counter so the OS-level `flock(LOCK_EX)` is
/// taken only at the OUTERMOST entry and released only when depth returns to 0.
/// A single shared fd is kept for the process lifetime.
///
/// ## Timeout (never hangs)
/// `flock(LOCK_EX)` can block indefinitely. We instead spin `flock(LOCK_EX|LOCK_NB)`
/// with short `usleep` retries up to `timeout` seconds; on timeout we THROW
/// `StorageLockError.timeout` rather than hang forever.
public final class StorageLock {
    public static let shared = StorageLock()

    private let lockURL: URL
    /// In-process serialization + reentrancy. Held for the entire critical
    /// section so same-process threads serialize even though they share one fd.
    private let recursive = NSRecursiveLock()
    private var fd: Int32 = -1
    private var depth = 0
    /// Whether the OS-level flock is currently held (may be false if the lock
    /// file could not be opened — in that degraded case we proceed WITHOUT the
    /// cross-process guarantee rather than hang or crash).
    private var holdsFlock = false

    public init(lockURL: URL? = nil) {
        if let lockURL {
            self.lockURL = lockURL
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/clipslots/special_slots")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.lockURL = base.appendingPathComponent(".storage.lock")
        }
    }

    /// Run `body` while holding the cross-process advisory lock. Reentrant within
    /// a single process. Throws `StorageLockError.timeout` if the lock cannot be
    /// acquired within `timeout` seconds.
    @discardableResult
    public func withLock<T>(timeout: TimeInterval = 5.0, _ body: () throws -> T) throws -> T {
        recursive.lock()
        defer { recursive.unlock() }

        // Only take the OS-level flock at the outermost entry.
        if depth == 0 {
            try acquireFlock(timeout: timeout)
        }
        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                releaseFlock()
            }
        }
        return try body()
    }

    // MARK: - Private

    private func openFDIfNeeded() -> Int32 {
        if fd >= 0 { return fd }
        // Create the lock file (and, defensively, its directory) if missing.
        let dir = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 {
            NSLog("[ClipSlots] StorageLock: failed to open lock file \(lockURL.path) errno=\(errno)")
        }
        return fd
    }

    private func acquireFlock(timeout: TimeInterval) throws {
        let handle = openFDIfNeeded()
        guard handle >= 0 else {
            // Degraded mode: cannot open lock file. Do NOT hang — proceed without
            // the cross-process guarantee (in-process NSRecursiveLock still holds).
            holdsFlock = false
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(handle, LOCK_EX | LOCK_NB) == 0 {
                holdsFlock = true
                return
            }
            let err = errno
            if err != EWOULDBLOCK && err != EAGAIN {
                NSLog("[ClipSlots] StorageLock: unexpected flock error errno=\(err); proceeding without cross-process lock")
                holdsFlock = false
                return
            }
            if Date() >= deadline {
                throw StorageLockError.timeout
            }
            usleep(20_000) // 20ms between retries
        }
    }

    private func releaseFlock() {
        if holdsFlock, fd >= 0 {
            flock(fd, LOCK_UN)
        }
        holdsFlock = false
    }
}
