#if DEBUG
import AppKit
import ClipSlotsKit

enum StorageResponsivenessRegression {
    @MainActor static func run(root: URL, store: SlotStoreObservable,
                               check: (Bool, String) -> Void) async throws {
        let storage = store.specialStorage
        let group = try storage.createSpecialSlot(name: "后台存储测试")
        let other = try storage.createSpecialSlot(name: "后台存储另一组")
        store.reloadAll()
        check(storage.set(1, content: SlotContent(text: "初始正文"), in: group.id), "后台保存测试建立源槽")
        let snapshot = try store.captureSlotEditor(slot: 1, groupID: group.id)
        let model = try SlotEditorModel(snapshot: snapshot)
        model.draft = "👨‍👩‍👧‍👦e\u{301}🇨🇳中文"
        check(model.characterCount == model.draft.count, "缓存字数保持 Unicode 字素计数")
        let count = model.characterCount
        model.selectedRange = NSRange(location: 0, length: 1)
        check(model.characterCount == count, "选区变化不改变字数")
        model.draft += "🙂"
        check(model.characterCount == count + 1, "编辑草稿使字数缓存失效")
        model.draft = model.initialText
        check(model.characterCount == model.initialText.count, "撤销文本恢复正确字数")

        // A busy serial writer must not prevent the main actor from ticking.
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.slotWriteQueue.async {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { started.wait(); continuation.resume() }
        }
        defer { release.signal() }
        var saveFinished = false
        let save = Task { @MainActor in
            try await store.saveSlotEditorAsync(snapshot, body: AgentSlotBody(text: "后台新正文"), attachments: [])
            saveFinished = true
        }
        let start = Date()
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(20)) }
        let tickMS = Date().timeIntervalSince(start) * 1000
        check(!saveFinished && tickMS < 500, "写队列繁忙时主线程继续响应，保存等待后台提交")
        release.signal()
        store.switchSpecialSlot(id: other.id, fromNavigation: true)
        try await save.value
        check(storage.getOrUnknown(1, in: group.id)?.plainText == "后台新正文"
            && storage.getOrUnknown(1, in: other.id)?.hasEmptyBody == true,
            "后台保存期间切组仍写入捕获目标")
        do {
            try await store.saveSlotEditorAsync(snapshot, body: AgentSlotBody(text: "过期覆盖"), attachments: [])
            check(false, "后台保存拒绝过期快照")
        } catch {
            check(storage.getOrUnknown(1, in: group.id)?.plainText == "后台新正文",
                  "后台保存拒绝过期快照并保留已存内容")
        }
        store.switchSpecialSlot(id: group.id, fromNavigation: true)
        for _ in 0..<100 {
            if store.currentSpecialSlotId == group.id && store.displayedSpecialSlotId == group.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(store.currentSpecialSlotId == group.id && store.displayedSpecialSlotId == group.id,
              "撤销测试已完成真实目标组切换")
        store.undoLastClearIfPossible()
        check(storage.getOrUnknown(1, in: group.id)?.plainText == "初始正文", "后台保存的单槽撤销恢复正文")
        store.redoLastUndoIfPossible()
        check(storage.getOrUnknown(1, in: group.id)?.plainText == "后台新正文", "后台保存的单槽重做恢复正文")

        let clipboardFile = root.appendingPathComponent("快捷键 中文🙂.txt")
        let clipboardBytes = Data("快捷键独立副本".utf8)
        try clipboardBytes.write(to: clipboardFile)
        let clipboardContent = SlotContent(items: [[
            .init(type: "public.file-url", data: Data(clipboardFile.absoluteString.utf8)),
            .init(type: "public.url", data: Data(clipboardFile.absoluteString.utf8)),
            .init(type: "public.utf8-plain-text", data: Data("兼容表示".utf8))]])
        func drainWriter() async {
            await Task.yield()
            for _ in 0..<500 {
                if store.transientUI.importCancellation == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            await withCheckedContinuation { continuation in
                store.slotWriteQueue.async {
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
        store.handleCapturedContentForSave(clipboardContent, targetSlot: 4)
        await drainWriter()
        let clipboardSaved = storage.getOrUnknown(4, in: group.id)
        let ownedClipboard = clipboardSaved?.primaryFileURL
        check(ownedClipboard != nil && ownedClipboard != clipboardFile,
              "真实快捷键保存入口创建自有文件副本")
        check(store.slots[4]?.primaryFileURL == ownedClipboard,
              "快捷键提交后界面立即使用自有路径")
        try FileManager.default.removeItem(at: clipboardFile)
        check(ownedClipboard.flatMap { try? Data(contentsOf: $0) } == clipboardBytes,
              "快捷键保存后删除 Finder 来源仍有完整字节")
        store.handleCapturedContentForSave(SlotContent(text: "替换文件"), targetSlot: 4)
        await drainWriter()
        store.undoLastClearIfPossible()
        await drainWriter()
        check(storage.getOrUnknown(4, in: group.id)?.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == clipboardBytes,
              "快捷键覆盖文件后撤销恢复原字节")
        store.redoLastUndoIfPossible()
        await drainWriter()
        check(storage.getOrUnknown(4, in: group.id)?.plainText == "替换文件",
              "快捷键文件覆盖可重做")
        store.handleCapturedContentForSave(clipboardContent, targetSlot: 4)
        await drainWriter()
        check(storage.getOrUnknown(4, in: group.id)?.plainText == "替换文件"
            && store.slots[4]?.plainText == "替换文件",
            "快捷键源消失时失败保留磁盘与界面已有内容")

        let copySource = root.appendingPathComponent("强制实际复制.bin")
        let copyBytes = Data(repeating: 0x65, count: 4 * 1024 * 1024)
        try copyBytes.write(to: copySource)
        let copySnapshot = try storage.editorSnapshot(5, in: group.id)
        let copyPaused = DispatchSemaphore(value: 0)
        let copyResume = DispatchSemaphore(value: 0)
        store.fileImportPreferClone = false
        store.fileImportCopyProbe = { copied, total in
            if copied > 0 && copied < total {
                copyPaused.signal()
                _ = copyResume.wait(timeout: .now() + 3)
            }
        }
        var copyFinished = false
        let copyTask = Task { @MainActor in
            try await store.importSelectedFile(copySource, snapshot: copySnapshot)
            copyFinished = true
        }
        let didPause = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: copyPaused.wait(timeout: .now() + 5) == .success)
            }
        }
        check(didPause, "真实上传入口在实际复制分块中暂停")
        let independentStart = ProcessInfo.processInfo.systemUptime
        let independent = try store.captureSlotEditor(slot: 6, groupID: group.id)
        try await store.saveSlotEditorAsync(independent, body: AgentSlotBody(text: "复制中编辑其他槽位"), attachments: [])
        let independentMS = (ProcessInfo.processInfo.systemUptime - independentStart) * 1000
        check(!copyFinished && independentMS < 500,
              "实际复制期间主线程读写其他槽位不等待文件导入队列")
        check(store.transientUI.importCancellation != nil, "上传复制提供取消入口")
        for _ in 0..<8 { copyResume.signal() }
        try await copyTask.value
        store.fileImportCopyProbe = nil
        store.fileImportPreferClone = true
        check(storage.getOrUnknown(5, in: group.id)?.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == copyBytes,
              "真实上传实际复制后字节完整")
        check(store.transientUI.importCancellation == nil && store.importProgress == nil,
              "上传结束清理取消入口和进度")
        // Reproduce the interval between disk commit and a queued UI refresh.
        store.slots[5] = copySnapshot.content
        store.updateTextSlot(6, text: "只保存被编辑的槽位")
        await drainWriter()
        check(storage.getOrUnknown(5, in: group.id)?.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == copyBytes,
              "编辑其他槽位不会把界面旧快照写回已导入的槽位")
        store.slots[5] = storage.getOrUnknown(5, in: group.id)
        let immediateFile = SlotContent(items: [[.init(type: "public.file-url", data: Data(copySource.absoluteString.utf8))]])
        store.handleCapturedContentForSave(immediateFile, targetSlot: 7)
        store.updateTextSlot(7, text: "后一次编辑")
        await drainWriter()
        check(storage.getOrUnknown(7, in: group.id)?.plainText == "后一次编辑",
              "文件保存后立即编辑同槽位，较早文件任务不覆盖新编辑")

        let cancelPaused = DispatchSemaphore(value: 0)
        let cancelResume = DispatchSemaphore(value: 0)
        store.fileImportPreferClone = false
        store.fileImportCopyProbe = { copied, total in
            if copied > 0 && copied < total {
                cancelPaused.signal()
                _ = cancelResume.wait(timeout: .now() + 3)
            }
        }
        let cancelSnapshot = try storage.editorSnapshot(8, in: group.id)
        let cancelTask = Task { @MainActor in
            try await store.importSelectedFile(copySource, snapshot: cancelSnapshot)
        }
        _ = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: cancelPaused.wait(timeout: .now() + 5))
            }
        }
        store.transientUI.importCancellation?.cancel()
        for _ in 0..<8 { cancelResume.signal() }
        do { try await cancelTask.value; check(false, "真实上传取消生效") }
        catch { check(storage.getOrUnknown(8, in: group.id)?.hasEmptyBody == true,
                      "真实上传取消保留空槽位并返回取消结果") }
        store.fileImportCopyProbe = nil
        store.fileImportPreferClone = true
        try FileManager.default.removeItem(at: copySource)

        let file = root.appendingPathComponent("后台移动原文件.bin")
        let bytes = Data(repeating: 0x53, count: 1024 * 1024)
        try bytes.write(to: file)
        let additions = AttachmentTransfer.files([file])
        check(await store.appendTransferredAttachmentsAsync(additions, groupID: group.id, slot: 2),
              "后台添加附件成功")
        let source = try storage.editorSnapshot(2, in: group.id)
        let move = SlotFileMove(snapshot: source, attachment: source.content.attachments[0])
        func transfer(_ move: SlotFileMove) async -> Bool {
            await withCheckedContinuation { continuation in
                store.acceptTransferInBackground(.move(move), groupID: other.id, slot: 2) {
                    continuation.resume(returning: $0)
                }
            }
        }
        check(await transfer(move), "后台跨组移动成功后回调")
        let target = storage.getOrUnknown(2, in: other.id)
        check(storage.getOrUnknown(2, in: group.id)?.attachments.isEmpty == true
            && target?.attachments.first?.resolveData() == bytes,
            "后台移动清除源附件且目标字节完整")
        check(try Data(contentsOf: file) == bytes, "后台移动保留 Finder 原文件")
        check(!(await transfer(move)) && storage.getOrUnknown(2, in: other.id)?.attachments.count == 1,
              "重复后台移动拒绝过期来源且不重复添加")
        try? FileManager.default.removeItem(at: file)
        check(!(await store.appendTransferredAttachmentsAsync(additions, groupID: other.id, slot: 3))
            && storage.getOrUnknown(3, in: other.id)?.attachments.isEmpty == true,
            "后台添加缺失文件失败且保留目标")
        let batchPage = try storage.createPage(name: "后台批量测试页", withDefaultGroup: true).page
        let batchGroup = storage.loadIndex().specialSlots.first { $0.pageId == batchPage.id }!
        store.reloadAll()
        store.switchSpecialSlot(id: batchGroup.id, fromNavigation: true)
        for _ in 0..<100 {
            if store.currentSpecialSlotId == batchGroup.id && !store.transientUI.isNavigationPending { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(store.currentSpecialSlotId == batchGroup.id, "批量测试已切至隔离页面目标组")
        let folder = root.appendingPathComponent("后台批量测试文件")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<25 {
            try Data("批量文件-\(i)🙂".utf8).write(to: folder.appendingPathComponent("file-\(i).txt"))
        }
        // Only this isolated regression process owns these modal windows.
        let confirmer = Timer(timeInterval: 0.02, repeats: true) { _ in
            if NSApp.modalWindow != nil { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        }
        RunLoop.main.add(confirmer, forMode: .common)
        RunLoop.main.add(confirmer, forMode: .modalPanel)
        defer { confirmer.invalidate() }
        store.executeToolbarImport(urls: [folder], mode: .allTotal, sortRule: .naturalNameAscending)
        store.switchSpecialSlot(id: other.id, fromNavigation: true)
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<500 {
            if !store.isBatchSaving { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        confirmer.invalidate()
        let batchGroups = storage.loadIndex().specialSlots.filter { $0.pageId == batchPage.id }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        let savedFiles = batchGroups.flatMap { group in
            (1...store.config.slots).compactMap { slot -> SlotContent? in
                guard var content = storage.getOrUnknown(slot, in: group.id), !content.hasEmptyBody else { return nil }
                content.label = storage.getLabel(slot, in: group.id)
                return content
            }
        }
        check(!store.isBatchSaving && savedFiles.count == 25, "真实后台批量入口跨组保存全部文件")
        check(savedFiles.enumerated().allSatisfy { i, content in
            content.label == "file-\(i).txt"
                && content.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == Data("批量文件-\(i)🙂".utf8)
        }, "后台批量导入保持自然排序、标签及全部文件字节")
        check(storage.getOrUnknown(1, in: other.id)?.hasEmptyBody == true,
              "目录扫描期间切页切组不改变批量导入目标")
        try storage.updateCurrentSpecialSlotSource(sourceType: .folderImport, sourcePath: folder.path,
                                                   groupID: batchGroup.id)
        let metadata = storage.loadIndex()
        check(metadata.specialSlots.first { $0.id == batchGroup.id }?.sourcePath == folder.path
            && metadata.specialSlots.first { $0.id == other.id }?.sourcePath != folder.path,
            "后台目录导入元数据只更新捕获的源组")
        let metrics: [String: Any] = ["busy_writer_main_actor_three_ticks_ms": tickMS,
                                     "physical_copy_other_slot_edit_ms": independentMS,
                                     "scope": "isolated actual Store async operations"]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("storage-responsiveness.json"))
    }
}
#endif
