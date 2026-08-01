import Foundation

/// A-2 / A-5 (v2.10.31): snapshot a directory tree using APFS copy-on-write `clonefile(2)`
/// when possible (sub-millisecond, constant-time, leaves the source in place), falling back
/// to a physical `copyItem` on non-APFS / cross-volume filesystems where the clone fails.
/// Used to take `.trash` snapshots INSIDE the cross-process storage lock without blocking
/// every other process for the whole duration of a multi-hundred-MB physical copy.
@discardableResult
func cloneOrCopyItem(at src: URL, to dst: URL) -> Bool {
    let rc = src.path.withCString { s in dst.path.withCString { d in clonefile(s, d, 0) } }
    if rc == 0 { return true }
    do {
        try FileManager.default.copyItem(at: src, to: dst)
        return true
    } catch {
        NSLog("[ClipSlots] cloneOrCopyItem FAIL \(src.lastPathComponent): \(error.localizedDescription)")
        return false
    }
}

struct SlotManifest: Codable {
    struct Entry: Codable {
        let description: String
        let itemCount: Int
        let slot: Int
        let totalBytes: Int
        let types: [String]
        let updatedAt: String
    }

    var entries: [Entry] = []
    var version: Int = 1
}

/// P1-6 (v2.10.9): a stat(2)-derived fingerprint of a slot directory used to
/// decide whether the in-memory cache is still fresh. The old signal was the
/// directory modificationDate, but on 1-second-granularity volumes (HFS+, SMB,
/// NFS) a same-second write by the CLI shared the same mtime and was missed.
/// writeSlotContent swaps the WHOLE slot dir via replaceItemAt, so its inode
/// changes on every write — combining st_ino with the full-resolution mtime
/// (sec AND nsec) and st_size makes a same-second external write detectable.
struct DirFingerprint: Equatable {
    let ino: UInt64
    let mtimeSec: Int
    let mtimeNsec: Int
    let size: Int64
}

public final class SlotStorage {
    public static let shared = SlotStorage()

    private let baseURL: URL
    private var cache: [Int: SlotContent] = [:]
    // P1-6 (v2.10.9): last-seen on-disk fingerprint per cached slot. `get` compares
    // it against a freshly-stat'd fingerprint so a value written by another process
    // (CLI) is picked up on the very next read, even on coarse-mtime volumes where
    // the old modificationDate signal (P2-15, v2.10.8) missed same-second writes.
    private var cacheFingerprint: [Int: DirFingerprint] = [:]
    // P0-1 (v2.10.38): in-memory label cache + per-slot label.txt fingerprint. `getLabel`
    // previously took the cross-process StorageLock and synchronously read `label.txt` on
    // EVERY call. `allSearchableSlots()` (global search) invokes it once per slot on the main
    // thread, so a large multi-group library paid N flock acquisitions + N synchronous file
    // reads on the main thread → opening/typing search froze (the "head culprit" in the
    // v2.10.37 analysis). This mirrors the `cache`/`cacheFingerprint` design used by `get()`:
    // serve the label from memory whenever the label.txt fingerprint is unchanged, and only
    // touch the lock + disk on a genuine miss. `label == nil` (no label.txt) is cached too,
    // distinguished from "not cached" by key presence. Guarded by `queue` like `cache`.
    private var labelCache: [Int: String?] = [:]
    private var labelCacheFingerprint: [Int: DirFingerprint?] = [:]
    // P0-3 (v2.10.38): read paths use a SHORT lock timeout so a main-thread read never blocks
    // for the full write timeout (5s) while a big import holds the lock in bursts. On timeout
    // both `get()` and `getLabel()` gracefully serve the last-known cached value, so bounding
    // the wait trades a rare re-read for eliminating the "everything spins 5s" beachball.
    private static let readLockTimeout: TimeInterval = 2.0
    // ST-2 (v2.10.15): slots whose attachments.json PHYSICALLY EXISTS but FAILED to
    // decode (genuine corruption), as opposed to a slot that is legitimately empty.
    // Set/cleared by readSlotContent and consulted by writeSlotContent so an empty
    // attachments payload cannot atomically overwrite (physically delete) a corrupt
    // attachments.json — mirroring the index-layer refusingToOverwriteWithEmpty
    // poison guard in SpecialSlotStorage. Accessed only on `queue` (get/set both hop
    // through queue.sync), so a plain Set needs no extra locking.
    private var attachmentDecodeFailedSlots: Set<Int> = []
    // DS-3 / CR-3 (v2.10.30): once the owning slot group is deleted, its `SlotStorage`
    // instance must never write again. A lingering reference (retained by the UI, a watcher
    // callback, or an in-flight task captured before the delete) could otherwise call set()
    // and physically recreate the group's slot directory on disk — a "phantom group" that
    // reappears with orphaned data on the next reload. `SpecialSlotStorage` marks the cached
    // instance invalidated when it evicts the group; every write path checks this flag and
    // refuses. Guarded by `queue` like the rest of the mutable state.
    private var invalidated = false
    private let queue = DispatchQueue(label: "com.clipslots.storage", qos: .utility)
    // ST-5 (v2.10.15): the diagnostic manifest rebuild (updateManifest) walks every
    // slot directory off disk. It previously ran on the shared serial `queue`, so a
    // large rebuild blocked the get/set hot path (both use queue.sync). manifest.json
    // is a write-only diagnostic (readManifest has no callers) and updateManifest
    // touches ONLY the filesystem (no in-memory cache/state), so running it on a
    // dedicated serial queue moves the rebuild entirely off the hot path without
    // changing behavior or introducing data races.
    private let manifestQueue = DispatchQueue(label: "com.clipslots.storage.manifest", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(slotsDir: URL? = nil) {
        if let slotsDir {
            baseURL = slotsDir
        } else {
            baseURL = ClipSlotsPaths.slots
        }
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[ClipSlots] SlotStorage init: failed to create base dir \(baseURL.path): \(error)")
        }
        // P1-5 (v2.10.9): sweep any `.tmp_slot_*` staging dirs orphaned by a crash
        // (before replaceItemAt/moveItem completed) so they don't accumulate forever.
        cleanupStagingDirs()
    }

    /// P1-6 (v2.10.9): compute a slot directory's stat(2) fingerprint. Returns nil
    /// if the path cannot be stat'd (e.g. the slot dir does not exist yet).
    private func dirFingerprint(_ path: String) -> DirFingerprint? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return DirFingerprint(
            ino: UInt64(st.st_ino),
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            size: Int64(st.st_size)
        )
    }

    /// P1-5 (v2.10.9): remove orphaned atomic-write staging directories. With no
    /// argument it removes every `.tmp_slot_*` entry under baseURL (startup sweep);
    /// with `slot` it removes only `.tmp_slot_<slot>_*` entries (per-slot sweep run
    /// before a fresh write). A crash between staging and the atomic swap would
    /// otherwise leave these dirs behind permanently.
    private func cleanupStagingDirs(slot: Int? = nil) {
        let prefix = slot.map { ".tmp_slot_\($0)_" } ?? ".tmp_slot_"
        // DS-2 (v2.10.30): the startup sweep (slot == nil) previously deleted EVERY
        // `.tmp_slot_*` unconditionally. If another process (the `clipslots` CLI, or a second
        // GUI) is atomically writing a slot at the exact moment this instance starts up, its
        // in-flight staging dir would be wiped mid-write — corrupting that write. Only reap
        // staging dirs that are demonstrably stale (older than the threshold); a genuine crash
        // orphan is always far older, while a live atomic write completes within milliseconds.
        // The per-slot sweep (slot != nil) stays unconditional: it runs in THIS process right
        // before we (re)write that same slot, so there is no concurrent writer to protect.
        let isStartupSweep = (slot == nil)
        let keys: [URLResourceKey] = isStartupSweep ? [.contentModificationDateKey] : []
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: keys) else { return }
        // STG-3 (v2.10.32): the startup sweep judged staleness by the staging DIRECTORY's mtime.
        // But a directory's mtime only updates when entries are added/removed, NOT while a large
        // file is being written into item_0/*.bin. A single-file write that takes > threshold
        // (e.g. a 1GB attachment) leaves the dir mtime frozen at creation time, so another
        // process starting up would treat the still-active staging dir as stale and delete it
        // mid-write, failing the legitimate large write. Fix: (1) judge staleness by the MOST
        // RECENT mtime found anywhere in the staging subtree (a live write keeps bumping the
        // .bin file mtime), and (2) widen the threshold substantially so slow-but-legit writes
        // are never reaped.
        let staleThreshold: TimeInterval = 600
        let now = Date()
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            if isStartupSweep {
                let latest = latestModificationDate(in: entry)
                if let latest, now.timeIntervalSince(latest) < staleThreshold { continue }
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// STG-3 (v2.10.32): return the most recent contentModificationDate found anywhere in the
    /// directory subtree rooted at `url` (including `url` itself). Used to decide whether a
    /// staging directory is truly orphaned vs. an in-progress large write. A live write keeps
    /// touching a deep `.bin` file even when the parent directory's own mtime is stale.
    private func latestModificationDate(in url: URL) -> Date? {
        var latest = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []) {
            for case let child as URL in enumerator {
                if let m = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    if latest == nil || m > latest! { latest = m }
                }
            }
        }
        return latest
    }

    // MARK: - Slot Content

    public func get(_ slot: Int) -> SlotContent {
        let slotDir = baseURL.appendingPathComponent(String(slot))
        // PERF (switch lag): fast cache-hit path that does NOT take the cross-process
        // flock. Page/group switching reloads EVERY slot of the target group (loadSlots)
        // AND probes slots for the auto-mode cursor previews, so `get` is called dozens
        // of times per switch. The old implementation wrapped the whole body — including
        // the common cache-hit branch — in `StorageLock.withLock`, so each cache hit paid
        // for a flock acquire + holder-PID file write + release (plus spin-retries when
        // the CLI/FSEvents watcher held the lock). That per-slot syscall overhead is what
        // made switching feel progressively laggier as data grew.
        //
        // Correctness: the in-memory cache is guarded by the in-process serial `queue`;
        // the `dirFingerprint` stat below (st_ino + full-resolution mtime + size) detects
        // any external (CLI) write, so a stale value can never be served without a re-read.
        // No disk I/O of slot payloads happens on this path, so the cross-process lock is
        // unnecessary here — it is still taken on the slow path where we actually read.
        let diskFP = dirFingerprint(slotDir.path)
        if let cached = queue.sync(execute: {
            cache[slot].flatMap { cacheFingerprint[slot] == diskFP ? $0 : nil }
        }) {
            return cached
        }

        // Slow path (cache miss or external change): read under the cross-process lock so
        // the directory enumeration cannot race a concurrent atomic slot swap.
        // P0-3 (v2.10.38): use the SHORT read timeout so a main-thread read never waits the full
        // 5s while a big import holds the lock in bursts; on timeout we fall through to the
        // last-known cached value below (never synthesize an empty slot).
        if let content = try? StorageLock.shared.withLock(timeout: SlotStorage.readLockTimeout, {
            queue.sync {
                // Re-check inside the lock: another thread may have populated the cache
                // (or an external write may have landed) while we waited for the flock.
                let fp = dirFingerprint(slotDir.path)
                if let cached = cache[slot], cacheFingerprint[slot] == fp {
                    return cached
                }
                let content = readSlotContent(from: slotDir)
                cache[slot] = content
                // Step 2 (v2.10.42): readSlotContent 可能触发老数据懒迁移（写 .bin + 改写
                // attachments.json），改变了 slotDir 指纹。这里在读之后重新 stat 一次指纹再缓存，
                // 否则下一次 get() 会因指纹不匹配而多做一次无谓的整槽重读。
                cacheFingerprint[slot] = dirFingerprint(slotDir.path)
                return content
            }
        }) {
            return content
        }

        // DS-1 (v2.10.30): the cross-process lock could not be acquired (storage busy /
        // timeout). Previously we fell through to `?? SlotContent()`, handing back a FRESH
        // EMPTY slot. That "假空槽" is dangerous: it makes real content look lost in the UI
        // and, worse, could feed an overwrite decision that wipes the still-intact disk data.
        // Never synthesize an empty slot on a lock failure — serve the last-known cached
        // value instead. Only when we have genuinely never loaded this slot do we return an
        // empty SlotContent (nothing better exists), and we log so the degradation is visible.
        if let cached = queue.sync(execute: { cache[slot] }) {
            NSLog("[ClipSlots] SlotStorage.get slot=\(slot): lock busy, serving cached value (not empty)")
            return cached
        }
        NSLog("[ClipSlots] SlotStorage.get slot=\(slot): lock busy and no cache; returning empty placeholder")
        return SlotContent()
    }

    /// PERF (switch lag): cheap emptiness probe that does NOT load item payloads into
    /// memory. Mirrors `SlotContent.isEmpty` (main items empty AND attachments empty) but
    /// only stats / enumerates directory entries instead of reading every `.bin` blob.
    ///
    /// The auto-store / auto-paste cursor previews (`recomputeAutoPreviews`) run on EVERY
    /// page/group switch and previously tested emptiness via `get().isEmpty`, which forced
    /// a full-content disk read (all image/file bytes) of each probed slot — and, with
    /// "自动切换" on, across many groups/pages. Probing the filesystem shape instead keeps
    /// that scan proportional to the number of directory entries, not the payload size.
    public func isSlotEmpty(_ slot: Int) -> Bool {
        let slotDir = baseURL.appendingPathComponent(String(slot))
        let diskFP = dirFingerprint(slotDir.path)
        // Reuse the in-memory cache when fresh — avoids any filesystem work at all.
        if let cached = queue.sync(execute: {
            cache[slot].flatMap { cacheFingerprint[slot] == diskFP ? $0 : nil }
        }) {
            return cached.isEmpty
        }

        let result = probeSlotEmptyOnDisk(slotDir)
        // A-4 (v2.10.31): the probe above enumerates attachments.json + item_* dirs with
        // several non-atomic I/O calls while holding NEITHER the StorageLock NOR queue.sync.
        // A concurrent `replaceItemAt` (CLI/GUI overwrite swaps the whole slot dir) can be
        // observed mid-flight, yielding a TORN result (e.g. saw the old empty attachments.json
        // but not the freshly-written item_*, or vice versa). Basing an auto-store / auto-paste
        // "find empty slot" decision on a torn read risks overwriting live data. If the slot
        // dir fingerprint changed during the probe, the read was potentially torn — fall back
        // to the authoritative `get()`, which reads the full slot under the cross-process lock.
        if dirFingerprint(slotDir.path) != diskFP {
            NSLog("[ClipSlots] isSlotEmpty slot=\(slot): dir changed during probe, recomputing via get()")
            return get(slot).isEmpty
        }
        return result
    }

    /// A-4 (v2.10.31): the lock-free filesystem shape probe, extracted so `isSlotEmpty`
    /// can re-run it / fall back to a locked `get()` when it detects a torn read.
    private func probeSlotEmptyOnDisk(_ slotDir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: slotDir.path, isDirectory: &isDir), isDir.boolValue else {
            return true
        }
        // P0-2 (v2.10.36): non-empty attachments.json → slot is not empty, but do NOT read
        // the whole file. Attachments are stored INLINE as base64 in attachments.json, so a
        // slot with a large attachment yields a multi-MB JSON file. The old probe did
        // `Data(contentsOf:) + JSONDecode([SlotAttachment])`, materializing every base64 blob
        // just to test `!isEmpty` — O(attachment bytes) per call. recomputeAutoPreviews (自动
        // 切换 default ON) scans isSlotEmpty across ALL groups/pages on every switch/action via
        // the auto-advance cursor, and those cross-group probes never populate the content
        // cache, so after a large (~1.6GB) pack import every UI action re-read hundreds of MB
        // on the main thread → 3-5s beachball. Replace with an O(1) head-window scan.
        let attachmentsURL = slotDir.appendingPathComponent("attachments.json")
        if attachmentsJSONHasEntry(attachmentsURL) {
            return false
        }
        // Any item_* dir containing at least one .bin file → not empty.
        if let entries = try? fm.contentsOfDirectory(at: slotDir, includingPropertiesForKeys: nil) {
            for itemDir in entries where itemDir.lastPathComponent.hasPrefix("item_") {
                if let files = try? fm.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: nil),
                   files.contains(where: { $0.pathExtension == "bin" }) {
                    return false
                }
            }
        }
        return true
    }

    /// P0-2 (v2.10.36): O(1) "does attachments.json contain at least one entry?" check that
    /// avoids reading/decoding the (potentially multi-MB, inline-base64) file. attachments.json
    /// is a JSON array: an empty list serializes to `[]` (no `{`), while any element makes it
    /// `[{...}]` — the first object-open `{` sits within the first few bytes right after `[`
    /// (the encoder emits compact JSON, no indentation). We read only a small head window and
    /// look for `{` (0x7B). Missing/unreadable file → treated as no entry (empty). A corrupt or
    /// truncated file that still contains `{` is conservatively treated as NON-empty, matching
    /// the project-wide "never mistake real data for an empty slot" invariant.
    private func attachmentsJSONHasEntry(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        return head.contains(0x7B) // '{'
    }

    @discardableResult
    public func set(_ slot: Int, content: SlotContent) -> Bool {
        // DS-3 / CR-3 (v2.10.30): a deleted group's storage must never write again.
        if isInvalidated {
            NSLog("[ClipSlots] SlotStorage.set slot=\(slot): refused — storage invalidated (group deleted)")
            return false
        }
        // v2.9.4 (#4): wrap the whole write in the cross-process lock so a CLI and
        // the GUI cannot clobber each other. flock is acquired OUTSIDE `queue`
        // (StorageLock uses its own NSRecursiveLock), never dispatched onto the
        // serial `queue`, so no queue.sync self-deadlock is possible. A lock
        // timeout degrades to a failed write (returns false) rather than a hang.
        return (try? StorageLock.shared.withLock {
            let ok: Bool = queue.sync {
                // A-1 (v2.10.31): re-check invalidation INSIDE the lock+queue. The pre-lock
                // `isInvalidated` guard above is a TOCTOU window: while this call waited for the
                // cross-process flock, the owning group could have been deleted + invalidated by
                // another thread/process. Writing now would resurrect the group's slot directory
                // ("phantom group"). `invalidated` is guarded by `queue`, so reading it here is safe.
                if invalidated {
                    NSLog("[ClipSlots] SlotStorage.set slot=\(slot): refused inside lock — invalidated while awaiting lock")
                    return false
                }
                do {
                    try writeSlotContent(content, to: slot)
                    cache[slot] = content
                    // P2-7 (v2.10.9): backfill the fingerprint with the freshly-written
                    // slot dir so the next get() serves the cache instead of doing a full
                    // disk re-read (the atomic swap changed the dir's inode/mtime/size).
                    let slotDir = baseURL.appendingPathComponent(String(slot))
                    cacheFingerprint[slot] = dirFingerprint(slotDir.path)
                    NSLog("[ClipSlots] SlotStorage.set OK slot=\(slot) preview=\(content.preview)")
                    return true
                } catch {
                    NSLog("[ClipSlots] SlotStorage.set FAIL slot=\(slot) error=\(error)")
                    return false
                }
            }
            // v2.8.0 (perf H2): manifest.json is a write-only diagnostic file (never
            // read back for correctness — `readManifest()` has no callers). Regenerating
            // it walks all 10 slot directories off disk, which previously ran inside the
            // synchronous save path and blocked the caller (usually the main thread) on
            // every save. Move it to the serial background queue so `set` returns as soon
            // as the slot itself is persisted and the in-memory cache is updated.
            if ok { scheduleManifestUpdate() }
            return ok
        }) ?? false
    }

    public func clear(_ slot: Int) {
        // DS-3 / CR-3 (v2.10.30): refuse writes on an invalidated (deleted-group) instance.
        if isInvalidated { return }
        // v2.9.4 (#4): cross-process lock around the delete write.
        try? StorageLock.shared.withLock {
            queue.sync {
                // A-1 (v2.10.31): re-check invalidation inside the lock (TOCTOU, see set()).
                if invalidated { return }
                cache[slot] = SlotContent()
                // P0-1 (v2.10.38): the slot dir (incl. label.txt) is removed below; drop its
                // label cache entry so getLabel doesn't serve a stale label for a cleared slot.
                labelCache.removeValue(forKey: slot)
                labelCacheFingerprint.removeValue(forKey: slot)
                let slotDir = baseURL.appendingPathComponent(String(slot))
                do {
                    try FileManager.default.removeItem(at: slotDir)
                } catch {
                    let nsErr = error as NSError
                    if nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4 { /* file not found */ }
                    else { NSLog("[ClipSlots] SlotStorage.clear FAIL slot=\(slot): \(error)") }
                }
            }
            scheduleManifestUpdate()
        }
    }

    public func clearAll(backupToTrash: Bool = true) {
        // DS-3 / CR-3 (v2.10.30): refuse on an invalidated instance — clearAll recreates
        // `baseURL`, which for a deleted group would resurrect its directory.
        if isInvalidated { return }
        // v2.9.4 (#4): cross-process lock around the wipe-and-recreate.
        try? StorageLock.shared.withLock {
            queue.sync {
                // A-1 (v2.10.31): re-check invalidation inside the lock (TOCTOU, see set()).
                if invalidated { return }
                // A-3 (v2.10.31): defense-in-depth soft delete. Previously the physical
                // `removeItem(baseURL)` below wiped the group with NO recycle-bin backup, so any
                // caller that reached the low-level `clearAll()` directly (bypassing
                // SpecialSlotStorage.clearAllSlots) lost the data unrecoverably. Snapshot the
                // group dir into `.trash` here so the LOW-LEVEL API self-defends. The one existing
                // caller already snapshots at the group layer and passes backupToTrash:false to
                // avoid a duplicate `.trash` entry.
                if backupToTrash { backupBaseDirToTrash() }
                cache.removeAll()
                // P0-1 (v2.10.38): the whole group dir is wiped/recreated; clear the label cache too.
                labelCache.removeAll()
                labelCacheFingerprint.removeAll()
                do {
                    try FileManager.default.removeItem(at: baseURL)
                    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
                    NSLog("[ClipSlots] SlotStorage.clearAll OK")
                } catch {
                    NSLog("[ClipSlots] SlotStorage.clearAll FAIL: \(error)")
                }
            }
            scheduleManifestUpdate()
        }
    }

    /// A-3 (v2.10.31): snapshot this group's slot directory into the sibling `.trash` before a
    /// destructive wipe, mirroring SpecialSlotStorage's group/overwrite soft-delete semantics.
    /// Uses `clonefile(2)` (via `cloneOrCopyItem`) so it stays cheap inside the storage lock.
    /// Only backs up a dir that actually has numeric slot data; skips a bare/empty group dir.
    /// Called on `queue` inside the StorageLock; failure only logs (never blocks the wipe).
    private func backupBaseDirToTrash() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseURL.path) else { return }
        let hasData = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil))?
            .contains(where: { Int($0.lastPathComponent) != nil }) ?? false
        guard hasData else { return }
        let trashDir = baseURL.deletingLastPathComponent().appendingPathComponent(".trash")
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let groupId = baseURL.lastPathComponent
        // Name ends with `_<秒.毫秒>` so SpecialSlotStorage.trashEntryDate() (splits on "_", last
        // segment parsed as Double) can date it for the unified retention/count pruning.
        var ts = Date().timeIntervalSince1970
        func target(_ ts: TimeInterval) -> URL {
            trashDir.appendingPathComponent("group_cleared_\(groupId)_\(String(format: "%.3f", ts))")
        }
        var t = target(ts)
        while fm.fileExists(atPath: t.path) { ts += 0.001; t = target(ts) }
        _ = cloneOrCopyItem(at: baseURL, to: t)
    }

    /// v2.8.0 (perf H2): regenerate the diagnostic manifest asynchronously on the
    /// serial storage queue so it never blocks the save/clear critical path.
    private func scheduleManifestUpdate() {
        // ST-5 (v2.10.15): rebuild on the dedicated manifestQueue (not the shared
        // storage `queue`) so the full slot-directory walk never blocks the get/set
        // hot path. Both callers invoke this AFTER their queue.sync write completes,
        // so the on-disk state is already current; updateManifest only reads the
        // filesystem, so it is safe off the storage queue.
        manifestQueue.async { [weak self] in
            do {
                try self?.updateManifest()
            } catch {
                NSLog("[ClipSlots] SlotStorage manifest update FAIL: \(error)")
            }
        }
    }

    public func snapshot() -> [Int: SlotContent] {
        queue.sync { cache }
    }

    /// v2.9.15 (fix): drop the in-memory SlotContent cache so the next `get(_:)`
    /// re-reads from disk. `get(_:)` serves cached SlotContent and never notices a
    /// change made by ANOTHER process (the `clipslots` CLI). The GUI's FSEvents watcher
    /// calls this before reloading so external writes are reflected. (The body was always
    /// correctly persisted to disk — this was a read-cache staleness bug, not a write bug.)
    /// P0-1 (v2.10.38): also drops the label cache (getLabel now caches label.txt too), so an
    /// external CLI label change is guaranteed to surface on the next read after invalidation.
    public func invalidateCache() {
        // P1-6 (v2.10.9): also clear the fingerprint map so the next get() cannot
        // match a stale fingerprint and serve dropped content.
        queue.sync {
            cache.removeAll()
            cacheFingerprint.removeAll()
            labelCache.removeAll()
            labelCacheFingerprint.removeAll()
        }
    }

    /// DS-3 / CR-3 (v2.10.30): permanently disable this storage instance. Called by
    /// `SpecialSlotStorage` when the owning slot group is deleted. After this, every write
    /// path (`set` / `clear` / `clearAll` / `setLabel`) refuses, so a lingering reference to
    /// a deleted group's storage can never physically recreate its directory ("phantom group").
    public func invalidate() {
        queue.sync { invalidated = true }
    }

    /// Whether this instance has been invalidated (group deleted). Read on `queue`.
    private var isInvalidated: Bool { queue.sync { invalidated } }

    // MARK: - Label

    public func getLabel(_ slot: Int) -> String? {
        let labelFile = baseURL.appendingPathComponent(String(slot)).appendingPathComponent("label.txt")
        // P0-1 (v2.10.38): fast path — if the label.txt fingerprint is unchanged since we last
        // read it, serve the cached label WITHOUT taking the cross-process lock or touching disk.
        // This is what makes global search on a large multi-group library stop freezing the main
        // thread. `dirFingerprint` returns nil when label.txt is absent; that (== nil) is a valid
        // cached state too. Outer optional from the closure = "was it a cache hit?".
        let diskFP = dirFingerprint(labelFile.path)
        if let cached: String? = queue.sync(execute: { () -> String?? in
            guard labelCache.index(forKey: slot) != nil else { return nil }      // never cached
            guard labelCacheFingerprint[slot]! == diskFP else { return nil }      // stale — re-read
            return labelCache[slot]!                                              // .some(String?)
        }) {
            return cached
        }

        // Slow path (miss or changed): read label.txt under the cross-process lock with the SHORT
        // read timeout (P0-3) so a main-thread search never stalls for the full 5s write timeout.
        if let result = try? StorageLock.shared.withLock(timeout: SlotStorage.readLockTimeout, {
            queue.sync { () -> String? in
                // Re-check inside the lock: another thread may have refreshed the cache meanwhile.
                let fp = dirFingerprint(labelFile.path)
                if labelCache.index(forKey: slot) != nil, labelCacheFingerprint[slot]! == fp {
                    return labelCache[slot]!
                }
                let value = (try? String(contentsOf: labelFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                labelCache[slot] = value
                labelCacheFingerprint[slot] = fp
                return value
            }
        }) {
            return result
        }

        // Lock busy / timed out: serve the last-known cached label rather than stall or lie.
        return queue.sync { labelCache.index(forKey: slot) != nil ? labelCache[slot]! : nil }
    }

    /// P0 (v2.10.40): no-lock label read for callers that ALREADY run on `queue`
    /// (and, in the write path, already hold `StorageLock`). `getLabel` takes
    /// `queue.sync`, so calling it from inside `set()`'s `queue.sync` block (via
    /// `writeSlotContent`) triggered "dispatch_sync called on queue already owned
    /// by current thread" (EXC_BREAKPOINT) — the v2.10.39 pack-import crash. This
    /// variant mirrors `getLabel`'s cache/disk logic WITHOUT re-dispatching onto
    /// `queue` or re-taking the cross-process lock. MUST only be called while
    /// executing on `queue`.
    private func getLabelOnQueue(_ slot: Int) -> String? {
        let labelFile = baseURL.appendingPathComponent(String(slot)).appendingPathComponent("label.txt")
        let fp = dirFingerprint(labelFile.path)
        // Serve the cache when its fingerprint still matches disk.
        if labelCache.index(forKey: slot) != nil, labelCacheFingerprint[slot]! == fp {
            return labelCache[slot]!
        }
        // Miss / stale: read label.txt directly (we're already on `queue`, and the
        // caller holds the cross-process lock, so no extra locking is needed).
        let value = (try? String(contentsOf: labelFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        labelCache[slot] = value
        labelCacheFingerprint[slot] = fp
        return value
    }

    public func setLabel(_ slot: Int, label: String?) {
        // DS-3 / CR-3 (v2.10.30): refuse writes on an invalidated (deleted-group) instance.
        if isInvalidated { return }
        // v2.9.4 (#4): cross-process lock around the label write.
        try? StorageLock.shared.withLock {
            queue.sync {
                let slotDir = baseURL.appendingPathComponent(String(slot))
                do {
                    try FileManager.default.createDirectory(at: slotDir, withIntermediateDirectories: true)
                } catch {
                    NSLog("[ClipSlots] setLabel: create dir FAIL slot=\(slot): \(error)")
                    return
                }
                let labelFile = slotDir.appendingPathComponent("label.txt")
                if let label = label, !label.isEmpty {
                    do {
                        try label.write(to: labelFile, atomically: true, encoding: .utf8)
                    } catch {
                        NSLog("[ClipSlots] setLabel: write FAIL slot=\(slot): \(error)")
                    }
                } else {
                    do { try FileManager.default.removeItem(at: labelFile) } catch {
                        let nsErr = error as NSError
                        if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) {
                            NSLog("[ClipSlots] setLabel: remove FAIL: \(error)")
                        }
                    }
                }
                // P0-1 (v2.10.38): invalidate the label cache entry so the next getLabel re-reads
                // the just-written value exactly once and repopulates the cache coherently.
                labelCache.removeValue(forKey: slot)
                labelCacheFingerprint.removeValue(forKey: slot)
            }
        }
    }

    // MARK: - Content Metadata (persisted alongside item data)

    private struct SlotContentMeta: Codable {
        let contentId: String
        let updatedAt: TimeInterval
    }

    // MARK: - Internal Read/Write

    private func readSlotContent(from slotDir: URL) -> SlotContent {
        var content = SlotContent()

        var isSlotDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: slotDir.path, isDirectory: &isSlotDir), isSlotDir.boolValue else {
            return content
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: slotDir.path),
           let modDate = attrs[.modificationDate] as? Date {
            content.timestamp = modDate
        }

        // Enumerate all item_N directories, sorted
        let itemDirs: [URL]
        do {
            itemDirs = try FileManager.default.contentsOfDirectory(at: slotDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("item_") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            NSLog("[ClipSlots] readSlotContent list FAIL slotDir=\(slotDir.path): \(error)")
            return content
        }

        var groups: [[PasteboardItem]] = []

        for itemDir in itemDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: nil)
            } catch {
                NSLog("[ClipSlots] readSlotContent read itemDir FAIL \(itemDir.path): \(error)")
                continue
            }

            var items: [PasteboardItem] = []
            for file in files where file.pathExtension == "bin" {
                let encodedType = file.deletingPathExtension().lastPathComponent
                let typeName = decodeSafeFileName(encodedType)
                do {
                    let data = try Data(contentsOf: file)
                    items.append(PasteboardItem(type: typeName, data: data))
                } catch {
                    NSLog("[ClipSlots] readSlotContent read file FAIL type=\(typeName): \(error)")
                }
            }

            if !items.isEmpty {
                groups.append(items)
            }
        }

        content.items = groups

        // Restore content identity from metadata file (v2.3.6+).
        // Slots saved before v2.3.6 won't have this file — we generate new IDs
        // so the first thumbnail load after upgrade is a one-time cache miss.
        let metaURL = slotDir.appendingPathComponent("content.json")
        if let metaData = try? Data(contentsOf: metaURL),
           let meta = try? decoder.decode(SlotContentMeta.self, from: metaData) {
            content.contentId = meta.contentId
            content.updatedAt = meta.updatedAt
        } else {
            // Legacy slot: generate stable-ish IDs so restarts don't thrash.
            content.contentId = UUID().uuidString
            content.updatedAt = content.timestamp.timeIntervalSince1970
        }

        // v2.8.3 (fix): restore slot attachments persisted alongside item data.
        // Prior to v2.8.3 attachments lived only in SlotStorage's in-memory cache
        // and were never serialized, so they vanished on the next app launch
        // (cold cache → disk read reconstructed SlotContent without attachments).
        // Missing/legacy file → keep the default empty array (fully backward compatible).
        let attachmentsURL = slotDir.appendingPathComponent("attachments.json")
        // ST-2 (v2.10.15): track whether THIS slot's attachments.json failed to decode
        // so writeSlotContent can refuse to physically overwrite a corrupt file with an
        // empty payload. Slot number is derived from the dir name (get() passes the
        // integer-named slot dir); nil means an unexpected path — treat as no tracking.
        let slotNum = Int(slotDir.lastPathComponent)
        if FileManager.default.fileExists(atPath: attachmentsURL.path) {
            if let attData = try? Data(contentsOf: attachmentsURL),
               let atts = try? decoder.decode([SlotContent.SlotAttachment].self, from: attData) {
                // Step 2 (v2.10.42) 老数据懒迁移：若解码出的附件仍内联着 base64 `data`
                // （老格式，storagePath 缺失/文件不存在），首次读到时把字节外置成独立文件并
                // 回写 JSON，收敛到「JSON 只存元数据 + storagePath」的新格式。见方法内注释——
                // 全程原子化、先落盘 .bin 再改写 JSON，中途崩溃不丢原始 data；无迁移需求时零写盘。
                content.attachments = migrateInlineAttachmentsIfNeeded(atts, slotDir: slotDir)
                // Clean decode clears any prior corruption poison for this slot.
                if let s = slotNum { attachmentDecodeFailedSlots.remove(s) }
            } else {
                // P2 (v2.10.13): 文件「存在但解码失败」= 真实损坏（区别于「文件缺失」的正常
                // 首次/legacy 情形）。此前一律走 try? 静默回退为空，随后一次 writeSlotContent
                // 会因 attachments 为空而不再写 attachments.json，把「空」固化 → 附件永久丢失。
                // 这里在返回空之前，先把损坏文件备份到 baseURL 下的兄弟文件（放在 slotDir 之外，
                // 使其能在下一次「原子替换整个槽目录」后依然存活），与 index.json 的
                // poison+backup 保护对齐，保证用户仍可从备份恢复。
                // ST-2 (v2.10.15): also POISON this slot so a following empty-attachment
                // write refuses to drop the corrupt file (see writeSlotContent).
                if let s = slotNum { attachmentDecodeFailedSlots.insert(s) }
                let slotName = slotDir.lastPathComponent
                // P2-6 (v2.10.16): 损坏备份改为「固定文件名覆盖式」。此前用带时间戳的
                // `.corrupt-<ts>`，每次读到同一损坏文件都会新建一份备份且无任何清理，
                // 反复读会持续堆盘，与 index.json「单份备份」的设计不一致。改为统一用
                // 不带时间戳的 `slot_<slotName>_attachments.json.corrupt`，每次损坏就以
                // .atomic 覆盖写这一份，保证同一损坏文件最多只占用一份备份。
                let backupURL = baseURL.appendingPathComponent(
                    "slot_\(slotName)_attachments.json.corrupt")
                do {
                    try Data(contentsOf: attachmentsURL).write(to: backupURL, options: .atomic)
                    NSLog("[ClipSlots] ERROR: slot \(slotName) attachments.json failed to decode; "
                        + "backed up corrupt bytes to \(backupURL.path) before falling back to empty. "
                        + "Recover attachments from that backup.")
                } catch {
                    NSLog("[ClipSlots] ERROR: slot \(slotName) attachments.json failed to decode AND "
                        + "the corrupt backup failed: \(error). Falling back to empty attachments.")
                }
            }
        } else {
            // ST-2 (v2.10.15): no file on disk = genuinely empty (or legacy). Clear any
            // stale poison so it never blocks a legitimate empty-attachment write.
            if let s = slotNum { attachmentDecodeFailedSlots.remove(s) }
        }

        return content
    }

    private func writeSlotContent(_ content: SlotContent, to slot: Int) throws {
        let slotDir = baseURL.appendingPathComponent(String(slot))

        // P1-5 (v2.10.9): sweep any staging dirs for THIS slot orphaned by a prior
        // crash before creating a fresh one, so `.tmp_slot_<slot>_*` cannot pile up.
        cleanupStagingDirs(slot: slot)

        // Preserve label before rebuilding.
        // P0 (v2.10.40): writeSlotContent always runs inside set()'s `queue.sync`
        // block, so it MUST use the no-lock, on-queue variant. Calling the public
        // `getLabel` here re-entered `queue.sync` on the queue-owning thread and
        // crashed with "dispatch_sync called on queue already owned by current
        // thread" during pack import (v2.10.39).
        let existingLabel = getLabelOnQueue(slot)

        // P1-3 (v2.10.8): atomic write. The old implementation removed `slotDir`
        // first and then rebuilt it file-by-file. If the process crashed / was
        // killed after the delete but before the rebuild finished (auto-update
        // ditto over a running bundle, power loss, etc.), the slot was left as a
        // half-written directory — or an empty one — losing data permanently.
        // Now everything is written into a same-volume staging directory and then
        // swapped into place with `replaceItemAt` (atomic rename on the same
        // volume). Any mid-way failure leaves the existing slot fully intact.
        let stagingDir = baseURL.appendingPathComponent(".tmp_slot_\(slot)_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            // Restore label into the staging dir.
            if let label = existingLabel, !label.isEmpty {
                try label.write(to: stagingDir.appendingPathComponent("label.txt"),
                                atomically: true, encoding: .utf8)
            }

            // v2.8.3 (fix): a slot may carry attachments even when its main content is
            // empty (attachments are added independently in the node canvas). Persist
            // payload if EITHER items or attachments exist; an empty slot is a
            // label-only staging dir (matches the previous wipe-then-empty behaviour).
            if !content.isEmpty || !content.attachments.isEmpty {
                for (groupIdx, items) in content.items.enumerated() {
                    let targetDir = stagingDir.appendingPathComponent("item_\(groupIdx)")
                    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

                    for item in items {
                        let safeName = encodeSafeFileName(item.type) + ".bin"
                        let typeFile = targetDir.appendingPathComponent(safeName)
                        try item.data.write(to: typeFile, options: .atomic)
                    }
                }

                // Persist content identity so thumbnail keys survive app restarts.
                let meta = SlotContentMeta(contentId: content.contentId, updatedAt: content.updatedAt)
                let metaData = try encoder.encode(meta)
                try metaData.write(to: stagingDir.appendingPathComponent("content.json"), options: .atomic)

                // Persist slot attachments alongside item data so they survive restarts.
                // Step 2 (v2.10.42) 附件字节外置：把「带字节」的附件写成独立文件
                // `{slotDir}/attachments/{id}.bin`，attachments.json 从此只存元数据 + storagePath
                // （data 置 nil）。externalizeAttachments 在 staging 目录内落盘，随整槽目录原子 swap
                // 一并生效——JSON 与其引用的 .bin 文件永远同生共死，不会出现「JSON 指向不存在字节」。
                if !content.attachments.isEmpty {
                    let externalized = try externalizeAttachments(content.attachments, slot: slot, stagingDir: stagingDir)
                    let attData = try encoder.encode(externalized)
                    try attData.write(to: stagingDir.appendingPathComponent("attachments.json"), options: .atomic)
                }
            }

            // ST-2 (v2.10.15): if this payload carries NO attachments but the slot's
            // on-disk attachments.json previously FAILED to decode (genuine corruption,
            // tracked in attachmentDecodeFailedSlots — NOT a legitimately-empty slot),
            // do NOT let the atomic swap physically drop that file: that would be
            // permanent data loss. Mirror the index-layer refusingToOverwriteWithEmpty
            // guard by carrying the original (corrupt) file into the staging dir so it
            // survives the swap, and log the refusal instead of silently clearing.
            if content.attachments.isEmpty, attachmentDecodeFailedSlots.contains(slot) {
                let liveAttachments = slotDir.appendingPathComponent("attachments.json")
                let stagedAttachments = stagingDir.appendingPathComponent("attachments.json")
                if FileManager.default.fileExists(atPath: liveAttachments.path),
                   !FileManager.default.fileExists(atPath: stagedAttachments.path) {
                    try? FileManager.default.copyItem(at: liveAttachments, to: stagedAttachments)
                    NSLog("[ClipSlots] WARNING: slot \(slot) attachments.json is corrupt (failed to decode); "
                        + "refusing to overwrite it with an empty payload — preserving the original file "
                        + "across the atomic write so it stays recoverable.")
                }
            }

            // Atomic swap: replace the live slot dir with the fully-built staging dir.
            if FileManager.default.fileExists(atPath: slotDir.path) {
                _ = try FileManager.default.replaceItemAt(slotDir, withItemAt: stagingDir)
            } else {
                try FileManager.default.moveItem(at: stagingDir, to: slotDir)
            }
        } catch {
            // Best-effort cleanup of the staging dir; the original slot is untouched.
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }
    }

    /// Step 2 (v2.10.42) 附件字节外置：把每个「带字节」的附件写成独立文件
    /// `{stagingDir}/attachments/{id}.bin`（随整槽目录原子 swap 后成为 `{slotDir}/attachments/{id}.bin`），
    /// 返回「字节已外置」的附件数组（`data=nil`、`storagePath=最终路径`）用于写入 attachments.json。
    ///
    /// 字节来源优先级：
    ///   1) 内联 `data`（新写入 / 尚未迁移的内存态）——直接写文件；inline 已在内存中，不额外放大内存。
    ///   2) 已外置的 `storagePath` 指向的现存文件（本槽历次写入 / 读后内存 data 为 nil）——用 clonefile
    ///      克隆进 staging，保证「重写槽位（如只改正文/标签）」时不丢历史外置字节；否则整槽目录每次
    ///      staging→原子 swap，旧 `.bin` 会随 swap 一并消失。
    ///   3) 二者皆无（纯 path 引用 / url / reference / 断链）——原样保留元数据，不外置。
    private func externalizeAttachments(_ attachments: [SlotContent.SlotAttachment],
                                        slot: Int,
                                        stagingDir: URL) throws -> [SlotContent.SlotAttachment] {
        let fm = FileManager.default
        let finalAttachmentsDir = baseURL.appendingPathComponent(String(slot))
            .appendingPathComponent("attachments", isDirectory: true)
        let stagingAttachmentsDir = stagingDir.appendingPathComponent("attachments", isDirectory: true)

        func ensureStagingDir() throws {
            if !fm.fileExists(atPath: stagingAttachmentsDir.path) {
                try fm.createDirectory(at: stagingAttachmentsDir, withIntermediateDirectories: true)
            }
        }

        var result: [SlotContent.SlotAttachment] = []
        result.reserveCapacity(attachments.count)

        for att in attachments {
            let binName = att.id.uuidString + ".bin"
            let destFile = stagingAttachmentsDir.appendingPathComponent(binName)
            // storagePath 记录的是「原子 swap 后」的最终路径，读侧稳定可寻址。
            let finalPath = finalAttachmentsDir.appendingPathComponent(binName).path

            var out = att
            if let inline = att.data, !inline.isEmpty {
                // 情形 1：内联字节 → 落成独立文件。
                try ensureStagingDir()
                try inline.write(to: destFile, options: .atomic)
                out.data = nil
                out.storagePath = finalPath
            } else if let sp = att.storagePath, !sp.isEmpty, fm.fileExists(atPath: sp) {
                // 情形 2：本已外置、内存无 data → 把现存 .bin 克隆进 staging（零内存），
                // 否则整目录原子 swap 会把旧字节文件一并替换掉导致丢失。
                try ensureStagingDir()
                try? fm.removeItem(at: destFile)
                if cloneOrCopyItem(at: URL(fileURLWithPath: sp), to: destFile) {
                    out.data = nil
                    out.storagePath = finalPath
                } else {
                    // 搬运失败：不谎报外置路径（会让读侧断链），退回「无字节」元数据。
                    out.data = nil
                    out.storagePath = nil
                    NSLog("[ClipSlots] externalizeAttachments slot=\(slot) att=\(att.id) clone FAIL from \(sp)")
                }
            } else {
                // 情形 3：无字节（纯 path 引用 / url / reference / storagePath 已断链）——原样保留元数据。
                // 若 storagePath 指向已不存在的文件，清空以如实反映断链，避免读侧误判有字节。
                if let sp = att.storagePath, !sp.isEmpty, !fm.fileExists(atPath: sp) {
                    out.storagePath = nil
                }
            }
            result.append(out)
        }
        return result
    }

    /// Step 2 (v2.10.42) 老数据懒迁移：把 attachments.json 里仍内联着 base64 `data` 的老附件
    /// 字节外置成独立文件 `{slotDir}/attachments/{id}.bin`，并回写 JSON（data 置 nil、写入
    /// storagePath），使老数据收敛到新格式。仅在 get() 的慢路径（已持跨进程 StorageLock + 串行
    /// queue）内被 readSlotContent 调用，故此处磁盘写入是并发安全的。
    ///
    /// 崩溃安全（要求 5）——严格的落盘顺序 + 原子操作：
    ///   1) 逐条把内联字节写入唯一命名的临时文件，再 rename 到最终 `{id}.bin`（rename 前最终名不
    ///      可见，崩溃只会留下可被覆盖/清理的 .tmp，绝不产生半截 .bin）。
    ///   2) 只有 .bin 全部安全落盘后，才原子改写 attachments.json 去掉内联 data。
    ///   因此任意时刻「原始内联 data」与「已外置 .bin」至少一份完整存在：崩溃在改写 JSON 之前 →
    ///   旧 JSON（含 data）仍在，下次读幂等重迁；崩溃在之后 → .bin + 新 JSON 一致。原始 data 永不丢。
    ///
    /// 无迁移需求时（新数据 / 无内联 data）零写盘，直接返回原数组，不影响正常读取。
    private func migrateInlineAttachmentsIfNeeded(_ attachments: [SlotContent.SlotAttachment],
                                                  slotDir: URL) -> [SlotContent.SlotAttachment] {
        let fm = FileManager.default
        // 需要迁移 = 携带内联 data，且尚无可用的外置文件。
        func needsMigration(_ att: SlotContent.SlotAttachment) -> Bool {
            guard let d = att.data, !d.isEmpty else { return false }
            if let sp = att.storagePath, !sp.isEmpty, fm.fileExists(atPath: sp) { return false }
            return true
        }
        guard attachments.contains(where: needsMigration) else { return attachments }

        let attachmentsDir = slotDir.appendingPathComponent("attachments", isDirectory: true)
        var migrated = attachments
        var anyChanged = false

        for i in migrated.indices {
            let att = migrated[i]
            guard needsMigration(att), let bytes = att.data else { continue }
            let binName = att.id.uuidString + ".bin"
            let finalFile = attachmentsDir.appendingPathComponent(binName)
            do {
                if !fm.fileExists(atPath: attachmentsDir.path) {
                    try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
                }
                // 临时文件 + rename：唯一命名的 .tmp 写完再 move 到最终名，保证最终 .bin 不会半截。
                let tmpFile = attachmentsDir.appendingPathComponent(".mig_\(binName)_\(UUID().uuidString).tmp")
                try bytes.write(to: tmpFile)
                if fm.fileExists(atPath: finalFile.path) { try? fm.removeItem(at: finalFile) }
                try fm.moveItem(at: tmpFile, to: finalFile)
                // .bin 安全落盘后，才把内存态改为「已外置」：data 置 nil、storagePath 指向新文件。
                migrated[i].data = nil
                migrated[i].storagePath = finalFile.path
                anyChanged = true
            } catch {
                // 单条迁移失败：保留内联 data（绝不丢原始字节），下次读再重试（幂等）。
                NSLog("[ClipSlots] migrate attachment slot=\(slotDir.lastPathComponent) att=\(att.id) FAIL: \(error)")
            }
        }

        // 只有确有字节成功外置后，才原子改写 attachments.json（此时 .bin 已安全落盘）。
        if anyChanged {
            do {
                let attData = try encoder.encode(migrated)
                try attData.write(to: slotDir.appendingPathComponent("attachments.json"), options: .atomic)
            } catch {
                // JSON 改写失败：.bin 已在盘上但 JSON 仍是旧的（含 data）——数据不丢；下次读因旧 JSON
                // 无 storagePath 仍判定需迁移，会覆盖同名 .bin 并重试写 JSON（幂等）。本次返回 migrated
                // （storagePath 已指向存在文件），读取正常。
                NSLog("[ClipSlots] migrate rewrite attachments.json FAIL slot=\(slotDir.lastPathComponent): \(error)")
            }
        }
        return migrated
    }

    // MARK: - Safe Filename Encoding

    private let slashPlaceholder = "$slash$"

    private func encodeSafeFileName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: slashPlaceholder)
    }

    private func decodeSafeFileName(_ encoded: String) -> String {
        encoded.replacingOccurrences(of: slashPlaceholder, with: "/")
    }

    // MARK: - Manifest

    private func manifestURL() -> URL {
        baseURL.appendingPathComponent("manifest.json")
    }

    private func readManifest() throws -> SlotManifest {
        let data = try Data(contentsOf: manifestURL())
        return try decoder.decode(SlotManifest.self, from: data)
    }

    private func updateManifest() throws {
        var entries: [SlotManifest.Entry] = []

        // v2.10.3 (P2): enumerate actual on-disk integer-named slot dirs instead of a
        // hardcoded `1...10`, so a larger configured slot count is not silently dropped.
        let slotNumbers = (try? FileManager.default.contentsOfDirectory(atPath: baseURL.path))?
            .compactMap { Int($0) }
            .sorted() ?? []

        for slot in slotNumbers {
            let slotDir = baseURL.appendingPathComponent(String(slot))

            var isSlotDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: slotDir.path, isDirectory: &isSlotDir), isSlotDir.boolValue else {
                continue
            }

            // Find the first item_N directory
            let itemDirs = try FileManager.default.contentsOfDirectory(at: slotDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("item_") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            guard !itemDirs.isEmpty, let firstItemDir = itemDirs.first else { continue }

            var types: [String] = []
            var totalBytes = 0
            var preview = "(empty)"
            let itemCount = itemDirs.count

            // Read all item dirs for types and totals
            for itemDir in itemDirs {
                let files = try FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: [.fileSizeKey])
                for file in files where file.pathExtension == "bin" {
                    let encodedType = file.deletingPathExtension().lastPathComponent
                    let typeName = decodeSafeFileName(encodedType)
                    types.append(typeName)

                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let size = attrs[.size] as? Int { totalBytes += size }

                    // Preview from the first item dir only
                    if itemDir == firstItemDir {
                        if typeName == "public.utf8-plain-text" || typeName == "NSStringPboardType" {
                            if let data = try? Data(contentsOf: file),
                               let str = String(data: data, encoding: .utf8) {
                                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                                preview = String(trimmed.prefix(37))
                            }
                        } else if typeName == "public.rtf" {
                            preview = "[Rich Text]"
                        } else if typeName.contains("image") {
                            preview = "[Image \(totalBytes / 1024)KB]"
                        } else if typeName == "public.file-url" {
                            if let data = try? Data(contentsOf: file),
                               let urlStr = String(data: data, encoding: .utf8),
                               let url = URL(string: urlStr) {
                                preview = "[File] \(url.lastPathComponent)"
                            } else {
                                preview = "[File]"
                            }
                        }
                    }
                }
            }

            if let label = getLabel(slot), !label.isEmpty {
                preview = "[\(label)] \(preview)"
            }

            if preview.hasPrefix("[Rich Text]"),
               let richTextFile = firstItemDir.appendingPathComponent(encodeSafeFileName("public.utf8-plain-text") + ".bin") as URL?,
               FileManager.default.fileExists(atPath: richTextFile.path),
               let data = try? Data(contentsOf: richTextFile),
               let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let chars = trimmed.count
                let suffix = chars > 0 ? " \(chars) chars: \(String(trimmed.prefix(37)))" : ""
                preview = "[Rich Text]\(suffix)"
            }

            entries.append(SlotManifest.Entry(
                description: preview,
                itemCount: itemCount,
                slot: slot,
                totalBytes: totalBytes,
                types: types.sorted(),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            ))
        }

        let manifest = SlotManifest(entries: entries, version: 1)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(), options: .atomic)
    }
}
