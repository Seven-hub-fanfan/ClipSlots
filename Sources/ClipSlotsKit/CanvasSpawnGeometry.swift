import Foundation
import CoreGraphics

/// 「新节点该出现在哪」的纯几何（v2.11.8）。
///
/// 为什么要下沉到 Kit：这批入口（双击画布、Cmd+V、节点下方 + 号）算的都是同一件事 ——
/// 屏幕上的一个点或一个已有节点 → 画布空间里一个不撞车的落点。三个入口各写一份，症状是
/// 「双击建的节点对齐网格、Cmd+V 建的偏半格」这种没人会写测试的细微不一致。
///
/// 坐标系沿用 `CanvasGeometry` 的约定：`screen = canvas * zoom + pan`。
public enum CanvasSpawnGeometry {

    /// 新节点相对上游节点的默认垂直间距（用户指定 60pt）。
    public static let downstreamGap: CGFloat = 60

    /// 撞车检测的判定距离：新落点与已有节点左上角的距离小于它，就认为「叠在一起了」。
    ///
    /// 取 24（= `CanvasGeometry.snapStep`）而不是节点全宽：**允许重叠，只禁止完全重合**。
    /// 画布上把两张卡片故意叠一半是常见排版意图，而完全重合会让用户以为「点了没反应」。
    public static let collisionRadius: CGFloat = 24

    /// 每次让位的位移量。斜向让位（右下）而不是纯向下：纯向下在连续粘贴时会排成一列，
    /// 和「+ 号建下游节点」的视觉语义（下方 = 下游）撞车。
    public static let cascadeStep: CGSize = CGSize(width: 28, height: 28)

    /// 视口中心对应的**画布坐标**。
    ///
    /// Cmd+V 用它：粘贴出来的节点必须落在用户正在看的地方，而不是画布原点 —— 画布可以被平移到
    /// 几千点之外，落在原点等于「粘贴了但看不见」，用户会以为功能坏了。
    ///
    /// - Parameter viewportOrigin: 可见区域左上角在屏幕坐标里的位置。**槽位库侧栏展开时必须传它**：
    ///   侧栏是不透明的、占住左边 240pt，此时"视图中心"其实藏在侧栏后面，节点落在那里等于看不见。
    ///   传 `.zero` 即退化为整个视图的中心。
    public static func viewportCenter(pan: CGSize,
                                      zoom: CGFloat,
                                      viewportSize: CGSize,
                                      viewportOrigin: CGPoint = .zero) -> CGPoint {
        CanvasGeometry.canvasPoint(screen: CGPoint(x: viewportOrigin.x + viewportSize.width / 2,
                                                  y: viewportOrigin.y + viewportSize.height / 2),
                                   pan: pan,
                                   zoom: zoom)
    }

    /// 把「希望节点中心落在这里」换算成节点左上角坐标。
    ///
    /// 视口中心 / 双击点在用户脑子里都是「节点出现的位置」= 节点中心，而模型存的是左上角。
    /// 这个换算写错的表现很隐蔽：节点看起来总是偏右下半张卡片。
    public static func origin(forCenter center: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
    }

    /// 下游节点的左上角：与上游左对齐、在其下方留 `gap`。
    ///
    /// 刻意左对齐而不是中心对齐：Crate 那种自上而下的流程图里，等宽卡片左对齐才能连成一列，
    /// 中心对齐在卡片宽度不一致时会看起来像随机缩进。
    public static func downstreamOrigin(of frame: CGRect,
                                        newSize: CGSize,
                                        gap: CGFloat = downstreamGap) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.maxY + gap)
    }

    /// 避免与已有节点完全重合的落点。
    ///
    /// 逐步斜向让位，最多 `maxAttempts` 次后**接受重叠**并返回当前值：找不到空位时把节点扔到
    /// 视野外（或无限循环）比重叠糟糕得多。
    public static func nonOverlappingOrigin(desired: CGPoint,
                                           existing: [CGPoint],
                                           step: CGSize = cascadeStep,
                                           radius: CGFloat = collisionRadius,
                                           maxAttempts: Int = 40) -> CGPoint {
        guard !existing.isEmpty else { return desired }
        var candidate = desired
        var attempts = 0
        while attempts < maxAttempts,
              existing.contains(where: { hypot($0.x - candidate.x, $0.y - candidate.y) < radius }) {
            candidate.x += step.width
            candidate.y += step.height
            attempts += 1
        }
        return candidate
    }

    /// 选一个可用槽位号。
    ///
    /// 「ADD NODE」与 Cmd+V 都要**新建**内容，而本项目里节点就是槽位 —— 所以创建节点的前提是
    /// 找到一个空槽。规则：
    ///   - 从 1 扫到 `total`，返回第一个既没内容、也没被画布占用的槽位号；
    ///   - 全占满 → 返回 nil，由上层给出明确提示（"当前槽位组已满"），**绝不覆盖任何已有槽位**。
    ///     覆盖用户内容去满足一次"新建节点"是不可接受的交换。
    public static func firstFreeSlot(total: Int,
                                    occupied: Set<Int>) -> Int? {
        guard total > 0 else { return nil }
        for slot in 1...total where !occupied.contains(slot) {
            return slot
        }
        return nil
    }
}
