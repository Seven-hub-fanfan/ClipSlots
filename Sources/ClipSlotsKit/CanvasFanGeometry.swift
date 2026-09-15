import Foundation
import CoreGraphics

/// 槽位节点「扇形堆叠卡片」的布局数学（v2.11.8）。
///
/// 用户要的效果：槽位的多条内容在节点里以一叠卡片呈现，鼠标悬停时以**底边中心为轴**向左右
/// 扇形展开（fan-out），单张卡片再悬停会抬起放大。
///
/// 为什么这套数学必须下沉到 Kit（不是洁癖，是本项目踩过的坑）：
/// v2.11.0 的轮盘缩略图翻车就是因为极坐标布局写在 View 里 —— 往 VStack 里加元素等于沿**屏幕
/// 垂直方向**位移，而不是沿径向，10 槽位下角偏差 25°~30° 却没有任何测试能发现，最后靠离屏
/// 截图对照才定位。扇形展开同样是「一个符号错就整体歪掉、但看起来像是设计如此」的几何：
/// 角度对称性、层级顺序、收拢/展开的相对关系都在这里用断言钉死。
///
/// 约定：
///   - **角度单位是度**，正值 = 顺时针（向右倒）。SwiftUI 的 `.rotationEffect(.degrees(_))`
///     正值也是顺时针，两边同号，避免"翻译"时手滑取反。
///   - 旋转锚点固定为 `pivotAnchor`（底边中心）。这是「以底部为轴心展开」的全部实现 ——
///     锚点若用默认的 center，卡片会绕自己中心转，观感是散落而不是扇形。
///   - `offset` 是**卡片空间**的额外位移（pt，1x），渲染侧再按画布 zoom 缩放。
public enum CanvasFanGeometry {

    // MARK: - 常量（数值来自用户给的交互规格）

    /// 收拢态相邻卡片的角度差。小到只是"一叠没对齐的纸"，不是扇形。
    public static let collapsedSpread: CGFloat = 4.5
    /// 展开态相邻卡片的角度差。
    public static let expandedSpread: CGFloat = 17
    /// 收拢态相邻卡片的横向错位（露出后面卡片的边缘，提示"还有几张"）。
    public static let collapsedStagger: CGFloat = 3.5
    /// 展开态额外的横向张开量：只靠旋转的话，卡片顶端分开、底端仍然叠在一起。
    public static let expandedStagger: CGFloat = 9
    /// 单卡悬停时的抬起位移（用户指定 -8pt）。
    public static let hoverLift: CGFloat = -8
    /// 单卡悬停时的放大倍数（用户指定 1.08）。
    public static let hoverScale: CGFloat = 1.08
    /// 最多同时展示的卡片数。超出的内容不进扇形 —— 5 张以上在 168pt 宽的节点里必然互相糊成一团。
    public static let maxCards: Int = 4
    /// 纯文本槽位最多切成几张卡片（用户指定 3）。
    public static let maxTextCards: Int = 3

    /// 旋转与缩放的锚点：底边中心。
    public static let pivotAnchor = CGPoint(x: 0.5, y: 1.0)

    // MARK: - 单张卡片的布局

    public struct CardLayout: Equatable {
        public let index: Int
        /// 旋转角（度，正 = 顺时针）。
        public let angle: CGFloat
        /// 额外位移（pt，1x 卡片空间）。
        public let offset: CGSize
        public let scale: CGFloat
        public let zIndex: Double

        public init(index: Int, angle: CGFloat, offset: CGSize, scale: CGFloat, zIndex: Double) {
            self.index = index
            self.angle = angle
            self.offset = offset
            self.scale = scale
            self.zIndex = zIndex
        }
    }

    /// 计算整叠卡片的布局。
    ///
    /// - Parameters:
    ///   - count: 卡片数量（会被夹到 `1...maxCards`；0 张也返回 1 张 —— 空槽位要显示一张虚线空卡）。
    ///   - expanded: 整个节点是否处于 hover 展开态。
    ///   - hoveredIndex: 当前被单独悬停的卡片下标（nil = 没有）。
    ///
    /// 角度构造为 `(i - (n-1)/2) * spread`：**关于中轴严格对称**，因此任意张数下这叠卡片的
    /// 视觉重心都在节点正中，不会随张数奇偶跳动。
    public static func layouts(count: Int,
                               expanded: Bool,
                               hoveredIndex: Int? = nil) -> [CardLayout] {
        let n = min(max(count, 1), maxCards)
        let spread = expanded ? expandedSpread : collapsedSpread
        let stagger = expanded ? expandedStagger : collapsedStagger
        let mid = CGFloat(n - 1) / 2

        return (0..<n).map { i in
            let k = CGFloat(i) - mid
            let isHovered = (hoveredIndex == i)
            // 收拢态还有一点纵向下沉，让后面的卡片像被压在下面；展开态不下沉（要看清内容）。
            let sink: CGFloat = expanded ? 0 : abs(k) * 1.5
            let lift: CGFloat = isHovered ? hoverLift : 0
            return CardLayout(index: i,
                              angle: k * spread,
                              offset: CGSize(width: k * stagger, height: sink + lift),
                              scale: isHovered ? hoverScale : 1,
                              // 被悬停的卡片必须压住相邻卡片的边缘（用户明确要求 Z 层提升），
                              // 否则放大 1.08 的那 8% 会被邻居切掉一条边，看起来像渲染错误。
                              zIndex: isHovered ? 100 : Double(i))
        }
    }

    // MARK: - 内容 → 卡片

    /// 纯文本槽位切卡片。
    ///
    /// 规则：先按空行分段（用户手写的段落边界最可信），不够再按换行，仍然只有一段就整段作一张。
    /// **不按固定字数硬切**：中英混排下按字数切会把一个词劈成两半，卡片上呈现的是乱码感。
    public static func textSegments(_ text: String, limit: Int = maxTextCards) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard limit > 0 else { return [] }

        func clean(_ list: [String]) -> [String] {
            list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        var parts = clean(trimmed.components(separatedBy: "\n\n"))
        if parts.count < 2 {
            parts = clean(trimmed.components(separatedBy: .newlines))
        }
        if parts.isEmpty { parts = [trimmed] }
        return Array(parts.prefix(limit))
    }

    /// 一个槽位在画布上应该显示几张卡片、每张是什么。
    ///
    /// 优先级刻意与项目既有的「存入逻辑」同向：**图片附件是最具体的内容，优先成卡**；没有图片
    /// 附件时才把正文切段；两者都没有（空槽）→ 一张空卡。
    public enum CardSource: Equatable {
        case attachmentIndex(Int)
        case textSegment(String)
        case empty
    }

    public static func cardSources(attachmentImageIndices: [Int],
                                   text: String) -> [CardSource] {
        if !attachmentImageIndices.isEmpty {
            return attachmentImageIndices.prefix(maxCards).map { .attachmentIndex($0) }
        }
        let segments = textSegments(text)
        if !segments.isEmpty {
            return segments.map { .textSegment($0) }
        }
        return [.empty]
    }
}
