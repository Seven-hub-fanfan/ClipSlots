import CoreGraphics
import Foundation

/// v2.11.8：空白画布「双击」判定的纯逻辑。
///
/// ## 为什么不用 SwiftUI 的 `onTapGesture(count: 2)`
///
/// 实测（macOS 13/14，本项目画布）：同一个视图上同时挂 `onTapGesture(count: 2)` 与
/// `onTapGesture`（单击取消选中）时，**双击永远不触发** —— 两次点击都被单击手势吃掉。
/// 调换书写顺序、改 `.gesture` / `.highPriorityGesture` 都只是在「双击不响应」和
/// 「单击被延迟到双击超时之后才生效」之间换一个坑；后者会让「点空白取消选中」明显发涩。
///
/// 所以这里回到最朴素也最可控的做法：**只保留单击手势**（它一直是可靠的），在单击回调里
/// 用「上一次单击的时间 + 位置」自己判定这一次是不是双击。间隔阈值取系统的
/// `NSEvent.doubleClickInterval`（跟随用户在「辅助功能 / 鼠标」里的设置），位置阈值用
/// `slop` 兜住手抖，同时排除「在画布两头各点一下」被误判成双击。
public struct CanvasClickCadence {
    /// 两次点击被视为同一处的最大位移（点）。比系统的双击容差略松一点：画布上双击的落点常常
    /// 带一两个像素的漂移，卡太紧会让双击时不时"漏一次"，而漏掉的那次表现为"菜单没弹出来"。
    public static let defaultSlop: CGFloat = 6

    /// 上一次点击的时间与位置。
    public struct Click: Equatable {
        public var point: CGPoint
        public var time: TimeInterval
        public init(point: CGPoint, time: TimeInterval) {
            self.point = point
            self.time = time
        }
    }

    /// 这一次点击是否构成双击。
    ///
    /// - Parameters:
    ///   - previous: 上一次点击（nil = 本次是第一击）。
    ///   - current: 本次点击。
    ///   - interval: 双击时间上限，传 `NSEvent.doubleClickInterval`。
    ///   - slop: 位置容差。
    public static func isDoubleClick(previous: Click?,
                                     current: Click,
                                     interval: TimeInterval,
                                     slop: CGFloat = defaultSlop) -> Bool {
        guard let previous else { return false }
        let dt = current.time - previous.time
        // dt < 0 说明时钟回拨或调用方传错序，按"不是双击"处理，绝不能因为算出负数就当成 0 秒。
        guard dt >= 0, dt <= interval else { return false }
        let dx = current.point.x - previous.point.x
        let dy = current.point.y - previous.point.y
        return (dx * dx + dy * dy) <= slop * slop
    }
}
