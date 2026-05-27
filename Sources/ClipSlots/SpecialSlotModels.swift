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
    var version: Int = 2
    var currentSpecialSlotId: String
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

    static let `default` = SpecialSlotSettings()
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
