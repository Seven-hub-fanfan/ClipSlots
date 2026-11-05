#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

enum AttachmentBundleRegression {
    @MainActor static func run(root: URL, store: SlotStoreObservable,
                               check: (Bool, String) -> Void) async throws {
        let storage = store.specialStorage
        let page = try storage.createPage(name: "整组附件隔离页", withDefaultGroup: false)
        let source = try storage.createSpecialSlot(name: "整组附件来源", pageId: page.page.id)
        let target = try storage.createSpecialSlot(name: "整组附件目标", pageId: page.page.id)
        let file = root.appendingPathComponent("拖入 独立副本.md")
        let bytes = Data("# 保存副本🙂\n".utf8)
        try bytes.write(to: file)
        let imported = FolderImportService().makeSlotContent(for: file)
        check(imported.managedBodyFiles?.count == 1, "拖入构建器要求保存文件副本")
        check(storage.set(3, content: imported, in: source.id), "拖入内容保存成功")
        let owned = storage.get(3, in: source.id).primaryFileURL!
        check(owned != file && store.specialStorage.get(3, in: source.id).managedBodyFiles?.count == 1,
              "拖入后使用槽位自有文件路径")
        try Data("# Finder 新内容".utf8).write(to: file)
        check(try Data(contentsOf: owned) == bytes, "原位修改来源不影响副本")
        try FileManager.default.removeItem(at: file)
        check(SpecialSlotStorage().get(3, in: source.id).primaryFileURL.flatMap {
            try? Data(contentsOf: $0)
        } == bytes, "删除来源后冷读仍可打开副本")
        check(!storage.set(4, content: FolderImportService().makeSlotContent(for: file), in: source.id),
              "源文件消失后导入失败，不保存空壳路径")

        var content = SlotContent(text: "保留来源正文")
        content.attachments = [.init(name: "文件.md", type: .file, path: owned.path),
            .init(name: "文字", type: .text, data: Data("附件文本".utf8)),
            .init(name: "链接", type: .url, url: "https://example.com")]
        check(storage.set(1, content: content, in: source.id), "建立混合整组附件")
        check(storage.set(1, content: SlotContent(text: "保留目标正文"), in: target.id), "建立整组移动目标")
        store.switchSpecialSlot(id: source.id, fromNavigation: true)
        try await Task.sleep(for: .milliseconds(200))
        let droppedURL = root.appendingPathComponent("实际拖入.txt")
        try bytes.write(to: droppedURL)
        store.importDroppedFiles([droppedURL], toSlot: 5)
        await withCheckedContinuation { continuation in
            store.slotWriteQueue.async { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(80))
        let dropped = store.slots[5]?.primaryFileURL
        check(dropped != nil && dropped != droppedURL, "真实拖入入口回填已保存的副本路径")
        try FileManager.default.removeItem(at: droppedURL)
        check(store.slots[5]?.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == bytes,
              "真实拖入完成后删除原文件不影响当前 UI 文件")
        guard let move = store.fileMoveSource(groupID: source.id, slot: 1, moveAllAttachments: true) else {
            throw AgentOperationError("整组拖拽未生成")
        }
        let provider = AttachmentTransfer.provider(move)
        check(provider.hasItemConformingToTypeIdentifier(AttachmentTransfer.bundleType.identifier)
            && !provider.hasItemConformingToTypeIdentifier(AttachmentTransfer.bodyType.identifier)
            && !provider.hasItemConformingToTypeIdentifier("public.file-url"), "整组载荷只声明附件专用拖拽类型")
        check(!store.dropFilesIntoGroup([provider], groupID: target.id), "整组附件拒绝组按钮直接落点")
        check(!store.acceptTransfer(.move(move), groupID: target.id, slot: 2, destination: .body),
              "Store 层整组附件拒绝空槽正文")
        let loaded: AttachmentTransfer.Loaded? = await withCheckedContinuation { continuation in
            if !AttachmentTransfer.receive([provider], completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: nil)
            }
        }
        check(loaded != nil, "整组附件通过真实 NSItemProvider 解码")
        check(loaded.map { store.acceptTransfer($0, groupID: target.id, slot: 1) } == true, "真实 Store 接收整组附件")
        let result = storage.get(1, in: target.id)
        check(result.attachments.map(\.name) == ["文件.md", "文字", "链接"], "混合附件顺序和类型保留")
        check(result.attachments[0].resolveData() == bytes
            && result.attachments[1].resolveTextString() == "附件文本", "移动后的文件与文字可读取")
        check(storage.get(1, in: source.id).attachments.isEmpty
            && storage.get(1, in: source.id).plainText == "保留来源正文"
            && result.plainText == "保留目标正文", "整组移动保留双方正文并移除来源附件")

        store.switchSpecialSlot(id: target.id, fromNavigation: true)
        try await Task.sleep(for: .milliseconds(200))
        let host = NSHostingView(rootView: NodeAttachmentButton(slot: 1, store: store,
            attachmentCountOverride: result.attachments.count, groupId: target.id).padding(20))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 220, height: 90),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        func find(_ view: NSView) -> ClickHandleNSView? {
            if let handle = view as? ClickHandleNSView, handle.moveSource != nil { return handle }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        if let handle = find(host) {
            check(handle.acceptsFirstMouse(for: nil), "附件胶囊首按可响应")
            check(handle.moveSource?()?.attachmentBundle?.count == 3, "胶囊原生拖动入口捕获全部附件")
            check(handle.dragImage?().size == CompactFileDrag.size, "整组拖影尺寸保持紧凑")
            handle.action?()
            try await Task.sleep(for: .milliseconds(150))
            check(AttachmentManagerPanelController.shared.isVisible, "附件胶囊点击仍打开管理面板")
            handle.onDragStarted?()
            try await Task.sleep(for: .milliseconds(250))
            check(!AttachmentManagerPanelController.shared.isVisible, "拖动胶囊时关闭管理面板")
        } else { check(false, "附件胶囊原生拖动入口已挂载") }
        window.orderOut(nil)
        let editor = SlotEditorTextView.Editor()
        editor.loadPlainText("中文 PingFang / English SF", html: false)
        check(editor.font?.fontName == NSFont.systemFont(ofSize: 15).fontName, "正文编辑器使用 macOS 系统字体")
        editor.loadPlainText("<p>中文</p>", html: true)
        check(editor.font?.fontName == NSFont.systemFont(ofSize: 13).fontName, "HTML 编辑器使用 macOS 系统字体")
        try JSONSerialization.data(withJSONObject: ["passed": true, "owned_path": owned.path,
            "bundle_count": 3, "physical_mouse_drag_verified": false], options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("owned-file-and-attachment-bundle.json"))
    }
}
#endif
