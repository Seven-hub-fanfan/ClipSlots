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
/// 残差怎么处理（★ 九轮收口）：节点层那层差值 `zoom / layoutZoom` 对文字一样生效，所以文字再乘
/// `CanvasZoomLayout.textCounterScale` = 它的**精确倒数**。八轮把这个补偿钳成 `min(1, ·)`，
/// 于是缩小手势进行中（`layoutZoom` 还冻结在旧档、残差 <1）完全不补偿，文字跟着画布缩小 ——
/// 用户四次打回的"字体缩放仍未生效"就是它。九轮取消钳制后，任意 (zoom, layoutZoom) 组合下
/// 屏幕字号都严格等于设计 pt，`CANVAS-TEXT-EXACT` 那组测试逐点扫过两侧残差把这一点钉住。
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
    /// ★ v2.11.10：**改回“随画布等比”** —— 这是八轮“屏幕字号恒定”的一次有意识的回滚。
    ///
    /// ## 用户的两个诉求为何在老模型下不可能同时成立
    ///
    /// 诉求 A（八轮）：缩放时文字在屏幕上大小不变（缩小也能读）。
    /// 诉求 B（本轮）：缩放时文字不要“动态响应”（排版不抖）。
    ///
    /// 每行能装多少字 = 盒子宽度 / 字号。卡片宽度在屏幕上是 `cardWidth × zoom`，
    /// 而诉求 A 要求字号恒定 —— 于是每行字数 ∝ zoom，**换行位置必然随缩放变**，行数也必然
    /// 变（用户第二段录屏：缩小时 4~5 行 → 7~8 行，正文块变高把底部「入参文件」按钮顶得
    /// 上下抽搜）。这不是实现 bug，是诉求 A 的**数学后果**：只要字号不随缩放而盒子随，
    /// 流式排版就一定会重流。三轮/八轮/九轮那一系列补丁（档位量化、禁掉字距收紧、
    /// 反向补偿）只是在推迟重流的**时机**，消不掉重流本身。
    ///
    /// ## 为何等比矢量能同时满足“不模糊 + 不抖”
    ///
    /// 字号与盒子同乘 `renderScale` 后，每行字数与 zoom **无关** —— 100% 与 300% 下换行位置、
    /// 行数、段高占比完全一致，所以：
    ///   - 手势进行中（排版冻结、靠 `scaleEffect(zoom / layoutZoom)` 过渡）的画面与落定后的版面
    ///     **几何上全等**，落定时的重排看不出来（旧模型下它是一次胉眼的换行跳变）；
    ///   - 落定后 `layoutZoom == zoom`（上一轮的修正）→ 残差变换恒为 1，文字按真实字号光栅化，
    ///     **任何缩放档位静息时都是 1:1 清晰**（不再有反向补偿带来的二次重采样发虚）。
    ///
    /// 代价：缩得很小时文字真的会小到读不了。这本来就是画布类工具（Figma / FigJam / 即构）
    /// 的公共约定，且本工程已有兵：`hideCardTextBelowVisualSize` 会在节点小于阈值时直接隐文字，
    /// 避免退化成一堆灏灏的灰条（录屏里缩小后那种“模糊色块”就是旧模型下字号不跟着缩、
    /// 又被残差变换抽样出来的）。
    ///
    /// 函数名与文件名里的 "screen" 已不再贴切，但刻意不改：调用点遭地都是，而这一轮的重点
    /// 是**只改语义不改拓扑**，便于下一次反悔时改回来只需动这一行。
    public static func layoutFontSize(_ designPt: CGFloat, renderScale: CGFloat) -> CGFloat {
        max(0.01, designPt * max(0.01, renderScale))
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

    // MARK: - 固定字号的行高与「装得下几行」

    /// 行高系数（含行距）。SwiftUI 的 `Text` 实际行高约为字号的 1.2~1.3 倍，取 1.2 是保守下界。
    public static let lineHeightFactor: CGFloat = 1.2

    /// 固定字号文字占的行高（屏幕 pt = 排版 pt，因为字号不缩）。
    public static func lineHeight(_ fontSize: CGFloat) -> CGFloat {
        max(0, fontSize) * lineHeightFactor
    }

    /// 给定盒子高度（**排版**单位）装得下几行固定字号的文字。
    ///
    /// ## 这个函数取代了八轮的 `rowTextVisible` / `blockTextVisible`
    ///
    /// 八轮的思路是"这一行塞不下就把这一行藏起来"。用户九轮明确否掉了：
    /// 「节点视觉尺寸 < 40pt 时文字整体 opacity = 0，**不是逐行隐藏**」。
    ///
    /// 逐行隐藏本来就是在治症状。真正的病根是**版面预算算错了**：字号被固定成设计 pt（不随
    /// `renderScale` 缩），但卡片的纵向分区仍然整个乘 `renderScale`，于是缩小到一定程度后
    /// "各行要的高度之和" > "卡片总高"，定高父容器只能把某几行压扁 —— 屏幕上就是半截字。
    ///
    /// 九轮的修法是让预算自己算对：文字行按**固定高度**参与分配（`CanvasCardLayout.verticalPlan`），
    /// 可伸缩的预览区/正文区去让位。文字行因此永远有完整的行高，一个字都不会被切。
    /// 本函数只用来决定**正文块显示几行**（装不下第 4 行就只画 3 行，而不是画 3.4 行）。
    public static func fittingLineCount(boxHeight: CGFloat, fontSize: CGFloat) -> Int {
        let lh = lineHeight(fontSize)
        guard lh > 0 else { return 0 }
        return max(0, Int((max(0, boxHeight) + 0.001) / lh))
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
