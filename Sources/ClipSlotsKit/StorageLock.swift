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

    /// ST-7 (v2.10.15): observable degradation state. Set true whenever the OS-level
    /// cross-process flock could NOT be established and we fell back to "no-lock mode"
    /// (lock file unopenable, flock EPERM / unsupported filesystem, or `--force`); set
    /// false on a successful flock acquisition. Previously this downgrade was only
    /// written to a log + posted as a notification — invisible to callers, so
    /// cross-process serialization could silently fail with no upper-layer/UI signal.
    /// Callers can now inspect `isDegraded` to surface a visible warning or decide
    /// whether to proceed. Backward compatible: purely additive, existing call sites
    /// are unaffected. Guarded by `recursive` (reentrant) for thread-safe reads.
    private var _isDegraded = false
    public var isDegraded: Bool {
        recursive.lock(); defer { recursive.unlock() }
        return _isDegraded
    }

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
        // P2-9 (v2.10.9): the lockless downgrade was previously only visible as a
        // one-time stderr log — invisible to the GUI. Also post a one-time
        // notification (guarded by the same didWarnLockless once-flag) so a GUI
        // observer can surface a visible notice. The observer is added by another
        // agent; here we only emit the signal.
        NotificationCenter.default.post(
            name: Notification.Name("ClipSlotsStorageLockLockless"),
            object: nil,
            userInfo: ["reason": reason])
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
        // ★ v2.10.91 (perf): 若锁文件里已经就是本进程 PID，直接跳过这次写入。
        //
        // 背景（实测得到的卡顿真凶之一）：本方法在**每一次**成功 flock 后都会写锁文件。锁文件位于
        // `special_slots/` 内，而 GUI 的 StorageDirectoryWatcher 以 kFSEventStreamCreateFlagFileEvents
        // 监听整棵子树 —— 于是「任何一次读盘（读也要拿锁）→ 写 .storage.lock → FSEvents → 去抖 0.3s
        // → reloadAll → 又读盘」构成了 ~2Hz 的无限自触发全量重载，主线程每 0.5s 被占住 ~150ms。
        // watcher 侧已按「隐藏文件」过滤（见 StorageDirectoryWatcher），这里再从源头消除无意义写入：
        // PID 在进程生命周期内恒定，只要文件内容已是本进程 PID，重复写没有任何信息增量，纯粹是
        // 磁盘 I/O + mtime 变更 + FSEvents 噪声。
        //
        // 语义完全不变：跳过的前提正是「文件内容已等于要写的内容」。别的进程抢过锁并写入自己的 PID 后，
        // 内容与本进程 PID 不等，下一次获取锁仍会正常写回（stale-lock 回收逻辑因此不受影响）。
        if holderFileMatches(pidStr) { return }
        // P2-13 (v2.10.8): make the PID update atomic-ish for concurrent readers.
        // The old order was ftruncate(0) → write, which leaves an EMPTY window in
        // which a waiter's readHolderPID() sees no PID. We cannot rename a temp file
        // over the lock file (that would swap the inode out from under the live
        // flock fd and break mutual exclusion), so instead we write the full PID at
        // offset 0 FIRST, then truncate to its length. A concurrent reader therefore
        // always sees either the old PID, the new PID, or new-PID + trailing bytes
        // (never empty); readHolderPID() only parses the first line, so trailing
        // leftovers from a shorter new value are ignored.
        lseek(fd, 0, SEEK_SET)
        // P2-5 (v2.10.9): loop write() until the FULL PID has been written. A single
        // write() may return 0 < written < len (short write); the old code then did
        // ftruncate(fd, written), truncating the PID to garbage digits that
        // readHolderPID() misparses. Only truncate once the whole value is on disk;
        // on a short/failed write, leave the file's prior content intact (do NOT
        // ftruncate to a partial length).
        let didWriteFully = pidStr.withCString { cstr -> Bool in
            let len = Int(strlen(cstr))
            var total = 0
            while total < len {
                let n = write(fd, cstr + total, len - total)
                if n <= 0 { return false }
                total += n
            }
            return true
        }
        if didWriteFully {
            ftruncate(fd, off_t(pidStr.utf8.count))
        }
    }

    /// v2.10.91: 锁文件当前内容是否与 `expected` 完全一致（用于跳过重复的 PID 写入）。
    /// 用 `pread` 从偏移 0 读，不动共享 fd 的文件偏移，因此对 writeHolderPID 的 lseek/write 无副作用。
    private func holderFileMatches(_ expected: String) -> Bool {
        guard fd >= 0 else { return false }
        let expectedBytes = Array(expected.utf8)
        var buf = [UInt8](repeating: 0, count: expectedBytes.count + 1)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            pread(fd, raw.baseAddress, raw.count, 0)
        }
        guard n == expectedBytes.count else { return false }
        return Array(buf[0..<n]) == expectedBytes
    }

    /// v2.9.16 (#1): read the PID currently stored in the lock file (0 if none).
    private func readHolderPID() -> Int32 {
        // P2-13 (v2.10.8): parse only the FIRST line and tolerate a half-written /
        // empty value (returns 0), so a read racing with writeHolderPID() never
        // mis-parses trailing leftover bytes.
        guard let data = try? Data(contentsOf: lockURL),
              let str = String(data: data, encoding: .utf8) else {
            return 0
        }
        let firstLine = str.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return Int32(firstLine) ?? 0
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
            _isDegraded = true // ST-7 (v2.10.15): observable lockless downgrade.
            return
        }

        let handle = openFDIfNeeded()
        guard handle >= 0 else {
            // Degraded mode: cannot open lock file. Do NOT hang — proceed without
            // the cross-process guarantee (in-process NSRecursiveLock still holds).
            warnLocklessOnce("lock file could not be opened")
            holdsFlock = false
            _isDegraded = true // ST-7 (v2.10.15): observable lockless downgrade.
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(handle, LOCK_EX | LOCK_NB) == 0 {
                holdsFlock = true
                _isDegraded = false // ST-7 (v2.10.15): real lock acquired — not degraded.
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
                _isDegraded = true // ST-7 (v2.10.15): observable lockless downgrade.
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
                        _isDegraded = false // ST-7 (v2.10.15): real lock reclaimed — not degraded.
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
