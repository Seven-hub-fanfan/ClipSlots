import Foundation
import ClipSlotsKit

/// Captured on main, expanded off-main. No live storage handle is populated for
/// every library group; only explicit search reads touch this work queue.
struct SlotGlobalSearchGroup {
    let pageId: String
    let pageName: String
    let pageOrder: Int
    let groupId: String
    let groupName: String
    let groupOrder: Int
    let storageRoot: SpecialSlotStorage
    let slotCount: Int
}

enum SlotGlobalSearchWorker {
    struct Expansion {
        let results: [SlotGlobalSearchResult]
        let isComplete: Bool
    }

    static func expand(_ groups: [SlotGlobalSearchGroup], query: String, filter: SlotFilterType,
                       isCancelled: () -> Bool = { false },
                       onProgress: (([SlotGlobalSearchResult], Int) -> Void)? = nil) -> Expansion {
        var results: [SlotGlobalSearchResult] = []
        var publishedFirstPage = false
        var visitedGroups = 0
        for group in groups {
            guard !isCancelled() else { return .init(results: [], isComplete: false) }
            let read = group.storageRoot.searchCandidatesResult(in: group.groupId, slotCount: group.slotCount,
                                                                query: query, isCancelled: isCancelled)
            guard read.isComplete else { return .init(results: [], isComplete: false) }
            #if DEBUG
            let matchStart = SlotSearchDiagnostics.now
            #endif
            for slot in read.slots.keys.sorted() {
                guard let scanned = read.slots[slot] else { continue }
                guard !isCancelled() else { return .init(results: [], isComplete: false) }
                let label = scanned.label ?? ""
                guard SlotSearchMatcher.matches(slot: slot, content: scanned, label: label,
                                                query: query, filter: filter) else { continue }
                guard !isCancelled() else { return .init(results: [], isComplete: false) }
                results.append(SlotGlobalSearchResult(pageId: group.pageId, pageName: group.pageName,
                    groupId: group.groupId, groupName: group.groupName, slot: slot, content: scanned,
                    label: label, pageOrder: group.pageOrder, groupOrder: group.groupOrder))
            }
            #if DEBUG
            SlotSearchDiagnostics.record("matchingMS", since: matchStart)
            #endif
            visitedGroups += 1
            if !publishedFirstPage && results.count >= 64 {
                publishedFirstPage = true
                onProgress?(Array(results.prefix(64)), results.count)
            } else if visitedGroups % 128 == 0 {
                onProgress?(publishedFirstPage ? Array(results.prefix(64)) : [], results.count)
            }
        }
        return .init(results: results, isComplete: !isCancelled())
    }
}
