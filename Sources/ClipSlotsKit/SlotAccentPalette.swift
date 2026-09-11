import Foundation

/// 槽位强调色（slot color）的**纯数据 + 纯数学**定义。
///
/// v2.11.4 起，槽位色不再只是「卡片角标」的装饰，而是要参与圆盘的交互反馈：
///   • 悬停扇区的填充 / 描边跟随被悬停槽位的颜色；
///   • 底栏「上次粘贴」胶囊按钮的底色跟随目标槽位颜色，文字色按亮度自动取黑或白。
///
/// 之所以把调色板和亮度计算搬进 Kit（而不是继续留在 `AppTheme` 里），有两个原因：
///   1. `AppTheme` 依赖 SwiftUI / AppKit，本机只有 Command Line Tools，跑不了 App 层测试；
///      Kit 是零 UI 依赖的，可以被 `swift run ClipSlotsKitSmokeTests` 直接覆盖。
///   2. 「黑字还是白字」是一个**可验证的对比度问题**，不是审美问题，理应有断言兜着，
///      以免以后调色板换色时悄悄出现读不清的按钮。
public enum SlotAccentPalette {

    /// 一个 sRGB 颜色（分量 0...1），只承载数值，不引入任何 UI 类型。
    public struct RGB: Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// sRGB 分量 → 线性光强（WCAG 2.x 定义的 gamma 展开）。
        private static func linearize(_ channel: Double) -> Double {
            let c = min(max(channel, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        /// WCAG 相对亮度（0 = 纯黑，1 = 纯白）。
        ///
        /// 刻意不用「(r+g+b)/3」或 HSB 的 brightness：那两种算法都会把纯黄和纯蓝判成同一亮度，
        /// 而人眼对绿色敏感得多，用它们选黑白字必定翻车（蓝底配黑字、黄底配白字）。
        public var relativeLuminance: Double {
            0.2126 * RGB.linearize(red)
                + 0.7152 * RGB.linearize(green)
                + 0.0722 * RGB.linearize(blue)
        }

        /// 与另一颜色的 WCAG 对比度（1...21）。
        public func contrastRatio(to other: RGB) -> Double {
            let a = relativeLuminance
            let b = other.relativeLuminance
            let lighter = max(a, b)
            let darker = min(a, b)
            return (lighter + 0.05) / (darker + 0.05)
        }

        /// 把自己以 `alpha` 叠在 `background` 上做「源覆盖」合成（sRGB 空间近似）。
        ///
        /// 半透明胶囊底的真实观感取决于合成后的颜色，而不是原色：
        /// 0.85 透明度的深绿叠在浅色玻璃上会明显变浅，用原色算黑白字会选错。
        public func composited(alpha: Double, over background: RGB) -> RGB {
            let a = min(max(alpha, 0), 1)
            return RGB(red * a + background.red * (1 - a),
                       green * a + background.green * (1 - a),
                       blue * a + background.blue * (1 - a))
        }

        public static let white = RGB(1, 1, 1)
        public static let black = RGB(0, 0, 0)
    }

    /// 胶囊 / 扇区上的墨色只有黑白两种取值，避免调用方自由发挥。
    public enum Ink: Equatable {
        case white
        case black
    }

    // MARK: - 调色板

    /// 浅色外观下的槽位色（深而饱和，压得住浅背景）。
    public static let light: [RGB] = [
        RGB(0.12, 0.56, 0.28),
        RGB(0.72, 0.49, 0.04),
        RGB(0.78, 0.31, 0.08),
        RGB(0.72, 0.24, 0.43),
        RGB(0.16, 0.46, 0.70)
    ]

    /// 深色外观下的槽位色（同色相提亮成粉彩，避免在暗背景里糊成一团）。
    public static let dark: [RGB] = [
        RGB(0.42, 0.82, 0.55),
        RGB(0.94, 0.76, 0.32),
        RGB(0.95, 0.55, 0.31),
        RGB(0.91, 0.48, 0.64),
        RGB(0.48, 0.72, 0.92)
    ]

    /// 调色板循环取色：与 `AppTheme.slotAccent(_:)` 的历史行为逐字一致（slot 从 1 起）。
    public static func index(forSlot slot: Int) -> Int {
        max(0, slot - 1) % light.count
    }

    public static func light(forSlot slot: Int) -> RGB { light[index(forSlot: slot)] }
    public static func dark(forSlot slot: Int) -> RGB { dark[index(forSlot: slot)] }

    // MARK: - 交互态不透明度（圆盘与底栏共用，改一处即全局生效）

    /// 悬停扇区填充：保持透明感，让下面的磨砂玻璃与相邻扇区分界线仍然透出来。
    public static let hoverFillOpacity: Double = 0.45
    /// 悬停扇区描边：比填充实一档，负责「这一格被选中」的硬边界。
    public static let hoverStrokeOpacity: Double = 0.72
    /// 底栏胶囊底色：接近实心，但留一点底纹透出以维持玻璃感。
    public static let pillFillOpacity: Double = 0.85
    /// 底栏胶囊描边。
    public static let pillStrokeOpacity: Double = 0.95

    // MARK: - 黑白墨色决策

    /// 浅色外观下，圆盘底栏胶囊背后的近似底色（磨砂玻璃 + 浅色壁纸）。
    public static let lightSurface = RGB(0.95, 0.95, 0.96)
    /// 深色外观下的近似底色。
    public static let darkSurface = RGB(0.13, 0.13, 0.14)

    /// 在给定底色上、以给定不透明度铺一层 `accent` 之后，应该用黑字还是白字。
    ///
    /// 规则很直白：谁的 WCAG 对比度高就用谁。不做审美加权 —— 之前手工挑过一轮，
    /// 深色调色板里的橙（0.95, 0.55, 0.31）配白字对比度只有 2.4，属于「好看但读不清」，
    /// 这类取舍一律让对比度说话。
    public static func ink(for accent: RGB, fillOpacity: Double, over surface: RGB) -> Ink {
        let composited = accent.composited(alpha: fillOpacity, over: surface)
        let contrastWithBlack = composited.contrastRatio(to: .black)
        let contrastWithWhite = composited.contrastRatio(to: .white)
        return contrastWithBlack >= contrastWithWhite ? .black : .white
    }

    /// 便利重载：直接问「某个槽位在某个外观下的胶囊该用什么墨色」。
    public static func pillInk(forSlot slot: Int, isDark: Bool) -> Ink {
        ink(for: isDark ? dark(forSlot: slot) : light(forSlot: slot),
            fillOpacity: pillFillOpacity,
            over: isDark ? darkSurface : lightSurface)
    }
}
