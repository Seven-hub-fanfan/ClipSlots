import SwiftUI
import ClipSlotsKit
import AppKit

enum AppTheme {
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    static let cardPadding: CGFloat = 14
    /// Main-grid slot cards use a softer, editorial radius without changing other surfaces.
    static let slotCardCornerRadius: CGFloat = 24
    static let slotPreviewCornerRadius: CGFloat = 14
    static let slotCardPadding: CGFloat = 18
    static let pagePadding: CGFloat = 20

    // MARK: - Spacing (v2.9.18 — 收敛硬编码间距到统一 token)

    /// 紧凑元素间距（图标↔文字、chip 间隔等）。
    static let spacingTight: CGFloat = 4
    /// 常规元素间距。
    static let spacingSmall: CGFloat = 8
    /// 区块内成组元素间距。
    static let spacingMedium: CGFloat = 12
    /// 弹窗内各区块之间的间距。
    static let spacingLarge: CGFloat = 16
    /// 弹窗统一内边距（取代 18/20/24 等散落值）。
    static let sheetPadding: CGFloat = 20

    // MARK: - Sheet Width (v2.9.18 — 消除弹窗宽度在 390/420/440 间跳变)

    static let sheetWidthSmall: CGFloat = 400
    static let sheetWidthMedium: CGFloat = 480
    static let sheetWidthLarge: CGFloat = 560

    // MARK: - Fonts (v2.9.18 — 统一字体 token，最小可读字号 12pt)

    enum Fonts {
        /// 弹窗/页面主标题，统一 18pt semibold（消除 17/18 摇摆）。
        static let title = Font.system(size: 18, weight: .semibold)
        /// 次级标题 / 卡片标题，15pt semibold。
        static let headline = Font.system(size: 15, weight: .semibold)
        /// 小节标题，13pt medium。
        static let subheadline = Font.system(size: 13, weight: .medium)
        /// 正文，13pt。
        static let body = Font.system(size: 13)
        /// 说明文字，12pt（此前 11pt 副标题上调至此）。
        static let caption = Font.system(size: 12)
        /// 最小可读辅助文字，12pt（此前裸写的 9pt/11pt 全部上调至此，保证非视网膜屏可读）。
        static let footnote = Font.system(size: 12)
    }

    // MARK: - ★ v2.10.93 · 动态色（切深浅色不再需要整棵视图树重算）
    //
    // 背景（本轮实测结论）：切主题一次会造成 **130ms 的主线程停顿**（release 构建、10 张卡片），
    // 期间画面停在旧帧上，AppKit 材质层与 SwiftUI 内容各自在不同帧落地 —— 用户看到的就是
    // 「非常明显的卡颜色」。`sample` 采样显示这 130ms 几乎全在
    // AttributeGraph 重算 + CoreText 重新排版（`CTLineCreateWithAttributedString` / `InitShapingGlyphs`），
    // 也就是「每个视图都必须重新求值 body 才能换色」这一架构决定的必然开销。
    //
    // 根因：全部颜色 token 过去都是 `func x(_ scheme: ColorScheme) -> Color { scheme == .dark ? A : B }`，
    // 于是**每个用到颜色的视图都必须 `@Environment(\.colorScheme)`**；scheme 一变，整棵树的 body
    // 连带文字排版全部重算。这与 macOS 原生做法相反：原生用的是 **dynamic NSColor**，
    // 同一个颜色对象在绘制时按当前 appearance 解析，换主题只需重绘、不需要重新布局/排版。
    //
    // 现在 token 一律构造成 `NSColor(name:dynamicProvider:)` 包出来的动态色：
    //   • 视图侧不再需要读 colorScheme（读了才会被 scheme 变化拖着重算）；
    //   • 颜色在渲染阶段按 appearance 解析，深浅切换是一次纯重绘；
    //   • `NSApp.appearance`（v2.10.91 已统一设置）与 SwiftUI `.preferredColorScheme` 都会让
    //     视图层次拿到正确的 appearance，两条路径解析结果一致。
    //
    // 为了不动 100+ 处调用点，每个 token 都保留一个**忽略 scheme 参数**的同名重载 shim，
    // 老写法 `AppTheme.cardBackground(colorScheme, isEmpty:)` 继续可用且行为等价。

    /// 用「浅色值 / 深色值」构造一个在绘制时解析的动态色。
    private static func dyn(light: Color, dark: Color) -> Color {
        let lightNS = NSColor(light)
        let darkNS = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }

    /// 基于系统强调色的动态色（保持跟随用户在「系统设置 → 外观」里选的强调色）。
    private static func dynAccent(lightOpacity: Double, darkOpacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.controlAccentColor.withAlphaComponent(isDark ? darkOpacity : lightOpacity)
        })
    }

    /// 当前 appearance 是否深色（仅少数确实需要「按 scheme 分叉结构」的地方使用，例如
    /// 材质档位 Material 无法做成动态色）。
    static var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Skin（v2.11.7 简洁模式）

    /// 当前皮肤。视图侧判断「要不要画彩色装饰」时读它。
    static var skin: AppSkin { AppSkinCenter.current }

    /// 简洁模式下为真。比 `skin == .minimal` 读起来顺一点，调用点很多。
    static var isMinimalSkin: Bool { AppSkinCenter.current == .minimal }

    /// 把 Kit 里的中性调色板包成动态色。
    ///
    /// 注意这里**不能**偷懒写成 `dyn(light: .white, dark: .black).opacity(x)`：简洁模式的灰阶是
    /// 一组精确的不透明色值（它们要参与 WCAG 对比度断言），半透明叠加会随底色漂移，
    /// 实际渲染出来的对比度就不是测过的那个数了。
    private static func minimal(_ keyPath: KeyPath<MinimalSkinPalette.Surfaces, MinimalSkinPalette.RGB>) -> Color {
        dyn(light: color(MinimalSkinPalette.light[keyPath: keyPath]),
            dark: color(MinimalSkinPalette.dark[keyPath: keyPath]))
    }

    /// 简洁模式的中性色，按 alpha 叠加（阴影这类必须半透明的场合用）。
    private static func minimalAlpha(light: Double, dark: Double) -> Color {
        dyn(light: Color.black.opacity(light), dark: Color.black.opacity(dark))
    }

    /// 选中 / 悬停卡片的细描边（简洁模式唯一允许带颜色的表面：浅色淡紫、深色霓虹紫）。
    static let minimalSelectionBorder = minimal(\.selection)

    /// 简洁模式下**鼠标悬停**卡片的描边（v2.11.7 hotfix15）：浅色黑 35%、深色白 35%。
    ///
    /// 从上面的紫色选中描边里拆出来的。悬停不是状态、只是光标位置的回声，用紫色等于让
    /// 简洁模式里唯一的彩色出口跟着鼠标跑；闪烁定位与拖入目标那两种**真状态**仍然用紫色。
    /// 具体色值与 alpha 见 `MinimalSkinPalette.CardHover`（smoke 有断言钉住中性与方向）。
    static let minimalCardHoverBorder = dyn(
        light: color(MinimalSkinPalette.CardHover.light.base)
            .opacity(MinimalSkinPalette.CardHover.light.opacity),
        dark: color(MinimalSkinPalette.CardHover.dark.base)
            .opacity(MinimalSkinPalette.CardHover.dark.opacity)
    )

    /// 空槽「保存到槽位 X」主行动按钮：浅色近黑底白字、深色白底黑字。
    ///
    /// 反相是刻意的。简洁模式的空卡片除了这枚按钮之外几乎没有别的元素，
    /// 若按钮也用中间调的灰，整张卡片会平得看不出「这里可以点」。
    static let minimalCTAFill = minimal(\.ctaFill)
    static let minimalCTAInk = minimal(\.ctaInk)

    /// 简洁模式的中性表面。都是**不透明**色值，理由见上面 `minimal(_:)` 的注释。
    private static let minimalWindow = minimal(\.window)
    private static let minimalCardFilled = minimal(\.cardFilled)
    private static let minimalCardEmpty = minimal(\.cardEmpty)
    private static let minimalBorder = minimal(\.border)
    private static let minimalControlFill = minimal(\.controlFill)
    static let minimalControlInk = minimal(\.controlInk)
    static let minimalSecondaryInk = minimal(\.secondaryInk)

    /// 简洁模式的投影：「极微弱」。浅色几乎只是一层灰雾，深色靠底色差本身分层。
    private static let minimalShadowFilled = minimalAlpha(light: 0.055, dark: 0.20)
    private static let minimalShadowEmpty = minimalAlpha(light: 0.025, dark: 0.12)
    private static let minimalPreviewBackground = minimalAlpha(light: 0.035, dark: 0.24)

    // MARK: - Chrome accent（v2.11.7 hotfix）
    //
    // 「装饰性品牌色」与「功能性强调色」的分界线。这一组 token 专门给**前者**：
    // 工具栏图标、logo 底板、页面选择器图标、内容类型图标、附件计数胶囊——它们用蓝紫色纯粹是
    // 品牌观感，不携带任何状态信息。多彩模式保留原来的强调色，简洁模式一律收成中性墨色。
    //
    // 后者（选中的组、启用的拨杆、拖入高亮、已有连接、危险操作红）**不在这一组里**，两种皮肤下
    // 都保留强调色：那是在传递「哪个是当前的 / 这一下会发生什么」，收成灰会真的丢信息。
    // 简洁模式的设计里紫色本来就是选中色（见 MinimalSkinPalette.selection），所以这条分界线
    // 也让两者在视觉语言上自洽：**简洁模式里出现彩色，就意味着「这里有状态」**。

    /// 装饰性图标 / 文字的着色。
    static var chromeAccentInk: Color { isMinimalSkin ? minimalControlInk : Color.accentColor }

    /// 装饰性图标背后的浅色底板（原先各处裸写 `Color.accentColor.opacity(0.12~0.16)`）。
    private static let colorfulChromeAccentSoftFill = Color.accentColor.opacity(0.14)
    static var chromeAccentSoftFill: Color { isMinimalSkin ? minimalControlFill : colorfulChromeAccentSoftFill }

    /// 更淡一档的装饰底（快捷键提示条那种「几乎看不见」的色块）。
    private static let colorfulChromeAccentFaintFill = Color.accentColor.opacity(0.06)
    private static let minimalChromeAccentFaintFill = minimalAlpha(light: 0.035, dark: 0.16)
    static var chromeAccentFaintFill: Color {
        isMinimalSkin ? minimalChromeAccentFaintFill : colorfulChromeAccentFaintFill
    }

    /// 实心品牌色块（App logo 底板、有附件的计数胶囊）及其上的文字色 / 投影。
    static var chromeAccentTile: AnyShapeStyle {
        isMinimalSkin ? AnyShapeStyle(minimalControlFill) : AnyShapeStyle(brandGradient)
    }
    static var chromeAccentTileInk: Color { isMinimalSkin ? minimalControlInk : onAccentText }
    private static let colorfulChromeAccentTileShadow = Color.accentColor.opacity(0.25)
    static var chromeAccentTileShadow: Color { isMinimalSkin ? .clear : colorfulChromeAccentTileShadow }

    /// 实心品牌色块的描边。多彩模式靠白色高光提亮渐变；简洁模式改用与卡片同源的细边框
    /// （中性灰块没有渐变可提亮，白高光只会变成脏边）。
    private static let colorfulChromeAccentTileStroke = Color.white.opacity(0.22)
    static var chromeAccentTileStroke: Color { isMinimalSkin ? minimalBorder : colorfulChromeAccentTileStroke }

    // MARK: - Brand

    static let brandGradientStart = dyn(light: Color(red: 0.36, green: 0.49, blue: 1.00),
                                        dark: Color(red: 0.42, green: 0.50, blue: 1.00))
    static let brandGradientEnd = dyn(light: Color(red: 0.50, green: 0.35, blue: 1.00),
                                      dark: Color(red: 0.56, green: 0.36, blue: 1.00))
    static let brandGradient = LinearGradient(colors: [brandGradientStart, brandGradientEnd],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static func brandGradient(_ scheme: ColorScheme) -> LinearGradient { brandGradient }

    static let success = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let danger = Color(red: 1.00, green: 0.27, blue: 0.23)

    /// 位于彩色 / 品牌渐变背景上的文字色（此前各视图裸写 `.white`，v2.9.18 收敛于此）。
    static let onAccentText: Color = .white

    // MARK: - Floating Notice
    // 悬浮提示需要不透明实心底色，AppTheme 其余 background 都是半透明，故单列 opaque token。

    static let noticeBackground = dyn(light: Color(red: 0.97, green: 0.97, blue: 0.98),
                                      dark: Color(red: 0.12, green: 0.12, blue: 0.13))
    static func noticeBackground(_ scheme: ColorScheme) -> Color { noticeBackground }

    static let noticeBorder = dyn(light: Color(red: 0.84, green: 0.84, blue: 0.86),
                                  dark: Color(red: 0.24, green: 0.24, blue: 0.26))
    static func noticeBorder(_ scheme: ColorScheme) -> Color { noticeBorder }

    static let noticeSubtitle = dyn(light: Color(red: 0.38, green: 0.38, blue: 0.42),
                                    dark: Color(red: 0.72, green: 0.72, blue: 0.75))
    static func noticeSubtitle(_ scheme: ColorScheme) -> Color { noticeSubtitle }

    // MARK: - Window
    //
    // v2.11.7：凡是简洁模式要改写的 token，一律从 `static let` 改成**计算属性**，
    // 把多彩模式的原值原封不动挪进 `colorful*` 常量。
    //
    // 为什么不能沿用 dynamic NSColor 那一套「绘制时再解析」：`NSColor(name:dynamicProvider:)`
    // 的 provider 只在 **appearance**（深/浅）变化时被重新调用，皮肤是 App 自己定义的状态，
    // AppKit 根本不知道它变了。所以皮肤分叉必须发生在「读 token」的那一刻 —— 也就是
    // 计算属性；再由 `ContentView` 在皮肤变化时强制重建视图树（见 AppSkinCenter）。
    // 深浅切换依旧走动态色，零成本那条路径没有被牺牲。

    // v2.11.7 hotfix4: 多彩模式的窗口底改为直接引用 NeumorphicPalette 的 `ground`。
    // 工具栏去掉浮动面板后，它的承载面就是窗口底本身，两处必须**同源**——否则工具栏区
    // 会重新变成一块颜色略不同的方块压在内容上（简洁模式那侧同源于 MinimalSkinPalette.window，
    // 由 smoke 断言钉住两边相等）。取值与 hotfix4 之前逐位相同，视觉零变化。
    private static let colorfulWindowBackground = dyn(light: color(NeumorphicPalette.colorfulLight.ground),
                                                      dark: color(NeumorphicPalette.colorfulDark.ground))
    static var windowBackground: Color { isMinimalSkin ? minimalWindow : colorfulWindowBackground }
    static func windowBackground(_ scheme: ColorScheme) -> Color { windowBackground }

    private static let colorfulElevatedBackground = dyn(light: Color.white.opacity(0.82),
                                                        dark: Color.white.opacity(0.055))
    static var elevatedBackground: Color { isMinimalSkin ? minimalCardFilled : colorfulElevatedBackground }
    static func elevatedBackground(_ scheme: ColorScheme) -> Color { elevatedBackground }

    private static let colorfulHeaderBackground = dyn(light: Color.white.opacity(0.72),
                                                      dark: Color.white.opacity(0.04))
    static var headerBackground: Color { isMinimalSkin ? minimalCardEmpty : colorfulHeaderBackground }
    static func headerBackground(_ scheme: ColorScheme) -> Color { headerBackground }

    // MARK: - Card

    private static let cardBackgroundFilled = dyn(light: Color(red: 0.995, green: 0.99, blue: 0.98),
                                                  dark: Color(red: 0.105, green: 0.108, blue: 0.115).opacity(0.98))
    private static let cardBackgroundEmpty = dyn(light: Color(red: 0.965, green: 0.955, blue: 0.935),
                                                 dark: Color(red: 0.105, green: 0.108, blue: 0.115).opacity(0.92))
    static func cardBackground(isEmpty: Bool = false) -> Color {
        if isMinimalSkin { return isEmpty ? minimalCardEmpty : minimalCardFilled }
        return isEmpty ? cardBackgroundEmpty : cardBackgroundFilled
    }
    static func cardBackground(_ scheme: ColorScheme, isEmpty: Bool = false) -> Color {
        cardBackground(isEmpty: isEmpty)
    }

    /// A restrained, single-color identity per slot. The palette deliberately cycles
    /// instead of blending, so each card has one clear accent.
    ///
    /// v2.10.93: 深/浅两套调色板合并成一套动态色（原先是两个 `static let [Color]`，
    /// 由调用方按 scheme 选数组 —— 那正是逼着卡片必须读 colorScheme 的原因之一）。
    ///
    /// v2.11.4: 调色板数值本体搬到 `ClipSlotsKit.SlotAccentPalette`。这里只负责把 Kit 的
    /// 纯 RGB 包成动态 `Color`。动机是槽位色从「卡片装饰」升级成了「圆盘交互反馈」
    /// （悬停扇区、底栏胶囊都要跟色，还要按亮度自动决定黑字/白字），亮度与对比度计算
    /// 必须能被 smoke 测试覆盖，而 App 层在本机跑不了测试。
    private static let slotAccents: [Color] = zip(SlotAccentPalette.light, SlotAccentPalette.dark).map { pair in
        dyn(light: color(pair.0), dark: color(pair.1))
    }

    private static func color(_ rgb: SlotAccentPalette.RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func slotAccent(_ slot: Int) -> Color {
        slotAccents[SlotAccentPalette.index(forSlot: slot)]
    }
    static func slotAccent(_ slot: Int, scheme: ColorScheme) -> Color { slotAccent(slot) }

    /// 圆盘专用的**提亮版**槽位色（不透明，用于扇区外沿「上次粘贴」弧这类描线）。
    ///
    /// v2.11.4 hotfix：圆盘上的槽位色是大面积半透明色块，基础调色板铺上去偏深偏闷，
    /// 于是统一过一层 `SlotAccentPalette.radial`（色相不动，饱和度 ×1.20、明度朝白抬 45%）。
    /// 主界面卡片仍用基础色，两边同色相、只差一档明度，看得出是同一支色。
    static func radialSlotAccent(_ slot: Int) -> Color {
        dyn(light: color(SlotAccentPalette.radialLight(forSlot: slot)),
            dark: color(SlotAccentPalette.radialDark(forSlot: slot)))
    }

    /// 圆盘槽位色的半透明版本（动态色 + 指定 alpha）。
    ///
    /// 不能写成 `radialSlotAccent(slot).opacity(x)`：它返回的是 dynamic NSColor 包出来的
    /// `Color`，SwiftUI 的 `.opacity` 会在**当前**解析结果上乘 alpha，深浅切换时不会重新解析。
    /// 所以这里重新构造一次 dynamic provider，在绘制阶段先选色板再套 alpha。
    private static func slotAccentTint(_ slot: Int, opacity: Double) -> Color {
        let lightNS = NSColor(color(SlotAccentPalette.radialLight(forSlot: slot))).withAlphaComponent(opacity)
        let darkNS = NSColor(color(SlotAccentPalette.radialDark(forSlot: slot))).withAlphaComponent(opacity)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }

    /// 位于「槽位色胶囊」之上的墨色：按合成后亮度自动取黑或白（深浅两套各判一次）。
    private static func slotPillInk(_ slot: Int) -> Color {
        func ns(isDark: Bool) -> NSColor {
            SlotAccentPalette.pillInk(forSlot: slot, isDark: isDark) == .black
                ? NSColor.black.withAlphaComponent(0.88)
                : NSColor.white
        }
        let lightNS = ns(isDark: false)
        let darkNS = ns(isDark: true)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }

    /// High-chroma light fills for card actions. These stay bright without relying on
    /// opacity, which would mix the hue with the card background and create a muted gray cast.
    private static let slotActionAccents: [Color] = [
        dyn(light: Color(red: 0.56, green: 0.93, blue: 0.65), dark: Color(red: 0.42, green: 0.82, blue: 0.55)),
        dyn(light: Color(red: 1.00, green: 0.82, blue: 0.28), dark: Color(red: 0.94, green: 0.76, blue: 0.32)),
        dyn(light: Color(red: 1.00, green: 0.62, blue: 0.30), dark: Color(red: 0.95, green: 0.55, blue: 0.31)),
        dyn(light: Color(red: 0.98, green: 0.52, blue: 0.70), dark: Color(red: 0.91, green: 0.48, blue: 0.64)),
        dyn(light: Color(red: 0.45, green: 0.75, blue: 1.00), dark: Color(red: 0.48, green: 0.72, blue: 0.92))
    ]

    static func slotActionAccent(_ slot: Int) -> Color {
        // 简洁模式：操作按钮全部收成中性灰。槽位身份只由编号角标承载。
        if isMinimalSkin { return minimalControlFill }
        return slotActionAccents[max(0, slot - 1) % slotActionAccents.count]
    }
    static func slotActionAccent(_ slot: Int, scheme: ColorScheme) -> Color { slotActionAccent(slot) }

    private static let colorfulPreviewBackground = dyn(light: Color.black.opacity(0.035), dark: Color.black.opacity(0.22))
    static var previewBackground: Color {
        isMinimalSkin ? minimalPreviewBackground : colorfulPreviewBackground
    }
    static func previewBackground(_ scheme: ColorScheme) -> Color { previewBackground }

    private static let colorfulSubtleBorder = dyn(light: Color.black.opacity(0.075), dark: Color.white.opacity(0.10))
    static var subtleBorder: Color { isMinimalSkin ? minimalBorder : colorfulSubtleBorder }
    static func subtleBorder(_ scheme: ColorScheme) -> Color { subtleBorder }

    static let activeBorder = dynAccent(lightOpacity: 0.32, darkOpacity: 0.45)
    static func activeBorder(_ scheme: ColorScheme) -> Color { activeBorder }

    private static let cardShadowFilled = dyn(light: Color.black.opacity(0.09), dark: Color.black.opacity(0.30))
    private static let cardShadowEmpty = dyn(light: Color.black.opacity(0.035), dark: Color.black.opacity(0.16))
    static func cardShadow(isEmpty: Bool) -> Color {
        if isMinimalSkin { return isEmpty ? minimalShadowEmpty : minimalShadowFilled }
        return isEmpty ? cardShadowEmpty : cardShadowFilled
    }
    static func cardShadow(_ scheme: ColorScheme, isEmpty: Bool) -> Color { cardShadow(isEmpty: isEmpty) }

    /// 简洁模式的卡片投影半径：比多彩模式再收一档（6 → 4），配合极低的 alpha。
    static var cardShadowRadius: CGFloat { isMinimalSkin ? 4 : 6 }

    private static let slotBadgeEmptyBackground = dyn(light: Color.black.opacity(0.06),
                                                     dark: Color.white.opacity(0.08))
    static func slotBadgeBackground(isEmpty: Bool) -> AnyShapeStyle {
        if isMinimalSkin { return AnyShapeStyle(isEmpty ? slotBadgeEmptyBackground : minimalControlFill) }
        return isEmpty ? AnyShapeStyle(slotBadgeEmptyBackground) : AnyShapeStyle(brandGradient)
    }
    static func slotBadgeBackground(_ scheme: ColorScheme, isEmpty: Bool) -> AnyShapeStyle {
        slotBadgeBackground(isEmpty: isEmpty)
    }

    // MARK: - Chip

    private static let colorfulChipBackground = dyn(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.075))
    static var chipBackground: Color { isMinimalSkin ? minimalControlFill : colorfulChipBackground }
    static func chipBackground(_ scheme: ColorScheme) -> Color { chipBackground }

    private static let colorfulSoftButtonBackground = dyn(light: Color.black.opacity(0.055), dark: Color.white.opacity(0.08))
    static var softButtonBackground: Color { isMinimalSkin ? minimalControlFill : colorfulSoftButtonBackground }
    static func softButtonBackground(_ scheme: ColorScheme) -> Color { softButtonBackground }

    // MARK: - Radial Menu

    static let radialBackground = dyn(light: Color.white.opacity(0.40),
                                      dark: Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.46))
    static func radialBackground(_ scheme: ColorScheme) -> Color { radialBackground }

    static let radialCenterBackground = dyn(light: Color.white.opacity(0.54), dark: Color.black.opacity(0.22))
    static func radialCenterBackground(_ scheme: ColorScheme) -> Color { radialCenterBackground }

    private static let radialSegmentHovered = dynAccent(lightOpacity: 0.30, darkOpacity: 0.42)
    // v2.11.5：花瓣化之后静息态填充整体提浓（浅 0.10/0.18 → 0.17/0.30，深 0.018/0.045 → 0.05/0.10）。
    //
    // 原来的极淡填充是为「硬边扇形」调的：那时扇区彼此相接、靠分隔线划界，填充只需要
    // 隐约区分「空 / 有内容」。花瓣之间隔了 5pt 通道之后，填充要独自承担「这是一张卡片」
    // 的全部表达——0.018 的白在深色磨砂上根本看不出边界，十片花瓣会糊成一团雾。
    private static let radialSegmentEmpty = dyn(light: Color.white.opacity(0.17), dark: Color.white.opacity(0.05))
    private static let radialSegmentFilled = dyn(light: Color.white.opacity(0.30), dark: Color.white.opacity(0.10))
    static func radialSegment(isEmpty: Bool, isHovered: Bool) -> Color {
        if isHovered { return radialSegmentHovered }
        return isEmpty ? radialSegmentEmpty : radialSegmentFilled
    }
    static func radialSegment(_ scheme: ColorScheme, isEmpty: Bool, isHovered: Bool) -> Color {
        radialSegment(isEmpty: isEmpty, isHovered: isHovered)
    }

    /// 花瓣轮廓线（v2.11.5）。极细一圈（0.7pt），职责是把卡片的圆角边缘「收住」。
    ///
    /// 这笔预算是从删掉的径向分隔线那里挪来的：同样一条「划界」的线，画在卡片自己的边上
    /// 是卡片语义，画在两片花瓣正中间就是把留白重新填满。浓度刻意比原分隔线（浅 0.44）低
    /// 一半以上——轮廓要的是「有边界」，不是「有线条」。
    static let radialPetalEdge = dyn(light: Color.white.opacity(0.55), dark: Color.white.opacity(0.085))
    static func radialPetalEdge(_ scheme: ColorScheme) -> Color { radialPetalEdge }

    private static let radialStrokeIdle = dyn(light: Color.white.opacity(0.50), dark: Color.white.opacity(0.16))
    static func radialStroke(isHovered: Bool) -> Color {
        isHovered ? Color.accentColor.opacity(0.70) : radialStrokeIdle
    }
    static func radialStroke(_ scheme: ColorScheme, isHovered: Bool) -> Color { radialStroke(isHovered: isHovered) }

    // MARK: - Radial Menu · 槽位色跟随（v2.11.4）
    //
    // 在 v2.11.3 之前，圆盘的悬停反馈统一是「系统强调色蓝」：无论悬停第 1 格还是第 7 格，
    // 高亮都是同一种蓝。这让圆盘和主界面成了两套语言 —— 主界面每张卡片都有自己的槽位色，
    // 到了圆盘全被抹平，用户没法用颜色记住「绿色那格是我的常用文案」。
    //
    // v2.11.4 让悬停高亮与底栏「上次粘贴」胶囊都跟随槽位色。`slot` 传 nil（或非法值）时
    // 回落到原来的蓝色 / 玻璃灰，保证组扇区模式与「无上次粘贴记录」这两条路径行为不变。
    //
    // v2.11.4 hotfix4：悬停扇区**退出**槽位色跟随，换成一支统一的低饱和冷灰蓝。
    // 圆盘上同时有三处在讲槽位色（悬停填充、外沿「上次粘贴」弧、底栏胶囊），
    // 鼠标扫一圈就是五色相轮播，「哪一格被选中」这条信息被颜色噪声盖住了。
    // 现在职责切开：**槽位身份**只由外沿弧 + 底栏胶囊表达（不动），
    // **悬停/选中**由统一冷灰蓝表达。函数签名保留 `slot:` 不变，
    // 免得 40 多个调用点集体改写，也方便以后想回退时只改这一处。

    /// 统一悬停色的半透明动态版本。
    ///
    /// 与 `slotAccentTint` 同理不能写成 `Color(...).opacity(x)`：dynamic NSColor 包出来的 `Color`
    /// 上乘 alpha 会锁死在**当前**外观的解析结果，深浅切换时不重算。
    private static func hoverTint(opacity: Double) -> Color {
        let lightNS = NSColor(color(SlotAccentPalette.hoverAccentLight)).withAlphaComponent(opacity)
        let darkNS = NSColor(color(SlotAccentPalette.hoverAccentDark)).withAlphaComponent(opacity)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }

    private static let radialUnifiedHoverFill = hoverTint(opacity: SlotAccentPalette.hoverFillOpacity)
    private static let radialUnifiedHoverStroke = hoverTint(opacity: SlotAccentPalette.hoverStrokeOpacity)

    /// 悬停扇区填充：统一冷灰蓝 @0.25。透明度刻意留高，磨砂玻璃与扇区分界线要能透出来。
    ///
    /// `slot` 参数保留但不再参与取色（见上方 hotfix4 说明）。
    static func radialSegmentHoverFill(slot: Int?) -> Color {
        radialUnifiedHoverFill
    }

    /// 悬停扇区描边：统一冷灰蓝 @0.70，比填充实一档，负责「选中」的硬边界。
    static func radialSegmentHoverStroke(slot: Int?) -> Color {
        radialUnifiedHoverStroke
    }

    /// 底栏「上次粘贴」胶囊底色：槽位色 @0.28（无记录时回落玻璃灰）。
    static func radialSlotPillFill(slot: Int?) -> Color {
        guard let slot, slot >= 1 else { return radialGlassButtonTint }
        return slotAccentTint(slot, opacity: SlotAccentPalette.pillFillOpacity)
    }

    /// 底栏「上次粘贴」胶囊描边。
    static func radialSlotPillStroke(slot: Int?) -> Color {
        guard let slot, slot >= 1 else { return radialGlassButtonStroke }
        return slotAccentTint(slot, opacity: SlotAccentPalette.pillStrokeOpacity)
    }

    /// 底栏「上次粘贴」胶囊文字 / 图标色：按合成后亮度自动黑或白（无记录时回落玻璃文字色）。
    static func radialSlotPillText(slot: Int?) -> Color {
        guard let slot, slot >= 1 else { return radialGlassButtonText }
        return slotPillInk(slot)
    }

    static let radialDivider = dyn(light: Color.white.opacity(0.44), dark: Color.white.opacity(0.075))
    static func radialDivider(_ scheme: ColorScheme) -> Color { radialDivider }

    private static let radialPrimaryTextHovered = dyn(light: Color.black.opacity(0.82), dark: .white)
    private static let radialPrimaryTextEmpty = dyn(light: Color.black.opacity(0.28), dark: Color.white.opacity(0.28))
    private static let radialPrimaryTextFilled = dyn(light: Color.black.opacity(0.78), dark: Color.white.opacity(0.88))
    static func radialPrimaryText(isHovered: Bool, isEmpty: Bool) -> Color {
        if isHovered { return radialPrimaryTextHovered }
        return isEmpty ? radialPrimaryTextEmpty : radialPrimaryTextFilled
    }
    static func radialPrimaryText(_ scheme: ColorScheme, isHovered: Bool, isEmpty: Bool) -> Color {
        radialPrimaryText(isHovered: isHovered, isEmpty: isEmpty)
    }

    private static let radialSecondaryTextHovered = dyn(light: Color.black.opacity(0.58),
                                                        dark: Color.white.opacity(0.88))
    private static let radialSecondaryTextIdle = dyn(light: Color.black.opacity(0.52),
                                                     dark: Color.white.opacity(0.48))
    static func radialSecondaryText(isHovered: Bool) -> Color {
        isHovered ? radialSecondaryTextHovered : radialSecondaryTextIdle
    }
    static func radialSecondaryText(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        radialSecondaryText(isHovered: isHovered)
    }

    static let radialEmptyText = dyn(light: Color.black.opacity(0.30), dark: Color.white.opacity(0.26))
    static func radialEmptyText(_ scheme: ColorScheme) -> Color { radialEmptyText }

    // MARK: - Radial Segment Badges (v2.11.1)

    /// 扇区角标（非附件类）的图标色。刻意比编号更弱：它是「有没有」的信号，
    /// 不该跟槽位编号抢视觉权重。
    static let radialBadgeIcon = dyn(light: Color.black.opacity(0.58), dark: Color.white.opacity(0.70))
    static func radialBadgeIcon(_ scheme: ColorScheme) -> Color { radialBadgeIcon }

    /// 扇区**附件**角标（回形针）的图标色 —— 与主界面卡片「附件 N」胶囊同一套品牌蓝紫。
    ///
    /// 为什么不直接用 `brandGradient`：角标只有 9pt，渐变在这个尺寸上退化成一团糊色，
    /// 还会因为扇区方位不同而呈现不同色相（渐变是按 view bounds 取向的）。这里取渐变
    /// 起止色的**中点**做单色，色相与胶囊一致、在 9pt 上又足够干净：
    ///   light 0.36/0.49/1.00 ~ 0.50/0.35/1.00 → 0.43/0.42/1.00
    ///   dark  在中点基础上再提亮，保证压在深色扇区/手动封面图上仍然读得出是蓝紫而不是灰。
    static let radialAttachmentBadge = dyn(light: Color(red: 0.43, green: 0.42, blue: 1.00),
                                           dark: Color(red: 0.63, green: 0.59, blue: 1.00))
    static func radialAttachmentBadge(_ scheme: ColorScheme) -> Color { radialAttachmentBadge }

    /// 扇区角标的圆形底。给一点底色是为了在手动封面图/深色扇区上仍能辨认。
    static let radialBadgeFill = dyn(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.14))
    static func radialBadgeFill(_ scheme: ColorScheme) -> Color { radialBadgeFill }

    /// 附件角标的圆形底：换成同色系的极淡蓝紫，让 9pt 的回形针在浅底扇区上也有对比度。
    /// 只是把中性灰底替换成同色调，透明度与 `radialBadgeFill` 同档，不额外加重视觉。
    static let radialAttachmentBadgeFill = dyn(light: Color(red: 0.43, green: 0.42, blue: 1.00).opacity(0.14),
                                               dark: Color(red: 0.63, green: 0.59, blue: 1.00).opacity(0.20))
    static func radialAttachmentBadgeFill(_ scheme: ColorScheme) -> Color { radialAttachmentBadgeFill }

    static let radialShadow = dyn(light: Color.black.opacity(0.13), dark: Color.black.opacity(0.34))
    static func radialShadow(_ scheme: ColorScheme) -> Color { radialShadow }

    /// 材质档位没法做成动态值（Material 不是颜色），按当前 appearance 取。
    static func radialMaterial(_ scheme: ColorScheme) -> Material {
        scheme == .dark ? .thinMaterial : .ultraThinMaterial
    }

    static let radialOuterStroke = dyn(light: Color.white.opacity(0.70), dark: Color.white.opacity(0.18))
    static func radialOuterStroke(_ scheme: ColorScheme) -> Color { radialOuterStroke }

    static let radialOuterGlow = dyn(light: Color.white.opacity(0.55), dark: Color.white.opacity(0.045))
    static func radialOuterGlow(_ scheme: ColorScheme) -> Color { radialOuterGlow }

    static let radialInnerShadow = dyn(light: Color.black.opacity(0.06), dark: Color.black.opacity(0.24))
    static func radialInnerShadow(_ scheme: ColorScheme) -> Color { radialInnerShadow }

    // MARK: - Radial Menu HUD Overlay Text (v2.4.4) — 与 scheme 无关

    static let radialOverlayText = Color.white.opacity(0.94)
    static func radialOverlayText(_ scheme: ColorScheme) -> Color { radialOverlayText }

    static let radialOverlaySubtext = Color.white.opacity(0.82)
    static func radialOverlaySubtext(_ scheme: ColorScheme) -> Color { radialOverlaySubtext }

    static let radialOverlayTextShadow = Color.black.opacity(0.78)
    static func radialOverlayTextShadow(_ scheme: ColorScheme) -> Color { radialOverlayTextShadow }

    // MARK: - Radial Menu Glass Button (v2.4.5)

    static let radialGlassButtonTint = dyn(light: Color.white.opacity(0.46), dark: Color.black.opacity(0.22))
    static func radialGlassButtonTint(_ scheme: ColorScheme) -> Color { radialGlassButtonTint }

    static let radialGlassButtonStroke = dyn(light: Color.white.opacity(0.78), dark: Color.white.opacity(0.20))
    static func radialGlassButtonStroke(_ scheme: ColorScheme) -> Color { radialGlassButtonStroke }

    static let radialGlassButtonInnerStroke = dyn(light: Color.black.opacity(0.05), dark: Color.black.opacity(0.18))
    static func radialGlassButtonInnerStroke(_ scheme: ColorScheme) -> Color { radialGlassButtonInnerStroke }

    static let radialGlassButtonText = dyn(light: Color.black.opacity(0.78), dark: Color.white.opacity(0.92))
    static func radialGlassButtonText(_ scheme: ColorScheme) -> Color { radialGlassButtonText }

    static let radialGlassButtonShadow = dyn(light: Color.black.opacity(0.08), dark: Color.black.opacity(0.22))
    static func radialGlassButtonShadow(_ scheme: ColorScheme) -> Color { radialGlassButtonShadow }

    // MARK: - Radial Menu 底栏中性动作按钮（v2.11.4 hotfix4）
    //
    // 「全部粘贴」原先用 `Color.accentColor`（0.16 底 / 0.35 描边）。两个问题：
    //   1. accentColor 跟随系统偏好设置，用户设成粉 / 橙 / 石墨时，底栏会跟着换色，
    //      而它旁边就是跟随槽位色的「上次粘贴」胶囊 —— 两块彩色贴片抢同一条底栏；
    //   2. 「全部粘贴」是一个**无差别批量动作**，不隶属任何槽位，本来就没有色彩身份可言。
    //
    // 现在改成中性灰：浅色下在磨砂玻璃上压一层黑（→ 浅灰），深色下提一层白（→ 深灰），
    // 与系统默认 bezel 按钮同一路数。底栏的彩色配额留给唯一真正需要它的「上次粘贴」。
    static let radialNeutralActionFill = dyn(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.10))
    static func radialNeutralActionFill(_ scheme: ColorScheme) -> Color { radialNeutralActionFill }

    static let radialNeutralActionStroke = dyn(light: Color.black.opacity(0.14), dark: Color.white.opacity(0.20))
    static func radialNeutralActionStroke(_ scheme: ColorScheme) -> Color { radialNeutralActionStroke }

    static let radialNeutralActionText = dyn(light: Color.black.opacity(0.80), dark: Color.white.opacity(0.92))
    static func radialNeutralActionText(_ scheme: ColorScheme) -> Color { radialNeutralActionText }

    // MARK: - Search Field (v2.5)

    private static let colorfulSearchFieldBackground = dyn(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.06))
    static var searchFieldBackground: Color { isMinimalSkin ? minimalControlFill : colorfulSearchFieldBackground }
    static func searchFieldBackground(_ scheme: ColorScheme) -> Color { searchFieldBackground }

    private static let colorfulSearchFieldStroke = dyn(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.10))
    static var searchFieldStroke: Color { isMinimalSkin ? minimalBorder : colorfulSearchFieldStroke }
    static func searchFieldStroke(_ scheme: ColorScheme) -> Color { searchFieldStroke }

    // MARK: - Filter Chips (v2.5)

    private static let colorfulFilterChipBackground = dyn(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.05))
    static var filterChipBackground: Color { isMinimalSkin ? minimalControlFill : colorfulFilterChipBackground }
    static func filterChipBackground(_ scheme: ColorScheme) -> Color { filterChipBackground }

    static let filterChipSelectedBackground = dynAccent(lightOpacity: 0.16, darkOpacity: 0.28)
    static func filterChipSelectedBackground(_ scheme: ColorScheme) -> Color { filterChipSelectedBackground }

    static let filterChipText = dyn(light: Color.black.opacity(0.66), dark: Color.white.opacity(0.72))
    static func filterChipText(_ scheme: ColorScheme) -> Color { filterChipText }

    // MARK: - v2.10.93 · 原先散落在各视图里的 `colorScheme == .dark ? A : B` 内联取色
    // 收敛为动态 token。收敛的目的不是"整洁"，而是**让这些视图不再需要读 colorScheme**
    // —— 只要读了，切主题时它们的 body（连带内部所有文字的重新排版）就必须整棵重算。

    /// 卡片操作按钮：禁用态底色。
    static let actionButtonDisabledBackground = dyn(light: Color.black.opacity(0.10),
                                                    dark: Color.white.opacity(0.13))
    /// 卡片操作按钮：危险操作激活态底色。
    ///
    /// 简洁模式**不**把它收成灰：这是「再点一次就真的删了」的二次确认态，红色在这里不是装饰，
    /// 是安全信号。简洁模式收的是常态装饰色，不是功能色。
    static let actionButtonDangerActiveBackground = dyn(light: AppTheme.danger.opacity(0.14),
                                                        dark: AppTheme.danger)
    /// 卡片操作按钮：危险操作静息态底色。
    private static let colorfulActionButtonDangerIdleBackground = dyn(light: Color.black.opacity(0.075),
                                                                      dark: Color(red: 0.20, green: 0.21, blue: 0.23))
    static var actionButtonDangerIdleBackground: Color {
        isMinimalSkin ? minimalControlFill : colorfulActionButtonDangerIdleBackground
    }
    /// 卡片操作按钮：强调色按钮上的文字（多彩模式两套主题都用深墨色压在鲜亮槽位色上以保对比度）。
    private static let colorfulActionButtonAccentText = dyn(light: Color.black.opacity(0.72),
                                                            dark: Color.black.opacity(0.82))
    static var actionButtonAccentText: Color {
        // 简洁模式的按钮底已经是中性灰，再压深墨色就会在深色下变成黑底黑字。
        isMinimalSkin ? minimalControlInk : colorfulActionButtonAccentText
    }
    /// 卡片操作按钮：危险操作静息态文字。
    private static let colorfulActionButtonDangerIdleText = dyn(light: Color.black.opacity(0.68), dark: .white)
    static var actionButtonDangerIdleText: Color {
        isMinimalSkin ? minimalControlInk : colorfulActionButtonDangerIdleText
    }

    /// 顶部工具条上的软性胶囊底/描边（原 ContentView 内联取色）。
    static let capsuleFill = dyn(light: Color.primary.opacity(0.055), dark: Color.primary.opacity(0.09))
    static let capsuleStroke = dyn(light: Color.secondary.opacity(0.13), dark: Color.secondary.opacity(0.20))
    /// 深色下用黑字、浅色下用白字的反色前景（游标胶囊里的高亮数字）。
    static let invertedOnAccentText = dyn(light: .white, dark: .black)
    /// 组标签栏未选中项底色。
    static let groupTagIdleFill = dyn(light: Color.primary.opacity(0.07), dark: Color.primary.opacity(0.12))
    /// 搜索结果区强调描边。
    static let accentHairline = dynAccent(lightOpacity: 0.08, darkOpacity: 0.16)

    static let filterChipSelectedText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor.controlAccentColor
    })
    static func filterChipSelectedText(_ scheme: ColorScheme) -> Color { filterChipSelectedText }
}
