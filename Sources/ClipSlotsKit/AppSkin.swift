import Foundation

/// 界面皮肤（v2.11.7）。
///
/// `colorful`（多彩模式）是 v2.11.6 及之前的既有观感：卡片带槽位色装饰条、彩色操作按钮、
/// 槽位色描边与外发光。`minimal`（简洁模式）把这些彩色元素全部收回，只保留**槽位编号**的
/// 颜色作为点缀，其余一律中性灰阶。
///
/// 两者是纯视觉层的分叉——数据、存储、快捷键、CLI 行为完全共用，切换皮肤不动任何一个字节的用户数据。
///
/// 注意与 `ThemeMode`（深色 / 浅色 / 跟随系统）的区别：那是**明暗**，这是**风格**。两者正交，
/// 简洁模式同样有浅色与深色两套取值，跟随系统 appearance 自动解析。
/// UserDefaults 的键名也刻意分开：`appearanceMode` 早已被 `ThemeMode` 占用，皮肤用 `appearanceSkin`。
public enum AppSkin: String, CaseIterable, Codable, Sendable {
    case colorful
    case minimal

    /// UserDefaults 键名。
    public static let defaultsKey = "appearanceSkin"

    /// 老用户升级上来不应该被换皮肤，所以默认值是多彩模式。
    public static let fallback: AppSkin = .colorful

    public var title: String {
        switch self {
        case .colorful: return "多彩模式"
        case .minimal: return "简洁模式"
        }
    }

    public var subtitle: String {
        switch self {
        case .colorful: return "卡片带槽位配色、彩色按钮与高亮"
        case .minimal: return "中性灰阶界面，仅保留槽位编号的颜色"
        }
    }

    public var iconName: String {
        switch self {
        case .colorful: return "paintpalette.fill"
        case .minimal: return "circle.lefthalf.filled"
        }
    }

    /// 从 UserDefaults 读取。未设置或值非法时回落到多彩模式。
    public static func load(from defaults: UserDefaults) -> AppSkin {
        guard let raw = defaults.string(forKey: defaultsKey) else { return fallback }
        return AppSkin(rawValue: raw) ?? fallback
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: AppSkin.defaultsKey)
    }
}

/// 简洁模式的**纯数据**调色板（v2.11.7）。
///
/// 与 `SlotAccentPalette` 同样的取舍：把数值和对比度计算放在 Kit 里，而不是留在 `AppTheme`。
/// `AppTheme` 依赖 SwiftUI / AppKit，本机只有 Command Line Tools 跑不了 App 层测试；Kit 是零 UI
/// 依赖的，可以被 `swift run ClipSlotsKitSmokeTests` 直接覆盖。
///
/// 简洁模式有两条**可验证**的硬约束，正好适合用断言钉住，而不是靠眼睛盯：
///   1. **中性**：除了选中态的紫色描边，所有色值的 RGB 三分量必须几乎相等（灰阶）。
///      简洁模式的全部意义就是「不带颜色倾向」，一旦哪次调色手滑掺进偏蓝或偏暖的灰，
///      整屏会跟着发灰发蓝，而这种偏色在单张截图里极难察觉。
///   2. **对比度**：文字 / 按钮的 WCAG 对比度必须达标。简洁模式没有彩色兜底，
///      所有层级只能靠明度差表达，压得太近就会糊成一片。
public enum MinimalSkinPalette {

    public typealias RGB = SlotAccentPalette.RGB

    /// 一套明暗档位下的全部表面色。
    public struct Surfaces: Equatable {
        /// 窗口底色（卡片背后的画布）。
        public let window: RGB
        /// 有内容的卡片底色。
        public let cardFilled: RGB
        /// 空槽卡片底色。
        public let cardEmpty: RGB
        /// 卡片描边（静息态）。
        public let border: RGB
        /// 次级按钮（编辑 / 清空 / 复制）的底色。
        public let controlFill: RGB
        /// 次级按钮上的文字与图标色。
        public let controlInk: RGB
        /// 空槽「保存到槽位 X」主行动按钮的底色。浅色下是近黑，深色下是纯白——反相才能压住整张空卡片。
        public let ctaFill: RGB
        /// 主行动按钮上的文字色。
        public let ctaInk: RGB
        /// 正文色。
        public let primaryInk: RGB
        /// 次要说明文字色。
        public let secondaryInk: RGB
        /// 选中 / 悬停卡片的细描边。**唯一允许带颜色的表面**。
        public let selection: RGB

        /// 除选中描边外的全部表面色，用于中性断言。
        public var neutralMembers: [RGB] {
            [window, cardFilled, cardEmpty, border, controlFill, controlInk,
             ctaFill, ctaInk, primaryInk, secondaryInk]
        }
    }

    public static let light = Surfaces(
        window: RGB(0.949, 0.949, 0.953),       // #F2F2F3 — 比卡片略深，卡片才浮得起来
        cardFilled: RGB(1.0, 1.0, 1.0),         // #FFFFFF
        cardEmpty: RGB(0.976, 0.976, 0.980),    // #F9F9FA
        border: RGB(0.855, 0.855, 0.863),       // #DADADC
        controlFill: RGB(0.929, 0.929, 0.937),  // #EDEDEF
        controlInk: RGB(0.110, 0.110, 0.118),   // #1C1C1E
        ctaFill: RGB(0.110, 0.110, 0.118),      // #1C1C1E
        ctaInk: RGB(1.0, 1.0, 1.0),             // #FFFFFF
        primaryInk: RGB(0.110, 0.110, 0.118),   // #1C1C1E
        secondaryInk: RGB(0.404, 0.404, 0.416), // #676770
        selection: RGB(0.545, 0.482, 0.909)     // #8B7BE8 — 淡紫
    )

    public static let dark = Surfaces(
        window: RGB(0.086, 0.086, 0.094),       // #161618 — 哑光黑，不用纯黑（纯黑会和卡片糊在一起）
        cardFilled: RGB(0.137, 0.137, 0.145),   // #232325
        cardEmpty: RGB(0.110, 0.110, 0.118),    // #1C1C1E
        border: RGB(0.231, 0.231, 0.243),       // #3B3B3E
        controlFill: RGB(0.192, 0.192, 0.200),  // #313133
        controlInk: RGB(0.949, 0.949, 0.969),   // #F2F2F7
        ctaFill: RGB(1.0, 1.0, 1.0),            // #FFFFFF — 深色下反相成白按钮
        ctaInk: RGB(0.110, 0.110, 0.118),       // #1C1C1E
        primaryInk: RGB(0.949, 0.949, 0.969),   // #F2F2F7
        secondaryInk: RGB(0.616, 0.616, 0.635), // #9D9DA2
        selection: RGB(0.655, 0.545, 0.980)     // #A78BFA — 霓虹紫
    )

    /// 单个色值的「中性度」：RGB 三分量的极差。0 = 纯灰。
    public static func neutrality(_ color: RGB) -> Double {
        let channels = [color.red, color.green, color.blue]
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }
}
