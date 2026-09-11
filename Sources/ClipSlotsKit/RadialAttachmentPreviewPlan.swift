import Foundation

// MARK: - 悬浮预览 Panel 的附件展示计划（v2.11.1）
//
// 为什么这段「谁上缩略图、谁折成 +N、谁走文件小卡」的选择逻辑住在 Kit 而不是视图里：
// 和 v2.11.0 hotfix 把扇区几何抽到 `RadialSegmentLayout` 是同一个理由 —— 它是纯粹的
// 数据决策，放在 SwiftUI body 里只能靠肉眼验证，抽成纯函数就能被 smoke 断言钉死：
//   · 图片缩略图最多 maxImageThumbnails 张（预览窗只有 ~360pt 宽，也避免一次悬停拉起十几个解码）；
//   · 多出来的图片必须被 hiddenImageCount 如实计数，绝不静默丢弃；
//   · 非图片附件一个都不能漏，且**保持原始顺序**（用户排的附件顺序是有意义的）。
//
// 刻意只接受 `[Bool]`（每个附件是否「图片型」）而不是 `[SlotAttachment]`：
// 「是不是图片」要靠 UTType / 扩展名判断，那是 App 层 `RadialAttachmentKind` 的职责，
// Kit 只负责在给定判定结果后做选择，两边互不污染。

/// 附件展示区的渲染计划。所有字段都是 `attachments` 数组里的**下标**，调用方按下标取原对象。
public struct RadialAttachmentPreviewPlan: Equatable, Sendable {
    /// 要渲染真实缩略图的图片附件下标（按原顺序，最多 `maxImageThumbnails` 个）。
    public let imageIndices: [Int]
    /// 因超出上限而没渲染的图片附件数量（渲染成「+N」）。
    public let hiddenImageCount: Int
    /// 走「图标 + 文件名」小卡的非图片附件下标（按原顺序，全部保留）。
    public let chipIndices: [Int]
    /// 主体为空时可当主视觉的第一张图片附件下标；没有图片附件则为 nil。
    public let heroImageIndex: Int?

    public init(imageIndices: [Int], hiddenImageCount: Int, chipIndices: [Int], heroImageIndex: Int?) {
        self.imageIndices = imageIndices
        self.hiddenImageCount = hiddenImageCount
        self.chipIndices = chipIndices
        self.heroImageIndex = heroImageIndex
    }

    public static let empty = RadialAttachmentPreviewPlan(imageIndices: [],
                                                          hiddenImageCount: 0,
                                                          chipIndices: [],
                                                          heroImageIndex: nil)
}

public enum RadialAttachmentPreviewPlanner {
    /// 预览窗里同时渲染的图片缩略图上限。
    public static let maxImageThumbnails = 3

    /// - Parameters:
    ///   - imageFlags: 与附件数组等长；`true` 表示该附件能解出真实像素（图片型）。
    ///   - maxImageThumbnails: 缩略图上限，负数按 0 处理。
    public static func plan(imageFlags: [Bool],
                            maxImageThumbnails: Int = RadialAttachmentPreviewPlanner.maxImageThumbnails) -> RadialAttachmentPreviewPlan {
        guard !imageFlags.isEmpty else { return .empty }

        let cap = max(0, maxImageThumbnails)
        var images: [Int] = []
        var chips: [Int] = []
        for (index, isImage) in imageFlags.enumerated() {
            if isImage { images.append(index) } else { chips.append(index) }
        }

        let shown = Array(images.prefix(cap))
        return RadialAttachmentPreviewPlan(imageIndices: shown,
                                           hiddenImageCount: images.count - shown.count,
                                           chipIndices: chips,
                                           // hero 取「第一张图片」而不是「第一张被渲染的图片」——
                                           // cap 为 0 时缩略图条一张不显示，主视觉照样该有图可用。
                                           heroImageIndex: images.first)
    }
}
