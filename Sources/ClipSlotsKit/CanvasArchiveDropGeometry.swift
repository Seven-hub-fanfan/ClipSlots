import Foundation
import CoreGraphics

/// 「把画布节点拖进槽位库归槽」时那 10 个高亮分栏块的几何（v2.11.8 二轮）。
///
/// 用户要的动作：从画布上拖起一个节点、移到左侧槽位库上方，侧栏变成 10 个对应槽位 1~10 的高亮块，
/// 悬停哪个哪个放大，松手就把内容归进那个槽位。
///
/// ## 为什么这段数学必须下沉到 Kit（而不是就地写在面板里）
///
/// 因为**画块的人和判命中的人不是同一个视图**：
///   - 分栏块由 `CanvasSlotLibraryPanel` 渲染（它才是那块侧栏）；
///   - 松手事件却落在 `CanvasWorkspaceView` 的节点 `DragGesture` 上（拖拽从节点开始，手势的
///     整个生命周期都归它）。
///
/// 两处各写一份布局，就是"看起来在第 3 块上，松手却归到第 4 个槽位"的标准配方 —— 而且它只在
/// 某些窗口高度下发生（两份公式的舍入/内边距差异被高度放大），几乎不可能靠手测复现。
/// 所以布局只有这一份，两边都从这里取，并由 smoke 断言钉住"块不重叠、命中与渲染一致"。
public enum CanvasArchiveDropGeometry {

    /// 一个槽位分栏块。
    public struct Block: Equatable {
        /// 槽位号（1 起）。
        public let slot: Int
        /// 在**侧栏本地坐标**里的矩形。侧栏贴着画布根坐标空间的左上角，因此它同时也是根坐标。
        public let rect: CGRect

        public init(slot: Int, rect: CGRect) {
            self.slot = slot
            self.rect = rect
        }
    }

    /// 顶部留给标题的高度（"归入槽位" + 组名）。
    public static let headerHeight: CGFloat = 46
    /// 左右内边距。
    public static let sidePadding: CGFloat = 10
    /// 底部内边距。
    public static let bottomPadding: CGFloat = 12
    /// 块间距。
    public static let blockGap: CGFloat = 5
    /// 块高下限。窗口被压得很矮时宁可让最后几块溢出侧栏（用户会看到明显异常），
    /// 也不要把块压到点不中的高度 —— 后者的表现是"松手没反应"，用户只会认为功能是坏的。
    public static let minBlockHeight: CGFloat = 20

    /// 计算全部分栏块。
    ///
    /// - Parameters:
    ///   - panelSize: 侧栏尺寸（展开态宽度 × 画布可用高度）。
    ///   - count: 槽位数（= 该组的槽位上限，通常 10）。
    public static func blocks(panelSize: CGSize, count: Int) -> [Block] {
        guard count > 0, panelSize.width > 0 else { return [] }
        let n = CGFloat(count)
        let available = max(0, panelSize.height - headerHeight - bottomPadding)
        let height = max(minBlockHeight, (available - blockGap * (n - 1)) / n)
        let width = max(0, panelSize.width - sidePadding * 2)
        return (0..<count).map { i in
            let y = headerHeight + CGFloat(i) * (height + blockGap)
            return Block(slot: i + 1,
                         rect: CGRect(x: sidePadding, y: y, width: width, height: height))
        }
    }

    /// 命中判定：光标落在哪个槽位块上。
    ///
    /// 纵向按**块+间距的整条带**判定，而不是只判块本身的矩形：间距（5pt）若成死区，
    /// 用户会遇到"明明在两块之间慢慢移动，高亮却一闪一闪"的抖动。归槽是个粗动作，
    /// 不该要求像素级精准。横向仍要求落在侧栏内 —— 那是"要不要归槽"的开关。
    public static func blockIndex(at point: CGPoint, panelSize: CGSize, count: Int) -> Int? {
        let all = blocks(panelSize: panelSize, count: count)
        guard let first = all.first, let last = all.last else { return nil }
        guard point.x >= 0, point.x <= panelSize.width else { return nil }
        guard point.y >= first.rect.minY, point.y <= last.rect.maxY else { return nil }

        let stride = first.rect.height + blockGap
        guard stride > 0 else { return nil }
        let idx = Int((point.y - first.rect.minY) / stride)
        guard idx >= 0, idx < all.count else { return nil }
        return all[idx].slot
    }

    /// 光标是否落在侧栏范围内（= 是否进入"归槽"意图）。
    ///
    /// 单独一个函数是因为调用方需要在**画块之前**先知道要不要进入归槽模式：
    /// 拖节点经过侧栏上方才展开分栏，横穿画布时侧栏保持原样。
    public static func isInsidePanel(point: CGPoint, panelSize: CGSize) -> Bool {
        point.x >= 0 && point.x <= panelSize.width
            && point.y >= 0 && point.y <= panelSize.height
    }
}
