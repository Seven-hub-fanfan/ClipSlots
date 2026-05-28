import Foundation

final class SpecialSlotStorage {
    static let shared = SpecialSlotStorage()

    private let baseDir: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "com.clipslots.specialstorage", qos: .utility)

    init() {
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
        let defaultSlot = SpecialSlot(
            id: "default",
            name: "默认槽位",
            icon: "folder",
            colorHex: nil,
            sourceType: .migratedDefault,
            sourcePath: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let index = SpecialSlotIndex(
            version: 2,
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

    func loadIndex() -> SpecialSlotIndex {
        queue.sync {
            do {
                let data = try Data(contentsOf: indexURL)
                return try decoder.decode(SpecialSlotIndex.self, from: data)
            } catch {
                NSLog("[ClipSlots] Failed to load index: \(error)")
                return SpecialSlotIndex(
                    version: 2,
                    currentSpecialSlotId: "default",
                    specialSlots: [],
                    settings: .default
                )
            }
        }
    }

    func saveIndex(_ index: SpecialSlotIndex) throws {
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Current Special Slot

    func currentSpecialSlot() throws -> SpecialSlot {
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

    func switchToSpecialSlot(id: String) throws {
        var index = loadIndex()
        guard index.specialSlots.contains(where: { $0.id == id }) else {
            throw SpecialSlotError.specialSlotNotFound
        }
        index.currentSpecialSlotId = id
        try saveIndex(index)
    }

    // MARK: - CRUD Special Slots

    func createSpecialSlot(
        name: String,
        sourceType: SpecialSlotSourceType = .manual,
        sourcePath: String? = nil
    ) throws -> SpecialSlot {
        var index = loadIndex()

        guard index.specialSlots.count < index.settings.maxSpecialSlots else {
            throw SpecialSlotError.maxSpecialSlotsReached
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpecialSlotError.invalidSpecialSlotName
        }

        let slot = SpecialSlot(
            id: "special_\(UUID().uuidString)",
            name: String(trimmed.prefix(30)),
            icon: "folder",
            colorHex: nil,
            sourceType: sourceType,
            sourcePath: sourcePath,
            createdAt: Date(),
            updatedAt: Date()
        )

        let dir = specialSlotDirectory(for: slot.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        index.specialSlots.append(slot)
        try saveIndex(index)

        return slot
    }

    func deleteSpecialSlot(id: String) throws {
        var index = loadIndex()

        guard index.specialSlots.count > 1 else {
            throw SpecialSlotError.cannotDeleteLastSpecialSlot
        }

        guard index.specialSlots.contains(where: { $0.id == id }) else {
            throw SpecialSlotError.specialSlotNotFound
        }

        // Move to trash first
        let dir = specialSlotDirectory(for: id)
        let trashDir = baseDir.appendingPathComponent(".trash")
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let trashTarget = trashDir.appendingPathComponent("deleted_\(id)_\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: dir, to: trashTarget)

        // Update index
        index.specialSlots.removeAll { $0.id == id }

        if index.currentSpecialSlotId == id {
            index.currentSpecialSlotId = index.specialSlots.first?.id ?? "default"
        }

        try saveIndex(index)
    }

    func renameSpecialSlot(id: String, name: String) throws {
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

    // MARK: - Child Slot Operations (routed to current special slot)

    private var storageCache: [String: SlotStorage] = [:]

    private func slotStorage(for specialSlotId: String) -> SlotStorage {
        if let cached = storageCache[specialSlotId] {
            return cached
        }
        let dir = specialSlotDirectory(for: specialSlotId)
        let storage = SlotStorage(slotsDir: dir)
        storageCache[specialSlotId] = storage
        return storage
    }

    private var currentStorage: SlotStorage {
        let index = loadIndex()
        return slotStorage(for: index.currentSpecialSlotId)
    }

    func get(_ slot: Int) -> SlotContent {
        currentStorage.get(slot)
    }

    @discardableResult
    func set(_ slot: Int, content: SlotContent) -> Bool {
        var content = content
        content.timestamp = Date()
        let result = currentStorage.set(slot, content: content)
        if result { touchCurrentSpecialSlot() }
        return result
    }

    func clear(_ slot: Int) {
        currentStorage.clear(slot)
    }

    func clearAllSlotsInCurrentSpecialSlot() throws {
        currentStorage.clearAll()
    }

    func getLabel(_ slot: Int) -> String? {
        currentStorage.getLabel(slot)
    }

    func setLabel(_ slot: Int, label: String?) {
        currentStorage.setLabel(slot, label: label)
    }

    func snapshot() -> [Int: SlotContent] {
        currentStorage.snapshot()
    }

    // MARK: - Source Update

    func updateCurrentSpecialSlotSource(sourceType: SpecialSlotSourceType, sourcePath: String?) throws {
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

    func updateSettings(_ transform: (inout SpecialSlotSettings) -> Void) throws {
        var index = loadIndex()
        transform(&index.settings)
        try saveIndex(index)
    }

    // MARK: - Utilities

    private func specialSlotDirectory(for id: String) -> URL {
        baseDir.appendingPathComponent(id, isDirectory: true)
    }

    private func touchCurrentSpecialSlot() {
        var index = loadIndex()
        if let idx = index.specialSlots.firstIndex(where: { $0.id == index.currentSpecialSlotId }) {
            index.specialSlots[idx].updatedAt = Date()
            try? saveIndex(index)
        }
    }
}
