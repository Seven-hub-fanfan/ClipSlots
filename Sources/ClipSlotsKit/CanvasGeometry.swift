import Foundation
import CoreGraphics

/// 无限画布的几何运算（v2.11.7）。
///
/// 与 `RadialSegmentLayout` / `RadialPetalGeometry` 同构：**纯函数下沉到 Kit**，SwiftUI 侧只做
/// 「翻译」不做计算。理由是既往教训 —— 轮盘布局把极坐标数学写在 View 里，导致 10 槽位下扇区角
/// 偏差 25°~30° 却无法用测试发现，最后靠离屏截图对照才定位。画布的视口变换比那更容易出错：
/// 缩放锚点、平移累积、网格对齐三者互相耦合，一个符号错就表现为「缩放时画面往一个角落飘」。
///
/// 坐标系约定（全文统一，不要在别处另立一套）：
///   - **画布空间（canvas space）**：节点自身的坐标，与缩放/平移无关。持久化存的就是这个。
///   - **屏幕空间（screen space）**：视图内的实际像素位置。
///   - 变换公式恒为 `screen = canvas * zoom + pan`，`pan` 是屏幕空间的偏移量。
public enum CanvasGeometry {

    // MARK: - 缩放边界

    public static let zoomMin: CGFloat = 0.25
    public static let zoomMax: CGFloat = 4.0

    /// 把任意缩放值钳制到合法区间。
    ///
    /// 规则刻意只有两条，不做更细的分支：
    ///   - **NaN → 1**。NaN 没有「最近的合法值」，而它一旦流进 pan 的累积计算，整个画布会永久性
    ///     变成空白且无法靠继续操作恢复（NaN 参与任何算术仍是 NaN），用户只能删数据文件。
    ///     手势在极端情况下（两指同时落下、缩放比例算出 0/0）确实会喂进 NaN，所以这道闸必须在。
    ///   - **其余一律取最近的合法值**，`min(max(...))` 天然覆盖 ±∞ 与负数：+∞→zoomMax、
    ///     -∞ 与负数→zoomMin。不为负数单独回落到 1 —— 多一条特例就多一种「同样非法的输入却得到
    ///     不同结果」的不一致。
    public static func clampZoom(_ raw: CGFloat) -> CGFloat {
        guard !raw.isNaN else { return 1 }
        return min(max(raw, zoomMin), zoomMax)
    }

    // MARK: - 视口变换

    /// 画布坐标 → 屏幕坐标。
    public static func screenPoint(canvas: CGPoint, pan: CGSize, zoom: CGFloat) -> CGPoint {
        CGPoint(x: canvas.x * zoom + pan.width, y: canvas.y * zoom + pan.height)
    }

    /// 屏幕坐标 → 画布坐标。`screenPoint` 的逆运算。
    public static func canvasPoint(screen: CGPoint, pan: CGSize, zoom: CGFloat) -> CGPoint {
        let z = clampZoom(zoom)
        return CGPoint(x: (screen.x - pan.width) / z, y: (screen.y - pan.height) / z)
    }

    /// 画布矩形 → 屏幕矩形（尺寸同样按 zoom 缩放）。
    public static func screenRect(canvas: CGRect, pan: CGSize, zoom: CGFloat) -> CGRect {
        let origin = screenPoint(canvas: canvas.origin, pan: pan, zoom: zoom)
        return CGRect(x: origin.x, y: origin.y, width: canvas.width * zoom, height: canvas.height * zoom)
    }

    // MARK: - 锚点缩放

    /// 计算「以某个屏幕点为锚点缩放」之后应有的新 pan。
    ///
    /// 这是画布手感的核心：缩放必须让**光标下的内容保持不动**，而不是围绕视图中心或原点缩放。
    /// 后者在放大到 3x 时，用户想看的区域会瞬间飞出屏幕外。
    ///
    /// 推导：锚点在画布空间的位置 `c = (anchor - pan) / oldZoom` 在缩放前后必须映射到同一屏幕点，
    /// 即 `c * newZoom + newPan == anchor`，故 `newPan = anchor - c * newZoom`。
    public static func panForAnchoredZoom(anchorScreen: CGPoint,
                                         pan: CGSize,
                                         oldZoom: CGFloat,
                                         newZoom: CGFloat) -> CGSize {
        let oz = clampZoom(oldZoom)
        let nz = clampZoom(newZoom)
        let canvasAnchor = canvasPoint(screen: anchorScreen, pan: pan, zoom: oz)
        return CGSize(width: anchorScreen.x - canvasAnchor.x * nz,
                      height: anchorScreen.y - canvasAnchor.y * nz)
    }

    // MARK: - 背景网格

    /// 网格在屏幕空间的实际步长。
    ///
    /// 画布空间步长恒为 `base`，但屏幕步长 `base * zoom` 在缩小时会密到糊成一片（zoom=0.25 时
    /// 24pt 的网格只有 6pt）。所以按 2 的幂做**自适应加倍**，保证屏幕步长不低于 `minScreenStep`；
    /// 放大时反向减半，避免网格稀疏到失去参照作用。
    public static func gridScreenStep(base: CGFloat,
                                      zoom: CGFloat,
                                      minScreenStep: CGFloat = 14,
                                      maxScreenStep: CGFloat = 96) -> CGFloat {
        guard base > 0, minScreenStep > 0 else { return max(base, 1) }
        var step = base * clampZoom(zoom)
        guard step.isFinite, step > 0 else { return base }
        var guardCount = 0
        while step < minScreenStep && guardCount < 32 { step *= 2; guardCount += 1 }
        while step > maxScreenStep && guardCount < 64 { step /= 2; guardCount += 1 }
        return step
    }

    /// 在给定视图长度内，网格线应绘制的坐标列表（单轴通用，x / y 各调一次）。
    ///
    /// `panComponent` 传 pan 的对应分量。返回值总是升序，且第一条线 ≤ 0 < 第一条线 + step，
    /// 保证平移时网格是连续滑动而不是跳变。
    public static func gridLineOffsets(viewLength: CGFloat,
                                       panComponent: CGFloat,
                                       step: CGFloat) -> [CGFloat] {
        guard viewLength > 0, step > 0, step.isFinite, panComponent.isFinite else { return [] }
        // 第一条不小于 0 的网格线：pan 对 step 取模。
        var first = panComponent.truncatingRemainder(dividingBy: step)
        if first > 0 { first -= step }
        var out: [CGFloat] = []
        var x = first
        // 上限保护：极端 zoom 下 step 再小也不会画超过 4000 条线。
        while x <= viewLength && out.count < 4000 {
            out.append(x)
            x += step
        }
        return out
    }

    // MARK: - 节点吸附

    /// 把画布坐标对齐到网格（拖拽落点吸附）。`step <= 0` 时原样返回，表示关闭吸附。
    public static func snap(_ point: CGPoint, step: CGFloat) -> CGPoint {
        guard step > 0, point.x.isFinite, point.y.isFinite else { return point }
        return CGPoint(x: (point.x / step).rounded() * step,
                       y: (point.y / step).rounded() * step)
    }

    // MARK: - 多张展开布局

    /// 一次生成 N 张时，子节点在画布空间的落位（横向排开）。
    ///
    /// 对应 Crate CLI 的 `--count n` 语义：每张都是独立任务，所以每张都是一个独立节点。
    public static func fanOutFrames(origin: CGPoint,
                                    nodeSize: CGSize,
                                    count: Int,
                                    gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            CGRect(x: origin.x + CGFloat(i) * (nodeSize.width + gap),
                   y: origin.y,
                   width: nodeSize.width,
                   height: nodeSize.height)
        }
    }

    /// 展开占位区域的总包围盒（用于随后的推挤计算）。
    public static func fanOutBounds(origin: CGPoint,
                                    nodeSize: CGSize,
                                    count: Int,
                                    gap: CGFloat) -> CGRect {
        guard count > 0 else { return .zero }
        let totalWidth = CGFloat(count) * nodeSize.width + CGFloat(count - 1) * gap
        return CGRect(x: origin.x, y: origin.y, width: totalWidth, height: nodeSize.height)
    }

    /// 「向右推挤」：把挡在展开区域上的既有节点整体右移，给新节点腾出空间。
    ///
    /// 规则刻意做得**确定且可预测**（而不是找最近空位）：
    ///   1. 只考虑与展开区域**垂直方向有重叠**的节点 —— 不在同一「行」的节点绝不被无端移动。
    ///   2. 只考虑 `minX >= bounds.minX` 的节点 —— 展开区左侧的节点保持原位（跨越左边界的宽节点
    ///      也不动：那种情况下往哪推都会破坏用户已有的排版，宁可让它与新节点重叠，由用户自己拖开）。
    ///   3. **级联推挤**：按 X 升序逐个处理，只有真正被挡住的节点才移动，且移动量取「刚好让开」
    ///      的最小值。
    ///
    /// 第 3 条是从一个错版本改过来的：最初的写法是「同一行所有右侧节点统一位移，以保持相对间距」，
    /// 结果远处一个明明还空着 300pt 的节点也会被平移 —— 用户的观感是「我在这边展开，整个画布右半
    /// 边都跟着跑」。反过来若改成「只推真正重叠的那些」，被推的节点又可能撞上它右边原本无关的节点，
    /// 凭空造出新的重叠。级联是唯一同时满足「最小移动」和「不产生新重叠」的解法：维护一条
    /// `frontier`（必须让开的右边界），逐个判定是否越界，越界者推到 frontier 并把 frontier 顶到
    /// 自己右侧；未越界者不动，frontier 收敛到它的右边缘（**不额外加 gap** —— 两个原本紧挨着的
    /// 老节点没有理由因为这次展开被强行拉开）。
    ///
    /// 返回 `[索引: dx]`，只含需要移动的节点。母节点自身应由调用方从 `existing` 中排除。
    public static func pushRightOffsets(existing: [CGRect],
                                        bounds: CGRect,
                                        gap: CGFloat) -> [Int: CGFloat] {
        guard bounds.width > 0 else { return [:] }

        // 候选：同行 + 位于展开区起点右侧。
        var candidates: [(index: Int, rect: CGRect)] = []
        for (i, rect) in existing.enumerated() {
            let verticallyOverlaps = rect.maxY > bounds.minY && rect.minY < bounds.maxY
            guard verticallyOverlaps, rect.minX >= bounds.minX else { continue }
            candidates.append((i, rect))
        }
        guard !candidates.isEmpty else { return [:] }
        candidates.sort { $0.rect.minX < $1.rect.minX }

        var out: [Int: CGFloat] = [:]
        var frontier = bounds.maxX + gap
        for candidate in candidates {
            if candidate.rect.minX < frontier {
                let dx = frontier - candidate.rect.minX
                out[candidate.index] = dx
                frontier = candidate.rect.maxX + dx + gap
            } else {
                // 没被挡住 → 不动。后续节点只需避开它的实际右边缘，不必再加一个 gap。
                frontier = candidate.rect.maxX
            }
        }
        return out
    }

    // MARK: - 视图适配

    /// 「适应窗口」：算出让所有节点刚好落进视图的 zoom 与 pan。
    public static func fitTransform(contentBounds: CGRect,
                                    viewSize: CGSize,
                                    padding: CGFloat = 48) -> (zoom: CGFloat, pan: CGSize) {
        guard contentBounds.width > 0, contentBounds.height > 0,
              viewSize.width > padding * 2, viewSize.height > padding * 2 else {
            return (1, .zero)
        }
        let availW = viewSize.width - padding * 2
        let availH = viewSize.height - padding * 2
        let zoom = clampZoom(min(availW / contentBounds.width, availH / contentBounds.height))
        // 让内容中心对齐视图中心。
        let center = CGPoint(x: contentBounds.midX, y: contentBounds.midY)
        let pan = CGSize(width: viewSize.width / 2 - center.x * zoom,
                         height: viewSize.height / 2 - center.y * zoom)
        return (zoom, pan)
    }

    /// 一组节点的包围盒。空集返回 `.zero`。
    public static func bounds(of rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}
