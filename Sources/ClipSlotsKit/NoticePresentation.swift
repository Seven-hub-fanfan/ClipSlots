import CoreGraphics
import Foundation

// MARK: - Toast / 浮层通知的投递通道与几何（v2.11.7 hotfix13）
//
// 这个文件解决的是一个「同一条通知被弹了两次」的 bug，以及顺带把 Toast 的几何常量从视图里
// 抽出来变成可断言的纯数据。
//
// **重复弹出的根因**：v2.6.3 给通知加了一个跨 App 可见的全局 HUD 面板
// （`FloatingNoticeWindowController`），目的是「热键从 Finder 存图时主窗口不在前台也能看到反馈」。
// 但当时的实现是在 `showFloatingNotice` 里**无条件**同时做两件事：
//
//   1. `transientUI.floatingNotice = notice`  → 主窗口内的 SwiftUI 覆盖层渲染一张卡片
//   2. `FloatingNoticeWindowController.show`  → 再开一个 NSPanel 渲染**同一个** FloatingNoticeView
//
// 于是「主窗口就在眼前」这种最常见的情况下，两个通道同时命中，用户看到的就是两张一模一样的卡片
// （截图里的「已保存到槽位 1 / 图片 · 702×444」× 2）。它不是触发了两次业务逻辑——业务侧只调了
// 一次 `showFloatingNotice`，是**渲染通道重复**。
//
// 因此修复的正确层次不是「去抖 / 加锁 / 比对上一条内容」，而是把两个通道变成**互斥**的：
// 同一条通知只允许走一条通道。这里的 `NoticePresentationRouter` 就是这条选择逻辑的纯函数版本，
// 与 AppKit 解耦后可以被 smoke 直接断言「任何窗口状态组合下都只返回一个通道」。

/// 一条通知的投递通道。二者**互斥**：同一条通知只允许命中其中一个。
public enum NoticeChannel: String, Equatable, Sendable {
    /// 画在主窗口内部的 SwiftUI 覆盖层（跟随皮肤、有进出场动画、位置贴着窗口顶部）。
    case inline
    /// 独立的非激活 HUD 面板（跨 App / 跨 Space 可见），用于主窗口看不见时。
    case hud
}

/// 主窗口的可见性快照。由 App 层从 AppKit 读出后传进来，保持本类型可测。
public struct NoticeWindowState: Equatable, Sendable {
    /// App 是否处于激活态（`NSApp.isActive`）。
    public let appActive: Bool
    /// 是否存在一个可见的主窗口（`window.isVisible`）。
    public let mainWindowVisible: Bool
    /// 主窗口是否被最小化到 Dock。
    public let mainWindowMiniaturized: Bool
    /// 主窗口是否被其他窗口完全遮挡（`occlusionState` 不含 `.visible`）。
    public let mainWindowOccluded: Bool

    public init(appActive: Bool,
                mainWindowVisible: Bool,
                mainWindowMiniaturized: Bool,
                mainWindowOccluded: Bool) {
        self.appActive = appActive
        self.mainWindowVisible = mainWindowVisible
        self.mainWindowMiniaturized = mainWindowMiniaturized
        self.mainWindowOccluded = mainWindowOccluded
    }
}

/// 通知投递通道的选择器（纯函数，无 AppKit 依赖）。
public enum NoticePresentationRouter {

    /// 选出**唯一**的投递通道。
    ///
    /// 判据只有一条：用户此刻能不能在主窗口里看到这张卡片？
    /// - 能看到（App 在前台 + 主窗口可见 + 没最小化 + 没被完全遮挡）→ `.inline`。
    ///   窗内卡片跟随皮肤、贴着窗口顶部，是「在应用里操作」时最自然的反馈位置。
    /// - 看不到（热键从 Finder / 浏览器触发、窗口最小化或被挡住）→ `.hud`。
    ///   这正是 v2.6.3 引入 HUD 的初衷，此时窗内卡片画了也没人看得见。
    public static func channel(for state: NoticeWindowState) -> NoticeChannel {
        guard state.appActive,
              state.mainWindowVisible,
              !state.mainWindowMiniaturized,
              !state.mainWindowOccluded else {
            return .hud
        }
        return .inline
    }
}

/// Toast / 浮层通知的外观几何常量（v2.11.7 hotfix13 重新设计）。
///
/// 两种皮肤**共用同一套几何**，只有颜色与材质不同 —— 与 `NeumorphicMetrics` 的约定一致：
/// 皮肤差异不允许改尺寸，否则切皮肤会看出「跳一下」。
public enum NoticeMetrics {

    /// 卡片圆角。
    public static let cornerRadius: CGFloat = 12

    /// 卡片最大宽度。超出后副标题居中截断，不允许把卡片撑成横贯窗口的一条。
    public static let maxWidth: CGFloat = 280

    /// 卡片最小宽度。太短的文案（「已复制」）配上图标如果完全贴合内容，会缩成一颗小药丸，
    /// 在顶部很难被注意到。
    public static let minWidth: CGFloat = 132

    /// 卡片距**窗口顶部**的距离。两种皮肤、两种通道（窗内 / HUD）统一。
    public static let topInset: CGFloat = 16

    /// 卡片内边距。
    public static let horizontalPadding: CGFloat = 12
    public static let verticalPadding: CGFloat = 9

    /// 图标与文字块的间距，以及图标字号（「小而精致」：比原来的 20pt 收到 14pt）。
    public static let iconTextSpacing: CGFloat = 8
    public static let iconSize: CGFloat = 14

    /// 标题 / 副标题字号（原来是 14 / 12，整体收一档，避免一张 Toast 抢主界面的视觉权重）。
    public static let titleFontSize: CGFloat = 12.5
    public static let subtitleFontSize: CGFloat = 10.5

    /// HUD 面板为投影预留的四周留白。NSPanel 的 contentView 会裁掉超出边界的绘制，
    /// 不留白的话多彩模式那圈 blur 12 的投影会被切成硬边。
    public static let hudShadowPadding: CGFloat = 16

    /// 卡片宽度：**自适应内容、封顶 280pt**。
    ///
    /// 为什么要自己算而不是写 `.frame(maxWidth: 280)`：SwiftUI 的 `frame(maxWidth:)` 语义是
    /// 「在提案允许范围内尽量长到 maxWidth」，而 Toast 的父容器是整个窗口宽度的覆盖层，
    /// 于是每张卡片都会被撑成整整 280pt —— 「已复制」三个字后面拖着一大片空白。
    /// 反过来 `fixedSize()` 又会让长文案彻底不截断、把卡片顶出窗口。
    ///
    /// 所以宽度由**实测文字宽度**（App 层用 NSFont 量，见 `NoticeTextMeasure`）算出来，
    /// 这里只做「加内边距 → 夹到 [minWidth, maxWidth]」的纯算术，可被 smoke 直接断言。
    /// 卡片拿到固定宽度后，内部 `lineLimit(1)` 的文字会自然按可用宽度截断。
    ///
    /// - Parameters:
    ///   - titleTextWidth: 标题在标题字号下的实测宽度。
    ///   - subtitleTextWidth: 副标题实测宽度；无副标题传 0。
    public static func cardWidth(titleTextWidth: CGFloat, subtitleTextWidth: CGFloat) -> CGFloat {
        let textWidth = max(titleTextWidth, subtitleTextWidth)
        let raw = horizontalPadding * 2 + iconGlyphWidth + iconTextSpacing + textWidth
        return min(max(raw, minWidth), maxWidth)
    }

    /// SF Symbol 在 `iconSize` 字号下的实际占位宽度（略宽于字号本身）。
    /// 少算这几 pt 会让文字提前出现省略号。
    public static var iconGlyphWidth: CGFloat { iconSize + 3 }

    /// 文字列在卡片达到最大宽度时可用的宽度。仅用于断言与调试。
    public static var textColumnMaxWidth: CGFloat {
        maxWidth - horizontalPadding * 2 - iconGlyphWidth - iconTextSpacing
    }

    /// 主窗口不可见时 HUD 回退到屏幕顶部的距离（沿用 v2.6.3 的观感，不跟随 `topInset`：
    /// 屏幕顶部 16pt 会顶到菜单栏底沿）。
    public static let hudScreenTopInset: CGFloat = 120

    /// 计算 HUD 面板的左下角原点（AppKit 坐标系，y 向上）。
    ///
    /// - 主窗口可见时：贴主窗口顶部居中，距窗口顶沿 `topInset` —— 与窗内通道**同一个位置**，
    ///   这样「窗口在前台 / 不在前台」两种情况下 Toast 不会在屏幕上跳来跳去。
    /// - 主窗口不可见时（`windowFrame == nil`）：回退到屏幕可见区顶部居中。
    ///
    /// 结果会被夹到屏幕可见区内：贴边 / 半出屏的窗口不应该把 HUD 带出屏幕。
    /// 注意 `contentSize` 已经含 `hudShadowPadding` 的留白，所以这里要把留白减掉后再对齐，
    /// 否则卡片会比窗内通道低 16pt。
    public static func hudOrigin(windowFrame: CGRect?,
                                contentSize: CGSize,
                                screenVisibleFrame: CGRect,
                                shadowPadding: CGFloat = hudShadowPadding) -> CGPoint {
        let anchor = windowFrame ?? screenVisibleFrame
        let topGap = windowFrame == nil ? hudScreenTopInset : topInset

        var x = anchor.midX - contentSize.width / 2
        var y = anchor.maxY - topGap - contentSize.height + shadowPadding

        // 夹进屏幕可见区（窗口贴边 / 部分出屏时）。
        let maxX = screenVisibleFrame.maxX - contentSize.width
        if maxX >= screenVisibleFrame.minX {
            x = min(max(x, screenVisibleFrame.minX), maxX)
        } else {
            x = screenVisibleFrame.minX
        }
        let maxY = screenVisibleFrame.maxY - contentSize.height
        if maxY >= screenVisibleFrame.minY {
            y = min(max(y, screenVisibleFrame.minY), maxY)
        } else {
            y = screenVisibleFrame.minY
        }
        return CGPoint(x: x, y: y)
    }
}
