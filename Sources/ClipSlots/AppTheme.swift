import SwiftUI
import AppKit

enum AppTheme {
    static let cornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8

    // MARK: - Window

    static func windowBackground(_ scheme: ColorScheme) -> Color {
        Color(NSColor.controlBackgroundColor)
    }

    // MARK: - Card

    static func cardBackground(_ scheme: ColorScheme, isEmpty: Bool = false) -> Color {
        if scheme == .dark {
            return Color(NSColor.controlBackgroundColor).opacity(isEmpty ? 0.45 : 0.9)
        } else {
            return Color(NSColor.controlBackgroundColor).opacity(isEmpty ? 0.55 : 1.0)
        }
    }

    static func previewBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.textBackgroundColor).opacity(0.75)
            : Color(NSColor.textBackgroundColor)
    }

    static func subtleBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    static func activeBorder(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.35 : 0.25)
    }

    static func cardShadow(_ scheme: ColorScheme, isEmpty: Bool) -> Color {
        scheme == .dark
            ? Color.black.opacity(isEmpty ? 0.10 : 0.22)
            : Color.black.opacity(isEmpty ? 0.02 : 0.06)
    }

    // MARK: - Radial Menu

    static func radialBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.82)
            : Color.white.opacity(0.86)
    }

    static func radialCenterBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.68)
            : Color.white.opacity(0.72)
    }

    static func radialSegment(_ scheme: ColorScheme, isEmpty: Bool, isHovered: Bool) -> Color {
        if isHovered {
            return Color.accentColor.opacity(scheme == .dark ? 0.75 : 0.65)
        }
        if isEmpty {
            return scheme == .dark
                ? Color.white.opacity(0.04)
                : Color.black.opacity(0.035)
        }
        return scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.055)
    }

    static func radialStroke(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor }
        return scheme == .dark
            ? Color.white.opacity(0.15)
            : Color.black.opacity(0.10)
    }

    static func radialDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.10)
    }

    static func radialPrimaryText(_ scheme: ColorScheme, isHovered: Bool, isEmpty: Bool) -> Color {
        if isHovered { return .white }
        if isEmpty {
            return scheme == .dark
                ? Color.white.opacity(0.25)
                : Color.black.opacity(0.25)
        }
        return scheme == .dark
            ? Color.white.opacity(0.85)
            : Color.black.opacity(0.78)
    }

    static func radialSecondaryText(_ scheme: ColorScheme, isHovered: Bool) -> Color {
        if isHovered { return .white.opacity(0.85) }
        return scheme == .dark
            ? Color.white.opacity(0.42)
            : Color.black.opacity(0.48)
    }

    static func radialEmptyText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.25)
    }

    static func radialShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.55)
            : Color.black.opacity(0.18)
    }

    static func radialMaterial(_ scheme: ColorScheme) -> Material {
        scheme == .dark ? .ultraThinMaterial : .regularMaterial
    }
}
