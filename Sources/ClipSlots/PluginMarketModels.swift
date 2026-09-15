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
        // v2.9.53: 「社区插件」已解锁并上架首批第三方项目；
        // 「社区 Skill」已解锁——支持用户自定义上传 Skill 并软链安装到各 Agent。
        default: return false
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
    ///
    /// v2.11.8: 声明了 `githubRepo` 的条目这里留空 —— 版本号运行时从 GitHub latest release 取
    /// （见 GitHubReleaseWatcher）。写死版本号会让「别的 App 发版」变成 ClipSlots 的发版事项。
    let version: String
    /// True when this item installs a Skill into agent environments (drives the
    /// "安装到 Agent" section on the detail page).
    let installsToAgent: Bool
    /// v2.9.53: 第三方/社区项目的主页或仓库地址（详情页展示「访问项目」链接）。nil 表示官方内置项。
    var projectURL: String? = nil
    /// v2.10.10: 第三方 App 在 /Applications 下的 bundle 名（如 "Espanso.app"）。
    /// 用于真实检测该社区插件是否已安装（FileManager.fileExists），空数组表示无需真实检测。
    ///
    /// v2.11.8 由单个 appName 改成候选列表：ScrollApp 的 bundle 实际叫 `Scrollapp.app`（小写 a），
    /// 而仓库/展示名是 ScrollApp。默认 APFS 卷不区分大小写会掩盖这种拼写差异，一旦用户装在
    /// 区分大小写的卷上就检测不到，于是「已安装」永远不亮。列表里把已知写法都放进去。
    var appNames: [String] = []
    /// v2.11.8: GitHub 仓库 slug（"owner/repo"）。声明后「获取」按钮会先问 latest release
    /// 拿 .dmg 直链再打开浏览器（下载而不是落到 Release 页面），版本号也随之动态刷新。
    var githubRepo: String? = nil

    static func == (lhs: PluginMarketItem, rhs: PluginMarketItem) -> Bool { lhs.id == rhs.id }
}

/// The static catalog. Extend this array to add new market items.
enum PluginCatalog {
    static var allItems: [PluginMarketItem] {
        [clipSlotsSkill, scrollApp, espanso, massCode, monitorControl]
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

    // MARK: - Official Plugins（官方独立 App，v2.11.8 首批上架）

    /// ScrollApp：左键长按滚动。
    ///
    /// 版本号和下载直链都**不写死**：`githubRepo` 交给 GitHubReleaseWatcher 在运行时问
    /// latest release，点「获取」拿到的永远是当时的最新 DMG。硬编码 v2.2.3 的直链意味着
    /// ScrollApp 每发一版，ClipSlots 都得跟着改源码重新发版，否则这里就是个过期指路牌。
    static let scrollApp = PluginMarketItem(
        id: "scrollapp-leftclick",
        category: .officialPlugin,
        emoji: "🖱️",
        iconSystemName: "cursorarrow.motionlines",
        name: "ScrollApp",
        source: "官方 · scrollapp-leftclick",
        summary: "左键长按滚动工具，让鼠标左键长按时像中键一样滚动页面",
        detail: """
        ScrollApp 把鼠标左键长按变成「滚动模式」：按住不放再移动鼠标，页面就跟着滚，松手即恢复正常点击。适合只有两键的鼠标、或者中键手感不好、以及需要长时间浏览长文档的场景。

        点「获取」会实时向 GitHub 查询最新 Release，并直接开始下载 .dmg 安装包（不是跳到 Release 页面让你自己找文件）。下载后拖入「应用程序」即可；装好后这张卡片会自动变成「已安装」，可以直接从这里打开。

        需要在「系统设置 → 隐私与安全性 → 辅助功能」里给 ScrollApp 授权，它才能接管鼠标事件。
        """,
        version: "",
        installsToAgent: false,
        projectURL: "https://github.com/Seven-hub-fanfan/scrollapp-leftclick",
        // bundle 实际名是 Scrollapp.app（小写 a）；ScrollApp.app / scrollapp-leftclick.app 一并兜住，
        // 免得将来产品名大小写规整或改名后「已安装」不亮。
        appNames: ["Scrollapp.app", "ScrollApp.app", "scrollapp-leftclick.app"],
        githubRepo: "Seven-hub-fanfan/scrollapp-leftclick"
    )

    // MARK: - Community Plugins（第三方项目，v2.9.53 首批上架）

    static let espanso = PluginMarketItem(
        id: "espanso",
        category: .community,
        emoji: "⚡",
        iconSystemName: "bolt.fill",
        name: "Espanso",
        source: "社区 · Federico Terzi",
        summary: "跨平台文本扩展器，输入自定义缩写自动展开为完整文本，与 ClipSlots 互补。",
        detail: """
        Espanso 是一款开源的跨平台文本扩展器（Text Expander）：输入自定义缩写后自动展开为完整文本，适合处理邮件模板、代码片段、常用短语等重复输入。

        它与 ClipSlots 定位互补——ClipSlots 负责临时素材的收纳与整理，Espanso 负责固定短语的打字触发。两者搭配可覆盖「临时收纳」与「固定短语」两类高频场景。
        """,
        version: "",
        installsToAgent: false,
        projectURL: "https://github.com/espanso/espanso",
        appNames: ["Espanso.app"]
    )

    static let massCode = PluginMarketItem(
        id: "masscode",
        category: .community,
        emoji: "📦",
        iconSystemName: "doc.text.fill",
        name: "massCode",
        source: "社区 · massCodeIO",
        summary: "开发者代码片段管理工具，支持语法高亮、分层文件夹与 Raycast/Alfred 扩展。",
        detail: """
        massCode 是一款面向开发者的开源代码片段（Snippet）管理工具：支持多语言语法高亮、分层文件夹组织，并提供 Raycast / Alfred 扩展，方便随时检索调用。

        相较于 ClipSlots 的临时收纳定位，massCode 更适合长期知识积累与代码片段沉淀，是长期维护个人代码库的好帮手。
        """,
        version: "",
        installsToAgent: false,
        projectURL: "https://github.com/massCodeIO/massCode",
        appNames: ["massCode.app"]
    )

    static let monitorControl = PluginMarketItem(
        id: "monitorcontrol",
        category: .community,
        emoji: "🖥",
        iconSystemName: "display",
        name: "MonitorControl",
        source: "社区 · MonitorControl",
        summary: "macOS 菜单栏工具，用键盘快捷键调节外接显示器亮度和音量。",
        detail: """
        MonitorControl 是一款开源的 macOS 菜单栏工具：让你像调节内置屏幕一样，用键盘快捷键直接控制外接显示器的亮度与音量，无需伸手去按显示器的物理按键。

        对于使用外接显示器的 Mac 用户，它能显著提升日常调节效率，是桌面办公场景的实用补充。
        """,
        version: "",
        installsToAgent: false,
        projectURL: "https://github.com/MonitorControl/MonitorControl",
        appNames: ["MonitorControl.app"]
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
