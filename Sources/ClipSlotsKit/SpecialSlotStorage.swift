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

    public init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/clipslots/special_slots")
        baseDir = appSupport
        indexURL = baseDir.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        ensureInitialized()
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
            repairPageScopedSlotGroupsIfNeeded(index)
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
    private func repairPageScopedSlotGroupsIfNeeded(_ index: SpecialSlotIndex) {
        var modified = index
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

        // 4. Ensure each page has at least one slot group
        for page in modified.pages {
            let groupsInPage = modified.specialSlots.filter { $0.pageId == page.id }
            if groupsInPage.isEmpty {
                let defaultGroup = SpecialSlot(
                    id: "special_\(UUID().uuidString)",
                    name: "默认槽位组",
                    icon: "folder",
                    colorHex: nil,
                    sourceType: .manual,
                    sourcePath: nil,
                    pageId: page.id,
                    order: 0,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                let dir = specialSlotDirectory(for: defaultGroup.id)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                modified.specialSlots.append(defaultGroup)
                changed = true
            }
        }

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

    private func migrateLegacySlotsOrCreateDefault() {
        let legacyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/clipslots/slots")

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

    // MARK: - Index Operations

    public func loadIndex() -> SpecialSlotIndex {
        queue.sync {
            do {
                let data = try Data(contentsOf: indexURL)
                return try decoder.decode(SpecialSlotIndex.self, from: data)
            } catch {
                NSLog("[ClipSlots] ERROR decoding index.json: \(error)")
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

    // v2.4.1: cycle through slot groups within the current page
    public func switchToAdjacentSpecialSlot(direction: SlotGroupDirection) throws {
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

    public func updateSelectedSpecialSlot(id: String) {
        var index = loadIndex()
        guard index.specialSlots.contains(where: { $0.id == id }) else { return }
        index.selectedSpecialSlotId = id
        index.currentSpecialSlotId = id
        try? saveIndex(index)
    }

    public func updateActiveHotkeySpecialSlot(id: String) throws {
        var index = loadIndex()
        guard index.specialSlots.contains(where: { $0.id == id }) else {
            throw SpecialSlotError.specialSlotNotFound
        }
        index.activeHotkeySpecialSlotId = id
        try saveIndex(index)
    }

    // MARK: - CRUD Special Slots

    public func createSpecialSlot(
        name: String,
        pageId: String? = nil,
        sourceType: SpecialSlotSourceType = .manual,
        sourcePath: String? = nil
    ) throws -> SpecialSlot {
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

        let maxOrder = existingInPage.map { $0.order }.max() ?? (-1)
        let nextOrder = maxOrder + 1

        let slot = SpecialSlot(
            id: "special_\(UUID().uuidString)",
            name: String(trimmed.prefix(30)),
            icon: "folder",
            colorHex: nil,
            sourceType: sourceType,
            sourcePath: sourcePath,
            pageId: targetPageId,
            order: nextOrder,
            createdAt: Date(),
            updatedAt: Date()
        )

        let dir = specialSlotDirectory(for: slot.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        index.specialSlots.append(slot)
        try saveIndex(index)

        return slot
    }

    public func deleteSpecialSlot(id: String) throws {
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
    }

    public func renameSpecialSlot(id: String, name: String) throws {
        var index = loadIndex()

        guard let idx = index.specialSlots.firstIndex(where: { $0.id == id }) else {
            throw SpecialSlotError.specialSlotNotFound
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpecialSlotError.invalidSpecialSlotName
        }

        index.specialSlots[idx].name = String(trimmed.prefix(30))
        index.specialSlots[idx].updatedAt = Date()

        try saveIndex(index)
    }

    // MARK: - Page CRUD (v2.4)

    public func createPage(name: String) throws -> SlotPage {
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
        try saveIndex(index)
        NSLog("[ClipSlots] Page created: \(page.name)")
        return page
    }

    public func renamePage(id: String, name: String) throws {
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

    public func deletePage(id: String) throws {
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
        try saveIndex(index)
        NSLog("[ClipSlots] Page deleted: \(id)")
    }

    public func switchToPage(id: String) throws {
        var index = loadIndex()
        guard index.pages.contains(where: { $0.id == id }) else {
            throw PageError.pageNotFound
        }

        index.currentPageId = id

        // Switch to the first slot group in this page, or create a default one
        let groupsInPage = index.specialSlots.filter { $0.pageId == id }
        if let firstGroup = groupsInPage.sorted(by: { $0.order < $1.order }).first {
            index.currentSpecialSlotId = firstGroup.id
            index.selectedSpecialSlotId = firstGroup.id
            index.activeHotkeySpecialSlotId = firstGroup.id
        } else {
            // Create a default slot group for this page
            let maxOrder = groupsInPage.map { $0.order }.max() ?? (-1)
            let defaultGroup = SpecialSlot(
                id: "special_\(UUID().uuidString)",
                name: "默认槽位组",
                icon: "folder",
                colorHex: nil,
                sourceType: .manual,
                sourcePath: nil,
                pageId: id,
                order: maxOrder + 1,
                createdAt: Date(),
                updatedAt: Date()
            )
            let dir = specialSlotDirectory(for: defaultGroup.id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            index.specialSlots.append(defaultGroup)
            index.currentSpecialSlotId = defaultGroup.id
            index.selectedSpecialSlotId = defaultGroup.id
            index.activeHotkeySpecialSlotId = defaultGroup.id
        }

        try saveIndex(index)
        NSLog("[ClipSlots] Switched to page: \(id)")
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

    // MARK: - Source Update

    public func updateCurrentSpecialSlotSource(sourceType: SpecialSlotSourceType, sourcePath: String?) throws {
        var index = loadIndex()
        guard let idx = index.specialSlots.firstIndex(where: { $0.id == index.currentSpecialSlotId }) else {
            throw SpecialSlotError.specialSlotNotFound
        }
        index.specialSlots[idx].sourceType = sourceType
        index.specialSlots[idx].sourcePath = sourcePath
        index.specialSlots[idx].updatedAt = Date()
        try saveIndex(index)
    }

    // MARK: - Settings

    public func updateSettings(_ transform: (inout SpecialSlotSettings) -> Void) throws {
        var index = loadIndex()
        transform(&index.settings)
        try saveIndex(index)
    }

    // MARK: - Utilities

    private func specialSlotDirectory(for id: String) -> URL {
        baseDir.appendingPathComponent(id, isDirectory: true)
    }

    private func touchSpecialSlot(id: String) {
        var index = loadIndex()
        if let idx = index.specialSlots.firstIndex(where: { $0.id == id }) {
            index.specialSlots[idx].updatedAt = Date()
            try? saveIndex(index)
        }
    }
}
