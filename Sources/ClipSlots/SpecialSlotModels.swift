import Foundation

// MARK: - Folder Overflow Decision

enum FolderOverflowDecision {
    case confirm(suppressFutureWarning: Bool)
    case cancel
}

// MARK: - Page Model (v2.4)

/// Page 是最高级工作区，用于区分大的使用场景。
/// 每个 Page 下包含多个 SlotGroup（即 SpecialSlot）。
struct SlotPage: Codable, Identifiable, Equatable {
    var id: String            // "default_page" 或 "page_<UUID>"
    var name: String
    var order: Int
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Special Slot Model (v2.4 renamed to SlotGroup in UI)

/// SpecialSlot 在 v2.4 UI 中称为「槽位组」(SlotGroup)。
/// 每个 SpecialSlot 属于一个 Page，包含固定 10 个子槽位。
struct SpecialSlot: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String = "folder"
    var colorHex: String?
    var sourceType: SpecialSlotSourceType
    var sourcePath: String?
    var pageId: String = "default_page"   // v2.4: 所属页面 ID
    var order: Int = 0                    // v2.4: 页面内的排序
    var createdAt: Date
    var updatedAt: Date

    init(id: String, name: String, icon: String = "folder", colorHex: String? = nil,
         sourceType: SpecialSlotSourceType, sourcePath: String? = nil,
         pageId: String = "default_page", order: Int = 0,
         createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sourceType = sourceType
        self.sourcePath = sourcePath
        self.pageId = pageId
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom decoder for backward compatibility with pre-v2.4 JSON
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        sourceType = try c.decodeIfPresent(SpecialSlotSourceType.self, forKey: .sourceType) ?? .manual
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? "default_page"
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

enum SpecialSlotSourceType: String, Codable {
    case manual
    case folderImport
    case migratedDefault
}

// MARK: - Special Slot Index

struct SpecialSlotIndex: Codable {
    var schemaVersion: Int = 1              // v2.4: 数据格式版本，2 = Page/Group/Slot 三级结构。默认 1 确保旧数据触发迁移
    var version: Int = 4                    // 内部版本号
    var currentPageId: String = "default_page"  // v2.4: 当前选中的页面 ID
    var pages: [SlotPage] = []             // v2.4: 所有页面
    var currentSpecialSlotId: String
    var selectedSpecialSlotId: String?
    var activeHotkeySpecialSlotId: String?
    var specialSlots: [SpecialSlot]
    var settings: SpecialSlotSettings

    init(schemaVersion: Int = 1, version: Int = 4, currentPageId: String = "default_page",
         pages: [SlotPage] = [], currentSpecialSlotId: String, selectedSpecialSlotId: String? = nil,
         activeHotkeySpecialSlotId: String? = nil, specialSlots: [SpecialSlot], settings: SpecialSlotSettings) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.currentPageId = currentPageId
        self.pages = pages
        self.currentSpecialSlotId = currentSpecialSlotId
        self.selectedSpecialSlotId = selectedSpecialSlotId
        self.activeHotkeySpecialSlotId = activeHotkeySpecialSlotId
        self.specialSlots = specialSlots
        self.settings = settings
    }

    // Custom decoder for backward compatibility with pre-v2.4 JSON
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 3
        currentPageId = try c.decodeIfPresent(String.self, forKey: .currentPageId) ?? ""
        pages = try c.decodeIfPresent([SlotPage].self, forKey: .pages) ?? []
        currentSpecialSlotId = try c.decode(String.self, forKey: .currentSpecialSlotId)
        selectedSpecialSlotId = try c.decodeIfPresent(String.self, forKey: .selectedSpecialSlotId)
        activeHotkeySpecialSlotId = try c.decodeIfPresent(String.self, forKey: .activeHotkeySpecialSlotId)
        specialSlots = try c.decode([SpecialSlot].self, forKey: .specialSlots)
        settings = try c.decode(SpecialSlotSettings.self, forKey: .settings)
    }
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
        case .cannotDeleteLastSpecialSlot: return "无法删除最后一个槽位组"
        case .specialSlotNotFound: return "槽位组不存在"
        case .invalidSpecialSlotName: return "槽位组名称无效"
        case .maxSpecialSlotsReached: return "槽位组数量已达到上限 (10 个)"
        case .indexCorrupted: return "槽位组索引文件损坏"
        }
    }
}

// MARK: - Page Errors (v2.4)

enum PageError: Error, LocalizedError {
    case cannotDeleteLastPage
    case pageNotFound
    case duplicateName
    case emptyName

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastPage: return "至少需要保留一个页面"
        case .pageNotFound: return "页面不存在"
        case .duplicateName: return "已存在同名页面"
        case .emptyName: return "页面名称不能为空"
        }
    }
}
