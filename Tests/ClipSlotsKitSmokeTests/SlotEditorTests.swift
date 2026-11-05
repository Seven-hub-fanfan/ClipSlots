import Foundation
import ClipSlotsKit

func runSlotEditorTests(_ t: TestRunner) {
    runSlotFileEditorTests(t)
    runAttachmentBundleTests(t)
    t.withFreshStore("EDITOR-TRANSACTION") { storage in
        let group = try storage.createSpecialSlot(name: "编辑事务测试")
        var original = SlotContent(text: "编辑前")
        original.attachments = [.init(name: "旧附件.txt", type: .text, data: Data("参考资料".utf8))]
        original.label = "标签"
        original.manualThumbnailId = "cover"
        original.pendingManualThumbnailData = Data("test-cover-bytes".utf8)
        t.check(storage.set(1, content: original, in: group.id), "编辑 fixture 写入")
        let snapshot = try storage.editorSnapshot(1, in: group.id)
        let added = SlotContent.SlotAttachment(name: "新附件.txt", type: .text, data: Data("新资料".utf8))
        // Opening and abandoning a draft has no persistence call.
        var cancelledDraft = snapshot.content
        cancelledDraft.items = AgentSlotBody(text: "取消的草稿").items
        cancelledDraft.attachments.removeAll()
        t.equal(storage.getOrUnknown(1, in: group.id)?.plainText, "编辑前", "取消草稿不写正文")
        t.equal(storage.getOrUnknown(1, in: group.id)?.attachments.count, 1, "取消附件删除不写磁盘")
        let result = try storage.exchangeEditorContent(snapshot, body: AgentSlotBody(text: "编辑后"), attachments: [added])
        t.equal(result.plainText, "编辑后", "正文提交")
        t.equal(result.attachments.map(\.name), ["新附件.txt"], "附件与正文同次提交")
        t.equal(result.label, "标签", "保留标签")
        t.equal(result.manualThumbnailId, "cover", "保留手动封面")
        t.check(result.contentId != original.contentId, "提交刷新缓存身份")
        t.equal(result.attachments[0].resolveTextString(), "新资料", "附件字节持久化")
        t.expectThrows("重复使用旧编辑快照拒绝") {
            _ = try storage.exchangeEditorContent(snapshot, body: AgentSlotBody(text: "过期"), attachments: [])
        }
        t.equal(storage.getOrUnknown(1, in: group.id)?.plainText, "编辑后", "冲突保留已保存正文")
        let current = try storage.editorSnapshot(1, in: group.id)
        var external = current.content
        external.attachments.append(.init(name: "外部.txt", type: .text, data: Data("外部写入".utf8)))
        storage.set(1, content: external, in: group.id)
        t.expectThrows("外部只改附件也阻止旧草稿保存") {
            _ = try storage.exchangeEditorContent(current, body: AgentSlotBody(text: "错误覆盖"), attachments: [])
        }
        t.equal(storage.getOrUnknown(1, in: group.id)?.attachments.count, 2, "冲突不丢外部新增附件")
        let metadata = try storage.editorSnapshot(1, in: group.id)
        storage.setLabel(1, label: "外部新标签", in: group.id)
        let metaSaved = try storage.exchangeEditorContent(metadata, body: AgentSlotBody(text: "新正文"), attachments: metadata.content.attachments)
        t.equal(metaSaved.plainText, "新正文", "标签变化不阻止正文提交")
        t.equal(storage.getLabel(1, in: group.id), "外部新标签", "编辑期间的新标签保留")
        let deletion = try storage.editorSnapshot(1, in: group.id)
        try storage.deleteSpecialSlot(id: group.id)
        t.expectThrows("删除目标组后保存拒绝，不复活目标") {
            _ = try storage.exchangeEditorContent(deletion, body: AgentSlotBody(text: "幽灵组"), attachments: [])
        }
        t.check(!storage.loadIndex().specialSlots.contains(where: { $0.id == group.id }), "未重建被删目标组")
    }
    do {
        let scoped = SlotUndoSnapshot(slots: [1: SlotContent(text: "旧正文")], labels: [:],
            title: "编辑", groupId: "组", affectedSlots: [1])
        let decoded = try JSONDecoder().decode(SlotUndoSnapshot.self, from: JSONEncoder().encode(scoped))
        t.equal(decoded.affectedSlots, [1], "单槽编辑撤销范围持久化")
        let legacy = SlotUndoSnapshot(slots: [:], labels: [:], title: "旧版", groupId: "组")
        let legacyData = try JSONEncoder().encode(legacy)
        t.equal(try JSONDecoder().decode(SlotUndoSnapshot.self, from: legacyData).affectedSlots, nil,
                "旧版撤销仍为整组行为")
    } catch { t.check(false, "编辑撤销解码异常 \(error)") }
}
