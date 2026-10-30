import Foundation

/// 唯一的界面风格。保留类型和旧键用于读取历史设置；
/// 明暗仍由 `ThemeMode` / `appearanceMode` 独立管理。
public enum AppSkin: String, CaseIterable, Codable, Sendable {
    case minimal

    /// UserDefaults 键名。
    public static let defaultsKey = "appearanceSkin"

    /// 新安装与每次更新的默认外观为简洁模式。
    public static let fallback: AppSkin = .minimal

    public var title: String { "简洁模式" }

    public var subtitle: String { "中性灰阶界面，仅保留槽位编号的颜色" }

    public var iconName: String { "circle.lefthalf.filled" }

    /// 旧风格或非法值规范化为简洁模式；不改明暗选择与其他偏好。
    public static func load(from defaults: UserDefaults) -> AppSkin {
        if defaults.object(forKey: defaultsKey) != nil,
           defaults.string(forKey: defaultsKey) != fallback.rawValue {
            fallback.store(in: defaults)
        }
        return fallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard raw == Self.minimal.rawValue || raw == "colorful" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown appearance style")
        }
        self = .minimal
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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

    // MARK: - 卡片悬停描边（v2.11.7 hotfix15）
    //
    // `selection`（紫）原来同时承担三种状态：闪烁定位、拖入目标、**鼠标悬停**。前两种是
    // 「这里发生了事」的强信号，紫色合理；悬停不是状态、只是光标位置的回声，每划过一张卡片
    // 就亮一次紫边，等于让简洁模式里唯一的彩色出口变成鼠标轨迹。
    //
    // 所以悬停描边从 `selection` 里拆出来，收成**中性**的一档：浅色档压黑、深色档压白，
    // 「朝着与卡片底相反的方向压一层半透明中性色」，这样在白卡片 / 近黑卡片上都能看出轮廓，
    // 又不会引入任何色相。
    //
    // hotfix16 调浓度：hotfix15 首版给的是 35% / 1pt，实机上太淡——静息态描边本身就是
    // `border`（浅色 #DADADC ≈ 黑 15%、深色 #3B3B3E），悬停只比它浓一档，人眼在划过时
    // 几乎看不出变化。现在提到浅色黑 65% / 深色白 60%，并把线宽给回 1.5pt：
    // **悬停要能一眼看出来，同时仍然不带色相**（这是与紫色选中描边的唯一区别，不是「更淡」）。
    public enum CardHover {

        public struct Stroke: Equatable {
            /// 描边基色（不含 alpha）。这一档只允许纯黑或纯白。
            public let base: RGB
            public let opacity: Double
            public let width: CGFloat

            public init(base: RGB, opacity: Double, width: CGFloat) {
                self.base = base
                self.opacity = opacity
                self.width = width
            }
        }

        /// 浅色档：黑 65% / 1.5pt。
        public static let light = Stroke(base: RGB(0, 0, 0), opacity: 0.65, width: 1.5)
        /// 深色档：白 60% / 1.5pt。深色档比浅色档略低一点：白色在暗底上的视觉重量本来就更高，
        /// 同 alpha 会比黑边显得更抢。
        public static let dark = Stroke(base: RGB(1, 1, 1), opacity: 0.60, width: 1.5)

        public static func stroke(dark isDark: Bool) -> Stroke { isDark ? dark : light }

        /// 静息态描边（`border`）的等效黑 / 白浓度，用于断言「悬停必须显著浓于静息」。
        /// 浅色 #DADADC 相对白卡片 ≈ 黑 15%；深色 #3B3B3E 相对 #232325 卡片 ≈ 白 11%。
        public static let restingEquivalentOpacity: (light: Double, dark: Double) = (0.15, 0.11)
    }
}
