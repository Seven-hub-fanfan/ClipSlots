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
/// ## 参考卡（重叠一张 + 灰遮罩）已在七轮**整套删除**
///
/// 三~六轮的规则是「翻页步长 = 容量 − 1，重叠那张打 40% 黑遮罩当参考卡」，理由是卡片没有序号、
/// 整页替换会丢掉"我翻到哪了"的锚点。用户实测后直接否掉：录屏里点完「+2 点击加载」，最顶层那张
/// 内容图立刻变暗并一直灰着，原话是「这个可以直接去掉这个变灰的逻辑」。
///
/// 七轮起窗口按**固定栅格**分页，所有牌面全亮：
///
/// ```text
///   总 12 张，窗口 5：
///   第一页  [0 1 2 3 4] +7
///   前进 →  [5 6 7 8 9] +2
///   前进 →  [10 11]              ← 末页允许不满，就是灰卡上写的那个「+2」
///   后退 ←  [5 6 7 8 9] +2
/// ```
///
/// 栅格分页顺手治掉了用户报的第二个 bug「翻页后出现两张完全相同的图片」：
/// 六轮及之前末页要保持满窗（起点夹到 `total - cap`），总 7 张容量 5 时点「+2」起点从 5 被夹回 2，
/// 新页 `[2,7)` 与旧页 `[0,5)` 重叠 3 张 —— 用户看到的就是"刚才那几张又出现了一遍"。
/// 现在同一张卡只属于一页，翻页零重叠；同一帧里 `windowIndices` 恒为严格递增、无重复、不越界
/// （`indicesAreSane` + smoke 全组合扫描钉死）。
///
/// ## 为什么放在 Kit
///
/// 翻页边界是典型的"差一"重灾区：`hasNext` 少算一张会让最后一张永远看不到（三轮那个 bug 本身），
/// 步长算错则会让同一张卡在一帧里出现两次。这些全部在 smoke 里钉住，不靠肉眼。
extension CanvasFanGeometry {

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
        /// 窗口覆盖的全量下标（严格递增、连续、无重复）。★ 七轮：
        /// 用户报「翻页后出现两张一模一样的图」，所以把"窗口到底摊开成哪几个下标"显式暴露出来，
        /// 由 smoke 逐页断言 `无重复 / 严格递增 / 不越界`，而不是靠读 `start`/`count` 心算。
        public var windowIndices: [Int] { Array(indices) }
        /// 自检：下标严格递增、无重复、全部落在 `0..<total`。
        public var indicesAreSane: Bool {
            guard total > 0 else { return true }
            let ix = windowIndices
            guard !ix.isEmpty else { return false }
            guard Set(ix).count == ix.count else { return false }
            guard zip(ix, ix.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return false }
            return ix.first! >= 0 && ix.last! < total
        }

        public init(start: Int, count: Int, total: Int,
                    hasPrev: Bool, hasNext: Bool, remaining: Int) {
            self.start = start
            self.count = count
            self.total = total
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
    ///   - maxCards: 窗口容量（扇形 5，轮播 3）。
    ///
    /// ★ 七轮：删掉 `arrivedBackward` 与参考卡。用户在录屏里看到的是"点了 +2 之后第一张图直接变灰、
    /// 而且一直灰着"，并明确要求「直接去掉这个变灰的逻辑」。参考卡本来是为了给用户一个"我翻到哪了"
    /// 的锚点，但代价是每页都有一张内容卡被 40% 黑蒙层盖住 —— 用户不接受这个代价，于是整套摘掉：
    /// 现在窗口就是**纯窗口**，所有牌面全亮。
    public static func cardWindow(total: Int,
                                  start: Int,
                                  maxCards: Int = CanvasFanGeometry.maxCards) -> CardWindow {
        let cap = max(1, maxCards)
        guard total > 0 else {
            // 空槽位：外部仍要画一张虚线空卡，所以 count 给 1、total 给 0。
            return CardWindow(start: 0, count: 1, total: 0,
                              hasPrev: false, hasNext: false, remaining: 0)
        }
        // 起点对齐到**翻页栅格**：`[0,cap) [cap,2cap) …`（★ 七轮，与 `CanvasFanWindowState.clamp`
        // 共用同一条规则，避免两处各算一套）。
        //
        // 七轮之前这里是 `min(start, total - cap)`——"末页保持满窗"。那正是用户报的
        // 「翻页后出现两张完全相同的图片」的来源：总 7 张容量 5，点「+2」后起点 5 被夹回 2，
        // 新页 [2,7) 与旧页 [0,5) 重叠 3 张，屏幕上"刚才看过的图又来了一遍"。
        // 栅格分页后同一张卡只属于一页，翻页零重叠；末页允许不满（总 7 → 末页 2 张，
        // 正好就是灰卡上写的那个「+2」）。
        let s = CanvasFanWindowState.clamp(start: start, total: total, capacity: cap)
        let count = min(cap, total - s)
        let remaining = total - (s + count)
        return CardWindow(start: s, count: count, total: total,
                          hasPrev: s > 0, hasNext: remaining > 0,
                          remaining: remaining)
    }

    /// 前进（点「+N」卡或 ➡）后的新起点。
    ///
    /// ★ 七轮：步长从 `count - 1`（留一张参考卡）改成 `count` —— **纯窗口平移**，不再重叠一张。
    /// 起点最终仍要过 `cardWindow` 的钳制（末页保持满窗），所以点「+1」这种只剩一张的情况
    /// 表现为"整叠左推一格"，而不是跳到只有一张卡的末页。
    /// 已经到底时按用户要求**回到开头**（「点击 ➡ 到达末尾时，继续点击 ➡ 则直接跑到开头」）。
    public static func forwardStart(from window: CardWindow) -> Int {
        guard window.hasNext else { return 0 }
        return window.start + max(1, window.count)
    }

    /// 后退（点 ⬅）后的新起点。
    ///
    /// ★ 七轮：同样不再重叠，整窗后退一页。已在开头时保持不动（按钮此时本就不显示）。
    public static func backwardStart(from window: CardWindow,
                                    maxCards: Int = CanvasFanGeometry.maxCards) -> Int {
        guard window.hasPrev else { return 0 }
        let cap = max(1, maxCards)
        return max(0, window.start - cap)
    }
}
