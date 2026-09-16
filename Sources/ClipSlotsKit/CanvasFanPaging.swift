import Foundation
import CoreGraphics

/// 堆叠卡片的**翻页窗口**（v2.11.8 三轮 hotfix2）。
///
/// ## 为什么要有窗口这个概念
///
/// 二轮的规则是「扇形只画前 5 张，多出来的塞进右下角 `+N` 角标，点角标弹一个缩略图网格」。
/// 用户实测后否掉了：「当卡片含 5 张以上图片时，第 6 张以后看不到」—— 角标里的网格是**另一种**
/// 呈现（小方格），并不是"翻到后面几张卡"，所以第 6 张之后从来没以卡片形态出现过。
///
/// 三轮改成真正的翻页：卡片是一个在全量数组上滑动的**窗口**，最多 5 个牌面位；窗口之后还有内容时，
/// 第 6 个位置放一张灰色半透明的「+N」卡（同尺寸同圆角，用户指定），点它把窗口往后推。
///
/// ## 关键约束：**永远保留参考卡**（用户两次强调）
///
/// 「必须留一张前面的卡片做参考」「无论向前还是向后翻页，展示区第一个或最后一个位置必须保留
/// 上一页的最后一张（或第一张）作为参考卡（灰色遮罩），永远不会整页替换」。
///
/// 所以翻页步长是 `maxCards - 1` 而不是 `maxCards`：
///
/// ```text
///   总 12 张，窗口 5：
///   第一页  [0 1 2 3 4] +7        ← 无参考卡（本来就是开头）
///   前进 →  [4 5 6 7 8] +3        ← 位置 0 的 4 是上一页最后一张，灰
///   前进 →  [8 9 10 11]           ← 位置 0 的 8 是参考卡，灰；已到底，无 +N
///   后退 ←  [4 5 6 7 8] …         ← 从后往前翻时，参考卡在**最后一个**位置（下一页的第一张）
/// ```
///
/// 这个"重叠一张"的设计不是装饰：卡片本身没有序号，整页替换后用户完全失去"我翻到哪了"的锚点
/// （这正是二轮网格浮层被否掉的另一半原因）。
///
/// ## 为什么放在 Kit
///
/// 翻页边界是典型的"差一"重灾区：`hasNext` 少算一张会让最后一张永远看不到（正是本次要修的 bug 本身），
/// 参考卡下标算错会让灰遮罩盖在新卡上。这些全部在 smoke 里钉住，不靠肉眼。
extension CanvasFanGeometry {

    /// 参考卡（上一页残留的那张）的灰色遮罩不透明度。用户指定 0.4。
    public static let referenceDimOpacity: CGFloat = 0.4
    /// 「+N」灰卡自身的不透明度。用户指定 0.5。
    public static let overflowCardOpacity: CGFloat = 0.5
    /// 鼠标压在「+N」灰卡露出部分时的不透明度（★ 五轮）。
    ///
    /// 灰卡沉到牌面之下、不再是 `Button` 之后，它失去了 hover 光标与整卡可点性这两种"我能点"的
    /// 暗示。提浓 0.5 → 0.72 是替代方案：仍然明显比牌面淡（还是"不是真牌面"），但足以让人确认
    /// 鼠标位置有效。不要提到 1.0 —— 那会让它看起来变成了一张真牌面。
    public static let overflowCardHotOpacity: CGFloat = 0.72

    /// 「+N」文字在灰卡自身归一化坐标里的锚点（★ 五轮）。
    ///
    /// 不是 (0.5, 0.5)。灰卡沉到牌面之下后，居中的文字正好落在被左邻卡盖住的那半边 ——
    /// 实机截图 v5-crop 里只剩一条白描边，`+2` 一个字都看不见，"还有更多"这个信息就丢了。
    ///
    /// 这个值是算出来的：把露出的那块楔形（`hitTest` 判给灰卡的全部采样点）逆变换回卡片自身坐标，
    /// 取重心 = (0.68, 0.36)。楔形集中在卡片右上偏中 —— 因为灰卡比左邻卡多转 20°，
    /// 露出来的是"右上角那片扇形"，而不是想象中"右边一条竖缝"。
    /// smoke 里用 `cardPoint` 正向验证这个锚点确实落在灰卡露出的部分上。
    public static let overflowLabelAnchor = CGPoint(x: 0.68, y: 0.36)

    /// 左右翻页箭头再往容器内收的距离（1x，★ 五轮）。
    ///
    /// 预览区本身只比节点边框内缩 12pt，箭头贴着预览区边缘就意味着按钮距**节点边界**只有 12pt。
    /// 录屏 20260916125646 里那次"扇形突然收拢"就是伸手去点左箭头时过冲 12px 出了节点边界
    /// （见 `CanvasNodeHover`）。这 6pt 不解决根因（根因靠 hover 维持区 + 宽限期），
    /// 但把"必须精确摸到边缘"这个动作难度降下来。
    public static let arrowLaneInset: CGFloat = 6

    /// 一屏窗口的解算结果。
    public struct CardWindow: Equatable {
        /// 全量数组里的起点下标。
        public let start: Int
        /// 本页实际牌面数（≤ maxCards，末页可能不足）。
        public let count: Int
        public let total: Int
        /// 窗口内哪个位置是**参考卡**（0-based，nil = 本页没有参考卡，即停在开头）。
        public let referenceSlot: Int?
        public let hasPrev: Bool
        public let hasNext: Bool
        /// 窗口之后还剩几张（`+N` 的 N）。
        public let remaining: Int

        /// 是否需要在第 `count` 个位置画那张灰色「+N」卡。
        public var showsOverflowCard: Bool { remaining > 0 }
        /// 含「+N」卡在内，本页一共要摆几个位置（扇形布局按它算角度）。
        public var slotCount: Int { count + (showsOverflowCard ? 1 : 0) }
        /// 窗口覆盖的全量下标区间。
        public var indices: Range<Int> { start ..< (start + count) }

        public init(start: Int, count: Int, total: Int,
                    referenceSlot: Int?, hasPrev: Bool, hasNext: Bool, remaining: Int) {
            self.start = start
            self.count = count
            self.total = total
            self.referenceSlot = referenceSlot
            self.hasPrev = hasPrev
            self.hasNext = hasNext
            self.remaining = remaining
        }
    }

    /// 解一个窗口。
    ///
    /// - Parameters:
    ///   - total: 全量卡片数。
    ///   - start: 期望起点（会被夹进合法范围；越界不是错误，翻页 / 删卡都可能让它临时越界）。
    ///   - arrivedBackward: 是否**由后退（⬅）到达**本页。它只影响参考卡摆在头还是尾：
    ///     前进时用户的视线跟着"新卡从右边进来"，参考卡该留在**头部**；后退时反过来，留在**尾部**。
    ///   - maxCards: 窗口容量（扇形 5，轮播 3）。
    public static func cardWindow(total: Int,
                                  start: Int,
                                  arrivedBackward: Bool = false,
                                  maxCards: Int = CanvasFanGeometry.maxCards) -> CardWindow {
        let cap = max(1, maxCards)
        guard total > 0 else {
            // 空槽位：外部仍要画一张虚线空卡，所以 count 给 1、total 给 0。
            return CardWindow(start: 0, count: 1, total: 0,
                              referenceSlot: nil, hasPrev: false, hasNext: false, remaining: 0)
        }
        // 夹起点：不能负，也不能超过"最后一页的起点"。
        // 末页起点不是 total-1（那样末页只剩一张、参考卡都摆不下），而是 total-cap 与 0 的较大者。
        let maxStart = max(0, total - cap)
        let s = min(max(0, start), maxStart)
        let count = min(cap, total - s)
        let remaining = total - (s + count)
        let hasPrev = s > 0
        let hasNext = remaining > 0
        // 参考卡：后退到达且后面还有内容 → 尾部那张就是"下一页的第一张"，标灰；
        // 否则只要不是从头开始，头部那张就是"上一页的最后一张"，标灰。
        let reference: Int?
        if arrivedBackward && hasNext {
            reference = count - 1
        } else if hasPrev {
            reference = 0
        } else {
            reference = nil
        }
        return CardWindow(start: s, count: count, total: total,
                          referenceSlot: reference, hasPrev: hasPrev, hasNext: hasNext,
                          remaining: remaining)
    }

    /// 前进（点「+N」卡或 ➡）后的新起点。
    ///
    /// 步长 = `count - 1`：把本页**最后一张**留到下一页的头部当参考卡（用户强调的"永远不整页替换"）。
    /// 已经到底时按用户要求**回到开头**（「点击 ➡ 到达末尾时，继续点击 ➡ 则直接跑到开头」）。
    public static func forwardStart(from window: CardWindow) -> Int {
        guard window.hasNext else { return 0 }
        return window.start + max(1, window.count - 1)
    }

    /// 后退（点 ⬅）后的新起点。
    ///
    /// 同样重叠一张：新窗口的**尾部**是当前页的第一张。已在开头时保持不动（按钮此时本就不显示）。
    public static func backwardStart(from window: CardWindow,
                                    maxCards: Int = CanvasFanGeometry.maxCards) -> Int {
        guard window.hasPrev else { return 0 }
        let cap = max(1, maxCards)
        return max(0, window.start - max(1, cap - 1))
    }
}
