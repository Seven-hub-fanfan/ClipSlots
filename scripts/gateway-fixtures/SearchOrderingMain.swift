import Foundation
import ClipSlotsKit

@main enum SearchOrderingMain {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ name: String) { checks.append(["passed": value, "name": name]) }
        let content = SlotContent(items: [[PasteboardItem(type: "public.utf8-plain-text", data: Data("正文".utf8))]])
        let values = (0..<50000).map { index in
            SlotGlobalSearchResult(pageId: "p\(index / 10000)", pageName: "页",
                groupId: String(format: "g%05d", index / 10), groupName: "组", slot: index % 10 + 1,
                content: content, label: index % 2 == 0 ? "并列标签" : "并列标签2",
                pageOrder: 0, groupOrder: 0)
        }
        for rule in SlotSearchSortRule.allCases {
            let sorted = SlotGlobalSearchOrdering.sort(values.reversed(), rule: rule,
                                                        currentPageId: "p2", currentGroupId: "g02001")
            let reordered = SlotGlobalSearchOrdering.sort(Array(values.dropFirst(100)) + Array(values.prefix(100)),
                rule: rule, currentPageId: "p2", currentGroupId: "g02001")
            check(sorted.map(\.id) == reordered.map(\.id), "\(rule) repeated names/orders have deterministic identity ties")
            check(sorted.count == 50000 && Set(sorted.map(\.id)).count == 50000, "\(rule) full result count has no omissions/duplicates")
            let pages = stride(from: 0, to: sorted.count, by: 128).flatMap { offset in
                sorted[offset..<min(offset + 128, sorted.count)].map(\.id)
            }
            check(pages == sorted.map(\.id), "\(rule) paged projection preserves full order and final short page")
            if rule == .smart || rule == .pageGroupSlot {
                let first = Array(sorted.prefix(64))
                check(first.map(\.id) == Array(reordered.prefix(64)).map(\.id), "\(rule) first page matches complete ordering")
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "checks": checks, "failed": checks.filter { $0["passed"] as? Bool != true }.count
        ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}
