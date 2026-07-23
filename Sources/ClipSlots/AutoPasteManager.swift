import ClipSlotsKit
import Foundation

// MARK: - Auto Paste Manager (v2.10.0)

/// 「自动粘贴」拨杆的取值计算：从读游标位置找下一个非空槽（主体或附件非空）。
struct AutoPasteManager {
    let pages: [SlotPage]
    let groups: [SpecialSlot]
    let slotCount: Int
    /// 判断某地址是否非空（`!SlotContent.isEmpty`）。
    let isNonEmpty: (SlotAddress) -> Bool

    /// 找下一个非空槽。
    /// 遍历顺序：当前组剩余槽 → 同页下一组 → 下一页第一组（autoAdvance = true 时）。
    /// autoAdvance = false 时只在当前组内循环找非空槽。
    /// 返回 nil 表示对应范围内已无非空槽（全部粘贴完）。
    func findNextNonEmptySlot(from cursor: SlotAddress?, startGroupId: String, autoAdvance: Bool) -> SlotAddress? {
        AutoModeTraversal.findNext(
            pages: pages,
            groups: groups,
            slotCount: slotCount,
            cursor: cursor,
            startGroupId: startGroupId,
            autoAdvance: autoAdvance,
            matches: { isNonEmpty($0) }
        )
    }

    /// 全局第一个非空槽（用于「已粘贴完毕」后把读游标重置到第一个非空槽）。
    func firstNonEmptySlot() -> SlotAddress? {
        let flat = AutoModeTraversal.flatten(pages: pages, groups: groups, slotCount: slotCount)
        return flat.first(where: { isNonEmpty($0) })
    }
}
