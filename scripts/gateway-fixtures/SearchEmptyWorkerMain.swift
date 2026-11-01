import Foundation
import ClipSlotsKit
import Darwin

/// Uses the production worker with ordinary isolated files, including failures.
@main enum SearchEmptyWorkerMain {
    static func main() throws {
        guard let dataRoot = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"],
              dataRoot.hasPrefix("/private/tmp/clipslots-search-"),
              ProcessInfo.processInfo.environment["CLIPSLOTS_SEARCH_CACHE_DIR"]?.hasPrefix("/private/tmp/clipslots-search-") == true else { exit(2) }
        let root = URL(fileURLWithPath: dataRoot)
        let storage = SpecialSlotStorage(baseDirectory: root, role: .canvasPrivate)
        let directory = root.appendingPathComponent("empty-fixture", isDirectory: true)
        let live = storage.slotStorage(for: "empty-fixture")
        live.set(1, content: SlotContent(items: [[PasteboardItem(type: "public.utf8-plain-text",
                                                               data: Data("非空正文".utf8))]]))
        live.setLabel(2, label: "仅标签")
        live.finishPendingWritesBeforeMovingDirectory()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("3", isDirectory: true),
                                                withIntermediateDirectories: true)
        let group = SlotGlobalSearchGroup(pageId: "p", pageName: "页", pageOrder: 0,
            groupId: "empty-fixture", groupName: "组", groupOrder: 0, storageRoot: storage, slotCount: 10)
        var failures: [String] = []
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
        }
        func search(_ query: String = "", _ filter: SlotFilterType = .empty) -> SlotGlobalSearchWorker.Expansion {
            SlotGlobalSearchWorker.expand([group], query: query, filter: filter)
        }
        for round in 1...2 {
            let empty = search()
            check(empty.isComplete, "\(round) empty complete")
            check(empty.results.map(\.slot) == Array(2...10), "\(round) empty exact missing/existing/label-only")
            check(empty.results.first?.label == "仅标签", "\(round) empty label retained")
            check(search("仅标签").results.map(\.slot) == [2], "\(round) empty label query")
            check(search("槽位 3").results.map(\.slot) == [3], "\(round) empty GUI slot query")
            check(search("", .all).results.map(\.slot) == [1], "\(round) all excludes empty")
        }
        let cancelled = SlotGlobalSearchWorker.expand([group], query: "", filter: .empty,
                                                       isCancelled: { true })
        check(!cancelled.isComplete && cancelled.results.isEmpty, "cancel remains incomplete")
        let label = directory.appendingPathComponent("2/label.txt", isDirectory: false)
        check(chmod(directory.appendingPathComponent("2", isDirectory: true).path, 0) == 0,
              "permissions failure fixture installed")
        let unreadable = search()
        check(!unreadable.isComplete && unreadable.results.isEmpty, "unreadable slot is unknown")
        check(chmod(directory.appendingPathComponent("2", isDirectory: true).path, 0o700) == 0,
              "permissions fixture restored")
        let invalid = directory.appendingPathComponent("3/content.json", isDirectory: false)
        try Data("{broken".utf8).write(to: invalid)
        check(!search().isComplete, "corrupt empty metadata is unknown")
        try FileManager.default.removeItem(at: invalid)
        let corrupt = directory.appendingPathComponent("4/attachments.json", isDirectory: false)
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: corrupt)
        check(!search().isComplete, "corrupt empty attachments are unknown")
        try Data("[]".utf8).write(to: corrupt)
        try FileManager.default.removeItem(at: label)
        check(mkfifo(label.path, 0o600) == 0, "nonregular label fixture installed")
        check(!search().isComplete, "nonregular label is unknown")
        try FileManager.default.removeItem(at: label)
        try Data("仅标签".utf8).write(to: label)
        let recovered = search()
        check(recovered.isComplete && recovered.results.map(\.slot) == Array(2...10),
              "restored source recovers complete exact empty results")
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "passed": passed, "failed": failures.count, "failures": failures,
            "scope": "production worker ordinary disk fixture; no GUI"
        ], options: [.sortedKeys]), as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
