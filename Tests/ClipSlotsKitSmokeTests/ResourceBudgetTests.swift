import Foundation
import ClipSlotsKit

private actor ResourceWorkGate {
    var entered: [Int] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func hold(_ id: Int) async {
        entered.append(id)
        await withCheckedContinuation { pending[id] = $0 }
    }
    func release(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
}

func runResourceBudgetTests(_ t: TestRunner) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let budget = ResourceBudget(physicalMemory: 32 * 1024 * 1024 * 1024)
        let limiter = AsyncWorkLimiter(limit: 2, currentLimit: { budget.decodeConcurrency })
        let gate = ResourceWorkGate()
        let first = Task { try await limiter.withPermit { await gate.hold(1); return 1 } }
        let second = Task { try await limiter.withPermit { await gate.hold(2); return 2 } }
        for _ in 0..<100 where await gate.entered.count < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        t.equal(await gate.entered.count, 2, "local work starts at normal two-permit budget")
        let third = Task { try await limiter.withPermit { await gate.hold(3); return 3 } }
        let cancelled = Task { try await limiter.withPermit { await gate.hold(4); return 4 } }
        try? await Task.sleep(for: .milliseconds(30))
        budget.setPressure(.critical)
        cancelled.cancel()
        await gate.release(1)
        try? await Task.sleep(for: .milliseconds(30))
        t.equal(await gate.entered.count, 2, "lowered budget drains active work before starting queued work")
        await gate.release(2)
        for _ in 0..<100 where !(await gate.entered.contains(3)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        t.check(await gate.entered.contains(3), "accepted queued work continues under pressure")
        await gate.release(3)
        let firstValue = try? await first.value
        let secondValue = try? await second.value
        let thirdValue = try? await third.value
        t.check(firstValue == 1 && secondValue == 2 && thirdValue == 3,
                "pressure never discards active or accepted local work")
        do { _ = try await cancelled.value; t.check(false, "cancelled screen work leaves permit queue") }
        catch is CancellationError { t.check(true, "cancelled screen work leaves permit queue") }
        catch { t.check(false, "permit cancellation wrong error") }
        t.check(!(await gate.entered.contains(4)), "cancelled queued work performs no decode")
        let single = AsyncWorkLimiter(limit: 1)
        let priorityGate = ResourceWorkGate()
        let held = Task { try await single.withPermit { await priorityGate.hold(0) } }
        for _ in 0..<100 where !(await priorityGate.entered.contains(0)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let row = Task { try await single.withPermit { await priorityGate.hold(1) } }
        try? await Task.sleep(for: .milliseconds(20))
        let preview = Task { try await single.withPermit(priority: 10) { await priorityGate.hold(2) } }
        try? await Task.sleep(for: .milliseconds(20))
        await priorityGate.release(0)
        for _ in 0..<100 where !(await priorityGate.entered.contains(2)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        t.equal(await priorityGate.entered, [0, 2], "focused preview precedes queued list thumbnail")
        await priorityGate.release(2)
        for _ in 0..<100 where !(await priorityGate.entered.contains(1)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        t.equal(await priorityGate.entered, [0, 2, 1], "priority still preserves queued thumbnail")
        await priorityGate.release(1)
        _ = try? await held.value; _ = try? await preview.value; _ = try? await row.value
        done.signal()
    }
    t.check(done.wait(timeout: .now() + 10) == .success, "dynamic limiter fixture completed")
    let gib: UInt64 = 1024 * 1024 * 1024
    for (memory, expected) in [(8, 64), (16, 128), (32, 256)] {
        let budget = ResourceBudget(physicalMemory: UInt64(memory) * gib)
        t.equal(budget.totalBytes, expected * 1024 * 1024, "\(memory)GB automatic cache budget")
        t.check(ResourceBudget.Category.allCases.reduce(0) { $0 + budget.bytes(for: $1) }
                <= budget.totalBytes, "category allowances fit total budget")
        let cache = ResourceCache<String>(category: .slotBody, countLimit: 3, budget: budget)
        cache.setObject("a", forKey: "a", cost: 4096)
        cache.setObject("b", forKey: "b", cost: 4096)
        cache.setObject("c", forKey: "c", cost: 4096)
        _ = cache.object(forKey: "a")
        cache.setObject("d", forKey: "d", cost: 4096)
        t.check(cache.object(forKey: "b") == nil && cache.object(forKey: "a") == "a", "LRU keeps accessed value")
        cache.setObject("large", forKey: "large", cost: budget.totalBytes)
        t.check(cache.object(forKey: "large") == nil, "oversized entry never retained")
        for i in 0..<3 {
            cache.setObject("value", forKey: i, cost: budget.bytes(for: .slotBody) / 3 - 256)
        }
        budget.setPressure(.critical)
        t.check(cache.totalCost <= budget.bytes(for: .slotBody), "critical pressure promptly trims caches")
        t.equal(budget.decodeConcurrency, 1, "pressure limits local decode concurrency")
        budget.setPressure(.normal)
        budget.setActivity(background: true, lowPower: false)
        t.equal(budget.totalBytes, expected * 1024 * 1024 / 2, "hidden app releases half cache allowance")
        cache.removeAllObjects()
        t.equal(cache.totalCost, 0, "cache purge releases accounting")
    }

    let text = "中文👨‍👩‍👧‍👦e\u{301}👍🏽"
    let long = String(repeating: text, count: 100_000) + "完整末尾关键词"
    let expected = String(long.prefix(30)) + "…"
    for encoding in [String.Encoding.utf8, .utf16] {
        let data = long.data(using: encoding)!
        t.equal(TextPreview.prefix(data), expected, "bounded Unicode preview \(encoding.rawValue)")
        let content = SlotContent(items: [[PasteboardItem(type: "NSStringPboardType", data: data)]])
        t.equal(content.preview, expected, "slot Unicode summary")
        t.equal(content.plainText, long, "full copy text remains untruncated")
        t.check(SlotSearchIndex.matchesContent(content: content, label: "", query: "完整末尾关键词"),
                "search still matches end of large body")
    }
    let boundary = Data((String(repeating: "中", count: 6000) + "结束").utf8)
    t.equal(TextPreview.prefix(boundary), String(repeating: "中", count: 30) + "…",
            "UTF8 prefix split inside scalar remains valid")
    t.equal(TextPreview.prefix(Data("<p>中文 &amp; emoji 👍🏽</p>".utf8), html: true),
            "中文 & emoji 👍🏽", "HTML display summary keeps readable entities")
    t.equal(TextPreview.prefix(Data("  简短正文 \n".utf8)), "简短正文", "short preview has no ellipsis")
    do {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        t.equal(config.cacheBudgetMiB, 0, "old config automatically uses resource budget")
        t.equal(config.attachmentWarningCount, 50, "old config gets soft reminder default")
    } catch { t.check(false, "legacy config decode: \(error)") }

    let previous = ResourceBudget.shared.totalBytes
    ResourceBudget.shared.configure(cacheMiB: 32)
    defer { ResourceBudget.shared.configure(cacheMiB: previous / 1024 / 1024) }
    t.withFreshStore("GLOBAL-BODY-BUDGET") { store in
        let group = store.loadIndex().specialSlots.first!.id
        let directory = ClipSlotsPaths.dataRoot.appendingPathComponent("special_slots/" + group)
        let storage = SlotStorage(slotsDir: directory)
        let largeBody = String(repeating: "x", count: 1024 * 1024)
        for slot in 1...10 {
            let content = SlotContent(items: [[PasteboardItem(type: "public.utf8-plain-text",
                                                            data: Data(largeBody.utf8))]])
            t.check(storage.set(slot, content: content), "write budget fixture \(slot)")
        }
        let snapshot = storage.snapshot()
        t.check(snapshot.count < 10 && snapshot.values.reduce(0) { $0 + $1.memoryCacheCost }
                <= ResourceBudget.shared.bytes(for: .slotBody), "body cache evicts across slots by bytes")
        for slot in 1...10 {
            t.equal(storage.getOrUnknown(slot)?.plainText?.count, largeBody.count,
                    "evicted slot rereads original disk bytes \(slot)")
        }
        storage.finishPendingWritesBeforeMovingDirectory()
        let marker = directory.appendingPathComponent("lock-held")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import fcntl,pathlib,sys,time; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(8)",
            ClipSlotsPaths.lockFile.path, marker.path]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        t.check(FileManager.default.fileExists(atPath: marker.path), "budget unknown external lock entered")
        // Slot 1 was evicted by the subsequent reads; a busy writer must remain unknown.
        t.check(storage.getOrUnknown(1) == nil, "eviction plus busy writer stays unknown, not empty")
    }
}
