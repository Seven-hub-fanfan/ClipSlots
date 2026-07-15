import SwiftUI
import ClipSlotsKit
import AppKit

enum AppTheme {
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    static let cardPadding: CGFloat = 14
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

    // MARK: - Brand

    static func brandGradient(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [
                    Color(red: 0.42, green: 0.50, blue: 1.00),
                    Color(red: 0.56, green: 0.36, blue: 1.00)
                ]
                : [
                    Color(red: 0.36, green: 0.49, blue: 1.00),
                    Color(red: 0.50, green: 0.35, blue: 1.00)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var success: Color {
        Color(red: 0.20, green: 0.78, blue: 0.35)
    }

    static var warning: Color {
        Color(red: 1.00, green: 0.62, blue: 0.04)
    }

    static var danger: Color {
        Color(red: 1.00, green: 0.27, blue: 0.23)
    }

    /// 位于彩色 / 品牌渐变背景上的文字色（此前各视图裸写 `.white`，v2.9.18 收敛于此）。
    static let onAccentText: Color = .white

    // MARK: - Floating Notice (v2.9.18 — 收敛 FloatingNotice 此前自实现的一套 RGB 到主题)
    // 悬浮提示需要不透明实心底色，AppTheme 其余 background 都是半透明，故单列 opaque token。

    static func noticeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.13)
            : Color(red: 0.97, green: 0.97, blue: 0.98)
    }

    static func noticeBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.24, green: 0.24, blue: 0.26)
            : Color(red: 0.84, green: 0.84, blue: 0.86)
    }

    static func noticeSubtitle(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.72, green: 0.72, blue: 0.75)
            : Color(red: 0.38, green: 0.38, blue: 0.42)
    }

    // MARK: - Window

    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.075, green: 0.078, blue: 0.088)
            : Color(red: 0.965, green: 0.970, blue: 0.980)
    }

    static func elevatedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color.white.opacity(0.82)
    }

    static func headerBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.04)
            : Color.white.opacity(0.72)
    }

    // MARK: - Card

    static func cardBackground(_ scheme: ColorScheme, isEmpty: Bool = false) -> Color {
        if scheme == .dark {
            return Color.white.opacity(isEmpty ? 0.045 : 0.075)
        } else {
            return Color.white.opacity(isEmpty ? 0.62 : 0.92)
        }
    }

    static func previewBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.22)
            : Color.black.opacity(0.035)
    }

    static func subtleBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.075)
    }

    static func activeBorder(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.45 : 0.32)
    }

    static func cardShadow(_ scheme: ColorScheme, isEmpty: Bool) -> Color {
        scheme == .dark
            ? Color.black.opacity(isEmpty ? 0.16 : 0.30)
            : Color.black.opacity(isEmpty ? 0.035 : 0.09)
    }

    static func slotBadgeBackground(_ scheme: ColorScheme, isEmpty: Bool) -> AnyShapeStyle {
        if isEmpty {
            return AnyShapeStyle(
                scheme == .dark
                    ? Color.white.opacity(0.08)
                    : Color.black.opacity(0.06)
            )
        }
        return AnyShapeStyle(brandGradient(scheme))
    }

    // MARK: - Chip

    static func chipBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.075)
            : Color.black.opacity(0.045)
    }

    static func softButtonBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.055)
    }

    // MARK: - Radial Menu

    static func radialBackground(_ scheme: ColorScheme) -> Color {
        // v2.7.38: glassmorphism radial surface. Avoid the old heavy black/white disk.
        scheme == .dark
            ? Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.46)
            : Color.white.opacity(0.40)
    }

    static func radialCenterBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.22)
            : Color.white.opacity(0.54)
    }

    static func radialSegment(_ scheme: ColorScheme, isEmpty: Bool, isHovered: Bool) -> Color {
        if isHovered {
            return Color.accentColor.opacity(scheme == .dark ? 0.42 : 0.30)
        }
        if isEmpty {
            return scheme == .dark
                ? Color.white.opacity(0.018)
                : Color.white.opacity(0.10)
        }
        return scheme == .dark
            ? Color.white.opacity(0.045)
            : Color.white.opacity(0.18)
    }

    static func radialStroke(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor.opacity(0.70) }
        return scheme == .dark
            ? Color.white.opacity(0.16)
            : Color.white.opacity(0.50)
    }

    static func radialDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.075)
            : Color.white.opacity(0.44)
    }

    static func radialPrimaryText(_ scheme: ColorScheme, isHovered: Bool, isEmpty: Bool) -> Color {
        if isHovered { return scheme == .dark ? .white : Color.black.opacity(0.82) }
        if isEmpty {
            return scheme == .dark
                ? Color.white.opacity(0.28)
                : Color.black.opacity(0.28)
        }
        return scheme == .dark
            ? Color.white.opacity(0.88)
            : Color.black.opacity(0.78)
    }

    static func radialSecondaryText(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        if isHovered { return scheme == .dark ? .white.opacity(0.88) : Color.black.opacity(0.58) }
        return scheme == .dark
            ? Color.white.opacity(0.48)
            : Color.black.opacity(0.52)
    }

    static func radialEmptyText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.26)
            : Color.black.opacity(0.30)
    }

    static func radialShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.34)
            : Color.black.opacity(0.13)
    }

    static func radialMaterial(_ scheme: ColorScheme) -> Material {
        scheme == .dark ? .thinMaterial : .ultraThinMaterial
    }

    static func radialOuterStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.70)
    }

    static func radialOuterGlow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.55)
    }

    static func radialInnerShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.06)
    }

    // MARK: - Radial Menu HUD Overlay Text (v2.4.4)

    static func radialOverlayText(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(0.94)
    }

    static func radialOverlaySubtext(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(0.82)
    }

    static func radialOverlayTextShadow(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(0.78)
    }

    // MARK: - Radial Menu Glass Button (v2.4.5)

    static func radialGlassButtonTint(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.22)
            : Color.white.opacity(0.46)
    }

    static func radialGlassButtonStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.20)
            : Color.white.opacity(0.78)
    }

    static func radialGlassButtonInnerStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.18)
            : Color.black.opacity(0.05)
    }

    static func radialGlassButtonText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.78)
    }

    static func radialGlassButtonShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.22)
            : Color.black.opacity(0.08)
    }

    // MARK: - Search Field (v2.5)

    static func searchFieldBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    static func searchFieldStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    // MARK: - Filter Chips (v2.5)

    static func filterChipBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.04)
    }

    static func filterChipSelectedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.accentColor.opacity(0.28)
            : Color.accentColor.opacity(0.16)
    }

    static func filterChipText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.72)
            : Color.black.opacity(0.66)
    }

    static func filterChipSelectedText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.96)
            : Color.accentColor
    }
}
