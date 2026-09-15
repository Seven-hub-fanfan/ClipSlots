import CoreGraphics

// MARK: - v2.11.7 hotfix24 · 主窗口宽度预算
//
// 为什么需要这一份「宽度预算」：
//
// 用户反馈「缩小窗口（分有无智能体页面）会有 UI 错乱」。取证（PerfAutoTest 的 narrowshot 场景，
// 模式 × Agent 侧栏 × 宽度 三维叉乘出图 + clipcheck 逐行量留白）显示，错乱**不是**布局算法写错，
// 而是「窗口允许被缩到比内容真正需要的宽度更窄」：
//
//   • 主窗口最小宽度写死 720（main.swift 的 `.frame(minWidth: 720)`），而编辑页顶栏一行
//     （logo + 检查更新 + 两个拨杆 + 居中切换器 + 搜索栏 + 5 枚图标）实测要 ~840 才不被裁，
//     搜索栏内容不溢出、居中胶囊不压到拨杆则要更宽。
//   • 于是 720~840 这一段里：顶栏左右两簇双向溢出被窗口裁掉（logo 缺一半、齿轮掉出右边）、
//     页面行/组标签行/底栏同样顶到边缘、搜索栏被压到 0 宽后其内部「全部」筛选菜单溢出到
//     图标簇底下叠字、窗口正中的切换胶囊盖住「自动粘贴」拨杆标签。
//
// 关键教训（务必先读再改）：**SwiftUI 的 HStack 不会把「子视图放不下」上报成父容器的最小宽度**。
// 一堆 `.fixedSize()` 簇 + `Spacer(minLength: 8)` 组成的行，被压到放不下时不是拒绝变窄，
// 而是**静默溢出**再被窗口裁切。实测 `contentMinSize` 在内容明显溢出时仍稳定报 720x560、
// `NSHostingView.fittingSize` 更是直接返回 0x0。所以「靠内容自己顶住最小宽度」这条路走不通，
// 必须显式给窗口一个最小宽度。
//
// 这里只放**纯算术**（无 SwiftUI 依赖），以便 smoke 测试直接断言；真正的布局容器见
// `Sources/ClipSlots/CenterReservedRow.swift`。
public enum WindowLayoutMetrics {

    // MARK: - 顶栏：居中预留行

    /// 居中控件（工作区切换胶囊）与左右两簇之间的最小留白。
    public static let titleBarCenterGap: CGFloat = 12

    /// 「中间留给居中控件、两侧各占一半」这种行的最小宽度。
    ///
    /// 为什么是 `2 * max(左, 右)` 而不是 `左 + 右`：居中控件必须落在**整行的几何中线**上
    /// （v2.11.7 hotfix22/23 的硬约束 —— 画布模式没有顶栏，胶囊只能按窗口中线浮动，
    /// 编辑模式要与它逐像素对齐就只能同样按中线走）。中线固定 ⇒ 左右两个可用槽位宽度必然相等
    /// ⇒ 这个共同宽度必须同时容得下较宽的那一簇。这就是「真居中」的代价，无法通过重新分配消除。
    public static func centerReservedRowMinWidth(leftMin: CGFloat,
                                                 rightMin: CGFloat,
                                                 centerWidth: CGFloat,
                                                 gap: CGFloat = titleBarCenterGap) -> CGFloat {
        let half = max(max(leftMin, rightMin), 0)
        return 2 * half + max(centerWidth, 0) + 2 * max(gap, 0)
    }

    /// 给定整行宽度，左右两簇各自能用的宽度（两侧对称，中间挖掉居中控件 + 两道留白）。
    public static func centerReservedHalfWidth(totalWidth: CGFloat,
                                               centerWidth: CGFloat,
                                               gap: CGFloat = titleBarCenterGap) -> CGFloat {
        let usable = totalWidth - max(centerWidth, 0) - 2 * max(gap, 0)
        guard usable.isFinite else { return 0 }
        return max(0, usable / 2)
    }

    // MARK: - 内容区：工作区 + 侧栏

    /// 右侧 Agent 侧栏宽度（固定，不参与弹性分配）。
    /// 与 `AgentSidebarView.width` 必须一致 —— 后者引用本常量，避免两处各写一个数字。
    public static let agentSidebarWidth: CGFloat = 320

    /// 编辑页卡片区的最小可用宽度：一列卡片 + 左右内边距。再窄卡片本身就要被裁。
    public static let editWorkspaceMinWidth: CGFloat = 300

    /// 画布可视区（不含左侧槽位库）的最小宽度。再窄连一个节点卡片都摆不下。
    public static let canvasViewportMinWidth: CGFloat = 260

    /// 内容区一行（工作区 + 可选侧栏）的最小宽度。
    ///
    /// `libraryWidth` 是画布左侧槽位库当前占的宽度（展开 240 / 收起 44）；编辑页传 0。
    public static func contentRowMinWidth(canvas: Bool,
                                          libraryWidth: CGFloat,
                                          agentVisible: Bool) -> CGFloat {
        let workspace = canvas
            ? max(libraryWidth, 0) + canvasViewportMinWidth
            : editWorkspaceMinWidth
        return workspace + (agentVisible ? agentSidebarWidth : 0)
    }

    // MARK: - 窗口最小尺寸

    /// 主窗口内容区的最小宽度（与当前工作区**无关**）。
    ///
    /// 为什么必须与模式无关：画布模式没有顶栏，若让最小宽度随模式浮动，用户就能在画布里把窗口
    /// 缩到 720、再切回编辑 —— 顶栏当场溢出，等于没修。所以这里取「编辑页顶栏所需宽度」作为
    /// 全局下限，画布模式一起遵守。
    ///
    /// 数值来源：不是拍脑袋，而是 `CenterReservedRow` 在真机上按两簇的**内在最小宽度**算出来的
    /// 结果（取数手段见文件头注释）。实测：
    ///   左簇（logo + ClipSlots/检查更新 + 两个拨杆）  ≈ 322
    ///   右簇（搜索栏窄变体 ~232 + 5 枚 32pt 图标簇 192 + 间距） ≈ 432
    ///   ⇒ 行最小宽 = 2 × 432 + 130（胶囊）+ 24（两道留白）= 1018，加顶栏左右内边距 40 ⇒ 1058
    /// 取 1060 作为常量：比实测值只多 2pt，不留虚胖余量，同时是个整数便于口头交流。
    ///
    /// 想把这个数压下来，只能减少顶栏内容（例如窄窗下把「ClipSlots + 检查更新」收成纯 logo、
    /// 或把搜索栏折成一颗放大镜按钮）—— 那是功能取舍，不属于本次「修错乱」的范围。
    public static let minWindowContentWidth: CGFloat = 1060

    /// 主窗口内容区的最小高度。编辑页需要容下顶栏 + 页面行 + 组标签行 + 一行卡片 + 底栏。
    public static let minWindowContentHeight: CGFloat = 560
}
