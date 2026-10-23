import XCTest
@testable import ClipSlotsKit

/// SlotContent 的纯逻辑测试（不触碰磁盘）：空槽判定的口径必须与
/// list/read 返回的 `empty` 字段一致——主体与附件都为空才算空。
final class SlotContentTests: XCTestCase {

    private func textItem(_ s: String) -> PasteboardItem {
        PasteboardItem(type: "public.utf8-plain-text", data: Data(s.utf8))
    }

    func testFreshContentIsEmpty() {
        XCTAssertTrue(SlotContent().isEmpty, "新建 SlotContent 应为空")
    }

    func testContentWithBodyIsNotEmpty() {
        var c = SlotContent()
        c.items = [[textItem("hello")]]
        XCTAssertFalse(c.isEmpty, "有主体内容即为非空")
    }

    func testContentWithOnlyAttachmentIsNotEmpty() {
        var c = SlotContent()
        c.attachments = [SlotContent.SlotAttachment(name: "a.png", type: .image)]
        XCTAssertTrue(c.items.isEmpty, "主体为空")
        XCTAssertFalse(c.isEmpty, "仅有附件也应判为非空")
    }
}
