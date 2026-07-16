import SwiftUI

// v2.9.17: data-driven plugin/skill market catalog.
//
// The plugin popover was redesigned into an Obsidian-style marketplace. To keep
// it extensible as more official Skills ship (e.g. prompt generators), all items
// are declared as pure data here, and the UI renders whatever the catalog holds.
// Adding a new official Skill = append one `PluginMarketItem` to `PluginCatalog`.

/// Market category tabs shown at the top of the marketplace.
enum PluginMarketCategory: String, CaseIterable, Identifiable {
    case officialSkill
    case officialPlugin
    case community
    // v2.9.22: 新增「社区 Skill」分类（即将开放），与「社区插件」并列。
    case communitySkill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .officialSkill:   return "官方 Skill"
        case .officialPlugin:  return "官方插件"
        case .community:       return "社区插件"
        case .communitySkill:  return "社区 Skill"
        }
    }

    /// Categories that are intentionally empty placeholders for now.
    var comingSoon: Bool {
        switch self {
        case .community, .communitySkill: return true
        default:                          return false
        }
    }

    var emptyPlaceholder: (icon: String, text: String) {
        switch self {
        case .officialSkill:   return ("sparkles", "暂无官方 Skill")
        case .officialPlugin:  return ("shippingbox", "暂无官方插件")
        case .community:       return ("person.2", "社区插件即将开放")
        case .communitySkill:  return ("person.2.wave.2", "社区 Skill 即将开放")
        }
    }
}

/// A single marketplace entry (Skill or plugin).
struct PluginMarketItem: Identifiable, Equatable {
    let id: String
    let category: PluginMarketCategory
    /// Leading emoji glyph (preferred). Falls back to `iconSystemName` when nil.
    let emoji: String?
    let iconSystemName: String
    let name: String
    /// 作者 / 来源，例如 "官方 · clipslots-manager"。
    let source: String
    /// One-line description shown on the card.
    let summary: String
    /// Full description shown on the detail page.
    let detail: String
    /// Version string (empty when N/A).
    let version: String
    /// True when this item installs a Skill into agent environments (drives the
    /// "安装到 Agent" section on the detail page).
    let installsToAgent: Bool

    static func == (lhs: PluginMarketItem, rhs: PluginMarketItem) -> Bool { lhs.id == rhs.id }
}

/// The static catalog. Extend this array to add new market items.
enum PluginCatalog {
    static var allItems: [PluginMarketItem] {
        [clipSlotsSkill]
    }

    static func items(in category: PluginMarketCategory) -> [PluginMarketItem] {
        allItems.filter { $0.category == category }
    }

    // MARK: - Official Skills

    static let clipSlotsSkill = PluginMarketItem(
        id: "clipslots-manager",
        category: .officialSkill,
        emoji: "✨",
        iconSystemName: "sparkles",
        name: "ClipSlots Skill",
        source: "官方 · clipslots-manager",
        summary: "专为 Agent 设计的 clipslots CLI 操作能力",
        detail: """
        通过命令行工具 clipslots 以编程方式操作 ClipSlots：读取/写入/检索槽位内容、把内容加载到系统剪贴板、批量整理素材到「页面→槽位组→槽位」三层结构、创建/删除页面与槽位组。专为智能体（Agent）调用设计，输出结构化 JSON。

        安装后以软链接方式接入 Agent（Claude Code / Cursor / Codex / Gemini CLI），App 升级 SKILL.md 时 Agent 侧自动同步，无需重复安装。

        提示：此标记暂不影响 CLI（clipslots）的实际行为，仅作展示。CLI 与 App 共享本地数据，安装后始终可被智能体调用。
        """,
        version: AppVersion.current,
        installsToAgent: true
    )
}

/// Sort options for the marketplace list.
enum PluginMarketSort: String, CaseIterable, Identifiable {
    case recommended
    case nameAscending
    case installedFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended:    return "推荐"
        case .nameAscending:  return "名称"
        case .installedFirst: return "已安装优先"
        }
    }

    var iconName: String {
        switch self {
        case .recommended:    return "star"
        case .nameAscending:  return "textformat"
        case .installedFirst: return "checkmark.seal"
        }
    }
}
