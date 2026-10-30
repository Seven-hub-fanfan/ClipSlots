import Foundation
import ClipSlotsKit

/// Read-only engine benchmark. Input fixtures and caches must be isolated.
/// This does not measure the native input field, debounce or presented frames.
@main
struct SearchBenchmarkMain {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, args[1].hasPrefix("/private/tmp/clipslots-search-"),
              let count = Int(args[2]), count > 0, count % 10 == 0,
              let rounds = Int(args[3]), rounds >= 5,
              let cache = ProcessInfo.processInfo.environment["CLIPSLOTS_SEARCH_CACHE_DIR"],
              cache.hasPrefix("/private/tmp/clipslots-search-"),
              ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"] == args[1] else {
            throw NSError(domain: "SearchBenchmark", code: 2)
        }
        let root = URL(fileURLWithPath: args[1])
        let groups = (0..<(count / 10)).map { root.appendingPathComponent(String(format: "g%05d", $0)) }
        func measure(_ query: String, scene: String, round: Int) throws {
            let start = ProcessInfo.processInfo.systemUptime
            var hits = 0
            for group in groups {
                let values = SlotStorage.searchCandidates(slotsDir: group, slotCount: 10, query: query)
                hits += values.filter {
                    SlotSearchIndex.matches(slot: $0.key, content: $0.value,
                                            label: $0.value.label ?? "", query: query)
                }.count
            }
            var row: [String: Any] = ["scene": scene, "round": round, "slots": count,
                                     "hits": hits, "engineMS": (ProcessInfo.processInfo.systemUptime - start) * 1000]
            #if DEBUG
            row["diagnostics"] = SlotSearchDiagnostics.take()
            #endif
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
        try measure("ALL_中文", scene: "initial-index-all", round: 0)
        for round in 1...rounds {
            try measure("TEN_HITS", scene: "hot-ten", round: round)
            try measure("NO_SUCH_TOKEN", scene: "hot-none", round: round)
            try measure("ALL_中文", scene: "hot-all", round: round)
        }
    }
}
