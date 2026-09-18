import SwiftUI

// MARK: - 画布文字的「不许自作聪明」修饰
//
// ## 这个文件在十轮之后还剩什么
//
// 三轮 hotfix2 建立本文件时装了三个修饰：`canvasStableText` / `canvasStableLabel`（禁止字距收紧
// 与字号自适应）以及 `canvasScreenFixedText`（**文字反向补偿**，把上层缩放抵掉、让屏幕字号恒定）。
//
// 十轮按用户要求把第三个整个删除：反向补偿是"屏幕固定字号"路线的核心零件，而那条路线让容器与
// 文字变成两种量纲，正是文字溢出卡片边框 + 换行抖动的根因（完整推导见 `CanvasNodeText` 的类型
// 注释）。现在缩放只由节点层唯一一层 `scaleEffect(zoom)` 施加，文字与卡片同属一个相似变换 ——
// 没有任何"残差"需要抵消。**不要再把类似的补偿 modifier 加回来。**
//
// 留下的两个仍然有用，理由是它们跟缩放架构无关：
//
// SwiftUI 的 `Text` 默认允许两种"救急"行为 —— `allowsTightening`（宽度差一点时收紧字距）和
// `minimumScaleFactor`（差得多时整体缩小字号）。二者都是**宽度协商的函数**：容器宽度只要有亚像素
// 抖动（拖拽改宽、GeometryReader 回传值抖一下），同一段文字就会在"收紧一点点塞进这一行"与
// "塞不下、挪到下一行"之间反复横跳。十轮之后 zoom 已经不再改容器宽度，但**拖拽改节点尺寸**仍会，
// 所以这层保护继续留着。
//
// 关掉的代价：极端窄宽度下文字直接折行/截断，而不是"挤一挤"。这是刻意的取舍 —— 画布上卡片宽度
// 由用户拖定，稳定的版面比"尽量不换行"重要得多。
extension View {
    /// 画布上所有多行文字块的统一约束：宽度吃满容器、高度随内容、**禁止字距收紧与字号自适应**。
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
}
