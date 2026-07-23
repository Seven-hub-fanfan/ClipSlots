import Foundation

// MARK: - Slot Group Direction (v2.4.1)

public enum SlotGroupDirection {
    case previous
    case next
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

    // F7 (契约5): records what the startup default-page/group repair did on this
    // process. Empty => nothing needed repair. Read by the CLI to emit `repaired`
    // (+ `repair_actions`) on responses.
    public private(set) var lastRepairActions: [String] = []
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
            migrateLegacySlotsOrCreateDefault()
            return
        }
        // v2.4 migration: upgrade existing index to schemaVersion 2
        migrateToV2SchemaIfNeeded()
    }

    /// v2.4 migration: add Page layer on top of existing SpecialSlots.
    /// Safe to call repeatedly — checks schemaVersion before migrating.
    private func migrateToV2SchemaIfNeeded() {
        let index = loadIndex()

        // Already v2.4+ format — just repair any inconsistencies
        if index.schemaVersion >= 2 {
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
        try? storageLock.withLock {
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
            let fallback = currentPageGroups.sorted { $0.order < $1.order }.first
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
            try storageLock.withLock {
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
        queue.sync {
            do {
                let data = try Data(contentsOf: indexURL)
                return try decoder.decode(SpecialSlotIndex.self, from: data)
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
    }

    public func saveIndex(_ index: SpecialSlotIndex) throws {
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
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
        let index = loadIndex()
        guard let current = index.specialSlots.first(where: { $0.id == index.currentSpecialSlotId }) else {
            // Auto-fix: switch to first available
            var fixed = index
            fixed.currentSpecialSlotId = fixed.specialSlots.first?.id ?? "default"
            try saveIndex(fixed)
            guard let fallback = fixed.specialSlots.first else {
                throw SpecialSlotError.specialSlotNotFound
            }
            return fallback
        }
        return current
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
                .sorted { $0.order < $1.order }

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
        // v2.9.4 (#4): non-throwing — swallow lock timeout via try?.
        try? storageLock.withLock {
            var index = loadIndex()
            guard index.specialSlots.contains(where: { $0.id == id }) else { return }
            index.selectedSpecialSlotId = id
            index.currentSpecialSlotId = id
            try? saveIndex(index)
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

            // Move to trash first
            let dir = specialSlotDirectory(for: id)
            let trashDir = baseDir.appendingPathComponent(".trash")
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let trashTarget = trashDir.appendingPathComponent("deleted_\(id)_\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: dir, to: trashTarget)

            // Update index — use page-scoped fallback
            index.specialSlots.removeAll { $0.id == id }

            let fallbackInPage = index.specialSlots
                .filter { $0.pageId == targetSlot.pageId }
                .sorted { $0.order < $1.order }
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

            try saveIndex(index)

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

            // Check for duplicate name
            guard !index.pages.contains(where: { $0.name == trimmed }) else {
                throw PageError.duplicateName
            }

            let maxOrder = index.pages.map { $0.order }.max() ?? (-1)
            let page = SlotPage(
                id: "page_\(UUID().uuidString)",
                name: String(trimmed.prefix(30)),
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
            guard !index.pages.contains(where: { $0.id != id && $0.name == trimmed }) else {
                throw PageError.duplicateName
            }

            index.pages[idx].name = String(trimmed.prefix(30))
            index.pages[idx].updatedAt = Date()
            try saveIndex(index)
            NSLog("[ClipSlots] Page renamed to: \(trimmed)")
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
            let groupsInPage = index.specialSlots.filter { $0.pageId == id }
            if !groupsInPage.isEmpty {
                let trashDir = baseDir.appendingPathComponent(".trash")
                try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
                for group in groupsInPage {
                    let dir = specialSlotDirectory(for: group.id)
                    let trashTarget = trashDir.appendingPathComponent("page_deleted_\(group.id)_\(Int(Date().timeIntervalSince1970))")
                    try? FileManager.default.moveItem(at: dir, to: trashTarget)
                }
                index.specialSlots.removeAll { $0.pageId == id }
                NSLog("[ClipSlots] Page delete: \(groupsInPage.count) slot groups moved to .trash")
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
                .sorted { $0.order < $1.order }
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

            try saveIndex(index)
            NSLog("[ClipSlots] Page deleted: \(id)")

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
            if let firstGroup = groupsInPage.sorted(by: { $0.order < $1.order }).first {
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

    public func slotStorage(for specialSlotId: String) -> SlotStorage {
        if let cached = storageCache[specialSlotId] {
            return cached
        }
        let dir = specialSlotDirectory(for: specialSlotId)
        let storage = SlotStorage(slotsDir: dir)
        storageCache[specialSlotId] = storage
        return storage
    }

    // MARK: Explicit API — all callers must pass specialSlotId

    public func get(_ slot: Int, in specialSlotId: String) -> SlotContent {
        slotStorage(for: specialSlotId).get(slot)
    }

    @discardableResult
    public func set(_ slot: Int, content: SlotContent, in specialSlotId: String) -> Bool {
        var content = content
        content.timestamp = Date()
        let result = slotStorage(for: specialSlotId).set(slot, content: content)
        if result { touchSpecialSlot(id: specialSlotId) }
        return result
    }

    public func clear(_ slot: Int, in specialSlotId: String) {
        slotStorage(for: specialSlotId).clear(slot)
        touchSpecialSlot(id: specialSlotId)
    }

    public func clearAllSlots(in specialSlotId: String) throws {
        try slotStorage(for: specialSlotId).clearAll()
        touchSpecialSlot(id: specialSlotId)
    }

    public func getLabel(_ slot: Int, in specialSlotId: String) -> String? {
        slotStorage(for: specialSlotId).getLabel(slot)
    }

    public func setLabel(_ slot: Int, label: String?, in specialSlotId: String) {
        slotStorage(for: specialSlotId).setLabel(slot, label: label)
        touchSpecialSlot(id: specialSlotId)
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
        for storage in storageCache.values {
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
    public static let trashMaxEntries = 50

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
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        var survivors: [(url: URL, date: Date)] = []
        var removed = 0
        for url in entries {
            let date = trashEntryDate(url)
            if date < cutoff {
                try? fm.removeItem(at: url)
                removed += 1
            } else {
                survivors.append((url, date))
            }
        }

        // 2. Count-based pruning: keep only the newest `maxEntries` survivors.
        if survivors.count > maxEntries {
            let sorted = survivors.sorted { $0.date > $1.date } // newest first
            for entry in sorted.dropFirst(maxEntries) {
                try? fm.removeItem(at: entry.url)
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
