import Foundation

// MARK: - Storage Lock Error

public enum StorageLockError: Error, LocalizedError {
    /// The cross-process lock could not be acquired within the allotted time.
    /// `detail` carries a human-readable reason (incl. the current lock holder's
    /// PID when known) so callers can surface an accurate, non-misleading message.
    case timeout(detail: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let detail): return detail
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

    /// v2.9.16 (#6): when true, ALL lock acquisition is skipped and writes proceed
    /// without the cross-process guarantee. Set by the CLI `--force` flag. A
    /// one-time warning is emitted to stderr. Use only when you are certain no
    /// other ClipSlots process is running (data races become possible).
    public static var forceUnlocked = false

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
    /// v2.9.16 (#6): emit the "degraded to lockless" warning at most once per
    /// process so we don't spam stderr on every write.
    private var didWarnLockless = false

    public init(lockURL: URL? = nil) {
        if let lockURL {
            self.lockURL = lockURL
        } else {
            // v2.9.29 (CRITICAL): the lock follows the data dir. Deriving it from
            // ClipSlotsPaths keeps GUI+CLI coordinating on ONE lock file even when
            // CLIPSLOTS_DATA_DIR redirects the data root.
            let lock = ClipSlotsPaths.lockFile
            try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.lockURL = lock
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

    /// Emit a one-time stderr warning explaining we are running without the
    /// cross-process lock (sandbox EPERM, unopenable lock file, or `--force`).
    private func warnLocklessOnce(_ reason: String) {
        guard !didWarnLockless else { return }
        didWarnLockless = true
        FileHandle.standardError.write(Data(
            "[ClipSlots] WARNING: proceeding WITHOUT cross-process lock (\(reason)). "
            .utf8))
        FileHandle.standardError.write(Data(
            "Concurrent writes from another ClipSlots process could clobber data.\n".utf8))
    }

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

    /// v2.9.16 (#1): record the current PID as the lock holder inside the lock
    /// file, so a subsequent waiter can identify (and, if the holder is dead,
    /// reclaim) a stale lock.
    private func writeHolderPID() {
        guard fd >= 0 else { return }
        let pidStr = "\(getpid())\n"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = pidStr.withCString { cstr in
            write(fd, cstr, strlen(cstr))
        }
    }

    /// v2.9.16 (#1): read the PID currently stored in the lock file (0 if none).
    private func readHolderPID() -> Int32 {
        guard let data = try? Data(contentsOf: lockURL),
              let str = String(data: data, encoding: .utf8),
              let pid = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return pid
    }

    /// True if a process with `pid` currently exists (kill(pid, 0) probe).
    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM // exists but owned by another user
    }

    private func acquireFlock(timeout: TimeInterval) throws {
        // v2.9.16 (#6): `--force` bypasses the OS lock entirely.
        if StorageLock.forceUnlocked {
            warnLocklessOnce("--force")
            holdsFlock = false
            return
        }

        let handle = openFDIfNeeded()
        guard handle >= 0 else {
            // Degraded mode: cannot open lock file. Do NOT hang — proceed without
            // the cross-process guarantee (in-process NSRecursiveLock still holds).
            warnLocklessOnce("lock file could not be opened")
            holdsFlock = false
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(handle, LOCK_EX | LOCK_NB) == 0 {
                holdsFlock = true
                writeHolderPID()
                return
            }
            let err = errno
            // v2.9.16 (#6): sandbox / unsupported filesystem returns EPERM (or
            // other non-would-block errors) for flock. Degrade to lockless with a
            // clear warning instead of failing the write.
            if err != EWOULDBLOCK && err != EAGAIN {
                let reason = (err == EPERM)
                    ? "flock() EPERM — sandboxed or unsupported filesystem"
                    : "flock() errno=\(err)"
                NSLog("[ClipSlots] StorageLock: \(reason); proceeding without cross-process lock")
                warnLocklessOnce(reason)
                holdsFlock = false
                return
            }
            if Date() >= deadline {
                // v2.9.16 (#1 + #4): the lock is genuinely held by someone. If the
                // recorded holder PID is dead, treat it as a stale lock and try one
                // final acquisition (flock normally auto-releases on process exit,
                // but this also covers odd states). Otherwise surface an ACCURATE
                // "busy" error naming the live holder — never a misleading
                // "permission" message.
                let holder = readHolderPID()
                if holder > 0, !isProcessAlive(holder) {
                    NSLog("[ClipSlots] StorageLock: stale lock from dead PID \(holder); reclaiming")
                    if flock(handle, LOCK_EX | LOCK_NB) == 0 {
                        holdsFlock = true
                        writeHolderPID()
                        return
                    }
                }
                let who = holder > 0
                    ? "held by process pid \(holder) (\(isProcessAlive(holder) ? "alive" : "dead"))"
                    : "no holder PID recorded"
                throw StorageLockError.timeout(
                    detail: "storage is busy: lock \(who) not released within \(Int(timeout))s; "
                        + "another ClipSlots process is writing — retry shortly")
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
