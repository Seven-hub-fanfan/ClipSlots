import Foundation
import ClipSlotsKit

// MARK: - 轻量断言 harness（零依赖，替代 XCTest）

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []

    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 }
        else { failed += 1; failures.append("✗ \(message)") }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        check(a == b, "\(message)（期望 \(b)，实际 \(a)）")
    }

    func expectThrows(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, "\(message)（预期抛错但没有）") }
        catch { check(true, message) }
    }

    /// 每个用例用独立临时数据目录隔离。
    func withFreshStore(_ name: String, _ body: (SpecialSlotStorage) throws -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslots_smoke_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("CLIPSLOTS_DATA_DIR", dir.path, 1)
        defer {
            unsetenv("CLIPSLOTS_DATA_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        do { try body(SpecialSlotStorage()) }
        catch { check(false, "\(name) 抛出异常：\(error)") }
    }

    func report() -> Never {
        print("\n==== ClipSlotsKit Smoke Tests ====")
        for f in failures { print(f) }
        print("通过 \(passed)，失败 \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

// MARK: - Helpers

private func makeTextContent(_ text: String) -> SlotContent {
    let item = PasteboardItem(type: "public.utf8-plain-text", data: Data(text.utf8))
    var c = SlotContent()
    c.items = [[item]]
    c.timestamp = Date()
    return c
}

private func extractText(_ content: SlotContent) -> String? {
    guard let item = content.items.first?.first else { return nil }
    return String(data: item.data, encoding: .utf8)
}

private func firstGroupId(_ storage: SpecialSlotStorage) -> String {
    storage.loadIndex().specialSlots.first!.id
}

// MARK: - 用例

let t = TestRunner()

// 纯逻辑：SlotContent 空槽判定
do {
    t.check(SlotContent().isEmpty, "新建 SlotContent 应为空")
    var body = SlotContent(); body.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data("x".utf8))]]
    t.check(!body.isEmpty, "有主体内容即为非空")
    var att = SlotContent(); att.attachments = [SlotContent.SlotAttachment(name: "a.png", type: .image)]
    t.check(att.items.isEmpty && !att.isEmpty, "仅有附件也应判为非空")
}

// 建库
t.withFreshStore("建库") { storage in
    let index = storage.loadIndex()
    t.check(!index.pages.isEmpty, "首启应至少创建一个默认页面")
    t.check(!index.specialSlots.isEmpty, "首启应至少创建一个默认槽位组")
}

// 读写往返 + 空槽判定
t.withFreshStore("读写往返") { storage in
    let g = firstGroupId(storage)
    t.check(storage.isEmpty(1, in: g), "新槽位应为空")
    t.check(storage.set(1, content: makeTextContent("你好 ClipSlots"), in: g), "写入应成功")
    t.equal(extractText(storage.get(1, in: g)), "你好 ClipSlots", "读回内容应一致")
    t.check(!storage.isEmpty(1, in: g), "写入后不应为空")
}

// 持久化（重开）
t.withFreshStore("持久化") { storage in
    let g = firstGroupId(storage)
    _ = storage.set(3, content: makeTextContent("持久化内容"), in: g)
    let reopened = SpecialSlotStorage()   // 同一 CLIPSLOTS_DATA_DIR
    t.equal(extractText(reopened.get(3, in: firstGroupId(reopened))), "持久化内容", "重开后内容应仍在")
}

// 清空 → 重新为空
t.withFreshStore("清空") { storage in
    let g = firstGroupId(storage)
    _ = storage.set(2, content: makeTextContent("临时"), in: g)
    t.check(!storage.isEmpty(2, in: g), "写入后非空")
    _ = storage.set(2, content: SlotContent(), in: g)
    t.check(storage.isEmpty(2, in: g), "写入空内容后应重新判为空槽")
}

// 标签
t.withFreshStore("标签") { storage in
    let g = firstGroupId(storage)
    _ = storage.set(1, content: makeTextContent("x"), in: g)
    _ = storage.setLabel(1, label: "主视觉", in: g)
    t.equal(storage.getLabel(1, in: g), "主视觉", "标签应可写读")
}

// create-page 带默认组命名
t.withFreshStore("建页命名默认组") { storage in
    let r = try storage.createPage(name: "Q3项目", defaultGroupName: "品牌VI")
    t.equal(r.page.name, "Q3项目", "页面名应正确")
    t.equal(r.defaultGroup?.name, "品牌VI", "默认组应直接命名")
}

// 组间隔离
t.withFreshStore("组间隔离") { storage in
    let page = try storage.createPage(name: "隔离页", defaultGroupName: "组A")
    let a = page.defaultGroup!.id
    let b = try storage.createSpecialSlot(name: "组B", pageId: page.page.id).id
    _ = storage.set(1, content: makeTextContent("A的内容"), in: a)
    t.equal(extractText(storage.get(1, in: a)), "A的内容", "A 组内容正确")
    t.check(storage.isEmpty(1, in: b), "不同组同槽号互不影响")
}

// 同页重名拒绝
t.withFreshStore("同页重名拒绝") { storage in
    let page = try storage.createPage(name: "去重页", defaultGroupName: "唯一名")
    t.expectThrows("同页内同名组应拒绝") {
        _ = try storage.createSpecialSlot(name: "唯一名", pageId: page.page.id)
    }
}

// 删除组
t.withFreshStore("删除组") { storage in
    let page = try storage.createPage(name: "删除页", defaultGroupName: "待删组")
    let extra = try storage.createSpecialSlot(name: "保留组", pageId: page.page.id)
    try storage.deleteSpecialSlot(id: extra.id)
    t.check(!storage.loadIndex().specialSlots.contains { $0.id == extra.id }, "删除后该组不应在索引中")
}

// 读游标 set/get/reset
t.withFreshStore("读游标") { storage in
    let g = firstGroupId(storage)
    t.check(storage.autoPasteCursor() == nil, "初始读游标应为空")
    try storage.setAutoPasteCursor(SpecialSlotCursor(groupId: g, slot: 4))
    t.equal(storage.autoPasteCursor()?.slot, 4, "读游标槽号应正确")
    try storage.resetAutoPasteCursor()
    t.check(storage.autoPasteCursor() == nil, "重置后读游标应清空")
}

// 写游标持久化
t.withFreshStore("写游标持久化") { storage in
    let g = firstGroupId(storage)
    try storage.setAutoStoreCursor(SpecialSlotCursor(groupId: g, slot: 7))
    let reopened = SpecialSlotStorage()
    t.equal(reopened.autoStoreCursor()?.slot, 7, "写游标应持久化到磁盘")
}

t.report()
