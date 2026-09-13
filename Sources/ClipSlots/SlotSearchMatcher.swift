import Foundation
import ClipSlotsKit

// MARK: - Slot Search Matcher (v2.5, 可搜索文本自 v2.11.7 hotfix11 下沉到 Kit)
//
// 匹配语义 = 类型过滤器 AND 关键词子串匹配。关键词部分统一走
// `ClipSlotsKit.SlotSearchIndex`，与 CLI `clipslots search` 同一份实现（此前 GUI 只搜
// content.preview，也就是正文前 30 字，导致长文槽位「基本搜不到」）。

struct SlotSearchMatcher {

    /// Whether the search/filter is currently active.
    static func isActive(query: String, filter: SlotFilterType) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all
    }

    /// Check if a slot matches the given search query and type filter.
    static func matches(
        slot: Int,
        content: SlotContent,
        label: String,
        query: String,
        filter: SlotFilterType
    ) -> Bool {
        // 1. Type filter first
        if !matchesFilter(content: content, filter: filter) {
            return false
        }

        // 2. Query match
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty {
            return true
        }

        return SlotSearchIndex.matches(
            slot: slot,
            content: content,
            label: label,
            query: normalizedQuery
        )
    }

    // MARK: - Private

    private static func matchesFilter(
        content: SlotContent,
        filter: SlotFilterType
    ) -> Bool {
        switch filter {
        case .all:
            return true

        case .empty:
            return content.isEmpty

        case .file:
            return content.primaryFileURL != nil

        case .url:
            return content.detectedWebURL != nil

        case .image:
            return content.hasImage || content.isImageFile

        case .text:
            // Non-empty but not file, not URL, not image
            return !content.isEmpty
                && content.primaryFileURL == nil
                && content.detectedWebURL == nil
                && !content.hasImage
                && !content.isImageFile
        }
    }
}
