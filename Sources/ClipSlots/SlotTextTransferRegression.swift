#if DEBUG
import AppKit
import ClipSlotsKit

enum SlotTextTransferRegression {
    @MainActor static func run(root: URL, store: SlotStoreObservable, png: Data,
                               check: (Bool, String) -> Void) async throws {
        let storage = store.specialStorage
        let sourceGroup = try storage.createSpecialSlot(name: "文本来源")
        let targetGroup = try storage.createSpecialSlot(name: "文本目标")
        let text = "第一行\n第二行🙂\n第三行 **格式符号**\n"
        let textBytes = Data(text.utf8)
        var source = SlotContent(items: [[
            .init(type: "public.utf8-plain-text", data: textBytes),
            .init(type: "NSStringPboardType", data: textBytes)]],
            attachments: [.init(name: "来源附件", type: .text, data: Data("source".utf8))])
        source.label = "来源标签"
        check(storage.set(1, content: source, in: sourceGroup.id), "建立带附件文本来源")
        storage.setLabel(1, label: source.label, in: sourceGroup.id)
        var target = SlotContent()
        target.label = "目标标签"
        target.attachments = [.init(name: "目标附件", type: .text, data: Data("target".utf8))]
        check(storage.set(2, content: target, in: sourceGroup.id), "建立带附件空文本目标")
        storage.setLabel(2, label: target.label, in: sourceGroup.id)
        let captured = store.fileMoveSource(groupID: sourceGroup.id, slot: 1)!
        check(AgentSlotBody(storage.get(1, in: sourceGroup.id)) == AgentSlotBody(source),
              "开始拖动和取消不修改文本")
        let payload = await withCheckedContinuation { continuation in
            if !AttachmentTransfer.receive([AttachmentTransfer.provider(captured)], completion: {
                continuation.resume(returning: Optional($0))
            }) { continuation.resume(returning: nil) }
        }
        check(payload.map { store.acceptTransfer($0, groupID: sourceGroup.id, slot: 2,
                                                destination: .body) } == true,
              "纯文本原生载荷可移动到同组空槽位")
        let sameGroup = SpecialSlotStorage().get(2, in: sourceGroup.id)
        check(AgentSlotBody(sameGroup) == AgentSlotBody(source) && sameGroup.plainText == text,
              "文本移动原样保留多种剪贴板表示、中文、换行和 Unicode")
        check(storage.get(1, in: sourceGroup.id).hasEmptyBody
            && storage.get(1, in: sourceGroup.id).attachments.count == 1
            && sameGroup.attachments.count == 1, "文本移动只清除来源正文，双方附件保留")
        check(storage.getLabel(2, in: sourceGroup.id) == target.label, "文本移动保留目标标签")
        check(!store.acceptTransfer(.move(captured), groupID: targetGroup.id, slot: 1, destination: .body),
              "旧文本拖拽载荷不能重复移动")
        _ = storage.set(3, content: SlotContent(text: "已有正文"), in: sourceGroup.id)
        let cross = store.fileMoveSource(groupID: sourceGroup.id, slot: 2)!
        check(!store.acceptTransfer(.move(cross), groupID: sourceGroup.id, slot: 3, destination: .body),
              "文本拖入非空正文不会覆盖")
        check(storage.get(3, in: sourceGroup.id).plainText == "已有正文"
            && storage.get(2, in: sourceGroup.id).plainText == text, "拒绝覆盖保留来源和目标")
        check(store.acceptTransfer(.move(cross), groupID: targetGroup.id, slot: 1, destination: .body),
              "纯文本支持跨组移动")
        check(AgentSlotBody(SpecialSlotStorage().get(1, in: targetGroup.id)) == AgentSlotBody(source),
              "跨组文本冷读保留原始表示")
        let toAttachment = store.fileMoveSource(groupID: targetGroup.id, slot: 1)!
        check(store.acceptTransfer(.move(toAttachment), groupID: sourceGroup.id, slot: 3),
              "纯文本可拖到已有正文槽位的附件")
        let attached = storage.get(3, in: sourceGroup.id)
        check(attached.plainText == "已有正文" && attached.attachments.last?.resolveData() == textBytes
            && attached.attachments.last?.type == .text, "文本附件保留正文与完整文本字节")
        check(storage.get(1, in: targetGroup.id).hasEmptyBody, "转为文本附件后清除来源正文")
        _ = storage.set(4, content: SlotContent(text: "拖到组按钮"), in: sourceGroup.id)
        let toGroup = store.fileMoveSource(groupID: sourceGroup.id, slot: 4)!
        check(store.dropFilesIntoGroup([AttachmentTransfer.provider(toGroup)], groupID: targetGroup.id),
              "组按钮接收纯文本载荷")
        try await Task.sleep(for: .milliseconds(200))
        check(storage.get(1, in: targetGroup.id).plainText == "拖到组按钮"
            && storage.get(4, in: sourceGroup.id).hasEmptyBody, "拖到组按钮写入首个空槽位并移除来源")
        _ = storage.set(5, content: SlotContent(text: "拖动前"), in: sourceGroup.id)
        let stale = store.fileMoveSource(groupID: sourceGroup.id, slot: 5)!
        _ = storage.set(5, content: SlotContent(text: "拖动期间的新内容"), in: sourceGroup.id)
        check(!store.acceptTransfer(.move(stale), groupID: targetGroup.id, slot: 4, destination: .body)
            && storage.get(5, in: sourceGroup.id).plainText == "拖动期间的新内容",
              "文本来源变更时拒绝旧载荷，保留最新编辑")
        _ = storage.set(6, content: source, in: sourceGroup.id)
        let rollback = store.fileMoveSource(groupID: sourceGroup.id, slot: 6)!
        for failureStage in [1, 2] {
            do {
                _ = try storage.moveFile(rollback, from: storage, to: 2, groupID: targetGroup.id,
                    destination: .body, checkpoint: { stage in
                        if stage == failureStage { throw AgentCanvasError.writeFailed }
                    })
                check(false, "文本事务失败回滚 \(failureStage)")
            } catch {
                let cold = SpecialSlotStorage()
                check(AgentSlotBody(cold.get(6, in: sourceGroup.id)) == AgentSlotBody(source)
                    && cold.get(2, in: targetGroup.id).hasEmptyBody,
                      "文本交换第 \(failureStage) 个槽位失败时完整回滚")
            }
        }

        let fileSource = try storage.createSpecialSlot(name: "文件类型来源")
        let fileTarget = try storage.createSpecialSlot(name: "文件类型目标")
        let names = ["图片.png", "图片.jpg", "视频.mp4", "视频.mov", "音频.mp3", "音频.wav",
                     "文档.pdf", "文档.docx", "表格.xlsx", "演示.pptx", "压缩.zip", "压缩.7z",
                     "自定义.custom", "无扩展名"]
        for name in names {
            let file = root.appendingPathComponent(name)
            let bytes = name.hasSuffix(".png") ? png : Data([0, 255, 17, 99]) + Data(name.utf8)
            try bytes.write(to: file)
            _ = storage.set(1, content: SlotContent(items: [[
                .init(type: "public.file-url", data: Data(file.absoluteString.utf8))]]), in: fileSource.id)
            _ = storage.set(1, content: SlotContent(), in: fileTarget.id)
            _ = storage.set(2, content: SlotContent(text: "保留目标正文"), in: fileTarget.id)
            let drag = store.fileMoveSource(groupID: fileSource.id, slot: 1)!
            check(store.acceptTransfer(.move(drag), groupID: fileTarget.id, slot: 1, destination: .body),
                  "\(name) 支持普通文件跨槽位移动")
            let moved = SpecialSlotStorage().get(1, in: fileTarget.id)
            check(moved.primaryFileURL?.lastPathComponent == name
                && moved.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == bytes,
                  "\(name) 冷读保留文件名和原始字节")
            let promote = store.fileMoveSource(groupID: fileTarget.id, slot: 1)!
            check(store.acceptTransfer(.move(promote), groupID: fileTarget.id, slot: 2),
                  "\(name) 支持移到附件")
            let externalBytes = try Data(contentsOf: file)
            check(storage.get(2, in: fileTarget.id).attachments.last?.resolveData() == bytes
                && storage.get(2, in: fileTarget.id).plainText == "保留目标正文"
                && externalBytes == bytes, "\(name) 附件移动与外部原文件完整")
        }
        check(AttachmentTransfer.files([root]).isEmpty, "文件夹不作为普通文件附件导入")
        check(AttachmentTransfer.files([root.appendingPathComponent("不存在")]).isEmpty,
              "失效路径不作为普通文件附件导入")
        try JSONSerialization.data(withJSONObject: [
            "regular_file_names": names, "matrix_checks": names.count * 4,
            "text_body_move_preserves_representations": true,
            "text_attachments_preserve_utf8": true,
            "scope": "file transfer bytes and metadata, not media decoding or preview quality"
        ], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("text-and-file-transfer.json"), options: .atomic)
    }
}
#endif
