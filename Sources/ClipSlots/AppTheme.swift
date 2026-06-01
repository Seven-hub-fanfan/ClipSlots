import SwiftUI
import AppKit

enum AppTheme {
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    static let cardPadding: CGFloat = 14
    static let pagePadding: CGFloat = 20

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
        scheme == .dark
            ? Color.white.opacity(0.045)
            : Color.white.opacity(0.34)
    }

    static func radialCenterBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.35)
            : Color.white.opacity(0.76)
    }

    static func radialSegment(_ scheme: ColorScheme, isEmpty: Bool, isHovered: Bool) -> Color {
        if isHovered {
            return Color.accentColor.opacity(scheme == .dark ? 0.32 : 0.18)
        }
        if isEmpty {
            return scheme == .dark
                ? Color.white.opacity(0.018)
                : Color.white.opacity(0.12)
        }
        return scheme == .dark
            ? Color.white.opacity(0.040)
            : Color.white.opacity(0.24)
    }

    static func radialStroke(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor.opacity(0.95) }
        return scheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.09)
    }

    static func radialDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.075)
            : Color.black.opacity(0.045)
    }

    static func radialPrimaryText(_ scheme: ColorScheme, isHovered: Bool, isEmpty: Bool) -> Color {
        if isHovered { return .white }
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
        if isHovered { return .white.opacity(0.88) }
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
            ? Color.black.opacity(0.38)
            : Color.black.opacity(0.08)
    }

    static func radialMaterial(_ scheme: ColorScheme) -> Material {
        scheme == .dark ? .ultraThinMaterial : .regularMaterial
    }

    // MARK: - Radial Menu (v2.4.3 new)

    static func radialPanelBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.075, green: 0.078, blue: 0.090).opacity(0.82)
            : Color.white.opacity(0.72)
    }

    static func radialPanelMaterial(_ scheme: ColorScheme) -> Material {
        scheme == .dark ? .ultraThinMaterial : .thinMaterial
    }

    static func radialPanelStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.70)
    }

    static func radialOuterStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.60)
    }

    static func radialCircleShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.22)
            : Color.black.opacity(0.045)
    }

    static func radialShadowSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.34)
            : Color.black.opacity(0.075)
    }

    static func radialShadowAmbient(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.18)
            : Color.black.opacity(0.04)
    }

    static func radialControlBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.070)
            : Color.white.opacity(0.62)
    }

    static func radialControlStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.055)
    }

    // MARK: - Settings (v2.4.3)

    static func settingsWindowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.075, green: 0.078, blue: 0.090)
            : Color(red: 0.965, green: 0.968, blue: 0.975)
    }

    static func settingsCardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color.white.opacity(0.82)
    }

    static func settingsCardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.075)
    }

    static func settingsInputBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.045)
    }

    static func settingsInputStroke(_ scheme: ColorScheme, isFocused: Bool) -> Color {
        if isFocused {
            return Color.accentColor.opacity(scheme == .dark ? 0.70 : 0.65)
        }
        return scheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.065)
    }

    static func settingsFooterBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.20)
            : Color.black.opacity(0.035)
    }

    static func settingsBadgeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.055)
    }
}
