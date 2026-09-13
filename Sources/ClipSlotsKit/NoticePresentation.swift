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

// MARK: - 多彩皮肤 Toast 的明暗两档配色（v2.11.7 hotfix14）
//
// hotfix13 给多彩皮肤定的是**一张深色磨砂 HUD 卡片**（`#1C1C1E @ 90%` + 白 15% 描边），当时
// 的判断是「多彩模式本来就有品牌色，深色卡片在明暗两档下都能压住底下的彩色卡片」。这个判断
// 在浅色档是错的：多彩 + 浅色系统外观下整个界面是浅灰白底 + 品牌色点缀，往上贴一张近黑的卡片
// 不是「压住」，而是一块与界面无关的黑条 —— 和 hotfix13 之前「白块贴在深色内容上」是同一种错，
// 只是方向相反。
//
// 所以多彩皮肤也必须分明暗两档。简洁皮肤不需要：它的表面走 `NeuRaisedBackground`，颜色 token
// 本来就是动态色，明暗两档早已各有一套。
//
// 这里只放**数据**（RGBA / 材质档位 / 投影参数），可以被 smoke 直接断言；SwiftUI 侧
// （`NoticeSurface`）只负责把它翻成 `Color` / `Material` / `.shadow`。

/// 与 SwiftUI `Material` 一一对应的材质档位（Kit 不依赖 SwiftUI，所以用枚举表达）。
public enum NoticeMaterialLevel: String, Equatable, Sendable {
    /// `.ultraThinMaterial`：透背景最多。深色档用它，让底下的彩色内容透上来一点，
    /// 卡片才像「浮在内容之上的玻璃」而不是一块实心黑板。
    case ultraThin
    /// `.thinMaterial`：略实一档。浅色档用它，浅底 + 高透会让卡片和画布糊在一起。
    case thin
}

/// 一档 Toast 表面的完整外观参数。
public struct NoticeSurfaceStyle: Equatable, Sendable {

    public struct RGBA: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let opacity: Double

        public init(red: Double, green: Double, blue: Double, opacity: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.opacity = opacity
        }

        /// 感知亮度（Rec. 709），仅用于断言「浅色档的底真的比深色档亮」。
        public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    public struct Shadow: Equatable, Sendable {
        public let opacity: Double
        public let radius: CGFloat
        public let offsetY: CGFloat

        public init(opacity: Double, radius: CGFloat, offsetY: CGFloat) {
            self.opacity = opacity
            self.radius = radius
            self.offsetY = offsetY
        }
    }

    /// 底层磨砂材质档位。
    public let material: NoticeMaterialLevel
    /// 压在磨砂之上的染层（决定卡片是深色还是浅色）。
    public let tint: RGBA
    /// 一圈细边：卡片在同色系背景上唯一的轮廓来源。
    public let border: RGBA
    public let borderWidth: CGFloat
    /// 外部柔投影。多彩皮肤保留投影（它本来就是「浮在内容上的 HUD」语义），
    /// 与简洁皮肤的纯描边浮雕约定不冲突。
    public let shadow: Shadow
    /// 标题 / 副标题墨色。
    public let titleInk: RGBA
    public let subtitleInk: RGBA
    /// 卡片底是不是深色 —— 决定状态图标要不要提亮一档。
    public let isDarkSurface: Bool

    public init(material: NoticeMaterialLevel,
                tint: RGBA,
                border: RGBA,
                borderWidth: CGFloat,
                shadow: Shadow,
                titleInk: RGBA,
                subtitleInk: RGBA,
                isDarkSurface: Bool) {
        self.material = material
        self.tint = tint
        self.border = border
        self.borderWidth = borderWidth
        self.shadow = shadow
        self.titleInk = titleInk
        self.subtitleInk = subtitleInk
        self.isDarkSurface = isDarkSurface
    }
}

/// 多彩皮肤 Toast 的配色表（纯数据）。
public enum NoticePalette {

    /// - Parameter dark: 系统外观是否为深色。
    public static func colorfulSurface(dark: Bool) -> NoticeSurfaceStyle {
        dark ? colorfulDark : colorfulLight
    }

    /// 深色档：hotfix13 的设计原样保留（`#1C1C1E @ 90%` / 白 15% 边 / 黑 30% blur 12）。
    public static let colorfulDark = NoticeSurfaceStyle(
        material: .ultraThin,
        tint: .init(red: 0.110, green: 0.110, blue: 0.118, opacity: 0.90),
        border: .init(red: 1, green: 1, blue: 1, opacity: 0.15),
        borderWidth: 1,
        shadow: .init(opacity: 0.30, radius: 12, offsetY: 4),
        titleInk: .init(red: 1, green: 1, blue: 1, opacity: 1.0),
        subtitleInk: .init(red: 1, green: 1, blue: 1, opacity: 0.72),
        isDarkSurface: true
    )

    /// 浅色档（hotfix14 新增）：白 95% 染层 + `.thinMaterial`，黑 8% 细边，
    /// 投影比深色档更轻更紧（黑 15% / blur 8）——浅底上浓投影会立刻显脏。
    /// 文字换成 `#1C1C1E` 系深墨，与浅色多彩界面的正文同一档。
    public static let colorfulLight = NoticeSurfaceStyle(
        material: .thin,
        tint: .init(red: 1, green: 1, blue: 1, opacity: 0.95),
        border: .init(red: 0, green: 0, blue: 0, opacity: 0.08),
        borderWidth: 1,
        shadow: .init(opacity: 0.15, radius: 8, offsetY: 2),
        titleInk: .init(red: 0.110, green: 0.110, blue: 0.118, opacity: 1.0),
        subtitleInk: .init(red: 0.110, green: 0.110, blue: 0.118, opacity: 0.65),
        isDarkSurface: false
    )
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
