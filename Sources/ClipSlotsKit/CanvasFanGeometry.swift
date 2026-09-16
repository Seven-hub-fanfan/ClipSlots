import Foundation
import CoreGraphics

/// 槽位节点「堆叠卡片」的布局数学（v2.11.8）。
///
/// 用户要的效果：槽位的多条内容在节点里以一叠卡片呈现，鼠标悬停时展开。展开有**两种**风格，
/// 由节点自身的 `animationStyle` 决定：
///   - `.fanOut`   扇形：以**底边中心为轴**向左右扇开。
///   - `.carousel` 轮播：水平铺开成一排，同屏 3 张，左右箭头翻页。
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
    ///
    /// ★ v2.11.8 二轮：**17° → 20°**。用户实测反馈「展开很难选到第二个」「没有办法选择中间的」。
    /// 根因是每张卡的**独立可点面积**太小：卡片宽 ≈ 高 × 0.82，绕底边中心转 17° 时，相邻两卡
    /// 在下半部几乎完全重合，只有靠顶端一道窄楔形是"只属于自己"的；而 zIndex 是右压左，于是
    /// 中间那几张剩下的可点区域就是几个像素宽的月牙。角度加到 20° 并把横向张开量提到 12pt 后，
    /// 每张卡的独立楔形宽度大约翻倍。
    ///
    /// 为什么不继续加大：20° × 5 张 = 总张角 80°，最外侧卡片已经倒到接近水平，再大就不像"一叠卡"
    /// 而像"散落一地"，且会大幅溢出预览区撞到相邻节点。
    public static let expandedSpread: CGFloat = 20

    /// 收拢态相邻卡片的横向错位（露出后面卡片的边缘，提示"还有几张"）。
    public static let collapsedStagger: CGFloat = 3.5

    /// 展开态额外的横向张开量：只靠旋转的话，卡片顶端分开、底端仍然叠在一起。
    /// ★ v2.11.8 二轮：9 → 12，与 20° 配套拉开独立可点区域。
    public static let expandedStagger: CGFloat = 12

    /// 单卡悬停时的抬起位移。
    /// ★ v2.11.8 二轮：扇形态用户指定 -10pt（轮播态仍是 -8pt，见 `carouselHoverLift`）。
    public static let hoverLift: CGFloat = -10
    /// 单卡悬停时的放大倍数（用户指定 1.08）。
    public static let hoverScale: CGFloat = 1.08

    /// 扇形最多同时展开几张。
    /// ★ v2.11.8 二轮：4 → 5（用户指定）。超出的张数收进最外侧那张的 `+N` 角标。
    public static let maxCards: Int = 5

    /// 轮播态同屏展示几张（用户指定 3）。
    public static let carouselVisible: Int = 3
    /// 轮播态单卡悬停抬起位移（用户指定 -8pt）。
    public static let carouselHoverLift: CGFloat = -8
    /// 轮播态卡片间距（pt，1x）。均匀、不重叠是这个模式的全部意义。
    public static let carouselGap: CGFloat = 8

    /// 纯文本槽位最多切成几张卡片。
    /// ★ v2.11.8 二轮：3 → 5，与 `maxCards` 对齐（否则纯文本槽位永远吃不到第 4/5 张卡）。
    public static let maxTextCards: Int = 5

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

    /// 展开风格。持久化在 `CanvasNode.animationStyle`。
    public enum ExpandStyle: String, Codable, CaseIterable, Equatable {
        case fanOut
        case carousel
    }

    // MARK: - 扇形布局

    /// 计算整叠卡片的扇形布局。
    ///
    /// - Parameters:
    ///   - count: 卡片数量（会被夹到 `1...maxCards`；0 张也返回 1 张 —— 空槽位要显示一张虚线空卡）。
    ///   - expanded: 整个节点是否处于 hover 展开态。
    ///   - hoveredIndex: 当前被单独悬停的卡片下标（nil = 没有）。
    ///
    /// 角度构造为 `(i - (n-1)/2) * spread`：**关于中轴严格对称**，因此任意张数下这叠卡片的
    /// 视觉重心都在节点正中，不会随张数奇偶跳动。
    ///
    /// ## 层级方向：第 1 张在最上（★ v2.11.8 四轮，用户反馈）
    ///
    /// 四轮之前 `zIndex = Double(i)`，也就是**下标越大越靠前** —— 视觉上是"左底右顶"，最右边那张
    /// （内容顺序里的最后一张）压在所有卡片之上。用户明确要反过来：「第 1 张卡片在最左侧且在视觉最顶层，
    /// 后续卡片依次向右延伸且层级递减」。
    ///
    /// 所以现在是 `zIndex = Double(n - 1 - i)`：第 0 张最高，越往右越低。这不只是观感偏好 ——
    /// 卡片顺序本身是有语义的（附件列表首位 = 缩略图 / 圆盘 / 生成时取的那一张，见"设为入参"），
    /// 让首位那张被压在最底下等于把最重要的一张藏起来。
    ///
    /// **位置与角度刻意不动**：第 0 张本来就在最左（`k = -mid` → offset 为负），角度也已经是
    /// 左倾。若按字面把角度一起取反，就会出现"卡片待在左边却向右倾"，相邻卡片互相穿插，
    /// 观感是散落而不是一叠。扇形张开的方向（左→右）与"第 1 张在最左"本来就是一致的。
    ///
    /// `hitTest` 按 zIndex 从高到低遍历，所以命中优先级会**自动**跟着反转，不需要另外改 ——
    /// 这正是当初把命中判定从"各卡自己 onHover"改成统一命中层的收益。
    public static func layouts(count: Int,
                               expanded: Bool,
                               hoveredIndex: Int? = nil) -> [CardLayout] {
        // ★ v2.11.8 三轮：上界从 `maxCards` 放到 `maxCards + 1`。
        //
        // 多出来的那一格是翻页用的灰色「+N」卡（见 `CanvasFanPaging`）—— 它必须和牌面卡走**同一套**
        // 扇形数学，否则它的角度/错位与旁边的卡对不上，看起来像一张歪掉的卡而不是"这叠还有后续"。
        // 夹到 maxCards 的旧上界会让第 6 格被静默丢掉（症状：翻页入口整个不见）。
        let n = min(max(count, 1), maxCards + 1)
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
                              //
                              // ★ 四轮：静息层级由 `Double(i)` 反转为 `Double(n - 1 - i)`
                              // —— 第 1 张在最顶层，越靠右越靠底层（见类型注释）。
                              zIndex: isHovered ? 100 : Double(n - 1 - i))
        }
    }

    // MARK: - 轮播布局

    /// 计算水平轮播的布局（同屏 `carouselVisible` 张，均匀排列、互不重叠）。
    ///
    /// - Parameters:
    ///   - count: 当前页实际要显示的卡片数（≤ `carouselVisible`）。
    ///   - cardWidth: 单卡宽度（1x）。
    ///   - hoveredIndex: 被悬停的卡片下标（页内下标，0 起）。
    ///
    /// 与扇形的关键差异：**角度恒为 0**。轮播的可点性来自"物理上不重叠"，一旦带了旋转，
    /// 相邻卡片的角部就会互相探入，又回到扇形那个"看得见点不着"的问题。
    ///
    /// 层级同样是"第 1 张最高"（★ 四轮，与扇形保持一致）。轮播态卡片本来不重叠，层级平时看不出来，
    /// 但 hover 放大 1.08 的瞬间会短暂相交 —— 两种风格用同一套层级方向，切换风格时才不会
    /// 出现"同一叠卡的前后关系突然反过来"。
    public static func carouselLayouts(count: Int,
                                       cardWidth: CGFloat,
                                       hoveredIndex: Int? = nil) -> [CardLayout] {
        let n = max(count, 1)
        let step = cardWidth + carouselGap
        let mid = CGFloat(n - 1) / 2
        return (0..<n).map { i in
            let k = CGFloat(i) - mid
            let isHovered = (hoveredIndex == i)
            return CardLayout(index: i,
                              angle: 0,
                              offset: CGSize(width: k * step,
                                             height: isHovered ? carouselHoverLift : 0),
                              scale: isHovered ? hoverScale : 1,
                              zIndex: isHovered ? 100 : Double(n - 1 - i))
        }
    }

    /// 轮播翻页：当前页码 + 方向 → 新页码（**循环**）。
    ///
    /// 用户明确要「循环翻页」：50 张的情况下左右翻即可，不需要全部展开。
    public static func carouselPage(current: Int, delta: Int, total: Int) -> Int {
        let pages = carouselPageCount(total: total)
        guard pages > 0 else { return 0 }
        let raw = (current + delta) % pages
        return raw < 0 ? raw + pages : raw
    }

    public static func carouselPageCount(total: Int) -> Int {
        guard total > 0 else { return 1 }
        return (total + carouselVisible - 1) / carouselVisible
    }

    /// 某一页对应的原始下标区间。
    public static func carouselRange(page: Int, total: Int) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        let pages = carouselPageCount(total: total)
        let p = min(max(page, 0), pages - 1)
        let start = p * carouselVisible
        let end = min(start + carouselVisible, total)
        return start..<end
    }

    // MARK: - 卡片尺寸与展开包围盒（★ v2.11.8 五轮）

    /// 扇形态卡片尺寸（1x）。比预览区窄一圈：扇开时靠旋转向两侧溢出，卡片本身再宽就会把邻卡完全盖住。
    ///
    /// 五轮从 `CanvasSlotFanStack.fanCardSize` 搬到 Kit —— 不是为了整洁，是因为 hover 维持区
    /// （`CanvasNodeHover.holdRect`）必须知道这叠卡到底会张到多宽，而那是 Kit 里的纯计算。
    /// 留在 View 里就只能在两处各写一份同样的 `0.82`，改一处忘一处的下场是维持区比扇形窄，
    /// 表现为"鼠标移到最外侧那张卡上，扇形突然收了"——正是五轮要修的 bug。
    public static func fanCardSize(boxHeight: CGFloat) -> CGSize {
        let h = min(132, max(64, boxHeight - 10))
        return CGSize(width: h * 0.82, height: h)
    }

    /// 展开态整叠卡片相对**预览区中心**的最大横向半宽（1x，已含 hover 放大）。
    ///
    /// 用来回答一个具体问题：扇形会不会张到节点卡片的边框外面去？会的话 hover 维持区就得外扩，
    /// 否则鼠标追着最外侧那张卡走出节点边界，`onHover` 判定为"离开"，扇形当场收拢。
    ///
    /// 取所有 slot、以及"每个 slot 分别被 hover"两种情况的顶点并集 —— hover 会放大 1.08，
    /// 最外侧那张被 hover 时比静息时更宽。
    public static func expandedHalfWidth(slotCount: Int, cardSize: CGSize) -> CGFloat {
        var half: CGFloat = 0
        // hoveredIndex = nil 先算一遍静息，再逐个 slot 算 hover 态。
        let variants: [Int?] = [nil] + (0..<max(1, slotCount)).map { Optional($0) }
        for hovered in variants {
            let ls = layouts(count: slotCount, expanded: true, hoveredIndex: hovered)
            for l in ls {
                for p in cardPolygon(layout: l, cardSize: cardSize, containerSize: .zero) {
                    half = max(half, abs(p.x))
                }
            }
        }
        return half
    }

    // MARK: - 碰撞箱：旋转后的实际多边形

    /// 一张卡片经过 `offset` / `rotation`（锚点=底边中心）/ `scale` 之后的四个顶点。
    ///
    /// ★ v2.11.8 二轮，用户明确要求：「碰撞箱改用**旋转后的实际多边形**（而不是原始矩形），
    /// 按旋转角度计算 4 个顶点的真实坐标」。
    ///
    /// 为什么必须自己算而不能靠 SwiftUI 的命中测试：SwiftUI 对 `rotationEffect` 后的视图**确实**
    /// 会做正确的逆变换命中，问题出在**遮挡**上 —— 相邻卡片是不透明的白卡，谁在上面谁吃掉事件，
    /// 于是被压住的那几张只剩几像素可点。改成自己算多边形之后，命中层是**一整块**透明视图，
    /// 由这里的 `hitTest` 从**最上层往下**找第一个包含鼠标点的卡片，语义与"看到谁就点到谁"完全一致，
    /// 而且不会因为 SwiftUI 的子视图 hover 抢焦点而抖动。
    ///
    /// 变换顺序必须与渲染侧一致：`scaleEffect(anchor:.bottom)` → `rotationEffect(anchor:.bottom)`
    /// → `offset`。顺序换了会在大角度时肉眼可见地错位。
    ///
    /// - Parameters:
    ///   - layout: 该卡片的布局。
    ///   - cardSize: 卡片原始尺寸（1x）。
    ///   - containerSize: 命中层尺寸（1x）；卡片在其中**居中**摆放。
    /// - Returns: 顺时针 4 顶点（容器坐标系，y 向下）。
    public static func cardPolygon(layout: CardLayout,
                                   cardSize: CGSize,
                                   containerSize: CGSize) -> [CGPoint] {
        // 卡片在容器里居中 → 未变换时的矩形。
        let cx = containerSize.width / 2
        let cy = containerSize.height / 2
        let halfW = cardSize.width / 2
        let halfH = cardSize.height / 2

        // 锚点（底边中心）在容器坐标里的位置。scale / rotation 都绕它。
        let pivot = CGPoint(x: cx, y: cy + halfH)

        // 未变换的四角（相对锚点）。
        let raw: [CGPoint] = [
            CGPoint(x: -halfW, y: -cardSize.height),  // 左上
            CGPoint(x:  halfW, y: -cardSize.height),  // 右上
            CGPoint(x:  halfW, y: 0),                 // 右下
            CGPoint(x: -halfW, y: 0)                  // 左下
        ]

        let rad = layout.angle * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        let s = layout.scale

        return raw.map { p in
            // 1) 绕锚点缩放
            let sx = p.x * s
            let sy = p.y * s
            // 2) 绕锚点顺时针旋转（y 向下的坐标系里顺时针就是标准旋转矩阵）
            let rx = sx * cosA - sy * sinA
            let ry = sx * sinA + sy * cosA
            // 3) 回到容器坐标 + offset
            return CGPoint(x: pivot.x + rx + layout.offset.width,
                           y: pivot.y + ry + layout.offset.height)
        }
    }

    /// 卡片自身归一化坐标（0…1，左上为原点）里的一点，变换到容器坐标。
    ///
    /// ★ 五轮新增。用途很具体：「+N」灰卡沉到牌面之下后，它**居中**的文字正好落在被邻卡盖住的
    /// 那半边（实机截图 v5-crop：只看得见一条描边，`+2` 一个字都看不到）。要把文字挪到露出的楔形里，
    /// 就得能在测试里回答"卡片上的某个相对位置，变换后落在容器的哪里、是不是还露着"——
    /// 也就是 `hitTest(cardPoint(unit: 标签锚点)) == 灰卡那一格`。
    ///
    /// 变换与 `cardPolygon` 共用同一段数学（四角其实就是 unit = (0,0)/(1,0)/(1,1)/(0,1)）。
    public static func cardPoint(layout: CardLayout,
                                 cardSize: CGSize,
                                 containerSize: CGSize,
                                 unit: CGPoint) -> CGPoint {
        let cx = containerSize.width / 2
        let cy = containerSize.height / 2
        let halfW = cardSize.width / 2
        let halfH = cardSize.height / 2
        let pivot = CGPoint(x: cx, y: cy + halfH)

        // 相对锚点（底边中心）的未变换位置。
        let raw = CGPoint(x: (unit.x - 0.5) * cardSize.width,
                          y: (unit.y - 1.0) * cardSize.height)

        let rad = layout.angle * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        let sx = raw.x * layout.scale
        let sy = raw.y * layout.scale
        return CGPoint(x: pivot.x + (sx * cosA - sy * sinA) + layout.offset.width,
                       y: pivot.y + (sx * sinA + sy * cosA) + layout.offset.height)
    }

    /// 点是否落在凸多边形内（含边）。
    ///
    /// 用叉积同号法而不是射线法：卡片四边形一定是凸的，叉积法没有"射线正好穿过顶点"那类退化情况。
    public static func polygonContains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var positive = false
        var negative = false
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross > 1e-9 { positive = true }
            if cross < -1e-9 { negative = true }
            if positive && negative { return false }
        }
        return true
    }

    /// 命中测试：鼠标点落在哪张卡片上。
    ///
    /// 从 **zIndex 最高**的卡片往下找第一个命中的 —— 与视觉遮挡关系严格一致（上面那张吃事件）。
    /// 都没命中返回 nil（此时只算"悬停了节点"，不高亮任何卡片）。
    public static func hitTest(point: CGPoint,
                               layouts: [CardLayout],
                               cardSize: CGSize,
                               containerSize: CGSize) -> Int? {
        let ordered = layouts.sorted { $0.zIndex > $1.zIndex }
        for layout in ordered {
            let poly = cardPolygon(layout: layout, cardSize: cardSize, containerSize: containerSize)
            if polygonContains(poly, point) { return layout.index }
        }
        return nil
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
    /// 优先级刻意与项目既有的「存入逻辑」同向：**入参文件是最具体的内容，优先成卡**；没有附件时
    /// 才把正文切段；两者都没有（空槽）→ 一张空卡。
    public enum CardSource: Equatable {
        case attachmentIndex(Int)
        case textSegment(String)
        case empty
    }

    /// 全量卡片来源（**不截断**）。轮播模式与 `+N` 角标都要知道真实总数。
    ///
    /// ★ v2.11.8 三轮：入参从 `attachmentImageIndices` 改名为 `attachmentIndices` —— 语义从
    /// 「只有图片类附件成卡」放宽到「**所有**附件都成卡」。改名而不是沿用旧标签，是因为旧名字会
    /// 继续引导调用方在外面先按 `canvasIsImageLike` 过一遍，而这正是用户反馈的
    /// 「卡片不显示非图像文件」的根因：面板说 5 项、卡叠只画 3 张（见 `CanvasAttachmentKind`）。
    public static func allCardSources(attachmentIndices: [Int],
                                      text: String) -> [CardSource] {
        if !attachmentIndices.isEmpty {
            return attachmentIndices.map { .attachmentIndex($0) }
        }
        let segments = textSegments(text, limit: Int.max)
        if !segments.isEmpty {
            return segments.map { .textSegment($0) }
        }
        return [.empty]
    }

    /// 扇形模式实际渲染的卡片来源（截到 `maxCards`）。
    public static func cardSources(attachmentIndices: [Int],
                                   text: String) -> [CardSource] {
        Array(allCardSources(attachmentIndices: attachmentIndices, text: text)
                .prefix(maxCards))
    }

    /// 扇形模式最外侧那张卡上的 `+N` 数字（N = 总数 − maxCards）。0 表示不显示角标。
    public static func overflowCount(total: Int) -> Int {
        max(0, total - maxCards)
    }
}
