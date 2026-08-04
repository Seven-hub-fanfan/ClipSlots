import XCTest
@testable import ClipSlotsKit

/// 覆盖 ClipSlotsKit 存储层的关键「保命」路径：建库、槽位读写往返、空槽判定、
/// 标签、页面/组增删、自动游标持久化。每个用例使用独立的临时数据目录
/// （通过 CLIPSLOTS_DATA_DIR 隔离），互不干扰，可并行/重复运行。
final class SpecialSlotStorageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslots_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("CLIPSLOTS_DATA_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CLIPSLOTS_DATA_DIR")
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    private func makeTextContent(_ text: String) -> SlotContent {
        let item = PasteboardItem(type: "public.utf8-plain-text", data: Data(text.utf8))
        var content = SlotContent()
        content.items = [[item]]
        content.timestamp = Date()
        return content
    }

    private func extractText(_ content: SlotContent) -> String? {
        guard let item = content.items.first?.first else { return nil }
        return String(data: item.data, encoding: .utf8)
    }

    /// 取默认页里第一个组的 id，作为写入目标（避免依赖硬编码的 "default"）。
    private func firstGroupId(_ storage: SpecialSlotStorage) -> String {
        let index = storage.loadIndex()
        return index.specialSlots.first!.id
    }

    // MARK: - 建库

    func testFreshInitCreatesDefaultPageAndGroup() throws {
        let storage = SpecialSlotStorage()
        let index = storage.loadIndex()
        XCTAssertFalse(index.pages.isEmpty, "首启应至少创建一个默认页面")
        XCTAssertFalse(index.specialSlots.isEmpty, "首启应至少创建一个默认槽位组")
    }

    // MARK: - 槽位读写往返

    func testWriteThenReadTextRoundTrip() throws {
        let storage = SpecialSlotStorage()
        let group = firstGroupId(storage)
        XCTAssertTrue(storage.isEmpty(1, in: group), "新槽位应为空")

        let ok = storage.set(1, content: makeTextContent("你好 ClipSlots"), in: group)
        XCTAssertTrue(ok, "写入应成功")

        let read = storage.get(1, in: group)
        XCTAssertEqual(extractText(read), "你好 ClipSlots")
        XCTAssertFalse(storage.isEmpty(1, in: group), "写入后不应为空")
    }

    func testWritePersistsAcrossReopen() throws {
        do {
            let storage = SpecialSlotStorage()
            let group = firstGroupId(storage)
            _ = storage.set(3, content: makeTextContent("持久化内容"), in: group)
        }
        // 重新打开同一数据目录，内容应仍在（模拟 CLI/GUI 重启）。
        let reopened = SpecialSlotStorage()
        let group = firstGroupId(reopened)
        XCTAssertEqual(extractText(reopened.get(3, in: group)), "持久化内容")
    }

    func testEmptyContentMakesSlotEmptyAgain() throws {
        let storage = SpecialSlotStorage()
        let group = firstGroupId(storage)
        _ = storage.set(2, content: makeTextContent("临时"), in: group)
        XCTAssertFalse(storage.isEmpty(2, in: group))

        _ = storage.set(2, content: SlotContent(), in: group)
        XCTAssertTrue(storage.isEmpty(2, in: group), "写入空内容后应重新判为空槽")
    }

    // MARK: - 标签

    func testLabelSetAndGet() throws {
        let storage = SpecialSlotStorage()
        let group = firstGroupId(storage)
        _ = storage.set(1, content: makeTextContent("x"), in: group)
        _ = storage.setLabel(1, label: "主视觉", in: group)
        XCTAssertEqual(storage.getLabel(1, in: group), "主视觉")
    }

    // MARK: - 页面 / 组增删

    func testCreatePageWithNamedDefaultGroup() throws {
        let storage = SpecialSlotStorage()
        let result = try storage.createPage(name: "Q3项目", defaultGroupName: "品牌VI")
        XCTAssertEqual(result.page.name, "Q3项目")
        XCTAssertEqual(result.defaultGroup?.name, "品牌VI",
                       "create-page 带 defaultGroupName 时默认组应直接命名")
    }

    func testCreateGroupAndWriteIsIsolatedPerGroup() throws {
        let storage = SpecialSlotStorage()
        let page = try storage.createPage(name: "隔离页", defaultGroupName: "组A")
        let groupA = page.defaultGroup!.id
        let groupB = try storage.createSpecialSlot(name: "组B", pageId: page.page.id).id

        _ = storage.set(1, content: makeTextContent("A的内容"), in: groupA)
        XCTAssertEqual(extractText(storage.get(1, in: groupA)), "A的内容")
        XCTAssertTrue(storage.isEmpty(1, in: groupB), "不同组同槽号互不影响")
    }

    func testDuplicateGroupNameInSamePageThrows() throws {
        let storage = SpecialSlotStorage()
        let page = try storage.createPage(name: "去重页", defaultGroupName: "唯一名")
        XCTAssertThrowsError(
            try storage.createSpecialSlot(name: "唯一名", pageId: page.page.id),
            "同页内同名组应拒绝"
        )
    }

    func testDeleteSpecialSlotRemovesItFromIndex() throws {
        let storage = SpecialSlotStorage()
        let page = try storage.createPage(name: "删除页", defaultGroupName: "待删组")
        let extra = try storage.createSpecialSlot(name: "保留组", pageId: page.page.id)
        try storage.deleteSpecialSlot(id: extra.id)
        let index = storage.loadIndex()
        XCTAssertFalse(index.specialSlots.contains { $0.id == extra.id },
                       "删除后该组不应再出现在索引中")
    }

    // MARK: - 自动游标持久化

    func testAutoPasteCursorSetGetReset() throws {
        let storage = SpecialSlotStorage()
        let group = firstGroupId(storage)
        XCTAssertNil(storage.autoPasteCursor(), "初始读游标应为空")

        try storage.setAutoPasteCursor(SpecialSlotCursor(groupId: group, slot: 4))
        XCTAssertEqual(storage.autoPasteCursor()?.slot, 4)
        XCTAssertEqual(storage.autoPasteCursor()?.groupId, group)

        try storage.resetAutoPasteCursor()
        XCTAssertNil(storage.autoPasteCursor(), "重置后读游标应清空")
    }

    func testAutoStoreCursorPersistsAcrossReopen() throws {
        let group: String
        do {
            let storage = SpecialSlotStorage()
            group = firstGroupId(storage)
            try storage.setAutoStoreCursor(SpecialSlotCursor(groupId: group, slot: 7))
        }
        let reopened = SpecialSlotStorage()
        XCTAssertEqual(reopened.autoStoreCursor()?.slot, 7, "写游标应持久化到磁盘")
        XCTAssertEqual(reopened.autoStoreCursor()?.groupId, group)
    }
}
