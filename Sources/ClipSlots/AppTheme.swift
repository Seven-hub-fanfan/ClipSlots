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
            ? Color(red: 0.07, green: 0.075, blue: 0.09).opacity(0.90)
            : Color.white.opacity(0.90)
    }

    static func radialCenterBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.35)
            : Color.white.opacity(0.76)
    }

    static func radialSegment(_ scheme: ColorScheme, isEmpty: Bool, isHovered: Bool) -> Color {
        if isHovered {
            return Color.accentColor.opacity(scheme == .dark ? 0.78 : 0.68)
        }
        if isEmpty {
            return scheme == .dark
                ? Color.white.opacity(0.035)
                : Color.black.opacity(0.030)
        }
        return scheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.052)
    }

    static func radialStroke(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor.opacity(0.95) }
        return scheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.09)
    }

    static func radialDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.11)
            : Color.black.opacity(0.085)
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
            ? Color.black.opacity(0.62)
            : Color.black.opacity(0.20)
    }

    static func radialMaterial(_ scheme: ColorScheme) -> Material {
        scheme == .dark ? .ultraThinMaterial : .regularMaterial
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
            ? Color.black.opacity(0.28)
            : Color.white.opacity(0.42)
    }

    static func radialGlassButtonStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.18)
            : Color.white.opacity(0.72)
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
}
