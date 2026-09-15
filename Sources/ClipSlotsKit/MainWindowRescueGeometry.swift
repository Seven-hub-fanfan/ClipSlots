import CoreGraphics

/// v2.11.8：主窗口「离屏 / 最小化」自救的纯几何。
///
/// 背景：SwiftUI `WindowGroup` 的窗口位置由系统做状态恢复。若上次退出时窗口停在一台已断开的外接
/// 显示器上（或该显示器在系统设置里的排布变了），下次启动窗口会被恢复到当前所有屏幕之外——进程在跑、
/// Dock 图标在、`System Events` 也能枚举到 window 1，但用户屏幕上什么都看不到，表现为「App 打不开」。
/// 窗口若还处于最小化状态，同样是「有进程没界面」。
///
/// 这里只做几何判断与落点计算（可离屏单测），AppKit 侧的 deminiaturize / setFrame 在 AppDelegate。
/// 坐标系为 AppKit 的屏幕坐标（原点左下、y 向上），与 `NSScreen.visibleFrame` 一致。
public struct MainWindowRescueGeometry {
    /// 窗口面积中必须落在某块屏幕可见区域内的最小比例。低于它就认为用户「实际看不到窗口」。
    /// 取 0.35 而不是「有交集就算」：只露出一条 1pt 边同样等于看不见。
    public static let minVisibleFraction: CGFloat = 0.35

    /// 自救后窗口至少保留的尺寸，避免被极小屏幕夹到不可用。
    public static let minSize = CGSize(width: 900, height: 600)

    /// 窗口与某块屏幕可见区域的最大交集面积占窗口面积的比例（0...1）。
    public static func visibleFraction(window: CGRect, visibleFrames: [CGRect]) -> CGFloat {
        let area = window.width * window.height
        guard area > 0 else { return 0 }
        var best: CGFloat = 0
        for screen in visibleFrames {
            let inter = window.intersection(screen)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            best = max(best, (inter.width * inter.height) / area)
        }
        return best
    }

    /// 是否需要自救：无屏幕信息时保守地不动窗口；否则按可见比例判定。
    public static func needsRescue(window: CGRect, visibleFrames: [CGRect]) -> Bool {
        guard !visibleFrames.isEmpty else { return false }
        guard window.width > 0, window.height > 0 else { return true }
        return visibleFraction(window: window, visibleFrames: visibleFrames) < minVisibleFraction
    }

    /// 计算自救落点。
    ///
    /// 选屏策略：优先落在与当前窗口交集最大的那块屏（尊重用户把窗口拖到副屏的意图）；完全无交集时
    /// 落到 `visibleFrames.first`（调用方传入时把主屏放首位）。
    /// 尺寸先夹到目标屏可容纳范围，再把原点夹回屏内；若夹完仍装不下则居中。
    public static func rescuedFrame(window: CGRect, visibleFrames: [CGRect]) -> CGRect {
        guard let fallback = visibleFrames.first else { return window }

        var target = fallback
        var bestArea: CGFloat = 0
        for screen in visibleFrames {
            let inter = window.intersection(screen)
            guard !inter.isNull else { continue }
            let a = inter.width * inter.height
            if a > bestArea {
                bestArea = a
                target = screen
            }
        }

        var width = window.width > 0 ? window.width : minSize.width
        var height = window.height > 0 ? window.height : minSize.height
        width = min(max(width, min(minSize.width, target.width)), target.width)
        height = min(max(height, min(minSize.height, target.height)), target.height)

        var x = window.minX
        var y = window.minY
        x = min(max(x, target.minX), target.maxX - width)
        y = min(max(y, target.minY), target.maxY - height)

        // 原本完全在屏外时不要贴边，直接居中，视觉上更像「窗口回来了」。
        if bestArea <= 0 {
            x = target.midX - width / 2
            y = target.midY - height / 2
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
