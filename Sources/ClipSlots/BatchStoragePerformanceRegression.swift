#if DEBUG
import AppKit
import Combine
import CryptoKit
import ClipSlotsKit

/// Benchmarks the ordinary toolbar folder-import path in the primary app window.
/// The signed editor-regression gate supplies an isolated library and config.
enum BatchStoragePerformanceRegression {
    @MainActor static weak var primaryStore: SlotStoreObservable?

    @MainActor static func run(root: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["BATCH_STORAGE_MODE"] ?? ""
        guard ["reference", "clone"].contains(mode),
              let fixturePath = env["BATCH_STORAGE_FIXTURES"],
              fixturePath.hasPrefix("/private/tmp/clipslots-editor-") else {
            throw AgentOperationError("批量基准参数无效")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        var primary: SlotStoreObservable?
        for _ in 0..<500 {
            if let store = primaryStore,
               store.config.slots == 10, store.slots.count == 10,
               store.displayedSpecialSlotId == store.currentSpecialSlotId {
                primary = store
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let store = primary,
              let window = NSApp.windows.first(where: {
                  $0.styleMask.contains(.titled) && !($0 is NSPanel)
              }) else { throw AgentOperationError("主应用窗口未就绪") }
        guard store.specialSlots.count == 1, store.pages.count == 1,
              store.slots.values.allSatisfy(\.isEmpty) else {
            throw AgentOperationError("基准必须从独立空库开始")
        }
        UserDefaults.standard.set(true, forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
        store.fileImportReferenceOnly = mode == "reference"
        store.fileImportPreferClone = true
        window.setContentSize(NSSize(width: 1320, height: 820))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .seconds(2))

        var gaps: [[String: Double]] = []
        var origin = ProcessInfo.processInfo.systemUptime
        var last = origin
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append(["end_ms": (now - origin) * 1000, "gap_ms": (now - last) * 1000])
            last = now
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        try await Task.sleep(for: .seconds(2))
        let idleGaps = gaps
        gaps = []
        origin = ProcessInfo.processInfo.systemUptime
        last = origin
        var savingStarted: Double?
        var savingEnded: Double?
        var progressEvents: [[String: Any]] = []
        let savingSubscription = store.$isBatchSaving.dropFirst().sink { active in
            let elapsed = (ProcessInfo.processInfo.systemUptime - origin) * 1000
            if active { savingStarted = elapsed }
            else if savingStarted != nil { savingEnded = elapsed }
        }
        defer { savingSubscription.cancel() }
        let progressSubscription = store.transientUI.$importProgress.dropFirst().sink { progress in
            if let progress {
                progressEvents.append(["at_ms": (ProcessInfo.processInfo.systemUptime - origin) * 1000,
                    "completed": progress.completed, "total": progress.total, "detail": progress.detail])
            }
        }
        defer { progressSubscription.cancel() }
        let initialGroupID = store.currentSpecialSlotId
        print("batch-storage: start mode=\(mode) store=\(store.instanceID)"); fflush(stdout)
        store.executeToolbarImport(urls: [fixture], mode: .allTotal, sortRule: .naturalNameAscending)
        while savingEnded == nil && ProcessInfo.processInfo.systemUptime - origin < 240 {
            try await Task.sleep(for: .milliseconds(10))
        }
        var previewReady: Double?
        if savingEnded != nil {
            for _ in 0..<1000 {
                if store.currentSpecialSlotId == initialGroupID,
                   store.slots.count == 10,
                   (1...10).allSatisfy({ slot in
                       guard let content = store.slots[slot], !content.isEmpty else { return false }
                       let key = content.thumbnailKey(specialSlotId: initialGroupID, slot: slot)
                       return ThumbnailProvider.shared.image(for: key) != nil
                   }) {
                    previewReady = (ProcessInfo.processInfo.systemUptime - origin) * 1000
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .seconds(1))
        let measuredEnd = (ProcessInfo.processInfo.systemUptime - origin) * 1000
        timer.invalidate()
        var report: [String: Any] = [
            "mode": mode, "store_instance_id": store.instanceID,
            "saving_started_ms": savingStarted.map { $0 as Any } ?? NSNull(),
            "batch_complete_ms": savingEnded.map { $0 as Any } ?? NSNull(),
            "visible_previews_ready_ms": previewReady.map { $0 as Any } ?? NSNull(),
            "measurement_end_ms": measuredEnd,
            "idle_gaps": idleGaps, "main_runloop_gaps": gaps, "progress_events": progressEvents,
            "window_content_width": window.contentLayoutRect.width,
            "window_content_height": window.contentLayoutRect.height,
            "scope": "signed DEBUG; primary app Store and normal ContentView; toolbar folder import; 1000 unique JPEGs; default 10 slots/group; no group navigation",
            "sampling": "4ms main-runloop timer delivery gaps, not display FPS; includes scanning, planning, writing, final refresh, and a 1s tail"
        ]
        let reportURL = root.appendingPathComponent("batch-ui-performance.json")
        func persist() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        // Save timing evidence before the off-main integrity checks.
        try persist()
        let integrity = await Task.detached(priority: .utility) {
            verify(root: root, fixture: fixture, mode: mode)
        }.value
        report["integrity"] = integrity
        let passed = savingEnded != nil && previewReady != nil && integrity["passed"] as? Bool == true
        report["passed"] = passed
        try persist()
        print("batch-storage: complete mode=\(mode) passed=\(passed) elapsed_ms=\(savingEnded ?? -1)"); fflush(stdout)
        guard passed else { throw AgentOperationError("批量基准或完整性验证失败") }
    }

    private static func verify(root: URL, fixture: URL, mode: String) -> [String: Any] {
        let storage = SpecialSlotStorage.shared
        let index = storage.loadIndex()
        let groups = index.specialSlots.filter { !SpecialSlotStorage.isReservedGroupId($0.id) }
        var errors: [String] = []
        var count = 0, owned = 0, referenced = 0, hashMatches = 0, contentLabelMisses = 0
        var labels: Set<String> = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: fixture,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }
            var digests: [String: String] = [:]
            for url in files {
                digests[url.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }.joined()
            }
            for group in groups {
                for slot in 1...10 {
                    guard let content = storage.getOrUnknown(slot, in: group.id), !content.isEmpty,
                          let url = content.primaryFileURL else {
                        errors.append("缺少内容 \(group.id)/\(slot)"); continue
                    }
                    count += 1
                    // Body reloads do not promise to populate the separate label
                    // field. Use the label API, and verify its on-disk bytes too.
                    let label = storage.getLabel(slot, in: group.id) ?? ""
                    if content.label != label { contentLabelMisses += 1 }
                    let labelURL = storage.storageRoot.appendingPathComponent(group.id)
                        .appendingPathComponent(String(slot)).appendingPathComponent("label.txt")
                    if (try String(contentsOf: labelURL, encoding: .utf8)) != label {
                        errors.append("磁盘标签不匹配 \(label)")
                    }
                    if !labels.insert(label).inserted { errors.append("重复标签 \(label)") }
                    let digest = SHA256.hash(data: try Data(contentsOf: url))
                        .map { String(format: "%02x", $0) }.joined()
                    if digests[label] != digest { errors.append("文件哈希不匹配 \(label)") }
                    else { hashMatches += 1 }
                    let isOwned = url.path.hasPrefix(root.appendingPathComponent("data").path + "/")
                    if isOwned { owned += 1 } else { referenced += 1 }
                    if mode == "reference" && url.standardizedFileURL != fixture.appendingPathComponent(label).standardizedFileURL {
                        errors.append("引用路径不匹配 \(label)")
                    }
                    if mode == "clone" && (!isOwned || content.managedBodyFiles?.count != 1) {
                        errors.append("副本未归库管理 \(label)")
                    }
                }
            }
            if files.count != 1000 || count != 1000 || labels != Set(digests.keys) {
                errors.append("数量或标签集合不完整")
            }
            if groups.count != 100 || index.pages.count != 10 { errors.append("建组或分页数量异常") }
        } catch { errors.append(error.localizedDescription) }
        return ["passed": errors.isEmpty, "errors": errors, "items": count,
            "groups": groups.count, "pages": index.pages.count,
            "owned_files": owned, "referenced_files": referenced, "unique_labels": labels.count,
            "sha256_verified_items": hashMatches, "body_cache_label_misses": contentLabelMisses]
    }
}
#endif
