import Foundation
import ClipSlotsKit

func runSlotUndoMediaTests(_ t: TestRunner) {
    t.withFreshStore("UNDO-MEDIA") { storage in
        let fm = FileManager.default
        let group = try storage.createSpecialSlot(name: "历史素材")
        let archiveRoot = ClipSlotsPaths.undoDir.appendingPathComponent("media")
        let archive = SlotUndoMediaArchive(root: archiveRoot)
        let first = Data("原始图一".utf8), second = Data("原始图二".utf8)
        var content = SlotContent(text: "原始正文")
        content.attachments = [.init(name: "一.png", type: .image, data: first),
                               .init(name: "二.png", type: .image, data: second)]
        content.manualThumbnailId = UUID().uuidString
        content.pendingManualThumbnailData = Data("原始封面".utf8)
        t.check(storage.set(1, content: content, in: group.id), "UNDO fixture stored")
        storage.setLabel(1, label: "原标签", in: group.id)
        let cold = try storage.editorSnapshot(1, in: group.id).content
        let raw = SlotUndoSnapshot(slots: [1: cold], labels: [1: "原标签"],
            title: "删除附件", groupId: group.id, affectedSlots: [1])
        let sealed = try archive.seal(raw, storageRoot: storage.storageRoot)
        t.check(sealed.mediaArchiveID != nil && sealed.slots[1]!.attachments.allSatisfy { $0.data == nil },
                "UNDO history owns path-only independent copies")
        let encoded = try JSONEncoder().encode(sealed)
        t.check(encoded.count < 12000, "UNDO JSON has bounded metadata, no base64 media")
        try archive.prune(referencedIDs: [])
        t.check((try? archive.preparedForRestore(sealed)) != nil, "UNDO pending capture survives GC")
        let restart = try JSONDecoder().decode(SlotUndoSnapshot.self, from: encoded)
        t.check(storage.clear(1, in: group.id), "UNDO clears live bytes")
        try fm.removeItem(at: storage.storageRoot.appendingPathComponent(".trash"))
        let restored = try storage.restoreUndoSnapshot(restart, archive: SlotUndoMediaArchive(root: archiveRoot))
        t.equal(restored[1]?.attachments.map { $0.resolveData()! }, [first, second],
                "UNDO restores after restart without live files or trash")
        t.equal(storage.getLabel(1, in: group.id), "原标签", "UNDO label restored in same transaction")
        t.equal(restored[1]?.plainText, "原始正文", "UNDO body restored")
        t.equal(try Data(contentsOf: storage.manualThumbnailURL(1, in: group.id)!),
                Data("原始封面".utf8), "UNDO independent manual thumbnail restored")

        var empty = SlotContent(text: "新正文")
        empty.attachments = [.init(name: "新的资料", type: .text, data: Data("新资料".utf8))]
        t.check(storage.set(1, content: empty, in: group.id), "UNDO current state replaced")
        let protected = try storage.editorSnapshot(1, in: group.id).content
        let blob = URL(fileURLWithPath: sealed.slots[1]!.attachments[0].storagePath!)
        try Data("损坏".utf8).write(to: blob, options: .atomic)
        t.expectThrows("UNDO checksum failure rejects restore") {
            _ = try storage.restoreUndoSnapshot(sealed, archive: archive)
        }
        t.equal(storage.get(1, in: group.id).contentId, protected.contentId,
                "UNDO corruption preserves current identity")
        t.equal(storage.get(1, in: group.id).attachments.first?.resolveData(), Data("新资料".utf8),
                "UNDO corruption preserves current attachment bytes")
        try first.write(to: blob, options: .atomic)
        try fm.removeItem(at: blob)
        t.expectThrows("UNDO missing archive never falls back to unrelated bytes") {
            _ = try storage.restoreUndoSnapshot(sealed, archive: archive)
        }
        t.equal(storage.get(1, in: group.id).plainText, protected.plainText, "UNDO missing media preserves body")
        try first.write(to: blob, options: .atomic)

        var neighbor = SlotContent(text: "历史邻槽")
        neighbor.label = "邻槽标签"
        storage.set(2, content: neighbor, in: group.id, replacingLabel: true)
        var twoContent = cold
        twoContent.attachments[0].data = first
        twoContent.attachments[1].data = second
        twoContent.pendingManualThumbnailData = Data("原始封面".utf8)
        let two = try archive.seal(SlotUndoSnapshot(slots: [1: twoContent, 2: neighbor],
            labels: [1: "原标签", 2: "邻槽标签"], title: "整组撤销", groupId: group.id),
            storageRoot: storage.storageRoot)
        storage.set(2, content: SlotContent(text: "新邻槽"), in: group.id)
        let beforeFailure1 = storage.get(1, in: group.id)
        let beforeFailure2 = storage.get(2, in: group.id)
        t.expectThrows("UNDO failed second slot exchange rolls back whole transaction") {
            _ = try storage.restoreUndoSnapshot(two, archive: archive) { step in
                if step == 1 { throw AgentCanvasError.writeFailed }
            }
        }
        t.equal(storage.get(1, in: group.id).contentId, beforeFailure1.contentId, "UNDO rollback restores first slot identity")
        t.equal(storage.get(2, in: group.id).contentId, beforeFailure2.contentId, "UNDO rollback leaves second slot unchanged")
        t.equal(storage.get(1, in: group.id).attachments.first?.resolveData(), Data("新资料".utf8),
                "UNDO rollback preserves bytes after attempted exchange")
        let historyFile = ClipSlotsPaths.undoDir.appendingPathComponent("history.json")
        let oldHistory = Data("old history".utf8), newHistory = Data("new history".utf8)
        try oldHistory.write(to: historyFile, options: .atomic)
        t.expectThrows("UNDO history write and both slot exchanges roll back together") {
            _ = try storage.restoreUndoSnapshot(two, archive: archive, historyData: newHistory) { step in
                if step == 3 { throw AgentCanvasError.writeFailed }
            }
        }
        t.equal(try Data(contentsOf: historyFile), oldHistory, "UNDO rollback retains durable history")
        t.equal(storage.get(1, in: group.id).contentId, beforeFailure1.contentId,
                "UNDO metadata failure restores first slot")
        t.equal(storage.get(2, in: group.id).contentId, beforeFailure2.contentId,
                "UNDO metadata failure restores second slot")
        let final = try storage.restoreUndoSnapshot(two, archive: archive, historyData: newHistory)
        t.equal(try Data(contentsOf: historyFile), newHistory, "UNDO successful exchange commits durable history")
        t.equal(final[1]?.attachments.first?.resolveData(), first, "UNDO subsequent successful retry recovers bytes")
        t.equal(final[2]?.plainText, "历史邻槽", "UNDO subsequent retry recovers second slot")
        t.equal(storage.getLabel(2, in: group.id), "邻槽标签", "UNDO labels commit with affected slots")
        var wrong = sealed
        wrong.groupId = try storage.createSpecialSlot(name: "错误目标").id
        t.expectThrows("UNDO group binding refuses cross-group restore") {
            _ = try storage.restoreUndoSnapshot(wrong, archive: archive)
        }
        archive.releasePending(sealed.mediaArchiveID)
        archive.releasePending(two.mediaArchiveID)
        try archive.prune(referencedIDs: [two.mediaArchiveID!])
        t.check((try? archive.preparedForRestore(two)) != nil, "UNDO referenced shared media survives GC")
        t.expectThrows("UNDO discarded manifest is reclaimed") { _ = try archive.preparedForRestore(sealed) }
        try archive.prune(referencedIDs: [])
        t.equal(try fm.contentsOfDirectory(atPath: archiveRoot.appendingPathComponent("blobs").path).count, 0,
                "UNDO unreferenced media reclaimed")
    }

    t.withFreshStore("UNDO-BODY-AND-CAP") { storage in
        let group = try storage.createSpecialSlot(name: "文件正文")
        let file = storage.storageRoot.appendingPathComponent("原文.md")
        let bytes = Data("# 独立原文\n".utf8)
        try bytes.write(to: file)
        var body = SlotContent(items: [[.init(type: "public.file-url", data: Data(file.absoluteString.utf8)),
                                       .init(type: "public.url", data: Data(file.absoluteString.utf8))]])
        body.manageBodyFile(file)
        storage.set(1, content: body, in: group.id)
        let original = try storage.editorSnapshot(1, in: group.id).content
        let archiveRoot = ClipSlotsPaths.undoDir.appendingPathComponent("body-media")
        let archive = SlotUndoMediaArchive(root: archiveRoot)
        let sealed = try archive.seal(.init(slots: [1: original], labels: [:], title: "清空文件",
            groupId: group.id, affectedSlots: [1]), storageRoot: storage.storageRoot)
        storage.clear(1, in: group.id)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: storage.storageRoot.appendingPathComponent(".trash"))
        let result = try storage.restoreUndoSnapshot(sealed, archive: archive)
        t.equal(try Data(contentsOf: result[1]!.primaryFileURL!), bytes, "UNDO file body restored from independent archive")
        t.equal(result[1]!.items[0][0].data, result[1]!.items[0][1].data, "UNDO file URL representations agree")
        t.check(result[1]!.primaryFileURL!.path.hasPrefix(storage.storageRoot.path), "UNDO body URL rebased to live slot")
        let limited = SlotUndoMediaArchive(root: ClipSlotsPaths.undoDir.appendingPathComponent("limited"), byteLimit: 8)
        t.expectThrows("UNDO bounded archive refuses oversize capture") {
            _ = try limited.seal(.init(slots: [1: original], labels: [:], title: "过大",
                groupId: group.id), storageRoot: storage.storageRoot)
        }
        t.equal(try Data(contentsOf: storage.get(1, in: group.id).primaryFileURL!), bytes,
                "UNDO capacity failure preserves current file")
        let missing = SlotContent.SlotAttachment(name: "失联.png", type: .image)
        t.check(missing.isBrokenLocalFileRef, "UNDO pathless missing image shows warning")
        t.check(!SlotContent.SlotAttachment(name: "网络图片", type: .image, url: "https://example.com/a.png")
            .isBrokenLocalFileRef, "UNDO valid remote image is not falsely marked missing")
    }

    t.withFreshStore("UNDO-LEGACY") { storage in
        let group = try storage.createSpecialSlot(name: "旧历史")
        var content = SlotContent(text: "旧正文")
        content.attachments = [.init(name: "旧图.png", type: .image, data: Data("原图".utf8))]
        storage.set(1, content: content, in: group.id)
        let original = storage.get(1, in: group.id)
        let raw = SlotUndoSnapshot(slots: [1: original], labels: [:], title: "旧记录", groupId: group.id,
                                   affectedSlots: [1])
        storage.clear(1, in: group.id)
        let archive = SlotUndoMediaArchive(root: ClipSlotsPaths.undoDir.appendingPathComponent("legacy"))
        let restored = try storage.restoreUndoSnapshot(raw, archive: archive)
        t.equal(restored[1]?.attachments.first?.resolveData(), Data("原图".utf8),
                "UNDO legacy restores exact UUID from matching trash archive")
        var changed = original
        changed.attachments[0].data = Data("另一版本".utf8)
        storage.set(1, content: changed, in: group.id)
        storage.clear(1, in: group.id)
        t.expectThrows("UNDO ambiguous old UUID versions never choose newest silently") {
            _ = try storage.restoreUndoSnapshot(raw, archive: archive)
        }
        t.check(storage.get(1, in: group.id).isEmpty, "UNDO ambiguous legacy restore preserves current empty slot")
    }
}
