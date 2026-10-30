import Foundation
import ClipSlotsKit

/// Links the exact production worker, matcher, sort and media predicates.
/// Reports engine/first-page readiness; never claims presented GUI timing.
@main enum SearchWorkerMain {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1].hasPrefix("/private/tmp/clipslots-search-"),
              ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"] == args[1],
              ProcessInfo.processInfo.environment["CLIPSLOTS_SEARCH_CACHE_DIR"]?.hasPrefix("/private/tmp/clipslots-search-") == true,
              let count = Int(args[2]), [20000, 50000].contains(count) else { exit(2) }
        let root = URL(fileURLWithPath: args[1])
        let storage = SpecialSlotStorage(baseDirectory: root, role: .canvasPrivate)
        let groups = (0..<(count / 10)).map { index in
            SlotGlobalSearchGroup(pageId: "p0", pageName: "页", pageOrder: 0,
                groupId: String(format: "g%05d", index), groupName: "组", groupOrder: index,
                storageRoot: storage, slotCount: 10)
        }
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        for round in 1...5 {
            for (query, expected) in [("ALL_中文", count), ("TEN_HITS", 10), ("NO_SUCH_TOKEN", 0)] {
                let start = ProcessInfo.processInfo.systemUptime
                var firstPageMS: Double?
                var firstPage: [String] = []
                var counts: [Int] = []
                let result = SlotGlobalSearchWorker.expand(groups, query: query, filter: .all,
                    onProgress: { prefix, found in
                        counts.append(found)
                        if !prefix.isEmpty && firstPageMS == nil {
                            firstPageMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                            firstPage = prefix.map(\.id)
                        }
                    })
                let sorted = SlotGlobalSearchOrdering.sort(result.results, rule: .pageGroupSlot,
                                                            currentPageId: "p0", currentGroupId: "g00000")
                let endMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                check(result.isComplete && sorted.count == expected, "\(round):\(query) complete count")
                check(Set(sorted.map(\.id)).count == expected, "\(round):\(query) unique identities")
                check(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 },
                      "\(round):\(query) monotonic intermediate counts")
                if expected >= 64 {
                    check(firstPage == Array(sorted.prefix(64)).map(\.id), "\(round):\(query) first page matches full sort")
                }
                var row: [String: Any] = ["round": round, "query": query, "count": sorted.count,
                    "slots": count, "workerMS": endMS, "progressCounts": counts]
                row["firstPageMS"] = firstPageMS ?? endMS
                print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                fflush(stdout)
            }
        }
        var cancel = false, callbacks = 0
        let interrupted = SlotGlobalSearchWorker.expand(groups, query: "ALL_中文", filter: .all,
            isCancelled: { cancel }, onProgress: { _, _ in callbacks += 1; cancel = true })
        check(!interrupted.isComplete && interrupted.results.isEmpty && callbacks == 1,
              "cancel at actual first-page callback yields no late pages or complete result")
        let replacement = SlotGlobalSearchWorker.expand(groups, query: "TEN_HITS", filter: .all)
        check(replacement.isComplete && replacement.results.count == 10,
              "replacement query has only its own complete results")
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "failures": failures, "failed": failures.count, "cancelCallbacks": callbacks
        ], options: [.sortedKeys]), as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
