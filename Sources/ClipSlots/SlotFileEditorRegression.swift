#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

enum SlotFileEditorRegression {
    private static var fixtureWindow: NSWindow?

    @MainActor static func run(root: URL, store: SlotStoreObservable,
                               check: (Bool, String) -> Void) async throws {
        let storage = store.specialStorage
        let group = try storage.createSpecialSlot(name: "上传与 Markdown 测试")
        let other = try storage.createSpecialSlot(name: "另一组")
        store.switchSpecialSlot(id: group.id, fromNavigation: true)
        try await Task.sleep(for: .milliseconds(250))
        let url = root.appendingPathComponent("中文 空格.md")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# Markdown 原文\r\n\r\n**加粗**与 <html>片段</html>🙂\r\n".utf8)
        try bytes.write(to: url)
        let captured = try store.captureSlotEditor(slot: 1, groupID: group.id)
        let picker = SlotStoreObservable.singleSlotFilePanel()
        check(picker.canChooseFiles && !picker.canChooseDirectories && !picker.allowsMultipleSelection,
              "空槽上传使用系统单文件选择器")
        check(picker.allowedContentTypes.isEmpty,
              "单文件上传接受图片和其他文件类型")
        store.switchSpecialSlot(id: other.id, fromNavigation: true)
        try await Task.sleep(for: .milliseconds(150))
        try await store.importSelectedFile(url, snapshot: captured)
        let importedURL = storage.getOrUnknown(1, in: group.id)?.primaryFileURL
        check(importedURL != nil && importedURL != url
            && importedURL.flatMap { try? Data(contentsOf: $0) } == bytes,
              "真实 Store 上传写入点击时的组")
        check(storage.getOrUnknown(1, in: other.id)?.hasEmptyBody == true,
              "选择期间切组不写错位置")
        store.switchSpecialSlot(id: group.id, fromNavigation: true)
        try await Task.sleep(for: .milliseconds(200))
        store.undoLastClearIfPossible()
        check(storage.getOrUnknown(1, in: group.id)?.hasEmptyBody == true, "上传可以单槽撤销")
        store.redoLastUndoIfPossible()
        check(storage.getOrUnknown(1, in: group.id)?.primaryFileURL.flatMap {
            try? Data(contentsOf: $0)
        } == bytes, "上传可以单槽重做")
        let snapshot = try store.captureSlotEditor(slot: 1, groupID: group.id)
        let model = try SlotEditorModel(snapshot: snapshot)
        check(model.markdown != nil && model.formatName == "Markdown" && !model.isHTML,
              "MD 内嵌 HTML 仍按 Markdown 编辑")
        check(model.draft == "# Markdown 原文\n\n**加粗**与 <html>片段</html>🙂\n", "MD 编辑器读取实际文件")
        let cancelled = SlotEditorWindowController(model: model, parent: NSApp.keyWindow) { _ in
            throw AgentOperationError("取消操作不应保存")
        }
        cancelled.present()
        try await Task.sleep(for: .milliseconds(160))
        guard let editor = model.textBridge.editor else { throw AgentOperationError("MD 原生编辑器未挂载") }
        editor.insertText("未保存的编辑", replacementRange: NSRange(location: 0, length: 0))
        cancelled.cancel()
        check(try Data(contentsOf: url) == bytes && storage.getOrUnknown(1, in: group.id)?.primaryFileURL == importedURL,
              "取消 MD 草稿不写文件或槽位")
        let savedModel = try SlotEditorModel(snapshot: store.captureSlotEditor(slot: 1, groupID: group.id))
        let controller = SlotEditorWindowController(model: savedModel, parent: NSApp.keyWindow) { model in
            try await store.saveSlotEditorAsync(model.snapshot, body: model.body, attachments: model.attachments,
                                     markdownEdit: model.markdownEdit)
        }
        controller.present()
        try await Task.sleep(for: .milliseconds(160))
        guard let native = savedModel.textBridge.editor else { throw AgentOperationError("MD 原生编辑器未挂载") }
        native.insertText("\n## 新段落\n保留 **Markdown** 格式🙂\n",
            replacementRange: NSRange(location: (native.string as NSString).length, length: 0))
        savedModel.textBridge.commit()
        let expected = savedModel.draft
        check(savedModel.dirty && expected.contains("新段落"), "原生输入修改 MD 草稿")
        controller.save()
        check(savedModel.saving && !native.isEditable, "后台保存期间防止重复提交与修改提交草稿")
        controller.cancel()
        check(!savedModel.closed, "后台保存完成前不关闭草稿")
        while savedModel.saving { try await Task.sleep(for: .milliseconds(10)) }
        check(savedModel.closed && savedModel.error == nil, "后台保存成功后才关闭窗口")
        let saved = try store.captureSlotEditor(slot: 1, groupID: group.id).content
        check(saved.primaryFileURL?.lastPathComponent == url.lastPathComponent && saved.isMarkdownFile,
              "保存后的槽位仍是原文件名 MD")
        check(saved.plainText == nil && saved.primaryFileURL != url, "MD 保存仍是文件主体")
        check(try SlotMarkdownDocument(content: saved).text == expected, "保存后重新读取 MD 内容一致")
        check(try Data(contentsOf: url) == bytes, "MD 编辑保留 Finder 原始文件")
        let editedBytes = try Data(contentsOf: saved.primaryFileURL!)
        check(editedBytes.starts(with: [0xEF, 0xBB, 0xBF])
            && String(data: editedBytes.dropFirst(3), encoding: .utf8)?.contains("\r\n") == true,
              "MD 保存保留 BOM 与 CRLF")
        store.undoLastClearIfPossible()
        let undone = try store.captureSlotEditor(slot: 1, groupID: group.id).content
        check(try Data(contentsOf: undone.primaryFileURL!) == bytes, "MD 槽位撤销恢复原始字节")
        store.redoLastUndoIfPossible()
        let redone = try store.captureSlotEditor(slot: 1, groupID: group.id).content
        check(try Data(contentsOf: redone.primaryFileURL!) == editedBytes, "MD 槽位重做恢复新字节")
        store.undoLastClearIfPossible()
        store.redoLastUndoIfPossible()
        let repeated = try store.captureSlotEditor(slot: 1, groupID: group.id).content
        check(try Data(contentsOf: repeated.primaryFileURL!) == editedBytes, "MD 连续撤销重做无断链")
        let reopened = try SlotEditorModel(snapshot: store.captureSlotEditor(slot: 1, groupID: group.id))
        check(reopened.draft == expected && !reopened.dirty, "MD 重新打开显示保存内容")
        // Native hit testing checks every part of the visible upload preview,
        // including corners away from its glyph and text.
        let host = NSHostingView(rootView: SlotCardView(slot: 2, content: SlotContent(),
            specialSlotId: group.id, onPaste: {}, onCopy: {}, onSave: {}, onClear: {},
            onSetLabel: { _ in }, onUploadFile: {}, store: store))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 370),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        func handle(_ view: NSView) -> ClickHandleNSView? {
            if let click = view as? ClickHandleNSView, click.bounds.height > 50 { return click }
            return view.subviews.lazy.compactMap { handle($0) }.first
        }
        if let click = handle(host) {
            check(click.acceptsFirstMouse(for: nil), "空槽上传首按直接响应")
            check(click.bounds.width > 200 && click.bounds.height > 60, "整个空槽预览区域覆盖点击入口")
        } else { check(false, "空槽原生点击入口已挂载") }
        window.orderOut(nil)
        if ProcessInfo.processInfo.environment["CLIPSLOTS_EDITOR_SHOW_UI"] == "1" {
            let fixture = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 600),
                styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            fixture.title = "上传与 Markdown 隔离测试"
            fixture.contentView = NSHostingView(rootView: SlotFileEditorFixtureView(store: store, groupID: group.id))
            fixture.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            fixtureWindow = fixture
        }
    }
}

private struct SlotFileEditorFixtureView: View {
    @ObservedObject var store: SlotStoreObservable
    let groupID: String
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(1...3, id: \.self) { slot in
                SlotCardView(slot: slot, content: store.slots[slot] ?? SlotContent(), specialSlotId: groupID,
                    onPaste: {}, onCopy: {}, onSave: { store.saveToSlot(slot) }, onClear: {},
                    onSetLabel: { _ in }, onEditText: { _ in }, onEditHTML: { _ in },
                    onUploadFile: { store.chooseFileForEmptySlot(slot: slot, groupID: groupID) }, store: store)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(NSColor.windowBackgroundColor))
    }
}
#endif
