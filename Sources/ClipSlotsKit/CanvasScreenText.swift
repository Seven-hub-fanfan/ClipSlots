import CoreGraphics

/// 画布文字的「屏幕固定字号」数学（v2.11.8 八轮 · 需求 1）。
///
/// ## 用户要什么
///
/// 「画布缩放时，卡片/节点上的文字在屏幕上保持固定视觉大小（比如始终 13pt），不随 zoom 放大缩小；
/// 节点在屏幕上小到一定程度时文字直接隐藏，避免糊成噪点。」
///
/// ## 为什么不是 `scaleEffect(1 / zoom)`（用户建议的实现方式）
///
/// 需求描述里给的实现建议是给文字挂一层 `scaleEffect(1 / zoomScale)` 抵消画布缩放。在**别的**
/// 项目里这是对的，在本项目里它会退回一个已经修过的 bug：
///
/// 本项目的画布**没有**"整层 scaleEffect(zoom)"这种结构。v2.11.8 一轮就把它删了 —— 位图仿射
/// 放大是"放大后全糊"的根因（见 `CanvasNodeCardView` 类型注释）。现在的管线是：
///
/// ```text
///   节点子树按 layoutZoom 排版（所有长度 × renderScale，文字真的用大字号重新光栅化）
///   节点层再补一层 scaleEffect(zoom / layoutZoom)   ← 只补"缩放手势进行中"的那点差值，静息时 = 1
/// ```
///
/// 所以屏幕上看到的字号 = `排版字号 × zoom / renderScale`，静息时（`zoom == renderScale`）就是
/// **排版字号本身**。要让屏幕字号恒等于设计值，正确做法是排版时**不乘** renderScale ——
/// 这与 `scaleEffect(1/zoom)` 在几何上等价（`v·z·(1/z) = v`），但文字是在 13pt 真实字号上
/// 光栅化的，边缘是清的；挂 `scaleEffect` 则是"按 13·z 光栅化再缩回去"，缩小时丢像素、
/// 放大时糊边，正是一轮删掉整层 scaleEffect 的那个坑。
///
/// 代价（如实记录）：缩放手势**进行中**，节点层那层差值 `zoom / layoutZoom` 会把文字一起短暂
/// 拉伸（最多 ±18%，`CanvasZoomLayout` 的阶梯宽度），手势 settle 后回到固定字号。这个瞬时形变
/// 换来的是"不重新布局每一帧"—— 而每帧重排文字正是 `CanvasZoomLayout` 那一轮修掉的抖动 bug。
///
/// ## 为什么要有"太小就隐藏"
///
/// 屏幕固定字号有个必然的副作用：**缩小画布时文字相对卡片越来越大**。zoom 0.25 时节点只有
/// 80×55pt，13pt 的正文在里面就是一坨压字。所以低于阈值直接不画 —— 缩得那么小的时候用户在
/// 找的是"节点分布"，不是读字。阈值按用户给的 40pt（节点视觉短边）。
///
/// 视图侧还要另外保证"文字不撑破卡片"（`CanvasCardLayout.promptMaxHeight` + 裁剪），
/// 因为 40pt 阈值只兜住极端缩小，0.4~0.8 这段是"文字偏大但仍要显示"的正常区间。
public enum CanvasScreenText {

    // MARK: - 常量

    /// 节点视觉短边低于这个值（pt，屏幕像素点）就不画文字。用户给的建议值 40。
    public static let hideBelowVisualSize: CGFloat = 40

    /// 卡叠里单张卡片的文字阈值。
    ///
    /// 比节点阈值小：卡片本身就比节点小一大截（`fanCardSize` 约 108×132，而节点 320×220），
    /// 用同一个 40 会导致"节点文字还在、卡片文字先没了"这种不一致在很宽的缩放区间里都成立。
    /// 24pt 的含义是"卡片缩到指甲盖大小就别写字了"。
    public static let hideCardTextBelowVisualSize: CGFloat = 24

    // MARK: - 字号

    /// 设计字号（屏幕 pt）→ **排版**字号。
    ///
    /// 写成"乘 z 再乘 1/z"而不是直接 `return designPt`，是为了让"为什么这里不像其它几何量那样
    /// 乘 renderScale"这件事在代码里留痕：不是漏乘，是刻意抵消。
    /// （本文件类型注释里那条铁律"所有几何量都过 s(_:)"的唯一例外就在这里。）
    public static func layoutFontSize(_ designPt: CGFloat, renderScale: CGFloat) -> CGFloat {
        let z = max(0.01, renderScale)
        let counterScale = 1 / z          // 抵消画布缩放
        return max(0.01, designPt * z * counterScale)
    }

    /// 排版字号 → 用户**在屏幕上实际看到**的字号。
    ///
    /// 建模的就是当前管线：节点子树按 `renderScale` 排版，节点层再补 `zoom / renderScale`。
    /// 只给测试用（视图侧不需要它），但它是"屏幕固定"这句话唯一可被断言的形式。
    public static func screenFontSize(layoutPt: CGFloat,
                                      renderScale: CGFloat,
                                      zoom: CGFloat) -> CGFloat {
        let r = max(0.01, renderScale)
        return layoutPt * max(0, zoom) / r
    }

    /// 设计字号在屏幕上的最终字号（= 上面两步串起来）。静息时恒等于 `designPt`。
    public static func screenFontSize(designPt: CGFloat,
                                      renderScale: CGFloat,
                                      zoom: CGFloat) -> CGFloat {
        screenFontSize(layoutPt: layoutFontSize(designPt, renderScale: renderScale),
                       renderScale: renderScale,
                       zoom: zoom)
    }

    // MARK: - 可见性

    /// 尺寸（1x 画布坐标）在屏幕上的视觉尺寸。
    public static func visualSize(_ size: CGSize, zoom: CGFloat) -> CGSize {
        let z = max(0, zoom)
        return CGSize(width: max(0, size.width) * z, height: max(0, size.height) * z)
    }

    /// 视觉短边。
    public static func visualShortSide(_ size: CGSize, zoom: CGFloat) -> CGFloat {
        let v = visualSize(size, zoom: zoom)
        return min(v.width, v.height)
    }

    /// 节点上的文字该不该画。
    ///
    /// 用**短边**而不是面积/宽度：文字被压扁（很宽很矮的节点）和被压窄一样不可读，
    /// 而短边是这两种情形唯一共同的度量。
    public static func textVisible(nodeSize: CGSize,
                                  zoom: CGFloat,
                                  threshold: CGFloat = hideBelowVisualSize) -> Bool {
        visualShortSide(nodeSize, zoom: zoom) >= threshold
    }

    /// 卡叠里单张卡片上的文字该不该画。
    public static func cardTextVisible(cardSize: CGSize,
                                       zoom: CGFloat,
                                       threshold: CGFloat = hideCardTextBelowVisualSize) -> Bool {
        visualShortSide(cardSize, zoom: zoom) >= threshold
    }

    /// 便于视图直接 `.opacity(...)`：可见 1，不可见 0。
    ///
    /// 用 opacity 而不是 `if` 分支是刻意的：分支会改变 VStack 的子视图数量，缩放跨过阈值那一帧
    /// 整张卡片的纵向分区会重排（正文块塌陷 → 入参文件行上跳）。opacity 只改绘制，布局不动。
    public static func textOpacity(nodeSize: CGSize,
                                   zoom: CGFloat,
                                   threshold: CGFloat = hideBelowVisualSize) -> Double {
        textVisible(nodeSize: nodeSize, zoom: zoom, threshold: threshold) ? 1 : 0
    }
}
