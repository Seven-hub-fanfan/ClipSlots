import Foundation

// MARK: - Slot Group Direction (v2.4.1)

public enum SlotGroupDirection {
    case previous
    case next
}

// P0-1: raised by saveIndex when a save would overwrite real data with the empty fallback.
public enum SpecialSlotStorageError: Error {
    case refusingToOverwriteWithEmptyIndex
}

public final class SpecialSlotStorage {
    public static let shared = SpecialSlotStorage()

    private let baseDir: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "com.clipslots.specialstorage", qos: .utility)
    /// v2.9.4 (#4): cross-process advisory lock. Acquired OUTSIDE `queue` (never
    /// dispatched onto it) so `flock` acquisition can never deadlock with the
    /// serial `queue.sync` used inside `loadIndex`.
    private let storageLock = StorageLock.shared

    /// P1-4 (v2.10.9): "poison" flag set true when loadIndex() hits a genuine
    /// DECODE failure (corrupt index.json that physically exists), reset false on
    /// a clean successful decode. saveIndex() consults it to refuse persisting the
    /// schemaVersion=0 empty fallback (or a single slot appended to it) over real
    /// data — the P0-1 "completely empty" guard alone does not catch that case.
    ///
    /// P2 (v2.10.13): 该标志此前在 loadIndex()（queue.sync 内，行 398/415）写、在
    /// saveIndex()（不在 queue.sync 内，行 469）读，跨队列裸访问存在数据竞争（TSan 可报）。
    /// 改为经专用 NSLock 原子访问的计算属性——loadIndex 已在 queue.sync 内也能安全读写
    /// （不同锁，不会自锁），saveIndex 在任意上下文读取也线程安全。
    private let decodeFailedLock = NSLock()
    private var _lastLoadDecodeFailed = false
    private var lastLoadDecodeFailed: Bool {
        get { decodeFailedLock.lock(); defer { decodeFailedLock.unlock() }; return _lastLoadDecodeFailed }
        set { decodeFailedLock.lock(); defer { decodeFailedLock.unlock() }; _lastLoadDecodeFailed = newValue }
    }

    // F7 (契约5): records what the startup default-page/group repair did on this
    // process. Empty => nothing needed repair. Read by the CLI to emit `repaired`
    // (+ `repair_actions`) on responses.
    // DS-5 (v2.10.30): `lastRepairActions` is written on the background repair path
    // (repairDefaultsIfNeeded) and read by the CLI/UI on another thread — an unsynchronized
    // Array read/write is a data race (can crash / read a torn value). Back it with a private
    // store guarded by a dedicated lock; expose thread-safe get/set accessors.
    private var _lastRepairActions: [String] = []
    private let repairActionsLock = NSLock()
    public private(set) var lastRepairActions: [String] {
        get { repairActionsLock.lock(); defer { repairActionsLock.unlock() }; return _lastRepairActions }
        set { repairActionsLock.lock(); _lastRepairActions = newValue; repairActionsLock.unlock() }
    }
    public var didRepairDefaults: Bool { !lastRepairActions.isEmpty }

    public init() {
        // v2.9.29: honor CLIPSLOTS_DATA_DIR via ClipSlotsPaths (env > default).
        let appSupport = ClipSlotsPaths.specialSlots
        baseDir = appSupport
        indexURL = baseDir.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        ensureInitialized()
        // F7 (契约5): detect + auto-repair a missing default page / default group on
        // every process init (before trash cleanup so a repaired install is fully
        // consistent for the command about to run).
        repairDefaultsIfNeeded()
        // v2.9.5 (Feature #1): opportunistic trash cleanup at startup so a long-idle
        // install still shrinks accumulated `.trash` even without a new delete.
        cleanupTrash()
    }

    // MARK: - Init / Migration

    private func ensureInitialized() {
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            // P2 (v2.10.13): 首启建库 / legacy 迁移的写入纳入跨进程 storageLock，并在锁内
            // 二次校验 index.json 是否已被并发进程创建，做到幂等——GUI 与 CLI 同时首启时
            // 只有一个进程真正建库，另一个直接跳过，避免 copyItem 目标已存在报错或 index 半写。
            try? storageLock.withLock {
                guard !FileManager.default.fileExists(atPath: indexURL.path) else { return }
                migrateLegacySlotsOrCreateDefault()
            }
            return
        }
        // v2.4 migration: upgrade existing index to schemaVersion 2
        migrateToV2SchemaIfNeeded()
    }

    /// v2.4 migration: add Page layer on top of existing SpecialSlots.
    /// Safe to call repeatedly — checks schemaVersion before migrating.
    private func migrateToV2SchemaIfNeeded() {
        // Fast pre-check outside the lock (common already-migrated path avoids lock churn).
        if loadIndex().schemaVersion >= 2 {
            repairPageScopedSlotGroupsIfNeeded()
            return
        }

        // P2-12 (v2.10.8): run the migration read→transform→save atomically under the
        // cross-process lock. ensureInitialized()/migrate runs on EVERY CLI invocation
        // and GUI launch, so two processes racing on a not-yet-migrated index could both
        // migrate and clobber each other (lost update / duplicate default page). Re-load
        // and re-check the schema version under the lock so only the first writer migrates.
        //
        // P1-2 (v2.10.16): 与 repairPageScopedSlotGroupsIfNeeded 同理，此处也在 init 路径上。
        // 之前用默认 5s 超时，CLI 持锁时 GUI 启动仍可卡最多 5s。改为短超时（0.5s）：超时即跳过本次
        // 迁移，迁移逻辑幂等且下次任一命令启动会再次尝试，不会丢数据也不会阻塞启动。
        try? storageLock.withLock(timeout: 0.5) {
        let index = loadIndex()

        // Already v2.4+ format — another process migrated while we waited for the lock.
        if index.schemaVersion >= 2 {
            // P2-6 (v2.10.9): the fast pre-check path (schema>=2) runs the page-scoped
            // group repair; this in-lock recheck branch returned early WITHOUT it, so a
            // process that lost the migration race skipped repair entirely. repair is
            // idempotent, so run it here too before returning.
            repairPageScopedSlotGroupsIfNeeded()
            return
        }

        // Safety: if the index is empty/corrupt (e.g. from a failed decode fallback),
        // don't proceed — the original file is still on disk, try to back it up.
        if index.specialSlots.isEmpty && index.schemaVersion < 2 {
            NSLog("[ClipSlots] v2.4 migration: index has no slots (schemaVersion=\(index.schemaVersion)), possible decode error. Backing up and creating clean slate.")
            let backupDir = baseDir
                .deletingLastPathComponent()
                .appendingPathComponent("special_slots_backup_v2_corrupt", isDirectory: true)
            try? FileManager.default.removeItem(at: backupDir)
            try? FileManager.default.copyItem(at: baseDir, to: backupDir)
            NSLog("[ClipSlots] v2.4 migration: corrupt index backed up to \(backupDir.path)")
            try? createDefaultIndex()
            return
        }

        NSLog("[ClipSlots] Starting v2.4 schema migration (schemaVersion \(index.schemaVersion) → 2, slots=\(index.specialSlots.count))")

        // 1. Backup entire special_slots directory
        let backupDir = baseDir
            .deletingLastPathComponent()
            .appendingPathComponent("special_slots_backup_v2", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: backupDir.path) {
                try? FileManager.default.removeItem(at: backupDir)
            }
            try FileManager.default.copyItem(at: baseDir, to: backupDir)
            NSLog("[ClipSlots] v2.4 migration: backup created at \(backupDir.path)")
        } catch {
            NSLog("[ClipSlots] v2.4 migration: backup failed \(error), aborting")
            return
        }

        // 2. Create default page
        let defaultPage = SlotPage(
            id: "default_page",
            name: "默认页面",
            order: 0,
            createdAt: Date(),
            updatedAt: Date()
        )

        // 3. Assign all existing SpecialSlots to default page
        var updatedSlots = index.specialSlots
        for i in 0..<updatedSlots.count {
            updatedSlots[i].pageId = "default_page"
            updatedSlots[i].order = i
        }

        // 4. Build upgraded index
        var upgraded = index
        upgraded.schemaVersion = 2
        upgraded.version = 4
        upgraded.currentPageId = "default_page"
        upgraded.pages = [defaultPage]
        upgraded.specialSlots = updatedSlots

        // 5. Save
        do {
            try saveIndex(upgraded)
            NSLog("[ClipSlots] v2.4 migration complete: \(updatedSlots.count) slot groups → 默认页面")
        } catch {
            NSLog("[ClipSlots] v2.4 migration save failed: \(error)")
        }
        } // end storageLock.withLock (P2-12)
    }

    /// v2.4.1 Repair: ensure page-scoped slot group consistency.
    ///
    /// v2.9.41 (Problem B): this repair now runs INSIDE the cross-process lock and
    /// re-loads the index under that lock. Previously it read the index outside any
    /// lock (during storage init, which happens on EVERY CLI invocation) and then
    /// wrote back if it found an inconsistency. Because a parallel `create-group` /
    /// `write` could hold the lock and mutate the index between this read and write,
    /// the unlocked repair could clobber a concurrent write (a lost update) — which
    /// itself MANUFACTURED the very inconsistencies (dangling currentSpecialSlotId,
    /// missing groups) that caused a "repair event" to fire on the next command
    /// (e.g. delete-page). Reading + deciding + writing atomically under the lock
    /// removes that self-inflicted inconsistency source. If the lock is momentarily
    /// busy we simply skip repair this run (try?) — a later command repairs it.
    private func repairPageScopedSlotGroupsIfNeeded() {
        // P1-2 (v2.10.16): 此修复位于 init()/ensureInitialized() 路径，随每次 CLI 调用与 GUI 启动执行，
        // 且是所有已迁移用户（schema>=2）的公共快路径。之前用默认 5s 超时的 withLock，当 CLI 正持锁时
        // GUI 启动仍会在此阻塞最多 5s，正是 ST-1 (v2.10.15) 想根除的「启动卡死」。ST-1 只给
        // repairDefaultsIfNeeded 加了 0.5s 超时，却漏掉了 init 路径上更早的本修复与 v2 迁移。
        // 统一改为短超时（0.5s），超时即跳过本次修复——修复是幂等的，交由后续任一命令再修复。
        try? storageLock.withLock(timeout: 0.5) {
            var modified = loadIndex()
            var changed = false

        // 1. Ensure pages array is non-empty
        if modified.pages.isEmpty {
            let defaultPage = SlotPage(
                id: "default_page",
                name: "默认页面",
                order: 0,
                createdAt: Date(),
                updatedAt: Date()
            )
            modified.pages = [defaultPage]
            modified.currentPageId = "default_page"
            changed = true
        }

        let validPageIds = Set(modified.pages.map { $0.id })

        // 2. Ensure currentPageId is valid
        if modified.currentPageId.isEmpty || !validPageIds.contains(modified.currentPageId) {
            modified.currentPageId = modified.pages.first?.id ?? "default_page"
            changed = true
        }

        // 3. Fix slot groups with invalid or missing pageId
        for i in 0..<modified.specialSlots.count {
            let pageId = modified.specialSlots[i].pageId
            if pageId.isEmpty || !validPageIds.contains(pageId) {
                modified.specialSlots[i].pageId = modified.currentPageId
                changed = true
            }
        }

        // 3b. (v2.9.41) Back-fill `order` for legacy data. Pre-order groups decode
        // with order == 0, so a page full of legacy groups has duplicate orders and
        // no stable sort key. When a page's group orders are not all-distinct we
        // renumber them 0..n-1 IN THEIR CURRENT ARRAY ORDER (the historical insert
        // order), giving concurrent create-group a clean, gap-free base to insert
        // into. Pages whose orders are already distinct are left untouched.
        for pageId in validPageIds {
            let idxs = modified.specialSlots.indices.filter { modified.specialSlots[$0].pageId == pageId }
            guard idxs.count > 1 else { continue }
            let orders = idxs.map { modified.specialSlots[$0].order }
            if Set(orders).count != orders.count {
                for (newOrder, i) in idxs.enumerated() where modified.specialSlots[i].order != newOrder {
                    modified.specialSlots[i].order = newOrder
                    changed = true
                }
            }
        }

        // 4. (removed in v2.9.33) Previously this step lazily back-filled a
        // "默认槽位组" for any page that had none. That lazy backfill has been
        // removed to avoid two competing code paths: `createPage` now creates
        // the default group synchronously, so pages are never left empty at
        // creation time. Keeping the lazy repair as well caused unpredictable
        // timing (a page could momentarily appear empty between operations).

        // 5. Fix currentSpecialSlotId if it doesn't belong to current page
        let currentPageGroups = modified.specialSlots.filter { $0.pageId == modified.currentPageId }
        if !currentPageGroups.contains(where: { $0.id == modified.currentSpecialSlotId }) {
            let fallback = currentPageGroups.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }.first
            modified.currentSpecialSlotId = fallback?.id ?? modified.specialSlots.first?.id ?? "default"
            changed = true
        }

        // 6. Fix selectedSpecialSlotId / activeHotkeySpecialSlotId
        if let selectedId = modified.selectedSpecialSlotId,
           !currentPageGroups.contains(where: { $0.id == selectedId }) {
            modified.selectedSpecialSlotId = modified.currentSpecialSlotId
            changed = true
        }
        if let activeId = modified.activeHotkeySpecialSlotId,
           !currentPageGroups.contains(where: { $0.id == activeId }) {
            modified.activeHotkeySpecialSlotId = modified.currentSpecialSlotId
            changed = true
        }

            if changed {
                try? saveIndex(modified)
                NSLog("[ClipSlots] v2.4.1 repair: fixed page-scoped slot group inconsistencies")
            }
        }
    }

    private func migrateLegacySlotsOrCreateDefault() {
        let legacyDir = ClipSlotsPaths.slots

        if FileManager.default.fileExists(atPath: legacyDir.path) {
            NSLog("[ClipSlots] Migrating legacy slots to default special slot")
            do {
                try migrateLegacySlots(from: legacyDir)
            } catch {
                NSLog("[ClipSlots] Migration failed: \(error). Creating default index.")
                try? createDefaultIndex()
            }
        } else {
            try? createDefaultIndex()
        }
    }

    private func migrateLegacySlots(from legacyDir: URL) throws {
        let defaultDir = specialSlotDirectory(for: "default")

        if !FileManager.default.fileExists(atPath: defaultDir.path) {
            try FileManager.default.copyItem(at: legacyDir, to: defaultDir)
            NSLog("[ClipSlots] Copied legacy slots to special_slots/default")
        }

        try createDefaultIndex()

        // Write migration marker
        let marker = baseDir.appendingPathComponent(".migration_v2_done")
        try? "done".write(to: marker, atomically: true, encoding: .utf8)
        NSLog("[ClipSlots] Migration complete")
    }

    private func createDefaultIndex() throws {
        let defaultPage = SlotPage(
            id: "default_page",
            name: "默认页面",
            order: 0,
            createdAt: Date(),
            updatedAt: Date()
        )

        let defaultSlot = SpecialSlot(
            id: "default",
            name: "默认槽位组",
            icon: "folder",
            colorHex: nil,
            sourceType: .migratedDefault,
            sourcePath: nil,
            pageId: "default_page",
            order: 0,
            createdAt: Date(),
            updatedAt: Date()
        )

        let index = SpecialSlotIndex(
            schemaVersion: 2,
            version: 4,
            currentPageId: "default_page",
            pages: [defaultPage],
            currentSpecialSlotId: "default",
            specialSlots: [defaultSlot],
            settings: .default
        )

        try saveIndex(index)

        // Ensure default directory exists
        let defaultDir = specialSlotDirectory(for: "default")
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
    }

    /// F7 (契约5): ensure default page ("default_page") and default group ("default")
    /// exist; recreate whichever is missing. Idempotent, runs inside the cross-process
    /// storage lock. Records human-readable actions in `lastRepairActions` so the CLI
    /// can surface `repaired` / `repair_actions` on its responses.
    private func repairDefaultsIfNeeded() {
        do {
            // ST-1 (v2.10.15): init() calls this synchronously on the launching
            // thread (the main thread for the GUI). It previously used the default
            // 5s blocking lock timeout, so if the CLI held storageLock during a slow
            // import, GUI launch stalled for the full ~5s. Fix (least invasive, keeps
            // lastRepairActions semantics): stay SYNCHRONOUS — so the CLI still repairs
            // before its command runs and reports `repaired`/`repair_actions` — but
            // acquire the lock with a SHORT timeout instead of blocking 5s. On lock
            // contention the acquisition throws quickly and we fall back gracefully
            // (leave lastRepairActions empty; a later command performs the idempotent
            // repair), so the GUI never blocks on launch.
            try storageLock.withLock(timeout: 0.5) {
                var index = loadIndex()
                // Skip repair for the empty/corrupt fallback index (schemaVersion 0):
                // ensureInitialized()/migration owns that path; repairing here could
                // clobber a corrupt-but-recoverable file.
                guard index.schemaVersion >= 2 else { return }
                var actions: [String] = []
                var changed = false

                let hasDefaultPage = index.pages.contains { $0.id == "default_page" }
                if !hasDefaultPage {
                    let page = SlotPage(id: "default_page", name: "默认页面",
                                        order: (index.pages.map { $0.order }.max() ?? -1) + 1,
                                        createdAt: Date(), updatedAt: Date())
                    index.pages.append(page)
                    if index.currentPageId.isEmpty { index.currentPageId = "default_page" }
                    actions.append("recreated_default_page")
                    changed = true
                }

                if let gi = index.specialSlots.firstIndex(where: { $0.id == "default" }) {
                    // orphan reassign: default group points to a missing page
                    if !index.pages.contains(where: { $0.id == index.specialSlots[gi].pageId }) {
                        index.specialSlots[gi].pageId = "default_page"
                        index.specialSlots[gi].updatedAt = Date()
                        actions.append("reassigned_orphan_default_group")
                        changed = true
                    }
                } else {
                    let existingInPage = index.specialSlots.filter { $0.pageId == "default_page" }
                    let slot = SpecialSlot(id: "default", name: "默认槽位组", icon: "folder",
                                           colorHex: nil, sourceType: .migratedDefault, sourcePath: nil,
                                           pageId: "default_page",
                                           order: (existingInPage.map { $0.order }.max() ?? -1) + 1,
                                           createdAt: Date(), updatedAt: Date())
                    index.specialSlots.append(slot)
                    if index.currentSpecialSlotId.isEmpty { index.currentSpecialSlotId = "default" }
                    actions.append("recreated_default_group")
                    changed = true
                    let dir = specialSlotDirectory(for: "default")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }

                if changed { try saveIndex(index) }
                self.lastRepairActions = actions
            }
        } catch {
            // lock contention etc: leave lastRepairActions empty (no repair reported)
        }
    }

    // MARK: - Index Operations

    public func loadIndex() -> SpecialSlotIndex {
        queue.sync { loadIndexOnQueue() }
    }

    /// P1 (v2.10.51): 无锁内部版——**必须已在 `queue` 上执行**（由 `loadIndex()` 或其它
    /// `queue.sync`/`queue.async` 闭包调用），内部绝不再 `queue.sync`，杜绝 v2.10.40 式重入死锁。
    /// 抽出此版本的目的：让「已持有 queue」的路径（saveIndexOnQueue 的 schema 重读、未来的 repair
    /// 逻辑）能复用同一份读逻辑而不二次进队列。索引读/写现全部收敛到 `queue` 串行执行，
    /// 消除「load 走 queue、save 不走 queue」的队列不一致 data race。
    private func loadIndexOnQueue() -> SpecialSlotIndex {
        do {
                let data = try Data(contentsOf: indexURL)
                let decoded = try decoder.decode(SpecialSlotIndex.self, from: data)
                // P1-4 (v2.10.9): clean successful decode clears the poison flag.
                lastLoadDecodeFailed = false
                return decoded
            } catch {
                // NOTE (round 1 data-loss fix): loadIndex() intentionally does NOT throw.
                // It is called in ~30 places and converting it to `throws` is out of scope
                // for round 1. The risk is that this empty fallback index, once returned,
                // will be persisted by the next `saveIndex` mutation and permanently
                // overwrite the real index.json (losing all groups/pages).
                //
                // Mitigation: if the index file physically exists on disk, this is a real
                // corruption (not a first-run missing file). Before returning the empty
                // fallback, copy the corrupt bytes to a single stable backup so the user's
                // original data can be recovered even after a later save clobbers index.json.
                if FileManager.default.fileExists(atPath: indexURL.path) {
                    // P1-4 (v2.10.9): a physically-present index.json that fails to
                    // decode is a genuine corruption — poison saveIndex so the empty
                    // fallback (or a slot appended to it) cannot overwrite real data.
                    lastLoadDecodeFailed = true
                    let backupURL = indexURL.deletingLastPathComponent()
                        .appendingPathComponent("index.json.corrupt.bak")
                    do {
                        // Overwrite the single backup if it already exists — loadIndex is
                        // called many times, so we must NOT create timestamped duplicates.
                        if FileManager.default.fileExists(atPath: backupURL.path) {
                            try FileManager.default.removeItem(at: backupURL)
                        }
                        try FileManager.default.copyItem(at: indexURL, to: backupURL)
                        NSLog("[ClipSlots] ERROR: index.json failed to decode (\(error)). "
                            + "The corrupt file was backed up to \(backupURL.path) before "
                            + "falling back to an empty index. Recover your data from that backup.")
                    } catch {
                        NSLog("[ClipSlots] ERROR: index.json failed to decode AND the backup "
                            + "to index.json.corrupt.bak failed: \(error). Falling back to empty index.")
                    }
                } else {
                    // File missing = normal first run. Just fall back quietly, no scary log.
                    NSLog("[ClipSlots] index.json not found — treating as first run, creating empty index.")
                }
                // Return a minimal index with schemaVersion=0 so migration is forced.
                // This fallback has NO slots — if saved it would create a clean slate,
                // so the migration code must detect and back up the original file first.
                return SpecialSlotIndex(
                    schemaVersion: 0,
                    version: 1,
                    currentPageId: "",
                    pages: [],
                    currentSpecialSlotId: "default",
                    specialSlots: [],
                    settings: .default
                )
            }
    }

    public func saveIndex(_ index: SpecialSlotIndex) throws {
        // P1 (v2.10.51): 收编到与 loadIndex 相同的串行 `queue`，使索引的读与写全程串行化，
        // 消除「load 走 queue、save 不走 queue」的队列不一致 data race（schema 重读也一并纳入队列）。
        // 实际逻辑放在无锁内部版 saveIndexOnQueue()——任何「已持有 queue」的路径（未来的 repair 逻辑等）
        // 必须调用 saveIndexOnQueue() 而非本方法，否则会二次 queue.sync 触发 v2.10.40 式重入死锁。
        try queue.sync { try saveIndexOnQueue(index) }
    }

    /// P1 (v2.10.51): saveIndex 的无锁内部版——**必须已在 `queue` 上执行**，内部绝不再 `queue.sync`
    /// （否则重入死锁）。把原先在队列外裸执行的「schema 重读 + 原子写盘」整段纳入队列串行区间，
    /// 保证与 `loadIndexOnQueue()` 互斥，读到的现有索引不会是并发写的中间态。
    private func saveIndexOnQueue(_ index: SpecialSlotIndex) throws {
        // P0-1: never let the empty decode-failure fallback (schemaVersion 0, no pages
        // and no slots) overwrite an existing real index.json — that would wipe the
        // whole library. All legitimate save paths persist schemaVersion >= 2.
        if index.schemaVersion < 2, index.pages.isEmpty, index.specialSlots.isEmpty,
           FileManager.default.fileExists(atPath: indexURL.path) {
            NSLog("[ClipSlots] ERROR: refusing to overwrite index.json with empty fallback index; preserving existing data")
            throw SpecialSlotStorageError.refusingToOverwriteWithEmptyIndex
        }
        // P1-4 (v2.10.9): the P0-1 guard above only catches a COMPLETELY empty
        // fallback. loadIndex() returns a schemaVersion=0 fallback on ANY decode
        // failure; a write path that appended one slot to it would slip past the
        // "empty" check and PERMANENTLY overwrite the real (schema>=2) library.
        // Refuse a schema<2 save over an existing index when EITHER the last load
        // hit a decode failure (poison flag), OR the on-disk index is already
        // schema>=2 (a schema downgrade can only be the corrupt fallback).
        if index.schemaVersion < 2, FileManager.default.fileExists(atPath: indexURL.path) {
            if lastLoadDecodeFailed {
                NSLog("[ClipSlots] ERROR: refusing to overwrite index.json (last load decode failed); preserving existing data")
                throw SpecialSlotStorageError.refusingToOverwriteWithEmptyIndex
            }
            if let data = try? Data(contentsOf: indexURL),
               let existing = try? decoder.decode(SpecialSlotIndex.self, from: data),
               existing.schemaVersion >= 2 {
                NSLog("[ClipSlots] ERROR: refusing to downgrade index.json from schemaVersion \(existing.schemaVersion) to \(index.schemaVersion); preserving existing data")
                throw SpecialSlotStorageError.refusingToOverwriteWithEmptyIndex
            }
        }
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    /// A-6 (v2.10.31): escape the read-only "poison" dead state WITHOUT a process restart.
    /// When `loadIndex()` hits a genuine decode failure it sets `lastLoadDecodeFailed = true`,
    /// after which every `saveIndex` is refused (`refusingToOverwriteWithEmptyIndex`) to protect
    /// real data. That flag previously had NO in-memory self-heal path, so the GUI stayed frozen
    /// until relaunch. This method — meant to be wired to a user-confirmed "修复 / 从备份恢复"
    /// entry — clears the flag and rebuilds a usable index:
    ///   1) if `index.json.corrupt.bak` decodes cleanly (schema ≥ 2), restore it as the live index;
    ///   2) otherwise drop the corrupt `index.json` and recreate defaults (the corrupt bytes stay
    ///      in `.corrupt.bak` for manual recovery).
    /// Returns a short action string for logging / UI feedback.
    @discardableResult
    public func forceRepair() -> String {
        var action = "none"
        try? storageLock.withLock {
            let backupURL = indexURL.deletingLastPathComponent()
                .appendingPathComponent("index.json.corrupt.bak")

            // P0-1 (v2.10.32): NEVER run the destructive rebuild on a HEALTHY index.
            // Previously forceRepair() fell through to `removeItem(indexURL)` + recreate-default
            // whenever no decodable `.corrupt.bak` existed — but for a healthy library that is the
            // NORMAL case (no corrupt backup ever gets written), so `repair-index` on a perfectly
            // fine install silently deleted the real index and wiped every user page/group while
            // still returning ok:true. Guard: only enter ANY destructive path when the index is
            // ACTUALLY corrupt, i.e. the poison flag is set OR the current on-disk index.json
            // cannot be decoded into a schema>=2 index right now.
            let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
            var indexIsCorrupt = lastLoadDecodeFailed
            if indexExists, !indexIsCorrupt {
                // P1 (v2.10.51): 腐坏判定的读盘+解码收进 `queue` 串行执行——原先在队列外裸用共享
                // `decoder` 与 loadIndexOnQueue/saveIndexOnQueue 并发访问同一 decoder 是真实 data race；
                // 收进队列后既消除共享解码器竞争，读到的也是与索引读写串行一致的磁盘态。
                let decodesCleanly: Bool = queue.sync {
                    if let data = try? Data(contentsOf: indexURL),
                       let decoded = try? decoder.decode(SpecialSlotIndex.self, from: data),
                       decoded.schemaVersion >= 2 {
                        return true
                    }
                    return false
                }
                indexIsCorrupt = !decodesCleanly
            }
            // Healthy index (file present AND decodes cleanly) → refuse to touch anything.
            // A physically-missing index.json is a legitimate first-run/legacy recovery case
            // and is allowed to fall through to the (non-destructive) recreate path below.
            if indexExists, !indexIsCorrupt {
                action = "index_healthy_no_action"
                NSLog("[ClipSlots] P0-1 forceRepair: index is healthy — no action taken")
                return
            }

            // Clear the poison flag first so the writes below are not refused by saveIndex().
            lastLoadDecodeFailed = false
            // 1) Try restoring a valid backup.
            // P1 (v2.10.51): 备份读取/解码/写回整体收进 `queue` 串行——消除共享 decoder/encoder 的并发
            // 访问，并让恢复写入经无锁内部版 saveIndexOnQueue() 与其它索引读写互斥。restored.schemaVersion
            // >= 2，saveIndexOnQueue 的 schema<2 降级护栏不会触发，等价于原子写回。forceRepair 本身在
            // 队列外（仅持 storageLock），故此处 queue.sync 不会重入死锁。
            let restoredFromBackup: Bool = queue.sync {
                guard let data = try? Data(contentsOf: backupURL),
                      let restored = try? decoder.decode(SpecialSlotIndex.self, from: data),
                      restored.schemaVersion >= 2 else { return false }
                do { try saveIndexOnQueue(restored); return true } catch { return false }
            }
            if restoredFromBackup { action = "restored_from_corrupt_backup" }
            // 2) No usable backup → drop the corrupt index and recreate defaults.
            if action == "none" {
                if FileManager.default.fileExists(atPath: indexURL.path) {
                    // Preserve the corrupt file as the single stable backup if none exists yet.
                    if !FileManager.default.fileExists(atPath: backupURL.path) {
                        try? FileManager.default.copyItem(at: indexURL, to: backupURL)
                    }
                    // P0-1 (v2.10.32): additionally keep a timestamped snapshot so a second
                    // (mis)invocation cannot clobber the first backup, preserving every prior
                    // on-disk index state for manual recovery.
                    let stamp = Int(Date().timeIntervalSince1970)
                    let tsBackup = indexURL.deletingLastPathComponent()
                        .appendingPathComponent("index.json.corrupt.\(stamp).bak")
                    if !FileManager.default.fileExists(atPath: tsBackup.path) {
                        try? FileManager.default.copyItem(at: indexURL, to: tsBackup)
                    }
                    try? FileManager.default.removeItem(at: indexURL)
                }
                migrateLegacySlotsOrCreateDefault()
                action = "recreated_default_index"
            }
        }
        // Drop stale in-memory caches so the next read reflects the repaired index.
        NSLog("[ClipSlots] A-6 forceRepair: \(action)")
        return action
    }

    // MARK: - Auto Mode Cursors (v2.10.0)
    // 写/读游标持久化到磁盘 index.json（不用 UserDefaults），所有写入走跨进程写锁，
    // 与其它 index 变更串行化，避免 GUI/CLI 并发覆盖。

    public func autoStoreCursor() -> SpecialSlotCursor? {
        loadIndex().autoStoreCursor
    }

    public func autoPasteCursor() -> SpecialSlotCursor? {
        loadIndex().autoPasteCursor
    }

    public func setAutoStoreCursor(_ cursor: SpecialSlotCursor?) throws {
        try storageLock.withLock {
            var index = loadIndex()
            index.autoStoreCursor = cursor
            try saveIndex(index)
        }
    }

    public func setAutoPasteCursor(_ cursor: SpecialSlotCursor?) throws {
        try storageLock.withLock {
            var index = loadIndex()
            index.autoPasteCursor = cursor
            try saveIndex(index)
        }
    }

    // v2.10.1: 回退历史（深度 1）访问器。
    public func autoStoreCursorPrev() -> SpecialSlotCursor? {
        loadIndex().autoStoreCursorPrev
    }

    public func autoPasteCursorPrev() -> SpecialSlotCursor? {
        loadIndex().autoPasteCursorPrev
    }

    /// 推进写游标：把当前游标压入 prev（供回退），再写入新落点。原子操作。
    public func advanceAutoStoreCursor(to cursor: SpecialSlotCursor?) throws {
        try storageLock.withLock {
            var index = loadIndex()
            index.autoStoreCursorPrev = index.autoStoreCursor
            index.autoStoreCursor = cursor
            try saveIndex(index)
        }
    }

    /// 推进读游标：把当前游标压入 prev（供回退），再写入新落点。原子操作。
    public func advanceAutoPasteCursor(to cursor: SpecialSlotCursor?) throws {
        try storageLock.withLock {
            var index = loadIndex()
            index.autoPasteCursorPrev = index.autoPasteCursor
            index.autoPasteCursor = cursor
            try saveIndex(index)
        }
    }

    /// 回退写游标一步：cursor ← prev，prev ← nil。返回回退后的游标值。
    @discardableResult
    public func goBackAutoStoreCursor() throws -> SpecialSlotCursor? {
        try storageLock.withLock {
            var index = loadIndex()
            // v2.10.3 (P2): with no back-history, do NOT silently reset to the head —
            // that made "回退" destructively jump the cursor to slot 1. No-op instead.
            guard index.autoStoreCursorPrev != nil else { return index.autoStoreCursor }
            index.autoStoreCursor = index.autoStoreCursorPrev
            index.autoStoreCursorPrev = nil
            try saveIndex(index)
            return index.autoStoreCursor
        }
    }

    /// 回退读游标一步：cursor ← prev，prev ← nil。返回回退后的游标值。
    @discardableResult
    public func goBackAutoPasteCursor() throws -> SpecialSlotCursor? {
        try storageLock.withLock {
            var index = loadIndex()
            // v2.10.3 (P2): same guard — no history means no-op, not a reset.
            guard index.autoPasteCursorPrev != nil else { return index.autoPasteCursor }
            index.autoPasteCursor = index.autoPasteCursorPrev
            index.autoPasteCursorPrev = nil
            try saveIndex(index)
            return index.autoPasteCursor
        }
    }

    /// 重置写游标：cursor 与 prev 均清零，下次从第一个有效槽位开始。
    public func resetAutoStoreCursor() throws {
        try storageLock.withLock {
            var index = loadIndex()
            index.autoStoreCursor = nil
            index.autoStoreCursorPrev = nil
            try saveIndex(index)
        }
    }

    /// 重置读游标：cursor 与 prev 均清零，下次从第一个有效槽位开始。
    public func resetAutoPasteCursor() throws {
        try storageLock.withLock {
            var index = loadIndex()
            index.autoPasteCursor = nil
            index.autoPasteCursorPrev = nil
            try saveIndex(index)
        }
    }

    // MARK: - Current Special Slot

    public func currentSpecialSlot() throws -> SpecialSlot {
        // Fast path: read outside the lock. If the current id still resolves, no
        // write is needed, so an unlocked read is safe (and avoids lock churn on
        // the hot path).
        let snapshot = loadIndex()
        if let current = snapshot.specialSlots.first(where: { $0.id == snapshot.currentSpecialSlotId }) {
            return current
        }
        // Auto-fix path: the current id points at a missing group. This is a
        // read-modify-write and MUST be atomic. P1-2 (v2.10.8): the whole
        // load→decide→save is now performed INSIDE the cross-process lock and
        // re-loads the index under that lock. Previously the snapshot was read
        // OUTSIDE the lock (only the save was locked, v2.10.6 P2-13), so a parallel
        // create-group / switch / write landing between the unlocked read and the
        // locked write would be clobbered by the stale `fixed` snapshot (a silent
        // lost update). currentSpecialSlot() itself holds no lock, so wrapping the
        // reload here does not re-enter/deadlock.
        var result: SpecialSlot?
        try storageLock.withLock {
            var index = loadIndex()
            // Re-check under the lock: a concurrent writer may have already fixed
            // (or legitimately changed) currentSpecialSlotId while we waited.
            if let current = index.specialSlots.first(where: { $0.id == index.currentSpecialSlotId }) {
                result = current
                return
            }
            index.currentSpecialSlotId = index.specialSlots.first?.id ?? "default"
            try saveIndex(index)
            result = index.specialSlots.first
        }
        guard let fallback = result else {
            throw SpecialSlotError.specialSlotNotFound
        }
        return fallback
    }

    public func switchToSpecialSlot(id: String) throws {
        try storageLock.withLock {
            var index = loadIndex()
            guard let slot = index.specialSlots.first(where: { $0.id == id }) else {
                throw SpecialSlotError.specialSlotNotFound
            }
            // v2.4: also switch to the page that owns this slot group
            index.currentPageId = slot.pageId
            index.currentSpecialSlotId = id
            index.selectedSpecialSlotId = id
            index.activeHotkeySpecialSlotId = id
            try saveIndex(index)
        }
    }

    // v2.4.1: cycle through slot groups within the current page
    public func switchToAdjacentSpecialSlot(direction: SlotGroupDirection) throws {
        try storageLock.withLock {
            var index = loadIndex()

            let groupsInPage = index.specialSlots
                .filter { $0.pageId == index.currentPageId }
                .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }

            guard !groupsInPage.isEmpty else {
                throw SpecialSlotError.specialSlotNotFound
            }

            let currentId = index.currentSpecialSlotId
            let currentIdx = groupsInPage.firstIndex(where: { $0.id == currentId })

            let targetIdx: Int
            if let currentIdx = currentIdx {
                switch direction {
                case .previous:
                    targetIdx = currentIdx == 0 ? groupsInPage.count - 1 : currentIdx - 1
                case .next:
                    targetIdx = currentIdx >= groupsInPage.count - 1 ? 0 : currentIdx + 1
                }
            } else {
                // Current not in this page — pick first
                targetIdx = 0
            }

            let target = groupsInPage[targetIdx]
            index.currentSpecialSlotId = target.id
            index.selectedSpecialSlotId = target.id
            index.activeHotkeySpecialSlotId = target.id
            try saveIndex(index)
            NSLog("[ClipSlots] switchToAdjacentSpecialSlot direction=\(direction) to=\(target.id) name=\(target.name)")
        }
    }

    public func updateSelectedSpecialSlot(id: String) {
        // ST-4 (v2.10.15): this previously used `try? storageLock.withLock { ... }`
        // and dropped any lock timeout on the floor — under fast group switching the
        // persist could be silently skipped, so the selected item was lost on restart
        // with no trace. Surface the failure via NSLog (do NOT silently swallow), and
        // let the inner saveIndex error propagate to the same handler.
        do {
            try storageLock.withLock {
                var index = loadIndex()
                guard index.specialSlots.contains(where: { $0.id == id }) else { return }
                index.selectedSpecialSlotId = id
                index.currentSpecialSlotId = id
                try saveIndex(index)
            }
        } catch {
            NSLog("[ClipSlots] updateSelectedSpecialSlot(id=\(id)) failed to persist: \(error). "
                + "Selected slot may not survive restart.")
        }
    }

    public func updateActiveHotkeySpecialSlot(id: String) throws {
        try storageLock.withLock {
            var index = loadIndex()
            guard index.specialSlots.contains(where: { $0.id == id }) else {
                throw SpecialSlotError.specialSlotNotFound
            }
            index.activeHotkeySpecialSlotId = id
            try saveIndex(index)
        }
    }

    // MARK: - CRUD Special Slots

    public func createSpecialSlot(
        name: String,
        pageId: String? = nil,
        sourceType: SpecialSlotSourceType = .manual,
        sourcePath: String? = nil,
        requestedAt: Date = Date()
    ) throws -> SpecialSlot {
        try storageLock.withLock {
            var index = loadIndex()

            // v2.4.1: per-page limit instead of global limit
            let targetPageId = pageId ?? index.currentPageId
            let existingInPage = index.specialSlots.filter { $0.pageId == targetPageId }

            guard existingInPage.count < index.settings.maxSpecialSlots else {
                throw SpecialSlotError.maxSpecialSlotsReached
            }

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw SpecialSlotError.invalidSpecialSlotName
            }

            // v2.9.4 (Feature #4): reject a duplicate (trimmed) name WITHIN the same
            // target page (mirrors createPage's duplicate guard). A group name may
            // still repeat across DIFFERENT pages — only same-page collisions fail.
            let finalName = String(trimmed.prefix(30))
            guard !existingInPage.contains(where: { $0.name == finalName }) else {
                throw SpecialSlotError.duplicateName
            }

            // v2.9.41 (Problem A): assign order by REQUEST-RECEIPT time, not by
            // lock-acquisition (write-completion) time. Parallel `create-group`
            // processes serialize on the cross-process lock in a non-deterministic
            // order, so a blind `maxOrder + 1` append records "who won the lock"
            // rather than "who was invoked first". Instead we place the new group
            // BEFORE any existing group that was requested strictly later than us
            // (only siblings that also carry a `requestedAt` participate — legacy
            // groups without one are never reordered), then shift the trailing
            // orders up by one. This keeps issue order stable regardless of the
            // lock race, without renumbering / disturbing pre-existing groups.
            let laterOrders = existingInPage
                .compactMap { g -> Int? in
                    guard let r = g.requestedAt, r > requestedAt else { return nil }
                    return g.order
                }
            let insertOrder: Int
            if let minLater = laterOrders.min() {
                insertOrder = minLater
                for i in index.specialSlots.indices
                where index.specialSlots[i].pageId == targetPageId
                    && index.specialSlots[i].order >= insertOrder {
                    index.specialSlots[i].order += 1
                }
            } else {
                let maxOrder = existingInPage.map { $0.order }.max() ?? (-1)
                insertOrder = maxOrder + 1
            }

            let slot = SpecialSlot(
                id: "special_\(UUID().uuidString)",
                name: finalName,
                icon: "folder",
                colorHex: nil,
                sourceType: sourceType,
                sourcePath: sourcePath,
                pageId: targetPageId,
                order: insertOrder,
                requestedAt: requestedAt,
                createdAt: Date(),
                updatedAt: Date()
            )

            let dir = specialSlotDirectory(for: slot.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            index.specialSlots.append(slot)
            try saveIndex(index)

            return slot
        }
    }

    public func deleteSpecialSlot(id: String) throws {
        try storageLock.withLock {
            // F6 (契约5): default group is protected at the Kit layer too (双保险).
            if id == "default" { throw SpecialSlotError.defaultGroupProtected }
            var index = loadIndex()

            guard let targetSlot = index.specialSlots.first(where: { $0.id == id }) else {
                throw SpecialSlotError.specialSlotNotFound
            }

            // v2.4.1: check per-page — cannot delete the last slot group in its page
            let groupsInSamePage = index.specialSlots.filter { $0.pageId == targetSlot.pageId }
            guard groupsInSamePage.count > 1 else {
                throw SpecialSlotError.cannotDeleteLastSpecialSlot
            }

            // P2-3 (v2.10.16): 先更新并持久化索引（新索引不再引用该组），saveIndex 成功后再把
            // 数据目录移入 .trash。旧顺序是「先移目录再 saveIndex」，一旦 saveIndex 写盘失败（磁盘满/
            // IO 错误），目录已移走而索引仍指向它 → 悬挂索引项/孤儿数据。反转顺序后 saveIndex 抛错会在
            // 目录被移动前就 throw 退出（withLock 内、无副作用），数据保持一致。
            // Update index — use page-scoped fallback
            index.specialSlots.removeAll { $0.id == id }

            let fallbackInPage = index.specialSlots
                .filter { $0.pageId == targetSlot.pageId }
                .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
                .first
            let fallbackId = fallbackInPage?.id ?? index.specialSlots.first?.id ?? "default"

            if index.currentSpecialSlotId == id {
                index.currentSpecialSlotId = fallbackId
            }
            if index.selectedSpecialSlotId == id {
                index.selectedSpecialSlotId = fallbackId
            }
            if index.activeHotkeySpecialSlotId == id {
                index.activeHotkeySpecialSlotId = fallbackId
            }

            // P2-12 (v2.10.6): 删除组时一并清理指向该组的自动存储/自动粘贴读写游标及其
            // Prev 历史，避免留下悬空游标（遍历层虽能兜底不崩，但会丢失续传语义，且残留
            // Prev 会让「回退」还原到已不存在的组）。命中被删组即重置为 nil（下次从头开始）。
            if index.autoStoreCursor?.groupId == id { index.autoStoreCursor = nil }
            if index.autoStoreCursorPrev?.groupId == id { index.autoStoreCursorPrev = nil }
            if index.autoPasteCursor?.groupId == id { index.autoPasteCursor = nil }
            if index.autoPasteCursorPrev?.groupId == id { index.autoPasteCursorPrev = nil }

            try saveIndex(index)

            // P2-3 (v2.10.16): 索引已成功持久化，再把该组数据目录移入 .trash（软删除，可 30 天内恢复）。
            // 即使这一步失败，索引也已自洽（不再引用该组），只会残留一个可被后续 cleanup/覆盖处理的目录。
            let dir = specialSlotDirectory(for: id)
            let trashDir = baseDir.appendingPathComponent(".trash")
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let trashTarget = trashDir.appendingPathComponent("deleted_\(id)_\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: dir, to: trashTarget)

            // P2-3 (v2.10.9): evict this group's cached SlotStorage and notify the
            // GUI to clean up its connection cache for the deleted group.
            evictStorageCacheAndNotifyGroupDeletion(groupId: id)

            // v2.9.5 (Feature #1): prune old trash after adding a fresh entry so
            // repeated deletes cannot let `.trash` grow without bound.
            cleanupTrash()
        }
    }

    public func renameSpecialSlot(id: String, name: String) throws {
        try storageLock.withLock {
            var index = loadIndex()

            guard let idx = index.specialSlots.firstIndex(where: { $0.id == id }) else {
                throw SpecialSlotError.specialSlotNotFound
            }

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw SpecialSlotError.invalidSpecialSlotName
            }

            // v2.9.42: reject a rename that would collide with another group on
            // the SAME page (self-rename to the identical name is a no-op and is
            // allowed). Mirrors the page-scoped duplicate rule enforced by
            // createSpecialSlot, so group names stay unique within a page.
            let pageId = index.specialSlots[idx].pageId
            let clipped = String(trimmed.prefix(30))
            guard !index.specialSlots.contains(where: {
                $0.id != id && $0.pageId == pageId && $0.name == clipped
            }) else {
                throw SpecialSlotError.duplicateName
            }

            index.specialSlots[idx].name = clipped
            index.specialSlots[idx].updatedAt = Date()

            try saveIndex(index)
        }
    }

    // MARK: - Page CRUD (v2.4)

    /// Result of `createPage`: the new page plus its synchronously-created
    /// default slot group (nil only when `withDefaultGroup` is false).
    public struct CreatePageResult {
        public let page: SlotPage
        public let defaultGroup: SpecialSlot?
        public init(page: SlotPage, defaultGroup: SpecialSlot?) {
            self.page = page
            self.defaultGroup = defaultGroup
        }
    }

    /// Create a page and, by default, synchronously create its default slot
    /// group inside the same lock/transaction.
    ///
    /// v2.9.33: previously a page was created empty and its default group was
    /// only materialized lazily (by `repairPageScopedConsistency` on the next
    /// load, or by `switchToPage`). That lazy backfill created a timing hole:
    /// a `create-page` CLI call could return before any group existed, so a
    /// follow-up `groups` query might see none and callers could wrongly create
    /// an extra group. Building the group synchronously here — and returning it
    /// in `CreatePageResult.defaultGroup` — closes that gap so callers can use
    /// the id immediately without a second query.
    @discardableResult
    public func createPage(name: String, withDefaultGroup: Bool = true, defaultGroupName: String? = nil) throws -> CreatePageResult {
        try storageLock.withLock {
            var index = loadIndex()

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PageError.emptyName
            }

            // P2 (v2.10.13): 去重比较改用「截断后」的名字（与实际存储口径一致——下方按
            // prefix(30) 截断落盘）。此前用未截断的 trimmed 比较，两个仅在第 30 字符之后
            // 不同的长名会通过去重检查、却截断成同一存储名，导致页内出现重复显示名。
            let clipped = String(trimmed.prefix(30))
            // Check for duplicate name
            guard !index.pages.contains(where: { $0.name == clipped }) else {
                throw PageError.duplicateName
            }

            let maxOrder = index.pages.map { $0.order }.max() ?? (-1)
            let page = SlotPage(
                id: "page_\(UUID().uuidString)",
                name: clipped,
                order: maxOrder + 1,
                createdAt: Date(),
                updatedAt: Date()
            )

            index.pages.append(page)

            var defaultGroup: SpecialSlot? = nil
            if withDefaultGroup {
                // v2.9.43: create the default group with its final name in the SAME
                // transaction. Previously `create-page --group-name` created a group
                // literally named "默认槽位组" and then issued a SECOND rename write.
                // That intermediate state (a page carrying "默认槽位组") could be
                // observed by the running GUI (separate process; storageLock is
                // in-process only), and a GUI self-write racing between the two CLI
                // writes could resurrect/duplicate the default group — leaving both
                // "默认槽位组" and the intended group on the page. Naming the group
                // correctly up front means it is NEVER called "默认槽位组", removing
                // the race window entirely.
                let resolvedGroupName: String = {
                    guard let raw = defaultGroupName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else {
                        return "默认槽位组"
                    }
                    return String(raw.prefix(30))
                }()
                let group = SpecialSlot(
                    id: "special_\(UUID().uuidString)",
                    name: resolvedGroupName,
                    icon: "folder",
                    colorHex: nil,
                    sourceType: .manual,
                    sourcePath: nil,
                    pageId: page.id,
                    order: 0,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                let dir = specialSlotDirectory(for: group.id)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                index.specialSlots.append(group)
                defaultGroup = group
            }

            try saveIndex(index)
            NSLog("[ClipSlots] Page created: \(page.name)\(defaultGroup != nil ? " (+ default group)" : "")")
            return CreatePageResult(page: page, defaultGroup: defaultGroup)
        }
    }

    public func renamePage(id: String, name: String) throws {
        try storageLock.withLock {
            var index = loadIndex()
            guard let idx = index.pages.firstIndex(where: { $0.id == id }) else {
                throw PageError.pageNotFound
            }

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PageError.emptyName
            }
            // P2 (v2.10.13): 去重比较使用「截断后」名，与存储口径（prefix(30)）一致，
            // 避免两个超长名截断后同名却绕过去重（与 createPage 对齐）。
            let clipped = String(trimmed.prefix(30))
            guard !index.pages.contains(where: { $0.id != id && $0.name == clipped }) else {
                throw PageError.duplicateName
            }

            index.pages[idx].name = clipped
            index.pages[idx].updatedAt = Date()
            try saveIndex(index)
            NSLog("[ClipSlots] Page renamed to: \(clipped)")
        }
    }

    public func deletePage(id: String) throws {
        try storageLock.withLock {
            // F6 (契约5): default page is protected at the Kit layer too (双保险).
            if id == "default_page" { throw PageError.defaultPageProtected }
            var index = loadIndex()

            guard index.pages.count > 1 else {
                throw PageError.cannotDeleteLastPage
            }
            guard index.pages.contains(where: { $0.id == id }) else {
                throw PageError.pageNotFound
            }

            // v2.4.1: truly delete the page's slot groups (move data to .trash)
            // P2-3 (v2.10.16): 仅先做索引层移除，真正的目录移动推迟到 saveIndex 成功之后，
            // 避免「目录已移走但索引写盘失败」造成孤儿数据 / 悬挂索引。
            let groupsInPage = index.specialSlots.filter { $0.pageId == id }
            if !groupsInPage.isEmpty {
                index.specialSlots.removeAll { $0.pageId == id }
            }

            // If deleting current page, switch to another
            if index.currentPageId == id {
                index.currentPageId = index.pages.first(where: { $0.id != id })?.id ?? "default_page"
            }

            index.pages.removeAll { $0.id == id }

            // v2.9.41 (Problem B): re-point the slot-group selection pointers to a
            // valid group on the (possibly new) current page BEFORE saving. Deleting
            // a page removes its groups, so currentSpecialSlotId / selectedSpecialSlotId
            // / activeHotkeySpecialSlotId could otherwise be left dangling — which is
            // exactly the inconsistency that made a subsequent command's init-time
            // repair fire a "repair event". Fixing it here, inside the delete
            // transaction, keeps the on-disk state self-consistent so no later repair
            // is needed. Mirrors the post-conditions checked by repair (steps 5/6).
            let currentPageGroups = index.specialSlots
                .filter { $0.pageId == index.currentPageId }
                .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
            if !currentPageGroups.contains(where: { $0.id == index.currentSpecialSlotId }) {
                index.currentSpecialSlotId = currentPageGroups.first?.id
                    ?? index.specialSlots.first?.id ?? "default"
            }
            if let selectedId = index.selectedSpecialSlotId,
               !currentPageGroups.contains(where: { $0.id == selectedId }) {
                index.selectedSpecialSlotId = index.currentSpecialSlotId
            }
            if let activeId = index.activeHotkeySpecialSlotId,
               !currentPageGroups.contains(where: { $0.id == activeId }) {
                index.activeHotkeySpecialSlotId = index.currentSpecialSlotId
            }

            // P2-12 (v2.10.6): 删页会连带删除该页下所有组，需一并清理指向这些被删组的
            // 自动存储/自动粘贴读写游标及其 Prev 历史，避免悬空游标丢失续传语义、以及
            // 残留 Prev 让「回退」还原到已不存在的组。命中即重置为 nil（下次从头开始）。
            let deletedGroupIds = Set(groupsInPage.map { $0.id })
            if let c = index.autoStoreCursor, deletedGroupIds.contains(c.groupId) { index.autoStoreCursor = nil }
            if let c = index.autoStoreCursorPrev, deletedGroupIds.contains(c.groupId) { index.autoStoreCursorPrev = nil }
            if let c = index.autoPasteCursor, deletedGroupIds.contains(c.groupId) { index.autoPasteCursor = nil }
            if let c = index.autoPasteCursorPrev, deletedGroupIds.contains(c.groupId) { index.autoPasteCursorPrev = nil }

            try saveIndex(index)
            NSLog("[ClipSlots] Page deleted: \(id)")

            // P2-3 (v2.10.16): 索引已成功持久化，再把被删各组的数据目录移入 .trash（软删除，可恢复）。
            // 放到 saveIndex 之后，保证「目录移动」永远发生在索引一致之后，写盘失败时不会产生孤儿数据。
            if !groupsInPage.isEmpty {
                let trashDir = baseDir.appendingPathComponent(".trash")
                try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
                for group in groupsInPage {
                    let dir = specialSlotDirectory(for: group.id)
                    let trashTarget = trashDir.appendingPathComponent("page_deleted_\(group.id)_\(Int(Date().timeIntervalSince1970))")
                    try? FileManager.default.moveItem(at: dir, to: trashTarget)
                }
                NSLog("[ClipSlots] Page delete: \(groupsInPage.count) slot groups moved to .trash")
            }

            // P2-3 (v2.10.9): evict each deleted group's cached SlotStorage and
            // notify the GUI to purge connection state for every removed group.
            for group in groupsInPage {
                evictStorageCacheAndNotifyGroupDeletion(groupId: group.id)
            }

            // v2.9.5 (Feature #1): prune old trash after page delete too.
            cleanupTrash()
        }
    }

    public func switchToPage(id: String) throws {
        try storageLock.withLock {
            var index = loadIndex()
            guard index.pages.contains(where: { $0.id == id }) else {
                throw PageError.pageNotFound
            }

            index.currentPageId = id

            // Switch to the first slot group in this page.
            // v2.9.44: REMOVED the `else` branch that auto-created a "默认槽位组"
            // when no groups were found. That backfill was the true source of the
            // "extra default group" bug: `create-page --group-name` already creates
            // the first group atomically with the correct name, but if the GUI
            // called switchToPage in the brief window before the CLI write was
            // flushed (or immediately after, with a stale read), `groupsInPage`
            // could transiently appear empty and this branch would silently inject
            // a second "默认槽位组". Removing the branch is safe because:
            //   1. `createPage` always creates a group synchronously (since v2.9.33),
            //      so a page with zero groups should never exist in normal operation.
            //   2. If a page genuinely has no groups (corrupt data), leaving the
            //      selection pointers nil is far less harmful than injecting a
            //      phantom group — the UI can handle nil selection gracefully.
            let groupsInPage = index.specialSlots.filter { $0.pageId == id }
            if let firstGroup = groupsInPage.sorted(by: { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }).first {
                index.currentSpecialSlotId = firstGroup.id
                index.selectedSpecialSlotId = firstGroup.id
                index.activeHotkeySpecialSlotId = firstGroup.id
            }
            // No else: do NOT auto-create "默认槽位组" here. See comment above.

            try saveIndex(index)
            NSLog("[ClipSlots] Switched to page: \(id)")
        }
    }

    // MARK: - Child Slot Operations

    private var storageCache: [String: SlotStorage] = [:]
    /// v2.10.3 (P0 fix): in-process lock guarding `storageCache`. `slotStorage(for:)`
    /// is entered concurrently by the main-thread UI, the FSEvents watcher callback,
    /// and CLI-triggered tasks; Swift `Dictionary` is not thread-safe, so unguarded
    /// reads/writes could randomly crash or corrupt the cache. This is distinct from
    /// the cross-process `storageLock` (flock) — here we need an intra-process thread lock.
    private let storageCacheLock = NSLock()

    public func slotStorage(for specialSlotId: String) -> SlotStorage {
        storageCacheLock.lock()
        defer { storageCacheLock.unlock() }
        if let cached = storageCache[specialSlotId] {
            return cached
        }
        let dir = specialSlotDirectory(for: specialSlotId)
        let storage = SlotStorage(slotsDir: dir)
        storageCache[specialSlotId] = storage
        return storage
    }

    /// P2-3 (v2.10.9): on group/page delete, evict the per-group SlotStorage from
    /// `storageCache` (group IDs are UUIDs and never reused, so a retained entry
    /// leaks memory for the process lifetime) and notify listeners to purge stale
    /// connection state. SlotConnectionStorage lives in the GUI target and CANNOT
    /// be imported from ClipSlotsKit, so cross-module signalling is done via
    /// NotificationCenter; the GUI observer performs the actual connection cleanup.
    private func evictStorageCacheAndNotifyGroupDeletion(groupId: String) {
        storageCacheLock.lock()
        let evicted = storageCache.removeValue(forKey: groupId)
        storageCacheLock.unlock()
        // DS-3 / CR-3 (v2.10.30): evicting from the cache only stops NEW lookups from
        // reusing this instance; it does nothing about references already captured by the
        // UI / watcher / an in-flight task before the delete. Mark the evicted instance
        // invalidated so any such lingering reference refuses future writes and can never
        // physically recreate the deleted group's slot directory (phantom-group resurrection).
        evicted?.invalidate()
        NotificationCenter.default.post(
            name: Notification.Name("ClipSlotsSpecialSlotGroupDeleted"),
            object: nil,
            userInfo: ["groupId": groupId])
    }

    // MARK: Explicit API — all callers must pass specialSlotId

    public func get(_ slot: Int, in specialSlotId: String) -> SlotContent {
        slotStorage(for: specialSlotId).get(slot)
    }

    /// P1-01 (v2.10.45): UNKNOWN-aware variant of `get(_:in:)`. Returns nil ONLY in the
    /// degraded UNKNOWN state (cross-process lock busy AND slot never cached). Read-modify-write
    /// callers that carry over attachments MUST use this and abort the write on nil rather than
    /// overwrite the disk with an empty placeholder (which drops externalized `.bin` bytes).
    public func getOrUnknown(_ slot: Int, in specialSlotId: String) -> SlotContent? {
        slotStorage(for: specialSlotId).getOrUnknown(slot)
    }

    /// PERF (switch lag): cheap emptiness probe that avoids loading a slot's full payload.
    /// Prefer this over `get(_:in:).isEmpty` on hot paths (auto-mode cursor previews,
    /// auto-advance scans) where only emptiness — not the content — is needed.
    public func isEmpty(_ slot: Int, in specialSlotId: String) -> Bool {
        slotStorage(for: specialSlotId).isSlotEmpty(slot)
    }

    @discardableResult
    public func set(_ slot: Int, content: SlotContent, in specialSlotId: String) -> Bool {
        var content = content
        content.timestamp = Date()
        // P2-14 (v2.10.6): 内容写入本身此前不持跨进程锁，仅随后的 touchSpecialSlot 持锁，
        // GUI 自动存储与 CLI 同时写同一槽位时 SlotStorage 层的删除重建可能交错。此处把
        // 内容写入与索引 touch 一并纳入同一 storageLock.withLock 保护。set() 本身未持锁，
        // 且 touch 逻辑已内联到本作用域（不再调用 touchSpecialSlot），故不会重入死锁。
        // P2-4 (v2.10.16): 超时不再用 `try?` 静默吞掉。对齐 ST-4，超时路径记日志并向调用方返回
        // false（失败态），让 GUI/CLI 能感知「存储繁忙」而非误以为写入成功。
        // P1-C (v2.10.18): 覆盖前备份（整目录快照）移回 storageLock 临界区执行——v2.10.17 移出锁
        // 曾为了规避 I/O 阻塞，但导致了并发下的快照撕裂风险。改为锁内执行以确保原子性。
        do {
            return try storageLock.withLock {
                // STG-2 (v2.10.32): validate the target group is still in the index INSIDE the lock
                // before writing. A caller holding only a groupId string (e.g. CLI resolveGroup that
                // resolved the id before entering the lock — TOCTOU) could otherwise write to a group
                // that was concurrently deleted, causing slotStorage(for:) to build a fresh
                // (non-invalidated) instance and re-materialize special_slots/<deletedId>/ as an
                // orphan/phantom directory not referenced by any index. Reject the write instead.
                guard loadIndex().specialSlots.contains(where: { $0.id == specialSlotId }) else {
                    NSLog("[ClipSlots] STG-2: refusing set() to group '\(specialSlotId)' not present in index (deleted/ghost); write skipped")
                    return false
                }
                backupSlotBeforeOverwriteIfNeeded(slot: slot, in: specialSlotId)
                let result = slotStorage(for: specialSlotId).set(slot, content: content)
                if result {
                    var index = loadIndex()
                    if let idx = index.specialSlots.firstIndex(where: { $0.id == specialSlotId }) {
                        index.specialSlots[idx].updatedAt = Date()
                        try? saveIndex(index)
                    }
                }
                return result
            }
        } catch {
            NSLog("[ClipSlots] set(slot:\(slot) in:\(specialSlotId)) 获取存储锁失败，写入未执行：\(error.localizedDescription)")
            return false
        }
    }

    /// P1-C (v2.10.18): 覆盖写入前，把被覆盖槽位的「非空」旧内容整目录快照进 .trash，使覆盖写入也拥有
    /// 30 天回滚窗口（对齐 delete 的软删除），防止 AI 批量 write 时旧内容被永久覆盖。
    ///
    /// 相比 v2.10.17，本版本将备份操作移回了 storageLock 临界区，解决了并发写下备份撕裂或丢失的 P1。
    /// 依然保留毫秒精度去重逻辑，确保同秒内多次覆盖均有独立备份。
    ///
    /// 磁盘布局：单个槽位就是一个独立目录 baseDir/<specialSlotId>/<slot>/（含主体 + 全部附件），
    /// 整目录一次 copyItem 即可涵盖主体与附件。备份失败仅 NSLog、不阻断写入成功。
    private func backupSlotBeforeOverwriteIfNeeded(slot: Int, in specialSlotId: String) {
        backupSlotDirToTrash(slot: slot, in: specialSlotId, namePrefix: "slot_overwritten")
    }

    /// P1-1 / P1-3 (v2.10.34): 把指定槽位的「非空」旧内容整目录快照进 .trash，供【覆盖写】与【单槽
    /// clear】复用，使二者都拥有 30 天回滚窗口（对齐 delete 的软删除）。`namePrefix` 决定回收站条目
    /// 前缀（覆盖→`slot_overwritten`，清空→`slot_cleared`）；末段为 Double 秒时间戳，供 trashEntryDate()
    /// 统一识别与清理。必须在 storageLock 临界区内调用。备份失败仅 NSLog、不阻断调用方的破坏性操作。
    ///
    /// P1-3 (v2.10.34): 判空改用轻量 `SlotStorage.isSlotEmpty()`（只 stat / 枚举目录，不读 blob），不再
    /// 用 `get()` 把该槽所有 item_*/*.bin 与内联 base64 附件全量 Data(contentsOf:) 读进内存——后者仅为
    /// 拿一个 isEmpty 布尔，却对含大图 / 大内联附件的槽位每次覆盖 / 清空都产生一次与负载等大的瞬时
    /// 分配，批量覆盖大图时叠加内存尖峰。真正的备份是对【目录】做 cloneOrCopyItem，本不需要内容字节。
    private func backupSlotDirToTrash(slot: Int, in specialSlotId: String, namePrefix: String) {
        // 仅备份非空槽位（空槽不产生备份，避免污染回收站）。
        guard !slotStorage(for: specialSlotId).isSlotEmpty(slot) else { return }
        let slotDir = specialSlotDirectory(for: specialSlotId)
            .appendingPathComponent(String(slot))
        guard FileManager.default.fileExists(atPath: slotDir.path) else { return }
        let trashDir = baseDir.appendingPathComponent(".trash")
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        // 命名 <prefix>_<specialSlotId>_<slot>_<秒.毫秒>：时间戳位于末段，与既有
        // deleted_<id>_<ts> / page_deleted_<id>_<ts> / slot_overwritten_<...> 命名风格一致，
        // 且末段为 Double 可被 trashEntryDate() 识别。
        var ts = Date().timeIntervalSince1970
        func target(_ ts: TimeInterval) -> URL {
            trashDir.appendingPathComponent(
                "\(namePrefix)_\(specialSlotId)_\(slot)_\(String(format: "%.3f", ts))")
        }
        var trashTarget = target(ts)
        while FileManager.default.fileExists(atPath: trashTarget.path) {
            ts += 0.001   // 同毫秒碰撞：递增 1ms 直至路径空闲，保证唯一且时间戳仍准确可解析。
            trashTarget = target(ts)
        }
        // A-5 (v2.10.31): use clonefile(2) copy-on-write instead of a physical copyItem.
        // The backup runs INSIDE the cross-process storageLock; a physical copy of a slot
        // holding a large file (hundreds of MB) blocked GUI/CLI/FSEvents for seconds on
        // every overwrite. `cloneOrCopyItem` clones in constant time on APFS and only falls
        // back to copyItem on filesystems without clone support.
        guard cloneOrCopyItem(at: slotDir, to: trashTarget) else {
            NSLog("[ClipSlots] 备份槽位旧内容到 .trash 失败（不阻断操作）"
                + " prefix=\(namePrefix) slot=\(slot) group=\(specialSlotId)")
            return
        }
        // P1-C: 备份路径上也适时触发一次清理，避免 GUI 长会话「只写不删」时 .trash 无界堆积到
        // 下一次删组/删页/启动才收敛。放到后台队列执行，不拖慢写入热路径。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupTrash()
        }
    }

    @discardableResult
    public func clear(_ slot: Int, in specialSlotId: String) -> Bool {
        // P2-4 (v2.10.9): perform the content clear AND the index touch inside a
        // SINGLE withLock (mirroring set() in v2.10.8) so updatedAt and content can
        // never briefly disagree across an interleaving window. The touch is inlined
        // here (not via touchSpecialSlot) to keep both mutations in one lock scope.
        //
        // P2-4 (v2.10.16): 锁超时不再用 `try?` 静默吞掉——对齐 ST-4，超时记日志并返回 false，
        // 让调用方（GUI/CLI）能感知「清空」未生效，而非误以为成功。
        do {
            return try storageLock.withLock { () -> Bool in
                // STG-2 / P1-5 (v2.10.34): reject clear() on a group no longer in the index (deleted/ghost).
                // 此前只从闭包 return（Void），函数体随后仍无条件返回 true —— 被并发删除的 ghost 组上
                // clear 实际什么都没做却回报成功，与 set() 的 `return false` 语义不一致，会误导 CLI/AI。
                // 现让闭包返回 Bool，命中 ghost 组返回 false，如实反馈「未生效」。
                guard loadIndex().specialSlots.contains(where: { $0.id == specialSlotId }) else {
                    NSLog("[ClipSlots] STG-2: refusing clear() on group '\(specialSlotId)' not present in index (deleted/ghost); skipped")
                    return false
                }
                // P1-1 (v2.10.34): 单槽 clear 也接入 .trash 软删除备份（清空前对非空槽整目录快照进 .trash）。
                // `clip clear <slot>` 是无二次确认、AI 可直接调用的破坏性命令，此前是唯一未接入任何软删除
                // 的破坏性路径（覆盖写 / 清空整组 / 删组 / 删页均已备份），属契约违背式的永久丢失。补齐后
                // 拥有与它们一致的 30 天回滚窗口。备份失败仅 NSLog、不阻断清空。
                backupSlotDirToTrash(slot: slot, in: specialSlotId, namePrefix: "slot_cleared")
                slotStorage(for: specialSlotId).clear(slot)
                var index = loadIndex()
                if let idx = index.specialSlots.firstIndex(where: { $0.id == specialSlotId }) {
                    index.specialSlots[idx].updatedAt = Date()
                    try? saveIndex(index)
                }
                return true
            }
        } catch {
            NSLog("[ClipSlots] clear(slot:\(slot) in:\(specialSlotId)) 获取存储锁失败，清空未执行：\(error.localizedDescription)")
            return false
        }
    }

    public func clearAllSlots(in specialSlotId: String) throws {
        // P2-4 (v2.10.9): content wipe + index touch in ONE withLock (see clear()).
        try storageLock.withLock {
            // STG-2 (v2.10.66): mirror the guard already present in set()/clear()/setLabel().
            // clearAllSlots was the sole destructive entry lacking it. A caller (e.g. overwrite
            // import / "clear whole group") holding a groupId that was concurrently deleted by
            // another process (CLI delete-group) would otherwise fall through to
            // slotStorage(for:).clearAll(), whose non-invalidated instance recreates
            // special_slots/<deletedId>/ as an orphan/phantom directory not referenced by any
            // index — the exact "phantom group revival" the STG-2 invariant forbids. Reject it.
            guard loadIndex().specialSlots.contains(where: { $0.id == specialSlotId }) else {
                NSLog("[ClipSlots] STG-2: refusing clearAllSlots() on group '\(specialSlotId)' not present in index (deleted/ghost); skipped")
                return
            }
            // PK-1 (v2.10.30): overwrite-import and "clear whole group" previously routed
            // straight to SlotStorage.clearAll(), which physically removes the group's slot
            // directory with NO .trash backup — an unrecoverable data loss (e.g. importing a
            // .clipslotspack in overwrite mode wiped the entire target group forever). Snapshot
            // the whole group directory into .trash first (soft delete, 30-day recovery),
            // matching delete-group / overwrite-write semantics. Failure only logs; it does not
            // block the wipe (the wipe is what the caller asked for).
            backupGroupBeforeClearIfNeeded(specialSlotId: specialSlotId)
            // A-3 (v2.10.31): the group was just snapshotted above, so tell the low-level wipe
            // to skip its own (now defensive-only) `.trash` snapshot and avoid a duplicate entry.
            try slotStorage(for: specialSlotId).clearAll(backupToTrash: false)
            var index = loadIndex()
            if let idx = index.specialSlots.firstIndex(where: { $0.id == specialSlotId }) {
                index.specialSlots[idx].updatedAt = Date()
                try? saveIndex(index)
            }
        }
    }

    /// PK-1 (v2.10.30): snapshot an entire slot group's data directory into `.trash` before a
    /// destructive clearAll (overwrite import / clear-all-slots). Mirrors
    /// `backupSlotBeforeOverwriteIfNeeded` but at group granularity. Only backs up a group that
    /// actually has slot data on disk (skips empty groups to avoid polluting `.trash`). Must be
    /// called INSIDE `storageLock.withLock` so the snapshot is atomic w.r.t. concurrent writes.
    private func backupGroupBeforeClearIfNeeded(specialSlotId: String) {
        let groupDir = specialSlotDirectory(for: specialSlotId)
        guard FileManager.default.fileExists(atPath: groupDir.path) else { return }
        // Only back up if the group has at least one numeric slot dir (real content); a bare /
        // freshly-created group dir is not worth a .trash entry.
        let hasSlotData = (try? FileManager.default.contentsOfDirectory(
            at: groupDir, includingPropertiesForKeys: nil))?
            .contains(where: { Int($0.lastPathComponent) != nil }) ?? false
        guard hasSlotData else { return }
        let trashDir = baseDir.appendingPathComponent(".trash")
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        // 命名 group_cleared_<specialSlotId>_<秒.毫秒>：末段为 Double 时间戳，可被 trashEntryDate() 识别、
        // 参与统一的保留期/条数清理。
        var ts = Date().timeIntervalSince1970
        func target(_ ts: TimeInterval) -> URL {
            trashDir.appendingPathComponent(
                "group_cleared_\(specialSlotId)_\(String(format: "%.3f", ts))")
        }
        var trashTarget = target(ts)
        while FileManager.default.fileExists(atPath: trashTarget.path) {
            ts += 0.001
            trashTarget = target(ts)
        }
        do {
            // A-2 (v2.10.31): clonefile(2) copy-on-write instead of physical copyItem — this
            // runs inside storageLock and a big group (e.g. 500MB) previously blocked all other
            // processes for seconds. Clone keeps the group dir in place (so SlotStorage.clearAll's
            // remove/recreate is unaffected) yet completes in constant time on APFS.
            guard cloneOrCopyItem(at: groupDir, to: trashTarget) else {
                NSLog("[ClipSlots] PK-1: 清空整组前备份到 .trash 失败（不阻断清空）group=\(specialSlotId)")
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.cleanupTrash()
            }
        }
    }

    public func getLabel(_ slot: Int, in specialSlotId: String) -> String? {
        slotStorage(for: specialSlotId).getLabel(slot)
    }

    @discardableResult
    public func setLabel(_ slot: Int, label: String?, in specialSlotId: String) -> Bool {
        // P2-4 (v2.10.9): label write + index touch in ONE withLock (see clear()).
        // P2-4 (v2.10.16): 锁超时不再用 `try?` 静默吞掉——超时记日志并返回 false（对齐 ST-4）。
        do {
            try storageLock.withLock {
                // STG-2 (v2.10.32): reject setLabel() on a group no longer in the index (see set()).
                guard loadIndex().specialSlots.contains(where: { $0.id == specialSlotId }) else {
                    NSLog("[ClipSlots] STG-2: refusing setLabel() on group '\(specialSlotId)' not present in index (deleted/ghost); skipped")
                    return
                }
                slotStorage(for: specialSlotId).setLabel(slot, label: label)
                var index = loadIndex()
                if let idx = index.specialSlots.firstIndex(where: { $0.id == specialSlotId }) {
                    index.specialSlots[idx].updatedAt = Date()
                    try? saveIndex(index)
                }
            }
            return true
        } catch {
            NSLog("[ClipSlots] setLabel(slot:\(slot) in:\(specialSlotId)) 获取存储锁失败，标签未更新：\(error.localizedDescription)")
            return false
        }
    }

    public func snapshot(in specialSlotId: String) -> [Int: SlotContent] {
        slotStorage(for: specialSlotId).snapshot()
    }

    /// v2.9.15 (fix): invalidate the in-memory SlotContent caches of every open
    /// per-group SlotStorage so the next read re-loads from disk. Call this when an
    /// EXTERNAL process (the `clipslots` CLI) may have changed slot bodies on disk;
    /// otherwise the GUI keeps serving stale cached content (labels updated but body
    /// stuck at "空槽位 0 B", because getLabel reads disk directly while get() is
    /// cached). Invalidating ALL cached groups — not just the active one — also fixes
    /// the case where the user later switches to a group the CLI wrote to.
    public func invalidateContentCaches() {
        storageCacheLock.lock()
        let storages = Array(storageCache.values)
        storageCacheLock.unlock()
        for storage in storages {
            storage.invalidateCache()
        }
    }

    // MARK: - Source Update

    public func updateCurrentSpecialSlotSource(sourceType: SpecialSlotSourceType, sourcePath: String?) throws {
        try storageLock.withLock {
            var index = loadIndex()
            guard let idx = index.specialSlots.firstIndex(where: { $0.id == index.currentSpecialSlotId }) else {
                throw SpecialSlotError.specialSlotNotFound
            }
            index.specialSlots[idx].sourceType = sourceType
            index.specialSlots[idx].sourcePath = sourcePath
            index.specialSlots[idx].updatedAt = Date()
            try saveIndex(index)
        }
    }

    // MARK: - Settings

    public func updateSettings(_ transform: (inout SpecialSlotSettings) -> Void) throws {
        try storageLock.withLock {
            var index = loadIndex()
            transform(&index.settings)
            try saveIndex(index)
        }
    }

    // MARK: - Trash Auto-Cleanup (v2.9.5, Feature #1)

    /// Retention policy for `.trash` entries produced by delete-group / delete-page.
    /// An entry is removed when it is older than `trashRetentionDays`; after that,
    /// if more than `trashMaxEntries` still remain, the oldest surplus entries are
    /// removed too. Bounding BOTH age and count keeps the trash from growing without
    /// limit while still giving the user a generous recovery window.
    public static let trashRetentionDays = 30
    // v2.10.16: 回收站上限从 50 提升到 200。随着 write 覆盖也开始把旧内容备份进 .trash
    // （见 set() 的覆盖前备份），删除类操作产生的条目会更多，200 条给回滚留更充裕的空间。
    public static let trashMaxEntries = 200

    /// Extract the unix-second timestamp embedded in a trash entry directory name
    /// ("deleted_<id>_<ts>" / "page_deleted_<id>_<ts>"). Falls back to the entry's
    /// filesystem modification date, then `.distantPast` for un-parseable names.
    private func trashEntryDate(_ url: URL) -> Date {
        let name = url.lastPathComponent
        if let tsStr = name.split(separator: "_").last, let ts = TimeInterval(tsStr) {
            return Date(timeIntervalSince1970: ts)
        }
        if let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date {
            return mod
        }
        return .distantPast
    }

    /// Prune stale entries from `.trash`. Never throws — a cleanup failure must not
    /// break the delete that triggered it. Runs on delete and at startup.
    public func cleanupTrash(retentionDays: Int = SpecialSlotStorage.trashRetentionDays,
                             maxEntries: Int = SpecialSlotStorage.trashMaxEntries) {
        let fm = FileManager.default
        let trashDir = baseDir.appendingPathComponent(".trash")
        guard let entries = try? fm.contentsOfDirectory(
            at: trashDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }

        // 1. Age-based pruning: drop anything older than the retention window.
        // P2-14 (v2.10.8): tolerate "already gone". Two processes (GUI + CLI, or two
        // CLI calls) can run cleanup concurrently and race on the SAME trash entry;
        // guard fileExists before removing and keep `try?` so a concurrent delete that
        // wins the race (NSFileNoSuchFileError) is ignored rather than surfacing a
        // pointless I/O error.
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        var survivors: [(url: URL, date: Date)] = []
        var removed = 0
        for url in entries {
            let date = trashEntryDate(url)
            if date < cutoff {
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                removed += 1
            } else {
                survivors.append((url, date))
            }
        }

        // 2. Count-based pruning: keep only the newest `maxEntries` survivors.
        if survivors.count > maxEntries {
            let sorted = survivors.sorted { $0.date > $1.date } // newest first
            for entry in sorted.dropFirst(maxEntries) {
                if fm.fileExists(atPath: entry.url.path) {
                    try? fm.removeItem(at: entry.url)
                }
                removed += 1
            }
        }

        if removed > 0 {
            NSLog("[ClipSlots] Trash auto-cleanup: removed \(removed) stale entr\(removed == 1 ? "y" : "ies")")
        }
    }

    // MARK: - Utilities

    private func specialSlotDirectory(for id: String) -> URL {
        baseDir.appendingPathComponent(id, isDirectory: true)
    }

    private func touchSpecialSlot(id: String) {
        // v2.9.4 (#4): touchSpecialSlot is non-throwing; swallow a lock timeout
        // via try? so a busy lock degrades to "not touched" rather than crashing.
        try? storageLock.withLock {
            var index = loadIndex()
            if let idx = index.specialSlots.firstIndex(where: { $0.id == id }) {
                index.specialSlots[idx].updatedAt = Date()
                try? saveIndex(index)
            }
        }
    }
}
