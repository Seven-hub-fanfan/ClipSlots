import Foundation
import ClipSlotsKit

/// 空槽保存计划 P2（v2.17.107）：零字节「空白文本」必须被所有层识别为已占用，并能完整落盘读回。
func runBlankTextSlotTests(_ t: TestRunner) {
    let blank = SlotContent.blankText()
    t.check(!blank.isEmpty, "BLANK 空白文本 isEmpty == false（已占用）")
    t.check(blank.isBlankText, "BLANK isBlankText 识别")
    t.check(!SlotContent().isBlankText, "BLANK 未初始化空槽不是空白文本")
    t.check(!SlotContent(text: " ").isBlankText, "BLANK 含空格不是空白文本")
    var withAttachment = SlotContent.blankText()
    withAttachment.attachments = [.init(name: "a.txt", type: .text, data: Data("x".utf8))]
    t.check(!withAttachment.isBlankText, "BLANK 带附件不归为空白文本")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipslots-blank-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let storage = SlotStorage(slotsDir: dir)
    t.check(storage.isSlotEmpty(3), "BLANK 写入前槽位为空")
    t.check(storage.set(3, content: blank), "BLANK 写入成功")
    t.check(!storage.isSlotEmpty(3), "BLANK isSlotEmpty（缓存）== false")
    let cold = SlotStorage(slotsDir: dir)
    t.check(!cold.isSlotEmpty(3), "BLANK 冷探测 isSlotEmpty == false")
    let readBack = cold.get(3)
    t.check(readBack.isBlankText && !readBack.isEmpty, "BLANK 冷读回仍是空白文本且已占用")
    t.equal(readBack.items.first?.first?.type ?? "nil", "public.utf8-plain-text", "BLANK 读回保留纯文本类型")
    t.check(cold.set(3, content: SlotContent()), "BLANK 清空写入成功")
    t.check(SlotStorage(slotsDir: dir).isSlotEmpty(3), "BLANK 清空后恢复未占用")
}
