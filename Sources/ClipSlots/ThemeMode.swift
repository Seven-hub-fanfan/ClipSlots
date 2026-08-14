import SwiftUI
import ClipSlotsKit

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    // MARK: - v2.10.91 (修复「AppKit 弹窗没有浅色界面」)

    /// 本主题对应的 AppKit 外观；`.system` 返回 nil 表示「跟随系统」。
    ///
    /// 为什么需要它：此前 App 的主题**只**通过 SwiftUI 的 `.preferredColorScheme` 应用
    /// （见 main.swift 的根视图、RadialMenuWindowController、FloatingNoticeWindowController）。
    /// 但 `.preferredColorScheme` 的作用域仅限 SwiftUI 视图层级——由 AppKit 自己拥有、
    /// 不在该层级内的界面（`NSAlert` 确认框、`NSMenu`、`NSOpenPanel`/`NSSavePanel`、
    /// 代码创建的 `NSPopover` 等）跟随的是 `NSApp.effectiveAppearance`，而 `NSApp.appearance`
    /// 从来没被设置过 → 它们一律跟随**系统**外观。
    ///
    /// 于是出现这个 bug：App 内选了「浅色」但 macOS 处于深色时，删除槽位组/清空等确认弹窗
    /// 仍是深色，看起来就是「这个弹窗没有浅色界面」。反之亦然。
    ///
    /// 修法是在主题变化时同步设置 `NSApp.appearance`（见 AppDelegate.applyAppAppearance），
    /// 一处生效、覆盖全部 AppKit 界面，无需逐个 NSAlert 去设 window.appearance。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}
