import ClipSlotsKit
import Foundation

// MARK: - Auto Mode Traversal (v2.10.0)

/// 槽位在全局的定位：(groupId, slot 1...N)。用于自动模式的遍历与游标。
struct SlotAddress: Equatable {
    let groupId: String
    let slot: Int
}

/// 把「页面 → 槽位组 → 槽位」按 UI 显示顺序拍平成一维地址序列，
/// 供自动存储 / 自动粘贴按顺序推进（跨组 / 跨页）。
/// 顺序 = 数据层 order（等于 UI tab 顺序）：pages 按 order，组内 groups 按 order，槽位 1...slotCount。
enum AutoModeTraversal {
    static func flatten(pages: [SlotPage], groups: [SpecialSlot], slotCount: Int) -> [SlotAddress] {
        guard slotCount >= 1 else { return [] }
        var result: [SlotAddress] = []
        let sortedPages = pages.sorted { $0.order < $1.order }

        // 兜底：异常情况下没有任何 page，退化为直接按 group.order 排列。
        if sortedPages.isEmpty {
            for g in groups.sorted(by: { $0.order < $1.order }) {
                for s in 1...slotCount { result.append(SlotAddress(groupId: g.id, slot: s)) }
            }
            return result
        }

        for page in sortedPages {
            let groupsInPage = groups.filter { $0.pageId == page.id }.sorted { $0.order < $1.order }
            for g in groupsInPage {
                for s in 1...slotCount { result.append(SlotAddress(groupId: g.id, slot: s)) }
            }
        }
        return result
    }

    /// 线性遍历（autoAdvance = true）的起点索引：cursor 命中则从其后一位开始（tape 推进），
    /// 否则从 startGroupId 的第一个槽开始，再兜底 0。
    private static func linearStartIndex(flat: [SlotAddress], cursor: SlotAddress?, startGroupId: String) -> Int {
        if let cursor, let idx = flat.firstIndex(of: cursor) {
            return idx + 1
        }
        if let idx = flat.firstIndex(where: { $0.groupId == startGroupId }) {
            return idx
        }
        return 0
    }

    /// 自动模式的核心：从 cursor 之后寻找下一个满足 `matches` 的槽位。
    /// - autoAdvance = true：跨组 / 跨页线性推进，直到全局末尾（不回卷），到头返回 nil。
    /// - autoAdvance = false：只在 cursor（或 startGroupId）所在组内**循环**查找（会回卷），组内无匹配返回 nil。
    static func findNext(
        pages: [SlotPage],
        groups: [SpecialSlot],
        slotCount: Int,
        cursor: SlotAddress?,
        startGroupId: String,
        autoAdvance: Bool,
        matches: (SlotAddress) -> Bool
    ) -> SlotAddress? {
        let flat = flatten(pages: pages, groups: groups, slotCount: slotCount)
        guard !flat.isEmpty else { return nil }

        if autoAdvance {
            var i = linearStartIndex(flat: flat, cursor: cursor, startGroupId: startGroupId)
            while i < flat.count {
                if matches(flat[i]) { return flat[i] }
                i += 1
            }
            return nil
        }

        // 仅在当前组内循环（wrap-around）。
        let scopeGroupId = cursor?.groupId ?? startGroupId
        let groupSlots = flat.filter { $0.groupId == scopeGroupId }
        guard !groupSlots.isEmpty else { return nil }

        var startOffset = 0
        if let cursor, cursor.groupId == scopeGroupId, let idx = groupSlots.firstIndex(of: cursor) {
            startOffset = (idx + 1) % groupSlots.count
        }
        for k in 0..<groupSlots.count {
            let addr = groupSlots[(startOffset + k) % groupSlots.count]
            if matches(addr) { return addr }
        }
        return nil
    }
}

// MARK: - Auto Store Manager (v2.10.0)

/// 「自动存储」拨杆的落点计算：找下一个空槽（主体 + 附件都为空）。
struct AutoStoreManager {
    let pages: [SlotPage]
    let groups: [SpecialSlot]
    let slotCount: Int
    /// 判断某地址是否为空槽（`SlotContent.isEmpty`：主体 items 为空 AND 附件为空）。
    let isEmpty: (SlotAddress) -> Bool

    /// 找下一个空槽。
    /// 遍历顺序：当前组剩余槽 → 同页下一组 → 下一页第一组（autoAdvance = true 时）。
    /// autoAdvance = false 时只在当前组内循环找空槽。
    /// 返回 nil 表示对应范围内已无空槽（全满）。
    func findNextEmptySlot(from cursor: SlotAddress?, startGroupId: String, autoAdvance: Bool) -> SlotAddress? {
        AutoModeTraversal.findNext(
            pages: pages,
            groups: groups,
            slotCount: slotCount,
            cursor: cursor,
            startGroupId: startGroupId,
            autoAdvance: autoAdvance,
            matches: { isEmpty($0) }
        )
    }
}
