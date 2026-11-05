import Foundation
import ClipSlotsKit

func runAttachmentBundleTests(_ t: TestRunner) {
    t.withFreshStore("ATTACHMENT-BUNDLE") { storage in
        let a = try storage.createSpecialSlot(name: "来源")
        let b = try storage.createSpecialSlot(name: "目标")
        let file = storage.storageRoot.appendingPathComponent("资料.md")
        try Data("# 附件🙂".utf8).write(to: file)
        var origin = SlotContent(text: "来源正文")
        origin.attachments = [.init(name: "资料.md", type: .file, path: file.path),
            .init(name: "纯文本", type: .text, data: Data("text".utf8)),
            .init(name: "链接", type: .url, url: "https://example.com")]
        t.check(storage.set(1, content: origin, in: a.id), "建立整组附件来源")
        var target = SlotContent(text: "目标正文")
        target.attachments = [.init(name: "现有附件", type: .text, data: Data("keep".utf8))]
        t.check(storage.set(2, content: target, in: b.id), "建立带正文的附件目标")
        let snapshot = try storage.editorSnapshot(1, in: a.id)
        let move = SlotFileMove(snapshot: snapshot, moveAllAttachments: true)
        let encoded = try JSONEncoder().encode(move)
        let decoded = try JSONDecoder().decode(SlotFileMove.self, from: encoded)
        t.equal(decoded.attachmentBundle?.map(\.id), snapshot.content.attachments.map(\.id),
                "整组拖动序列化保留每个附件身份")
        t.check(decoded.body == nil && decoded.attachment == nil, "整组载荷只携带附件")
        t.expectThrows("整组附件拒绝空正文落点") {
            _ = try storage.moveFile(decoded, from: storage, to: 3, groupID: b.id, destination: .body)
        }
        t.equal(storage.get(1, in: a.id).attachments.count, 3, "拒绝正文落点后原附件不变")
        t.check(storage.get(3, in: b.id).hasEmptyBody, "拒绝正文落点后目标保持空")
        var during = snapshot.content
        during.attachments.append(.init(name: "拖动中新增加", type: .text, data: Data("new".utf8)))
        storage.set(1, content: during, in: a.id)
        let moved = try storage.moveFile(decoded, from: storage, to: 2, groupID: b.id, destination: .attachments)
        t.equal(moved.attachments.map(\.name), ["现有附件", "资料.md", "纯文本", "链接"], "整组按拖动时的顺序追加")
        t.equal(Array(moved.attachments.dropFirst()).map(\.id), snapshot.content.attachments.map(\.id),
                "移动保留附件身份")
        t.equal(moved.plainText, "目标正文", "整组移动保留目标正文")
        t.equal(storage.get(1, in: a.id).plainText, "来源正文", "整组移动保留来源正文")
        t.equal(storage.get(1, in: a.id).attachments.map(\.name), ["拖动中新增加"], "拖动中新增加附件留在来源")
        try FileManager.default.removeItem(at: file)
        t.equal(SpecialSlotStorage().get(2, in: b.id).attachments[1].resolveData(), Data("# 附件🙂".utf8),
                "移动后附件自有字节不依赖外部文件")
        t.expectThrows("重复投递整组载荷拒绝") {
            _ = try storage.moveFile(decoded, from: storage, to: 2, groupID: b.id, destination: .attachments)
        }
        let next = SlotFileMove(snapshot: try storage.editorSnapshot(2, in: b.id), moveAllAttachments: true)
        let beforeA = storage.get(1, in: a.id)
        let beforeB = storage.get(2, in: b.id)
        t.expectThrows("双槽交换中断触发回滚") {
            _ = try storage.moveFile(next, from: storage, to: 1, groupID: a.id, destination: .attachments,
                checkpoint: { _ in throw AgentCanvasError.writeFailed })
        }
        t.equal(storage.get(1, in: a.id).attachments, beforeA.attachments, "中断回滚恢复目标附件")
        t.equal(storage.get(2, in: b.id).attachments, beforeB.attachments, "中断回滚恢复来源附件")
        for failureStage in [1, 2] {
            t.expectThrows("无目录空目标中断触发回滚 \(failureStage)") {
                _ = try storage.moveFile(next, from: storage, to: 7, groupID: a.id, destination: .attachments,
                    checkpoint: { if $0 == failureStage { throw AgentCanvasError.writeFailed } })
            }
            let cold = SpecialSlotStorage()
            t.check(cold.get(7, in: a.id).isEmpty && cold.get(7, in: a.id).attachments.isEmpty,
                    "中断恢复无目录空目标 \(failureStage)")
            t.equal(cold.get(2, in: b.id).attachments, beforeB.attachments,
                    "空目标回滚保留来源附件 \(failureStage)")
        }
        let same = try storage.moveFile(next, from: storage, to: 2, groupID: b.id, destination: .attachments)
        t.equal(same.attachments, beforeB.attachments, "拖回自身不重复或删除附件")
        var changed = beforeB
        changed.attachments.removeLast()
        storage.set(2, content: changed, in: b.id)
        t.expectThrows("捕获的附件被删除后整组移动全部拒绝") {
            _ = try storage.moveFile(next, from: storage, to: 1, groupID: a.id, destination: .attachments)
        }
        t.equal(storage.get(1, in: a.id).attachments, beforeA.attachments, "冲突不部分追加")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SlotFileMove(snapshot: try storage.editorSnapshot(1, in: a.id)))) as! [String: Any]
        legacy.removeValue(forKey: "attachmentBundle")
        let old = try JSONDecoder().decode(SlotFileMove.self, from: JSONSerialization.data(withJSONObject: legacy))
        t.check(old.attachmentBundle == nil && old.body != nil, "旧正文拖拽载荷向后兼容")
    }
}
