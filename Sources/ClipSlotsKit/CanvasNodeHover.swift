import Foundation
import CoreGraphics

/// 节点 hover 的**维持区**判定（★ v2.11.8 五轮）。
///
/// ## 要修的是什么
///
/// 用户录屏（20260916125646）逐帧分析的结论很具体：扇形展开后收拢的**每一次**，光标都已经越出
/// 节点卡片的圆角边框；其中一次只越出约 12px —— 那是用户正把鼠标往**左翻页箭头**上送的路上。
/// 左箭头圆心距节点左边框只有约 11px（箭头贴着预览区边缘，预览区又只比节点内缩 12pt），
/// 于是"去点箭头"这个动作本身有很大概率先摸出节点边界一下：
///
/// ```text
///   ┌ 节点边框                       鼠标轨迹
///   │  ◀ 箭头(距边框~11px)         ← ← ←·  ← 只要过冲 12px 就出框
///   │  ┌───────────────┐
///   │  │ 扇形卡片       │
/// ```
///
/// 而 SwiftUI 的 `.onHover` 是**边界即真理**：出框那一帧就是 `false`，扇形立刻收拢、箭头随之消失，
/// 用户的动作被打断（录屏里 f_035 展开 → f_036 收拢 → f_037 又展开，0.33s 内闪了一次）。
///
/// ## 为什么不用"给节点套一圈更大的透明 hover halo"
///
/// 那是最少行数的写法，但 halo 落在节点卡片的**祖先手势链**里（`nodeDragGesture` / `onTapGesture`
/// 都挂在节点外层），于是节点周围 30pt 的空白会变成"能拖动节点、点了会选中节点"的隐形区域，
/// 框选（marquee）从节点旁边起手就会变成拖节点。用透明视图换 hover 精度，代价是把画布上最基础的
/// 两个手势弄脏 —— 不划算。
///
/// 五轮改成**纯坐标判定**：画布本来就有一个 `.onContinuousHover` 在实时更新光标位置（`cursorScreen`，
/// 原本用于捏合缩放锚点），把它换算成画布坐标后与这里的矩形比一下即可。没有新增任何可命中视图，
/// 手势链一行没动，而且判定是纯函数、可以被 smoke 钉死。
///
/// ## 两级矩形（进入严、维持宽）
///
///   - `ownRect`：节点本体。**只有**光标落在本体里才会"进入" hover —— 维持区如果也能触发进入，
///     鼠标从节点旁边 30pt 掠过就会让节点亮边框、弹出风格切换按钮，画布会显得到处在闪。
///   - `holdRect`：本体 + 外扩。已经 hover 的节点靠它**维持**，外扩量取
///     `max(sideSlop, 扇形实际半宽 - 节点半宽 + fanGrace)`，即"至少 30pt，且一定盖住扇形本身"。
///     后半项是给未来改扇形参数的人留的保险：`expandedSpread`/`expandedStagger` 一旦调大，
///     维持区自动跟着变宽，不需要有人想起来同步这个常量（smoke 里有断言盯着）。
public enum CanvasNodeHover {

    // MARK: - 常量

    /// hover 离开的宽限期。用户明确要求"约 200ms"。
    ///
    /// 它和 `holdRect` 是两件不同的事，都需要：矩形解决"鼠标停在扇形/箭头上"，宽限期解决
    /// "鼠标快速穿过缝隙、或在边界上抖了一下"。录屏里那次 0.33s 的闪烁属于后者。
    /// ★ v2.11.14：0.2s → **0.12s**。用户反馈"收起有点慢"，其中约 200ms 其实是这段
    /// 还没开始动的宽限期（录屏里能看到鼠标已离开、牌还钉在展开态）。0.12s 仍然盖得住
    /// "快速穿过缝隙 / 在边界上抖一下"这两种误触（它们的持续时间在 30~80ms 量级），
    /// 但把"没反应"的死区砍掉近一半。真正的防误触主力是 `holdRect`，不是这个延迟。
    public static let leaveDelay: TimeInterval = 0.12

    /// 维持区的最小外扩量（1x 画布坐标，四边）。
    ///
    /// 30pt 的来历：录屏里那次误触是过冲 12px，箭头到边框只剩 11px；30pt 意味着"把箭头整个圆
    /// 再往外让出一倍"，日常操作不会碰到边界。再大就开始和相邻节点的本体抢光标了（本体优先，
    /// 见 `resolve`，所以只是浪费，不至于出错）。
    public static let sideSlop: CGFloat = 30

    /// 扇形半宽之外再留的余量（避免"刚好压线"）。
    public static let fanGrace: CGFloat = 10

    // MARK: - 矩形

    /// 节点本体矩形（画布坐标，1x）。
    public static func ownRect(node: CanvasNode) -> CGRect {
        CGRect(x: node.x, y: node.y, width: max(1, node.width), height: max(1, node.height))
    }

    /// hover 维持区（画布坐标，1x）。
    ///
    /// 纯文本节点没有卡叠，但仍然给同样的外扩：它也有"正文点进去编辑"这类贴边操作，
    /// 而且分两套规则只会让"为什么这个节点边上能维持、那个不能"变成新的玄学。
    public static func holdRect(node: CanvasNode) -> CGRect {
        let box = CanvasCardLayout.previewHeight(nodeHeight: node.height)
        let card = CanvasFanGeometry.fanCardSize(boxHeight: box)
        // 扇形最多 maxCards + 1 个 slot（第 6 格是 `+N` 翻页卡），按最宽的情况算。
        let slots = CanvasFanGeometry.maxCards + 1
        let fanHalf = CanvasFanGeometry.expandedHalfWidth(slotCount: slots, cardSize: card)
        // ★ 九轮：展开风格只剩扇形，维持区就按扇形的最宽形态算（八轮那句"对两种风格取并集"
        // 随「交替叠放」一起删掉了）。
        let need = fanHalf - max(1, node.width) / 2 + fanGrace
        let slop = max(sideSlop, need)
        return ownRect(node: node).insetBy(dx: -slop, dy: -slop)
    }

    // MARK: - 判定

    /// 给定光标位置，算出"当前应该被视为 hover"的节点。
    ///
    /// - Parameters:
    ///   - current: 上一帧的结果（维持的对象）。
    ///   - point: 光标位置（**画布坐标**，1x）。
    ///   - nodes: 全部节点，**按绘制顺序**（数组末尾画在最上层）。
    /// - Returns: 节点 id；`nil` 表示没有任何节点该保持 hover。
    ///
    /// 顺序很重要：本体命中优先于维持。否则两个节点靠得近时，光标已经压在 B 的身上，
    /// 却因为还在 A 的维持区里而继续把 hover 记在 A 头上，表现是"点 B 的卡片没反应"。
    public static func resolve(current: String?, point: CGPoint, nodes: [CanvasNode]) -> String? {
        if let hit = nodes.last(where: { ownRect(node: $0).contains(point) }) {
            return hit.id
        }
        if let cur = current,
           let node = nodes.first(where: { $0.id == cur }),
           holdRect(node: node).contains(point) {
            return cur
        }
        return nil
    }
}
