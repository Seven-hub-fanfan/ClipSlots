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

        // MARK: - HSB 与提亮

        /// 转成 HSB（hue 以 0...1 圈计，与 `NSColor` / `colorsys` 同约定）。
        public var hsb: (hue: Double, saturation: Double, brightness: Double) {
            let maxV = max(red, green, blue)
            let minV = min(red, green, blue)
            let delta = maxV - minV
            guard delta > 0, maxV > 0 else { return (0, 0, maxV) }

            let hue: Double
            switch maxV {
            case red:   hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: hue = (blue - red) / delta + 2
            default:    hue = (red - green) / delta + 4
            }
            let normalized = (hue / 6).truncatingRemainder(dividingBy: 1)
            return (normalized < 0 ? normalized + 1 : normalized, delta / maxV, maxV)
        }

        public static func fromHSB(hue: Double, saturation: Double, brightness: Double) -> RGB {
            let s = min(max(saturation, 0), 1)
            let v = min(max(brightness, 0), 1)
            guard s > 0 else { return RGB(v, v, v) }

            let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
            let sector = floor(h)
            let f = h - sector
            let p = v * (1 - s)
            let q = v * (1 - s * f)
            let t = v * (1 - s * (1 - f))

            switch Int(sector) % 6 {
            case 0: return RGB(v, t, p)
            case 1: return RGB(q, v, p)
            case 2: return RGB(p, v, t)
            case 3: return RGB(p, q, v)
            case 4: return RGB(t, p, v)
            default: return RGB(v, p, q)
            }
        }

        /// 保持色相不变，把饱和度按比例拉高、明度朝纯白方向抬一档。
        ///
        /// 明度用「补足式」`v + (1 - v) * lift` 而不是 `v * scale`：后者对本来就亮的深色调色板
        /// （粉彩系，v 已接近 0.95）几乎无效，还会在乘出 >1 时被截断成失真的纯色。
        public func vivid(saturationScale: Double, brightnessLift: Double) -> RGB {
            let (h, s, v) = hsb
            return RGB.fromHSB(hue: h,
                               saturation: s * saturationScale,
                               brightness: v + (1 - v) * min(max(brightnessLift, 0), 1))
        }
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

    // MARK: - 圆盘专用「提亮版」调色板（v2.11.4 hotfix）

    // 圆盘上的槽位色是**大面积半透明色块**（扇区高亮、底栏胶囊、外沿弧），和主界面卡片上那种
    // 几毫米见方的小角标不是一回事：同一支色，铺成小色点时「深而稳」，铺成扇区就是「脏而闷」，
    // 叠上 0.25~0.28 的不透明度之后更是往灰里塌。
    //
    // 所以圆盘不直接吃基础调色板，而是过一层提亮：色相锁死不动（红还是红、绿还是绿，
    // 与主界面卡片仍然一眼同源），只把饱和度 ×1.20、明度朝白抬 45%。
    // 主界面卡片 / 连接色点等仍用基础调色板，本次不动。

    public static let radialSaturationScale: Double = 1.20
    public static let radialBrightnessLift: Double = 0.45

    private static func radialVivid(_ rgb: RGB) -> RGB {
        rgb.vivid(saturationScale: radialSaturationScale, brightnessLift: radialBrightnessLift)
    }

    public static func radialLight(forSlot slot: Int) -> RGB { radialVivid(light(forSlot: slot)) }
    public static func radialDark(forSlot slot: Int) -> RGB { radialVivid(dark(forSlot: slot)) }

    /// 圆盘用色（按外观选深浅两套之一，已提亮）。
    public static func radial(forSlot slot: Int, isDark: Bool) -> RGB {
        isDark ? radialDark(forSlot: slot) : radialLight(forSlot: slot)
    }

    // MARK: - 统一悬停色（v2.11.4 hotfix4）
    //
    // hotfix1~3 一直在给「跟随槽位色的悬停扇区」调浓度，但问题不在浓度而在**色数**：
    // 一个 10 槽位的圆盘，鼠标一圈扫过去就是绿→黄→橙→粉→蓝→绿…… 五种色相轮播，
    // 悬停反馈本该是「哪一格被选中」这一条信息，却被读成了「这一格是什么颜色」。
    // 槽位色的身份识别职责已经由主界面卡片、扇区外沿弧、底栏「上次粘贴」胶囊承担，
    // 悬停态不需要再重复一遍。
    //
    // 所以悬停扇区改为一支**统一的低饱和冷灰蓝**：色相锁在 220°/224°（比系统默认强调蓝更冷、更收），
    // 饱和度压到 0.18~0.26（几乎是带蓝调的灰，不与任何槽位色抢眼），明度 0.84~0.88。
    // 铺 @0.25 之后浅色下约 #E4E7F0、深色下约 #40444F —— 只是「亮了一档 + 微微偏蓝」，
    // 不产生第六种颜色。
    //
    // 刻意不用 `Color.accentColor`：那是跟随系统偏好设置的（用户可能设成粉、橙、石墨），
    // 圆盘上一旦跟着变，就又回到「悬停色不可控」的老问题。

    /// 浅色外观的统一悬停色：HSB(220°, 18%, 88%) ≈ #B8C5E0。
    public static let hoverAccentLight = RGB.fromHSB(hue: 220.0 / 360.0, saturation: 0.18, brightness: 0.88)
    /// 深色外观的统一悬停色：同色系略深略艳 HSB(224°, 26%, 84%) ≈ #9FADD6，
    /// @0.25 叠在深底上得到冷灰蓝的抬升，而不是发白的雾。
    public static let hoverAccentDark = RGB.fromHSB(hue: 224.0 / 360.0, saturation: 0.26, brightness: 0.84)

    public static func hoverAccent(isDark: Bool) -> RGB { isDark ? hoverAccentDark : hoverAccentLight }

    // MARK: - 交互态不透明度（圆盘与底栏共用，改一处即全局生效）
    //
    // v2.11.4 hotfix2：三档整体降 20%（0.45→0.25 / 0.72→0.52 / 0.85→0.65）。
    // v2.11.4 hotfix3：底栏胶囊底再降到 0.28 —— 0.65 仍然是「一块实色贴片」，
    // 与旁边同为半透明玻璃的组名 chip / 全部粘贴按钮不在一个重量级上，整条底栏被它带塌。
    // 现在胶囊底与悬停扇区填充同档（0.25 / 0.28），槽位色只作为一层轻染色；
    // 按钮的边界交给 0.95 的同色描边守住 —— 底色越淡，越需要一条清晰的轮廓线，
    // 否则胶囊会在磨砂底栏上「化开」，看不出这是个可点的控件。
    // v2.11.4 hotfix4：悬停描边 0.52 → 0.70。染色从高饱和槽位色换成低饱和冷灰蓝后，
    // 同样的 0.52 在浅色下几乎看不出边界（#D4DBE9 与白底差不到一档），
    // 必须把描边补实一点，「选中」的硬边界才还在。填充仍保持 0.25 的轻盈。

    /// 悬停扇区填充：只做一层轻染色，下面的磨砂玻璃与相邻扇区分界线要能透出来。
    public static let hoverFillOpacity: Double = 0.25
    /// 悬停扇区描边：比填充实一档，负责「这一格被选中」的硬边界。
    public static let hoverStrokeOpacity: Double = 0.70
    /// 底栏胶囊底色：与悬停填充同档的轻盈感（略高一点，因为它是常驻控件而非瞬时反馈）。
    public static let pillFillOpacity: Double = 0.28
    /// 底栏胶囊描边：三档里最实的一档，替淡底色守住按钮轮廓。
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
    ///
    /// 注意算的是**提亮后**的圆盘用色：胶囊底铺的就是它，拿基础色算会选错墨色。
    public static func pillInk(forSlot slot: Int, isDark: Bool) -> Ink {
        ink(for: radial(forSlot: slot, isDark: isDark),
            fillOpacity: pillFillOpacity,
            over: isDark ? darkSurface : lightSurface)
    }
}
