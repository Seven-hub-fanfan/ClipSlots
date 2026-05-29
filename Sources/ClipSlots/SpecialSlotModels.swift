import Foundation

// MARK: - Folder Overflow Decision

enum FolderOverflowDecision {
    case confirm(suppressFutureWarning: Bool)
    case cancel
}

// MARK: - Special Slot Model

struct SpecialSlot: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String = "folder"
    var colorHex: String?
    var sourceType: SpecialSlotSourceType
    var sourcePath: String?
    var createdAt: Date
    var updatedAt: Date
}

enum SpecialSlotSourceType: String, Codable {
    case manual
    case folderImport
    case migratedDefault
}

// MARK: - Special Slot Index

struct SpecialSlotIndex: Codable {
    var version: Int = 3
    var currentSpecialSlotId: String
    var selectedSpecialSlotId: String?
    var activeHotkeySpecialSlotId: String?
    var specialSlots: [SpecialSlot]
    var settings: SpecialSlotSettings
}

// MARK: - Special Slot Settings

struct SpecialSlotSettings: Codable {
    var maxSpecialSlots: Int = 10
    var maxChildSlotsPerSpecialSlot: Int = 10
    var suppressFolderOverflowWarning: Bool = false
    var folderImportSortRule: FolderImportSortRule = .naturalNameAscending
    var confirmBeforeOverwrite: Bool = true
    var confirmBeforeClearAllSlots: Bool = true
    var confirmBeforeDeleteSpecialSlot: Bool = true
    var confirmBeforePasteAllSlots: Bool = true
    var confirmBeforeClearSingleSlot: Bool = true

    static let `default` = SpecialSlotSettings()

    init(
        maxSpecialSlots: Int = 10,
        maxChildSlotsPerSpecialSlot: Int = 10,
        suppressFolderOverflowWarning: Bool = false,
        folderImportSortRule: FolderImportSortRule = .naturalNameAscending,
        confirmBeforeOverwrite: Bool = true,
        confirmBeforeClearAllSlots: Bool = true,
        confirmBeforeDeleteSpecialSlot: Bool = true,
        confirmBeforePasteAllSlots: Bool = true,
        confirmBeforeClearSingleSlot: Bool = true
    ) {
        self.maxSpecialSlots = maxSpecialSlots
        self.maxChildSlotsPerSpecialSlot = maxChildSlotsPerSpecialSlot
        self.suppressFolderOverflowWarning = suppressFolderOverflowWarning
        self.folderImportSortRule = folderImportSortRule
        self.confirmBeforeOverwrite = confirmBeforeOverwrite
        self.confirmBeforeClearAllSlots = confirmBeforeClearAllSlots
        self.confirmBeforeDeleteSpecialSlot = confirmBeforeDeleteSpecialSlot
        self.confirmBeforePasteAllSlots = confirmBeforePasteAllSlots
        self.confirmBeforeClearSingleSlot = confirmBeforeClearSingleSlot
    }

    enum CodingKeys: String, CodingKey {
        case maxSpecialSlots
        case maxChildSlotsPerSpecialSlot
        case suppressFolderOverflowWarning
        case folderImportSortRule
        case confirmBeforeOverwrite
        case confirmBeforeClearAllSlots
        case confirmBeforeDeleteSpecialSlot
        case confirmBeforePasteAllSlots
        case confirmBeforeClearSingleSlot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxSpecialSlots = try c.decodeIfPresent(Int.self, forKey: .maxSpecialSlots) ?? 10
        maxChildSlotsPerSpecialSlot = try c.decodeIfPresent(Int.self, forKey: .maxChildSlotsPerSpecialSlot) ?? 10
        suppressFolderOverflowWarning = try c.decodeIfPresent(Bool.self, forKey: .suppressFolderOverflowWarning) ?? false
        folderImportSortRule = try c.decodeIfPresent(FolderImportSortRule.self, forKey: .folderImportSortRule) ?? .naturalNameAscending
        confirmBeforeOverwrite = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeOverwrite) ?? true
        confirmBeforeClearAllSlots = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeClearAllSlots) ?? true
        confirmBeforeDeleteSpecialSlot = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDeleteSpecialSlot) ?? true
        confirmBeforePasteAllSlots = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforePasteAllSlots) ?? true
        confirmBeforeClearSingleSlot = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeClearSingleSlot) ?? true
    }
}

enum FolderImportSortRule: String, Codable {
    case naturalNameAscending
}

// MARK: - Errors

enum SpecialSlotError: Error, LocalizedError {
    case cannotDeleteLastSpecialSlot
    case specialSlotNotFound
    case invalidSpecialSlotName
    case maxSpecialSlotsReached
    case indexCorrupted

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastSpecialSlot: return "无法删除最后一个特殊槽位"
        case .specialSlotNotFound: return "特殊槽位不存在"
        case .invalidSpecialSlotName: return "特殊槽位名称无效"
        case .maxSpecialSlotsReached: return "特殊槽位数量已达到上限 (10 个)"
        case .indexCorrupted: return "特殊槽位索引文件损坏"
        }
    }
}
