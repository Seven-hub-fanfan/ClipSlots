import SwiftUI
import ClipSlotsKit

// MARK: - v2.11.7 hotfix24 · 居中预留行
//
// 专门解决顶栏的一类结构性问题：**中间那颗控件必须落在整行几何中线上，而它又不在布局流里。**
//
// 背景：工作区切换胶囊（编辑 / 画布）全 App 只有一份，挂在内容区根节点的 overlay 上按窗口中线
// 浮动（v2.11.7 hotfix22/23 —— 画布模式没有顶栏，胶囊只能按中线定位；编辑模式要和它逐像素对齐
// 就只能同样按中线走）。overlay 不参与布局，所以顶栏必须自己把中间那块宽度**让出来**。
//
// 原实现用 `Spacer(minLength: 8) + 透明占位 + Spacer(minLength: 8)` 让位，有两处致命问题：
//
//   1. 让出来的位置**不在中线上**。两个 Spacer 分的是「剩余空间」，剩余空间的中点取决于左右两簇
//      的宽度差；左簇 ~322、右簇 ~432 并不相等，占位块因此整体偏左。窗口越窄两个 Spacer 越接近
//      各自的 minLength 8，占位块与真正的中线越分越开 —— 实测 840pt 宽时胶囊已经压在
//      「自动粘贴」拨杆的标签上。
//   2. 放不下时**不会拒绝变窄**。HStack 面对「子视图总宽 > 提案宽度」不会把差额上报成父容器的
//      最小宽度（实测 contentMinSize 恒为 720，见 WindowLayoutMetrics 文件头），而是静默溢出、
//      再被窗口裁掉：logo 缺半个、齿轮掉出右边、搜索栏被压成 0 宽后内部「全部」菜单溢出到图标簇
//      底下叠字。
//
// 本 Layout 把这两点都变成**构造上不可能**：
//   • 中间永远精确挖在 `bounds.midX`，与两簇宽度无关 ⇒ overlay 里的胶囊必然落在挖出来的空档里。
//   • 两侧各拿到 `(width - centerWidth - 2*gap)/2`，且 `sizeThatFits` 把
//     `2*max(左最小, 右最小) + centerWidth + 2*gap` 如实上报为本行最小宽度 ⇒ 只要窗口最小宽度
//     不低于它，两簇就永远拿得到自己的最小宽度，不存在溢出。
//
// 用法：必须恰好两个子视图（左簇、右簇），中间那块由 `centerWidth` 描述、不占子视图位。
struct CenterReservedRow: Layout {
    /// 中间要让给浮动控件的宽度。
    var centerWidth: CGFloat
    /// 中间控件与左右两簇之间的最小留白。
    var gap: CGFloat = WindowLayoutMetrics.titleBarCenterGap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else {
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }
        // 两簇各自的**内在最小宽度**：给 width: 0 的提案即可问出来
        // （左簇是 .fixedSize，会如实回答自己的理想宽；右簇里搜索栏会回答窄变体的宽度）。
        let leftMin = subviews[0].sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width
        let rightMin = subviews[1].sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width
        let minWidth = WindowLayoutMetrics.centerReservedRowMinWidth(leftMin: leftMin,
                                                                    rightMin: rightMin,
                                                                    centerWidth: centerWidth,
                                                                    gap: gap)
        // 关键：把 minWidth 作为**下限**返回。父容器问最小尺寸（提案 width: 0）时拿到的就是它，
        // 这个值会一路传到 NSHostingView → NSWindow.contentMinSize，窗口因此拖不到更窄。
        let width = max(proposal.width ?? minWidth, minWidth)
        let half = WindowLayoutMetrics.centerReservedHalfWidth(totalWidth: width,
                                                              centerWidth: centerWidth,
                                                              gap: gap)
        let halfProposal = ProposedViewSize(width: half, height: proposal.height)
        let height = max(subviews[0].sizeThatFits(halfProposal).height,
                         subviews[1].sizeThatFits(halfProposal).height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let half = WindowLayoutMetrics.centerReservedHalfWidth(totalWidth: bounds.width,
                                                              centerWidth: centerWidth,
                                                              gap: gap)
        let sideProposal = ProposedViewSize(width: half, height: bounds.height)
        // 左簇贴左边、右簇贴右边，纵向都居中（与原 HStack 的默认 .center 对齐口径一致）。
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY),
                          anchor: .leading,
                          proposal: sideProposal)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY),
                          anchor: .trailing,
                          proposal: sideProposal)
    }
}
