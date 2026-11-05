import Foundation
import ClipSlotsKit

func runSlotFileEditorTests(_ t: TestRunner) {
    runPreparedFileImportTests(t)
    t.withFreshStore("CLIPBOARD-OWNED-FILE") { storage in
        let group = try storage.createSpecialSlot(name: "快捷键文件")
        let source = storage.storageRoot.appendingPathComponent("中文 空格🙂.txt")
        let bytes = Data("保存副本".utf8)
        try bytes.write(to: source)
        var body = SlotContent(items: [[.init(type: "public.file-url", data: Data(source.absoluteString.utf8)),
                                        .init(type: "public.url", data: Data(source.absoluteString.utf8)),
                                        .init(type: "public.utf8-plain-text", data: Data("保留表示".utf8))]])
        body.manageBodyFile(source)
        t.check(storage.set(1, content: body, in: group.id), "剪贴板单文件摄取成功")
        let saved = storage.getOrUnknown(1, in: group.id)!
        let owned = saved.primaryFileURL!
        t.check(owned != source, "剪贴板文件拥有独立路径")
        t.equal(saved.items[0][2].data, body.items[0][2].data, "文件摄取保留非 URL 表示")
        t.equal(saved.items[0][0].data, saved.items[0][1].data, "文件两种 URL 均重定位")
        try Data("源已修改".utf8).write(to: source)
        t.equal(try Data(contentsOf: owned), bytes, "源文件原位编辑不污染副本")
        try FileManager.default.removeItem(at: source)
        t.equal(try Data(contentsOf: owned), bytes, "删除源文件后副本完整")
        t.check(!storage.set(1, content: body, in: group.id), "缺失源文件摄取失败")
        t.equal(try Data(contentsOf: owned), bytes, "失败摄取不移除已有副本")
        t.check(storage.set(1, content: SlotContent(text: "覆盖正文"), in: group.id), "覆盖拥有文件的槽位")
        t.check(!FileManager.default.fileExists(atPath: owned.path), "覆盖移除旧实时副本")
        t.check(storage.set(1, content: saved, in: group.id), "撤销从回收快照恢复自有文件")
        t.equal(try Data(contentsOf: storage.getOrUnknown(1, in: group.id)!.primaryFileURL!), bytes,
                "撤销恢复原文件字节")
        t.check(storage.clear(1, in: group.id), "清空拥有文件的槽位")
        t.check(!FileManager.default.fileExists(atPath: owned.path), "清空移除实时文件目录")
        t.check(storage.set(1, content: saved, in: group.id), "清空后可从回收快照恢复文件")
        t.equal(try Data(contentsOf: storage.getOrUnknown(1, in: group.id)!.primaryFileURL!), bytes,
                "清空恢复保留字节")
    }
    t.withFreshStore("SINGLE-FILE-UPLOAD") { storage in
        let group = try storage.createSpecialSlot(name: "上传目标")
        let other = try storage.createSpecialSlot(name: "其他组")
        let file = storage.storageRoot.appendingPathComponent("上传样本.md")
        try Data("# 原文件\n".utf8).write(to: file)
        var empty = SlotContent()
        empty.label = "保留标签"
        empty.attachments = [.init(name: "旧资料", type: .text, data: Data("资料".utf8))]
        storage.set(1, content: empty, in: group.id)
        storage.setLabel(1, label: "保留标签", in: group.id)
        let snapshot = try storage.editorSnapshot(1, in: group.id)
        var changed = snapshot.content
        changed.attachments.append(.init(name: "新资料", type: .text, data: Data("新增".utf8)))
        storage.set(1, content: changed, in: group.id)
        let imported = try storage.importFileIntoEmptyBody(file, snapshot: snapshot)
        t.equal(imported.after.detectedFileURLs.count, 1, "单文件上传只写一个文件")
        let owned = imported.after.detectedFileURLs[0]
        t.check(owned != file && owned.path.hasPrefix(storage.storageRoot.path + "/" + group.id + "/1/body-files/"),
                "导入文件写入独立的槽位路径")
        let originalBytes = try Data(contentsOf: file)
        try Data("# 外部改写\n".utf8).write(to: file)
        t.equal(try Data(contentsOf: owned), originalBytes, "外部原位改写不影响槽位副本")
        try FileManager.default.removeItem(at: file)
        let cold = SpecialSlotStorage().getOrUnknown(1, in: group.id)!
        t.equal(try Data(contentsOf: cold.detectedFileURLs[0]), originalBytes, "删除来源后冷读仍有文件字节")
        try originalBytes.write(to: file)
        t.equal(imported.after.attachments.map(\.name), ["旧资料", "新资料"], "上传保留选择期间新增附件")
        t.equal(imported.before.attachments.count, 2, "上传撤销快照使用最新附件")
        t.equal(storage.getLabel(1, in: group.id), "保留标签", "上传保留槽位标签")
        t.check(storage.getOrUnknown(1, in: other.id)?.hasEmptyBody == true, "上传只写捕获的组")
        t.expectThrows("重复上传不覆盖已占用主体") {
            _ = try storage.importFileIntoEmptyBody(file, snapshot: snapshot)
        }
        let blank = try storage.editorSnapshot(2, in: group.id)
        storage.set(2, content: SlotContent(text: ""), in: group.id)
        t.expectThrows("选择期间创建空白文本也拒绝覆盖") {
            _ = try storage.importFileIntoEmptyBody(file, snapshot: blank)
        }
        let missing = try storage.editorSnapshot(3, in: group.id)
        t.expectThrows("消失的文件拒绝上传") {
            _ = try storage.importFileIntoEmptyBody(file.appendingPathExtension("missing"), snapshot: missing)
        }
        t.expectThrows("目录不能作为单文件上传") {
            _ = try storage.importFileIntoEmptyBody(storage.storageRoot, snapshot: missing)
        }
        try storage.deleteSpecialSlot(id: group.id)
        t.expectThrows("删除目标组后上传不能复活组") {
            _ = try storage.importFileIntoEmptyBody(file, snapshot: missing)
        }
    }
    t.withFreshStore("MARKDOWN-FILE-EDITOR") { storage in
        let group = try storage.createSpecialSlot(name: "Markdown")
        let fixtures: [(String, Data, String.Encoding)] = [
            ("中文 空格.md", Data("# 原文\n段落🙂\n".utf8), .utf8),
            ("BOM.MD", Data([0xEF, 0xBB, 0xBF]) + Data("# 原文\r\n段落🙂\r\n".utf8), .utf8),
            ("LE.md", Data([0xFF, 0xFE]) + "# 原文\r\n段落🙂\r\n".data(using: .utf16LittleEndian)!, .utf16LittleEndian),
            ("BE.md", Data([0xFE, 0xFF]) + "# 原文\r段落🙂\r".data(using: .utf16BigEndian)!, .utf16BigEndian)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let (name, bytes, _) = fixture
            let source = storage.storageRoot.appendingPathComponent(name)
            try bytes.write(to: source)
            let data = Data(source.absoluteString.utf8)
            var content = SlotContent(items: [[.init(type: "public.file-url", data: data),
                                               .init(type: "public.url", data: data)]])
            content.attachments = [.init(name: "资料.txt", type: .text, data: Data("资料".utf8))]
            storage.set(index + 1, content: content, in: group.id)
            let snapshot = try storage.editorSnapshot(index + 1, in: group.id)
            let document = try SlotMarkdownDocument(content: snapshot.content)
            t.equal(document.text, "# 原文\n段落🙂\n", "\(name) 无损读取编码与换行")
            let edited = "# 新文\n保留 Markdown **语法**🙂\n"
            let result = try storage.exchangeEditorContent(snapshot, body: AgentSlotBody(snapshot.content),
                attachments: snapshot.content.attachments, markdownEdit: .init(document: document, text: edited))
            let url = result.detectedFileURLs[0]
            t.equal(url.lastPathComponent, name, "\(name) 保存保留文件名和扩展名")
            t.equal(try Data(contentsOf: url), try document.encoded(edited), "\(name) 保存保持编码和换行")
            t.equal(try Data(contentsOf: source), bytes, "\(name) Finder 原始文件不被改写")
            t.equal(result.attachments.count, 1, "\(name) 保存保留附件")
            t.equal(try SlotMarkdownDocument(content: result).text, edited, "\(name) 重新打开读取已保存内容")
            t.check(result.items[0].allSatisfy { String(data: $0.data, encoding: .utf8) == url.absoluteString },
                    "\(name) 两种文件 URL 均指向新文件")
            let undo = document.contentForUndo(snapshot.content)
            let restored = try JSONDecoder().decode(SlotContent.self, from: JSONEncoder().encode(undo))
            storage.set(index + 1, content: restored, in: group.id)
            t.equal(try Data(contentsOf: storage.getOrUnknown(index + 1, in: group.id)!.detectedFileURLs[0]), bytes,
                    "\(name) 序列化撤销恢复原字节")
        }
        let source = storage.storageRoot.appendingPathComponent("冲突.md")
        try Data("# 原文".utf8).write(to: source)
        let content = SlotContent(items: [[.init(type: "public.file-url", data: Data(source.absoluteString.utf8))]])
        storage.set(5, content: content, in: group.id)
        let snapshot = try storage.editorSnapshot(5, in: group.id)
        let document = try SlotMarkdownDocument(content: snapshot.content)
        try Data("# 外部".utf8).write(to: source)
        t.expectThrows("编辑期间外部修改原文件拒绝旧草稿保存") {
            _ = try storage.exchangeEditorContent(snapshot, body: AgentSlotBody(snapshot.content), attachments: [],
                markdownEdit: .init(document: document, text: "错误覆盖"))
        }
        t.equal(try Data(contentsOf: source), Data("# 外部".utf8), "冲突保留外部文件")
        t.equal(storage.getOrUnknown(5, in: group.id)?.detectedFileURLs, [source], "冲突不替换槽位主体")
        try Data([0xFF, 0x00, 0x81]).write(to: source)
        t.expectThrows("非法编码拒绝有损编辑") { _ = try SlotMarkdownDocument(content: content) }
        try Data("<html>Markdown 中的 HTML</html>".utf8).write(to: source)
        let valid = try SlotMarkdownDocument(content: content)
        t.check(valid.text.contains("<html>"), "Markdown 内嵌 HTML 不转换格式")
        t.expectThrows("超过编辑上限的保存拒绝") {
            _ = try valid.encoded(String(repeating: "x", count: SlotMarkdownDocument.maximumBytes + 1))
        }
    }
}

private final class ImportTestResult {
    let lock = NSLock()
    private var value: Result<SlotContent, Error>?
    func put(_ result: Result<SlotContent, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<SlotContent, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

private func runPreparedFileImportTests(_ t: TestRunner) {
    t.withFreshStore("PREPARED-FILE-IMPORT") { storage in
        let group = try storage.createSpecialSlot(name: "锁外复制")
        let source = storage.storageRoot.appendingPathComponent("副本 中文🙂.bin")
        let bytes = Data(repeating: 0x73, count: 4 * 1024 * 1024)
        try bytes.write(to: source)
        let snapshot = try storage.editorSnapshot(1, in: group.id)
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let result = ImportTestResult()
        DispatchQueue.global().async {
            result.put(Result {
                try storage.importFileIntoEmptyBody(source, snapshot: snapshot, preferClone: false) { copied, total in
                    if copied > 0 && copied < total {
                        paused.signal()
                        guard resume.wait(timeout: .now() + 10) == .success else { throw AgentCanvasError.busy }
                    }
                }.after
            })
            done.signal()
        }
        t.check(paused.wait(timeout: .now() + 5) == .success, "实际复制首个分块后暂停")
        let start = ProcessInfo.processInfo.systemUptime
        t.check(storage.set(2, content: SlotContent(text: "复制中仍可写"), in: group.id),
                "复制暂停期间其他槽位可以写入")
        t.equal(storage.getOrUnknown(2, in: group.id)?.plainText, "复制中仍可写", "复制暂停期间可以读取")
        t.check(ProcessInfo.processInfo.systemUptime - start < 0.5, "其他槽位读写不等待文件复制")
        var live = storage.getOrUnknown(1, in: group.id)!
        live.attachments = [.init(name: "复制期间新增", type: .text, data: Data("新附件".utf8))]
        storage.set(1, content: live, in: group.id)
        storage.setLabel(1, label: "复制期间的标签", in: group.id)
        // Supply enough signals for every possible throttled callback.
        for _ in 0..<8 { resume.signal() }
        t.check(done.wait(timeout: .now() + 10) == .success, "实际复制与原子提交完成")
        let saved = try result.get()!.get()
        t.equal(try Data(contentsOf: saved.primaryFileURL!), bytes, "实际复制字节一致")
        t.equal(saved.attachments.map(\.name), ["复制期间新增"], "提交保留最新附件")
        t.equal(storage.getLabel(1, in: group.id), "复制期间的标签", "提交保留最新标签")
        try Data("改变源".utf8).write(to: source)
        t.equal(try Data(contentsOf: saved.primaryFileURL!), bytes, "实际复制与源文件互相独立")
        try bytes.write(to: source)

        func scratchCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: storage.storageRoot.path)) ?? [])
                .filter { $0.hasPrefix(".file-import-") }.count
        }
        let cancellation = FileImportCancellation()
        t.expectThrows("分块复制中取消") {
            _ = try storage.importFileIntoEmptyBody(source,
                snapshot: storage.editorSnapshot(3, in: group.id), cancellation: cancellation,
                preferClone: false) { copied, _ in if copied > 0 { cancellation.cancel() } }
        }
        t.check(storage.getOrUnknown(3, in: group.id)!.hasEmptyBody, "取消不产生半截槽位")
        t.equal(scratchCount(), 0, "取消清理临时副本")
        t.expectThrows("复制过程中源文件变化拒绝提交") {
            _ = try storage.importFileIntoEmptyBody(source,
                snapshot: storage.editorSnapshot(3, in: group.id), preferClone: false) { copied, total in
                if copied > 0 && copied < total { try Data("源被替换".utf8).write(to: source) }
            }
        }
        t.equal(scratchCount(), 0, "源文件冲突清理临时副本")
        try bytes.write(to: source)
        t.expectThrows("复制期间目标改变拒绝覆盖") {
            _ = try storage.importFileIntoEmptyBody(source,
                snapshot: storage.editorSnapshot(3, in: group.id), preferClone: false) { copied, total in
                if copied == total { storage.set(3, content: SlotContent(text: "保留新内容"), in: group.id) }
            }
        }
        t.equal(storage.getOrUnknown(3, in: group.id)?.plainText, "保留新内容", "并发目标内容保留")
        t.equal(scratchCount(), 0, "目标冲突清理临时副本")
        t.expectThrows("复制读取错误拒绝发布") {
            _ = try storage.importFileIntoEmptyBody(source,
                snapshot: storage.editorSnapshot(4, in: group.id), preferClone: false) { copied, _ in
                if copied > 0 { throw AgentCanvasError.unavailable }
            }
        }
        t.equal(scratchCount(), 0, "复制错误清理临时副本")
        let deleted = try storage.createSpecialSlot(name: "复制时删除")
        t.expectThrows("复制期间删除组不能复活目标") {
            _ = try storage.importFileIntoEmptyBody(source,
                snapshot: storage.editorSnapshot(1, in: deleted.id), preferClone: false) { copied, total in
                if copied == total { try storage.deleteSpecialSlot(id: deleted.id) }
            }
        }
        t.check(!FileManager.default.fileExists(atPath: storage.storageRoot.appendingPathComponent(deleted.id).path),
                "被删除组不被准备好的副本重建")
        t.equal(scratchCount(), 0, "目标删除清理临时副本")
    }
}
