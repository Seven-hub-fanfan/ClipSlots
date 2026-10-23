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
        // ★ v2.11.11：回到屏幕恒定。用户的原话是“我就是不想让文字变大变小”，
        // 这是硬约束，不再拿它换稳定性。
        //
        // v2.11.10 把字号改成随缩放等比，确实令排版绝对稳定（每行字数与 zoom 无关），
        // 但代价就是用户最不想要的那个现象。既然“字号恒定 + 填满卡片宽度”必然意味着
        // 换行位置会随缩放变（每行字数 = 盒子宽 / 字号，分母恒定而分子随 zoom），
        // v2.11.11 的思路改成：**不再尝试消除重排，而是把重排的可见后果全部扦掉** ——
        // 正文区改成**定高盒子 + 永远填满 + 底部渐隐**（见 `CanvasNodeCardView.promptArea`）：
        //   - 盒子高度不随行数变 → 底部「入参文件」行、图片区、卡片高度全部不动（抽搜消失）；
        //   - 行数按盒子能装的量 +1 行并裁切，多出来的那行藏在渐隐里 → 既不留空白，
        //     行数增减也不再是“突然多一行/少一行”的跳变；
        //   - 手势进行中排版冻结（`layoutZoom` 不动），重排只在**停手落定后**发生一次，
        //     而且落定时 `layoutZoom == zoom` → 残差变换恒 1，静息态仍然 1:1 清晰。
        //
        // 剩下的唯一可见变化：停手后段内“哪个词跑到下一行”会变一次。这一条在字号恒定的
        // 前提下是数学上不可消除的（除非让正文列不填满卡片、留一道随缩放变宽的右侧空白，
        // 那是一个**常驻**的丑，比一次性的重排更难忍）。
        // ★★ v2.11.13：回到"字号 × 排版尺度"的朴素等比关系。
        //
        // 这不是又一次摇摆：v2.11.10 的等比之所以还会抖，是因为当时 `renderScale`（= layoutZoom）
        // 仍会随缩放落定而换档，换档就重算一次排版，字体度量/像素对齐的微小差异就够让换行位置
        // 变一下。v2.11.13 把 `renderScale` 钉成常量 `CanvasZoomLayout.layoutBaseScale`，排版
        // 从此**只算一次**，等比关系才真正兑现成"永不重排"。
        return max(0.01, designPt * max(0.01, renderScale))
    }

    /// 文字的**布局尺度** = `min(1, zoom)`（★ v2.11.12 · 用户第 6 次打回「还是会动」）。
    ///
    /// ## 为什么必须是 `min(1, zoom)` 而不是 1 或 zoom
    ///
    /// 「文字在屏幕上大小不变」（v2.11.11，尺度恒 1）与「文字排版不重流」这两件事，在
    /// **盒子宽度随 zoom 变**的前提下是互斥的：每行字数 = 盒子宽 / 字号，字号恒定而分子随
    /// zoom 走，换行位置就一定会变。v2.11.11 把重排的**后果**关进定高盒子里（底部按钮不再
    /// 抽搜），但重排本身还在 —— 用户看到的“还是会动”就是它。
    ///
    /// 破局的关键不是继续妥协字号，而是**把文字块的盒子也从 zoom 里摘出来**：
    /// 字号与文本列宽/块高**同乘一个尺度** `textScale`，于是「每行装几个字」与 zoom 无关，
    /// 换行位置、行数、段内布局在任何缩放下**逐字全等** —— 数学上不可能再重流。
    ///
    /// 尺度取 `min(1, zoom)` 的两段行为：
    ///   - **zoom ≥ 1（放大，用户读字的区间）**：尺度恒 1 → 字号 = 设计 pt（屏幕恒定，
    ///     满足“不想让文字变大变小”），文本列宽 = 1x 卡片内宽 → 文字块在屏幕上是一个
    ///     尺寸**完全不变**的块，只随卡片平移。缩放全程零重排、零字号变化。
    ///   - **zoom < 1（缩小看全局）**：尺度 = zoom → 文字与卡片**等比**缩小。等比不会重流
    ///     （分子分母同乘 zoom），观感与图片一致；小到 `hideCardTextBelowVisualSize` 以下
    ///     直接隐字。这里不敢再钉恒定字号：那会让文字块比卡片还宽、被裁掉右半边。
    ///
    /// 代价（写清楚，别再当 bug 排查）：zoom > 1 时文本列宽仍是 1x，正文区右侧/下方会出现
    /// 随缩放变大的留白。这是“字号恒定 + 绝不重排”的必然找零；若哪天用户更在意填满，
    /// 唯一的自洽出路是让**整张卡片**屏幕尺寸恒定（缩放只改卡片间距），而不是回到重排。
    /// ⚠️ v2.11.13 起**恒返 1**：排版尺度已由 `CanvasZoomLayout.layoutBaseScale` 统一接管，
    /// 文字不再有自己的一套尺度。保留符号只为不打断历史调用点/测试。
    public static func textScale(_ zoom: CGFloat) -> CGFloat {
        _ = zoom
        return 1
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
