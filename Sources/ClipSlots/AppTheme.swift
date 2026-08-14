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

    static let windowBackground = dyn(light: Color(red: 0.965, green: 0.970, blue: 0.980),
                                      dark: Color(red: 0.075, green: 0.078, blue: 0.088))
    static func windowBackground(_ scheme: ColorScheme) -> Color { windowBackground }

    static let elevatedBackground = dyn(light: Color.white.opacity(0.82),
                                        dark: Color.white.opacity(0.055))
    static func elevatedBackground(_ scheme: ColorScheme) -> Color { elevatedBackground }

    static let headerBackground = dyn(light: Color.white.opacity(0.72),
                                      dark: Color.white.opacity(0.04))
    static func headerBackground(_ scheme: ColorScheme) -> Color { headerBackground }

    // MARK: - Card

    static let cardBackgroundFilled = dyn(light: Color(red: 0.995, green: 0.99, blue: 0.98),
                                          dark: Color(red: 0.105, green: 0.108, blue: 0.115).opacity(0.98))
    static let cardBackgroundEmpty = dyn(light: Color(red: 0.965, green: 0.955, blue: 0.935),
                                         dark: Color(red: 0.105, green: 0.108, blue: 0.115).opacity(0.92))
    static func cardBackground(isEmpty: Bool = false) -> Color {
        isEmpty ? cardBackgroundEmpty : cardBackgroundFilled
    }
    static func cardBackground(_ scheme: ColorScheme, isEmpty: Bool = false) -> Color {
        cardBackground(isEmpty: isEmpty)
    }

    /// A restrained, single-color identity per slot. The palette deliberately cycles
    /// instead of blending, so each card has one clear accent.
    ///
    /// v2.10.93: 深/浅两套调色板合并成一套动态色（原先是两个 `static let [Color]`，
    /// 由调用方按 scheme 选数组 —— 那正是逼着卡片必须读 colorScheme 的原因之一）。
    private static let slotAccents: [Color] = [
        dyn(light: Color(red: 0.12, green: 0.56, blue: 0.28), dark: Color(red: 0.42, green: 0.82, blue: 0.55)),
        dyn(light: Color(red: 0.72, green: 0.49, blue: 0.04), dark: Color(red: 0.94, green: 0.76, blue: 0.32)),
        dyn(light: Color(red: 0.78, green: 0.31, blue: 0.08), dark: Color(red: 0.95, green: 0.55, blue: 0.31)),
        dyn(light: Color(red: 0.72, green: 0.24, blue: 0.43), dark: Color(red: 0.91, green: 0.48, blue: 0.64)),
        dyn(light: Color(red: 0.16, green: 0.46, blue: 0.70), dark: Color(red: 0.48, green: 0.72, blue: 0.92))
    ]

    static func slotAccent(_ slot: Int) -> Color {
        slotAccents[max(0, slot - 1) % slotAccents.count]
    }
    static func slotAccent(_ slot: Int, scheme: ColorScheme) -> Color { slotAccent(slot) }

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
        slotActionAccents[max(0, slot - 1) % slotActionAccents.count]
    }
    static func slotActionAccent(_ slot: Int, scheme: ColorScheme) -> Color { slotActionAccent(slot) }

    static let previewBackground = dyn(light: Color.black.opacity(0.035), dark: Color.black.opacity(0.22))
    static func previewBackground(_ scheme: ColorScheme) -> Color { previewBackground }

    static let subtleBorder = dyn(light: Color.black.opacity(0.075), dark: Color.white.opacity(0.10))
    static func subtleBorder(_ scheme: ColorScheme) -> Color { subtleBorder }

    static let activeBorder = dynAccent(lightOpacity: 0.32, darkOpacity: 0.45)
    static func activeBorder(_ scheme: ColorScheme) -> Color { activeBorder }

    static let cardShadowFilled = dyn(light: Color.black.opacity(0.09), dark: Color.black.opacity(0.30))
    static let cardShadowEmpty = dyn(light: Color.black.opacity(0.035), dark: Color.black.opacity(0.16))
    static func cardShadow(isEmpty: Bool) -> Color { isEmpty ? cardShadowEmpty : cardShadowFilled }
    static func cardShadow(_ scheme: ColorScheme, isEmpty: Bool) -> Color { cardShadow(isEmpty: isEmpty) }

    private static let slotBadgeEmptyBackground = dyn(light: Color.black.opacity(0.06),
                                                     dark: Color.white.opacity(0.08))
    static func slotBadgeBackground(isEmpty: Bool) -> AnyShapeStyle {
        isEmpty ? AnyShapeStyle(slotBadgeEmptyBackground) : AnyShapeStyle(brandGradient)
    }
    static func slotBadgeBackground(_ scheme: ColorScheme, isEmpty: Bool) -> AnyShapeStyle {
        slotBadgeBackground(isEmpty: isEmpty)
    }

    // MARK: - Chip

    static let chipBackground = dyn(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.075))
    static func chipBackground(_ scheme: ColorScheme) -> Color { chipBackground }

    static let softButtonBackground = dyn(light: Color.black.opacity(0.055), dark: Color.white.opacity(0.08))
    static func softButtonBackground(_ scheme: ColorScheme) -> Color { softButtonBackground }

    // MARK: - Radial Menu

    static let radialBackground = dyn(light: Color.white.opacity(0.40),
                                      dark: Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.46))
    static func radialBackground(_ scheme: ColorScheme) -> Color { radialBackground }

    static let radialCenterBackground = dyn(light: Color.white.opacity(0.54), dark: Color.black.opacity(0.22))
    static func radialCenterBackground(_ scheme: ColorScheme) -> Color { radialCenterBackground }

    private static let radialSegmentHovered = dynAccent(lightOpacity: 0.30, darkOpacity: 0.42)
    private static let radialSegmentEmpty = dyn(light: Color.white.opacity(0.10), dark: Color.white.opacity(0.018))
    private static let radialSegmentFilled = dyn(light: Color.white.opacity(0.18), dark: Color.white.opacity(0.045))
    static func radialSegment(isEmpty: Bool, isHovered: Bool) -> Color {
        if isHovered { return radialSegmentHovered }
        return isEmpty ? radialSegmentEmpty : radialSegmentFilled
    }
    static func radialSegment(_ scheme: ColorScheme, isEmpty: Bool, isHovered: Bool) -> Color {
        radialSegment(isEmpty: isEmpty, isHovered: isHovered)
    }

    private static let radialStrokeIdle = dyn(light: Color.white.opacity(0.50), dark: Color.white.opacity(0.16))
    static func radialStroke(isHovered: Bool) -> Color {
        isHovered ? Color.accentColor.opacity(0.70) : radialStrokeIdle
    }
    static func radialStroke(_ scheme: ColorScheme, isHovered: Bool) -> Color { radialStroke(isHovered: isHovered) }

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

    // MARK: - Search Field (v2.5)

    static let searchFieldBackground = dyn(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.06))
    static func searchFieldBackground(_ scheme: ColorScheme) -> Color { searchFieldBackground }

    static let searchFieldStroke = dyn(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.10))
    static func searchFieldStroke(_ scheme: ColorScheme) -> Color { searchFieldStroke }

    // MARK: - Filter Chips (v2.5)

    static let filterChipBackground = dyn(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.05))
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
    static let actionButtonDangerActiveBackground = dyn(light: AppTheme.danger.opacity(0.14),
                                                        dark: AppTheme.danger)
    /// 卡片操作按钮：危险操作静息态底色。
    static let actionButtonDangerIdleBackground = dyn(light: Color.black.opacity(0.075),
                                                      dark: Color(red: 0.20, green: 0.21, blue: 0.23))
    /// 卡片操作按钮：强调色按钮上的文字（两套主题都用深墨色压在鲜亮槽位色上以保对比度）。
    static let actionButtonAccentText = dyn(light: Color.black.opacity(0.72),
                                            dark: Color.black.opacity(0.82))
    /// 卡片操作按钮：危险操作静息态文字。
    static let actionButtonDangerIdleText = dyn(light: Color.black.opacity(0.68), dark: .white)

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
