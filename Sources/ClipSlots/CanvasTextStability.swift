import SwiftUI

// MARK: - 画布文字的「不许自作聪明」修饰（v2.11.8 三轮 hotfix2）
//
// ## 修的是什么
//
// 用户第二次录屏（20260916102744）里，Cmd+滚轮缩放时节点正文在**不停重新折行**：
// 「快速推进」/「快速推进(」两种断行来回跳、文本块底边上下抽动、下面整行「入参文件 6」被顶得一跳
// 一跳。图片是平滑的，只有文字在跳 —— 说明抖动来自**重排**，不是缩放本身。
//
// 重排有两个源头，必须两个都掐掉：
//   1. **排版尺寸变了** → 由 `CanvasZoomLayout` 的档位量化解决（同一档内 layoutZoom 不动）；
//   2. **同一个尺寸下 SwiftUI 自己改了字距 / 字号** → 就是这里要解决的。
//
// ## 为什么 (2) 会发生
//
// SwiftUI 的 `Text` 默认允许两种"救急"行为：`allowsTightening`（宽度差一点时收紧字距）和
// `minimumScaleFactor`（差得多时整体缩小字号）。二者都是**宽度协商的函数** —— 缩放过程中容器宽度
// 是连续变化的实数（`s(width)` 乘出来几乎永远带小数），于是同一段文字会在"收紧一点点塞进这一行"
// 与"塞不下、挪到下一行"之间反复横跳。这类跳变**与 layoutZoom 是否变化无关**，只要 GeometryReader
// 给出的宽度有亚像素抖动就会触发，所以单靠档位量化修不干净，必须显式关掉。
//
// 关掉的代价：极端窄宽度下文字会直接折行/截断，而不是"挤一挤"。这是刻意的取舍 —— 画布上卡片宽度
// 由用户拖定，稳定的版面比"尽量不换行"重要得多（用户的原话是「字体乱动」，不是「字挤在一起」）。
//
// ## 为什么不用 `.fixedSize` 一把梭
//
// `fixedSize(horizontal: false, vertical: true)` 只解决"高度随内容、别参与高度协商"，宽度方向的
// 字距/字号自适应依然生效。两者是互补的，卡片里的每个文字块**同时**需要。
extension View {
    /// 画布上所有文字块的统一约束：宽度吃满容器、高度随内容、**禁止字距收紧与字号自适应**。
    ///
    /// 用一个 modifier 而不是在每处手写三行，是为了让"哪些文字受此保护"可被 grep 出来 ——
    /// 漏掉一处的表现就是"整张卡只有那一行在跳"，肉眼很难定位到是哪一个修饰漏了。
    func canvasStableText() -> some View {
        self
            // 高度随内容，不参与高度协商（否则父容器一变高，文字块会被拉伸/压缩重排）。
            .fixedSize(horizontal: false, vertical: true)
            // 不许收紧字距：这是"同一宽度下换行位置来回跳"的直接肇因。
            .allowsTightening(false)
            // 不许缩小字号：1.0 = 只能用给定字号，塞不下就换行/截断。
            .minimumScaleFactor(1.0)
    }

    /// 单行文字（路径标识、状态角标、按钮标签等）的版本：不加 `fixedSize` 的垂直放行，
    /// 因为单行本来就不需要，加了反而会让 `lineLimit(1) + truncationMode` 的截断行为变奇怪。
    func canvasStableLabel() -> some View {
        self
            .allowsTightening(false)
            .minimumScaleFactor(1.0)
    }

    /// ★ 九轮：抹掉文字实际经历的**全部**上层缩放，让文字的**屏幕**尺寸精确恒定。
    ///
    /// `counter` 来自 `CanvasZoomLayout.textCounterScale(zoom:layoutZoom:)`（牌面卡还要再除掉
    /// 自己那层 `scaleEffect(layout.scale)`，见 `CanvasSlotFanStack.cardTextCounter`）。
    /// 它是精确倒数：静息态 ≤1，缩小手势进行中 >1 —— 九轮**取消了**八轮的 `min(1, ·)` 钳制，
    /// 因为那正是"缩小时文字仍跟着变小"的根因。这是**渲染期变换**，不改版面、不触发重排 ——
    /// 用改字号的方式去抵消残差会让每次缩放落定都重排一次文字，正是三轮修掉的「字体乱动」。
    ///
    /// `anchor` 必须与该文字块在卡片里的对齐方式一致：居中的文字用 `.center`，左对齐的正文用
    /// `.topLeading`。锚点选错的表现是"字变小的同时整块往某个方向缩过去"，看起来像布局在跳。
    func canvasScreenFixedText(_ counter: CGFloat, anchor: UnitPoint = .center) -> some View {
        scaleEffect(counter, anchor: anchor)
    }
}
