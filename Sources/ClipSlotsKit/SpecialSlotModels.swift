import Foundation

// MARK: - Folder Overflow Decision

public enum FolderOverflowDecision {
    case confirm(suppressFutureWarning: Bool)
    case cancel
}

// MARK: - Page Model (v2.4)

/// Page 是最高级工作区，用于区分大的使用场景。
/// 每个 Page 下包含多个 SlotGroup（即 SpecialSlot）。
public struct SlotPage: Codable, Identifiable, Equatable {
    public var id: String            // "default_page" 或 "page_<UUID>"
    public var name: String
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, order: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Special Slot Model (v2.4 renamed to SlotGroup in UI)

/// SpecialSlot 在 v2.4 UI 中称为「槽位组」(SlotGroup)。
/// 每个 SpecialSlot 属于一个 Page，包含固定 10 个子槽位。
public struct SpecialSlot: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var icon: String = "folder"
    public var colorHex: String?
    public var sourceType: SpecialSlotSourceType
    public var sourcePath: String?
    public var pageId: String = "default_page"   // v2.4: 所属页面 ID
    public var order: Int = 0                    // v2.4: 页面内的排序
    /// v2.9.41: 「请求接收时刻」。并行 create-group 时，各 CLI 进程抢锁的先后是
    /// 不确定的，若在写入完成时才分配 order，最终顺序反映的是「谁先抢到锁」而非
    /// 「谁先发起请求」。因此在请求接收时（持锁前）捕获这个时间戳并持久化，
    /// createSpecialSlot 依据它把新组插入到正确位置，从而即使并行写入也能保持
    /// 发起顺序。旧数据没有该字段时解码为 nil，排序回落到既有 order（不被打乱）。
    public var requestedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, icon: String = "folder", colorHex: String? = nil,
         sourceType: SpecialSlotSourceType, sourcePath: String? = nil,
         pageId: String = "default_page", order: Int = 0, requestedAt: Date? = nil,
         createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sourceType = sourceType
        self.sourcePath = sourcePath
        self.pageId = pageId
        self.order = order
        self.requestedAt = requestedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom decoder for backward compatibility with pre-v2.4 JSON
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        sourceType = try c.decodeIfPresent(SpecialSlotSourceType.self, forKey: .sourceType) ?? .manual
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? "default_page"
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        requestedAt = try c.decodeIfPresent(Date.self, forKey: .requestedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public enum SpecialSlotSourceType: String, Codable {
    case manual
    case folderImport
    case migratedDefault
}

// MARK: - Special Slot Index

public struct SpecialSlotIndex: Codable {
    public var schemaVersion: Int = 1              // v2.4: 数据格式版本，2 = Page/Group/Slot 三级结构。默认 1 确保旧数据触发迁移
    public var version: Int = 4                    // 内部版本号
    public var currentPageId: String = "default_page"  // v2.4: 当前选中的页面 ID
    public var pages: [SlotPage] = []             // v2.4: 所有页面
    public var currentSpecialSlotId: String
    public var selectedSpecialSlotId: String?
    public var activeHotkeySpecialSlotId: String?
    public var specialSlots: [SpecialSlot]
    public var settings: SpecialSlotSettings

    public init(schemaVersion: Int = 1, version: Int = 4, currentPageId: String = "default_page",
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
    public init(from decoder: Decoder) throws {
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

public struct SpecialSlotSettings: Codable {
    public var maxSpecialSlots: Int = 10
    public var maxChildSlotsPerSpecialSlot: Int = 10
    public var suppressFolderOverflowWarning: Bool = false
    public var folderImportSortRule: FolderImportSortRule = .naturalNameAscending
    public var confirmBeforeOverwrite: Bool = true
    public var confirmBeforeClearAllSlots: Bool = true
    public var confirmBeforeDeleteSpecialSlot: Bool = true
    public var confirmBeforePasteAllSlots: Bool = true
    public var confirmBeforeClearSingleSlot: Bool = true

    public static let `default` = SpecialSlotSettings()

    public init(
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

    public init(from decoder: Decoder) throws {
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

public enum FolderImportSortRule: String, Codable {
    case naturalNameAscending
}

// MARK: - Errors

public enum SpecialSlotError: Error, LocalizedError {
    case cannotDeleteLastSpecialSlot
    case specialSlotNotFound
    case invalidSpecialSlotName
    case maxSpecialSlotsReached
    case duplicateName
    case indexCorrupted
    case defaultGroupProtected

    public var errorDescription: String? {
        switch self {
        case .cannotDeleteLastSpecialSlot: return "无法删除当前页面的最后一个槽位组"
        case .specialSlotNotFound: return "槽位组不存在"
        case .invalidSpecialSlotName: return "槽位组名称无效"
        case .maxSpecialSlotsReached: return "当前页面的槽位组数量已达到上限，最多 10 个"
        case .duplicateName: return "当前页面已存在同名槽位组"
        case .indexCorrupted: return "槽位组索引文件损坏"
        case .defaultGroupProtected: return "默认槽位组受保护，无法删除"
        }
    }
}

// MARK: - Page Errors (v2.4)

public enum PageError: Error, LocalizedError {
    case cannotDeleteLastPage
    case pageNotFound
    case duplicateName
    case emptyName
    case defaultPageProtected

    public var errorDescription: String? {
        switch self {
        case .cannotDeleteLastPage: return "至少需要保留一个页面"
        case .pageNotFound: return "页面不存在"
        case .duplicateName: return "已存在同名页面"
        case .emptyName: return "页面名称不能为空"
        case .defaultPageProtected: return "默认页面受保护，无法删除"
        }
    }
}
