import Foundation
import ClipSlotsKit
import CryptoKit
import SQLite3

func runSearchSnapshotTests(_ t: TestRunner) {
    func text(_ value: String) -> SlotContent {
        SlotContent(items: [[PasteboardItem(type: "public.utf8-plain-text", data: Data(value.utf8))]])
    }
    func bytes(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let canonicalRoot = root.resolvingSymlinksInPath().path
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            // A preceding write asynchronously rebuilds this diagnostic manifest.
            // It is not a slot payload; all slot files remain covered below.
            if file.lastPathComponent == "manifest.json",
               file.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalRoot { continue }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               let data = try? Data(contentsOf: file) {
                result[file.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    t.withFreshStore("PERSISTENT-SEARCH-SNAPSHOT") { storage in
        guard let group = storage.loadIndex().specialSlots.first else {
            t.check(false, "search fixture group exists"); return
        }
        storage.set(1, content: text("OLD_BODY_骑马"), in: group.id)
        storage.setLabel(1, label: "旧标签", in: group.id)
        storage.set(2, content: text("第二个正文"), in: group.id)
        let directory = storage.storageRoot.appendingPathComponent(group.id)
        let first = SlotStorage(slotsDir: directory)
        let before = bytes(directory)
        let initial = first.searchScanSnapshot(slotCount: 10)
        t.equal(initial[1]?.plainText, "OLD_BODY_骑马", "initial disk search has complete body")
        t.equal(initial[1]?.label, "旧标签", "initial disk search has label")
        t.check(SlotSearchIndex.matches(slot: 1, content: initial[1] ?? SlotContent(), label: "", query: "OLD_BODY"),
                "initial haystack cached")
        let restarted = SlotStorage(slotsDir: directory)
        t.equal(restarted.searchScanSnapshot(slotCount: 10)[1]?.plainText, "OLD_BODY_骑马",
                "fresh storage object loads persisted search snapshot")
        t.equal(before, bytes(directory), "search snapshot does not mutate any business file")
        let body = directory.appendingPathComponent("1/item_0/public.utf8-plain-text.bin")
        let modified = try FileManager.default.attributesOfItem(atPath: body.path)[.modificationDate] as? Date
        try Data("NEW_BODY_摄影".utf8).write(to: body)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: body.path)
        }
        let updated = first.searchScanSnapshot(slotCount: 10)
        t.equal(updated[1]?.plainText, "NEW_BODY_摄影",
                "same-size in-place body write with original mtime refreshes snapshot")
        t.check(SlotSearchIndex.matches(slot: 1, content: updated[1] ?? SlotContent(), label: "", query: "NEW_BODY"),
                "unchanged persisted content identity does not reuse stale search haystack")
        t.check(!SlotSearchIndex.matches(slot: 1, content: updated[1] ?? SlotContent(), label: "", query: "OLD_BODY"),
                "old keyword disappears immediately")
        let label = directory.appendingPathComponent("1/label.txt")
        try Data("新标签".utf8).write(to: label)
        t.equal(restarted.searchScanSnapshot(slotCount: 10)[1]?.label, "新标签", "external label-only update refreshes")
        let item = directory.appendingPathComponent("3/item_0")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("新建槽位".utf8).write(to: item.appendingPathComponent("public.utf8-plain-text.bin"))
        t.equal(first.searchScanSnapshot(slotCount: 10)[3]?.plainText, "新建槽位",
                "newly created slot invalidates cached absence")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("2"))
        t.check(first.searchScanSnapshot(slotCount: 10)[2] == nil, "externally deleted slot disappears")
        t.check(first.searchScanSnapshot(slotCount: 1)[3] == nil, "smaller slot count cannot reuse larger snapshot")
        t.equal(first.searchScanSnapshot(slotCount: 10)[3]?.plainText, "新建槽位", "larger slot count rescans")
        t.check(first.searchScanSnapshot(slotCount: 10, isCancelled: { true }).isEmpty,
                "cancelled search returns no partial snapshot")
        t.equal(SlotStorage(slotsDir: directory).searchScanSnapshot(slotCount: 10)[3]?.plainText, "新建槽位",
                "cancellation does not poison persisted snapshot")
        let item1 = directory.appendingPathComponent("1/item_1")
        try FileManager.default.createDirectory(at: item1, withIntermediateDirectories: true)
        try Data("file:///tmp/new-reference.pdf".utf8).write(to: item1.appendingPathComponent("public.file-url.bin"))
        t.equal(first.searchScanSnapshot(slotCount: 10)[1]?.items.count, 2, "new nested item is discovered")
        var attachment = SlotContent.SlotAttachment(name: "搜索附件", type: .image)
        attachment.data = Data(repeating: 1, count: 1_000_000)
        try JSONEncoder().encode([attachment]).write(to: directory.appendingPathComponent("1/attachments.json"))
        let attachments = first.searchScanSnapshot(slotCount: 10)[1]?.attachments ?? []
        t.equal(attachments.first?.name, "搜索附件", "attachment-only metadata update refreshes")
        t.check(attachments.first?.data == nil, "inline attachment bytes excluded from search snapshot")
        let fresh = SlotStorage(slotsDir: directory).searchScanSnapshot(slotCount: 10)[1]
        t.equal(fresh?.attachments.first?.name, "搜索附件", "attachment metadata survives persistent round trip")
        t.check(fresh?.attachments.first?.data == nil, "persistent snapshot never hydrates attachment payload")
    }
    t.withFreshStore("SEARCH-CANDIDATES") { storage in
        guard let group = storage.loadIndex().specialSlots.first else { return }
        let values = [
            "中文骑马摄影 cafe\u{301} Straße İstanbul",
            "Emoji 👩🏽‍💻 family 👨‍👩‍👧‍👦 percent% under_score 'quoted'",
            "before\u{0}AFTER_NULL \u{212b}ngström",
            "123 http://example.com/文档.pdf"
        ]
        for (index, value) in values.enumerated() { storage.set(index + 1, content: text(value), in: group.id) }
        storage.setLabel(2, label: "独有标签", in: group.id)
        let directory = storage.storageRoot.appendingPathComponent(group.id)
        let live = SlotStorage(slotsDir: directory).searchScanSnapshot(slotCount: 10)
        let before = bytes(directory)
        let queries = ["", "中文", "骑", "摄影", "CAFÉ", "cafe\u{301}", "straße", "İstanbul",
                       "👩🏽‍💻", "👨‍👩‍👧‍👦", "%", "_", "'quoted'", "AFTER_NULL",
                       "\u{0}AFTER", "Ång", "独有标签", "  槽位 3  ", "3", "example.com",
                       "not-found", "\u{301}"]
        for query in queries {
            let expected = Set(live.filter {
                SlotSearchIndex.matches(slot: $0.key, content: $0.value, label: $0.value.label ?? "", query: query)
            }.keys)
            let candidates = storage.searchCandidates(in: group.id, slotCount: 10, query: query)
            let actual = Set(candidates.filter {
                SlotSearchIndex.matches(slot: $0.key, content: $0.value, label: $0.value.label ?? "", query: query)
            }.keys)
            t.equal(actual, expected, "persistent candidate query matches Swift: \(query.debugDescription)")
        }
        t.equal(before, bytes(directory), "candidate queries are read-only")
        let body = directory.appendingPathComponent("1/item_0/public.utf8-plain-text.bin")
        try Data("即时外部更新".utf8).write(to: body)
        t.equal(storage.searchCandidates(in: group.id, slotCount: 10, query: "即时")[1]?.plainText,
                "即时外部更新", "candidate query notices immediate raw external write")
        t.check(storage.searchCandidates(in: group.id, slotCount: 10, query: "骑马").isEmpty,
                "candidate query removes externally replaced body")
        t.check(storage.searchCandidates(in: group.id, slotCount: 10, query: "", isCancelled: { true }).isEmpty,
                "candidate query honors immediate cancellation")
        // Corrupt just the disposable payload using a separate SQLite connection,
        // exercising fallback with the process metadata cache already warm.
        let library = directory.deletingLastPathComponent().resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(library.utf8)).map { String(format: "%02x", $0) }.joined()
        let parent = ProcessInfo.processInfo.environment["CLIPSLOTS_SEARCH_CACHE_DIR"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.clipslots/search-v1")
        var db: OpaquePointer?
        if sqlite3_open(parent.appendingPathComponent(hash + ".sqlite").path, &db) == SQLITE_OK, let db {
            sqlite3_busy_timeout(db, 1000)
            let status = sqlite3_exec(db, "UPDATE search_slots SET value=x'00' WHERE slot=1", nil, nil, nil)
            sqlite3_close(db)
            t.equal(status, SQLITE_OK, "corrupt-cache fixture written")
            t.equal(storage.searchCandidates(in: group.id, slotCount: 10, query: "即时")[1]?.plainText,
                    "即时外部更新", "corrupt candidate payload falls back to live source")
            t.equal(storage.searchCandidates(in: group.id, slotCount: 10, query: "即时")[1]?.plainText,
                    "即时外部更新", "corrupt candidate payload repaired for next query")
        } else {
            if let db { sqlite3_close(db) }
            t.check(false, "candidate cache exists for corruption fixture")
        }
        try Data("{invalid metadata".utf8).write(to: directory.appendingPathComponent("1/attachments.json"))
        let corruptedSource = bytes(directory)
        t.equal(storage.searchCandidates(in: group.id, slotCount: 10, query: "即时")[1]?.plainText,
                "即时外部更新", "corrupt attachment metadata does not hide searchable body")
        t.equal(corruptedSource, bytes(directory), "search never writes backup files for corrupt source metadata")
        let missing = directory.appendingPathComponent("never-created")
        _ = SlotStorage.searchCandidates(slotsDir: missing, slotCount: 10, query: "")
        t.check(!FileManager.default.fileExists(atPath: missing.path),
                "global search never creates missing business directories")
    }
}
