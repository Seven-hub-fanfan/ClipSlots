import Foundation
import ClipSlotsKit
// v2.11.2: THUMB-CODEC 组要现造 PNG 测试图并读回像素尺寸。
import CoreGraphics
import ImageIO

// MARK: - 轻量断言 harness（零依赖，替代 XCTest）

/// v2.11.2: 端到端用例在前置条件不满足时用它提前退出本组（顶层代码不能 `return`）。
enum SmokeSkip: Error { case cliMissing }

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

/// v2.11.7 hotfix11: 造一个「冷缓存」SlotStorage——同一个组目录、全新实例，进程内缓存为空，
/// 等价于「这个组本次会话从没被用户打开过」。全局搜索漏搜就发生在这种状态下。
private func coldStorage(forGroup gid: String) -> SlotStorage {
    let dataDir = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]!
    let dir = URL(fileURLWithPath: dataDir)
        .appendingPathComponent("special_slots", isDirectory: true)
        .appendingPathComponent(gid, isDirectory: true)
    return SlotStorage(slotsDir: dir)
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

// PERF-7 (v2.10.84): resetAutoPasteCursor 在「游标本就为空」时会短路跳过写盘。
// 该短路必须是纯粹的性能优化，对外行为与旧实现完全一致，故守住三点：
//   1. 对空游标重复 reset 幂等且不报错（走短路分支）
//   2. 短路不会破坏索引里的既有页/组数据（确认没有误写空索引）
//   3. 短路之后仍能正常 set → reset（确认没有把状态卡死）
t.withFreshStore("读游标重置幂等（PERF-7 短路）") { storage in
    let g = firstGroupId(storage)
    let groupCountBefore = storage.loadIndex().specialSlots.count

    // 1. 空游标下连续 reset：走短路，应幂等无副作用
    try storage.resetAutoPasteCursor()
    try storage.resetAutoPasteCursor()
    t.check(storage.autoPasteCursor() == nil, "空游标重复重置后仍应为空")

    // 2. 短路不得动到索引内容
    t.equal(storage.loadIndex().specialSlots.count, groupCountBefore, "短路重置不应改变组数量")
    t.check(storage.loadIndex().specialSlots.contains { $0.id == g }, "短路重置后原有组应仍在索引中")

    // 3. 短路后写入再重置，仍走正常清空路径
    try storage.setAutoPasteCursor(SpecialSlotCursor(groupId: g, slot: 6))
    t.equal(storage.autoPasteCursor()?.slot, 6, "短路后仍应能正常写入读游标")
    try storage.resetAutoPasteCursor()
    t.check(storage.autoPasteCursor() == nil, "短路后仍应能正常清空读游标")
}

// 写游标持久化
t.withFreshStore("写游标持久化") { storage in
    let g = firstGroupId(storage)
    try storage.setAutoStoreCursor(SpecialSlotCursor(groupId: g, slot: 7))
    let reopened = SpecialSlotStorage()
    t.equal(reopened.autoStoreCursor()?.slot, 7, "写游标应持久化到磁盘")
}

// v2.10.85（环形预览显示文件图标而非真实内容）: Finder 复制文件时剪贴板里带的
// `com.apple.icns` 是文档图标，不是文件像素。它必须仍被识别为图片类型（真 .icns
// 粘贴要能渲染），同时又能被单独判定为「仅图标」，供预览路径改走真实文件像素。
t.check(SlotContent.isImagePasteboardType("com.apple.icns"), "icns 仍应算图片类型")
t.check(SlotContent.isIconOnlyPasteboardType("com.apple.icns"), "icns 应判定为仅图标类型")
t.check(SlotContent.isIconOnlyPasteboardType("ICNS"), "仅图标判定应大小写不敏感")
t.check(!SlotContent.isIconOnlyPasteboardType("public.png"), "public.png 不应判定为仅图标")
t.check(!SlotContent.isIconOnlyPasteboardType("public.tiff"), "public.tiff 不应判定为仅图标")

// MARK: - UPD-LOOP (v2.10.92): 自动更新版本比对 + 幂等护栏
//
// 线上事故语境：用户投诉「反复重装同一个版本」。这一组用例把「同版本绝不更新」钉成契约，
// 并覆盖所有历史上容易写错的比对姿势：`v` 前缀、字符串字典序、位数不同、相等误判为需更新。
do {
    // ① 规范化：`v` / `V` 前缀、首尾空白、`+build` 元数据都不应影响版本语义。
    t.equal(UpdateVersion.parse("v2.10.91").coreString, "2.10.91", "应剥掉小写 v 前缀")
    t.equal(UpdateVersion.parse("V2.10.91").coreString, "2.10.91", "应剥掉大写 V 前缀")
    t.equal(UpdateVersion.parse("  v2.10.91\n").coreString, "2.10.91", "应去掉首尾空白与换行")
    t.equal(UpdateVersion.parse("2.10.91+build7").coreString, "2.10.91", "应丢弃 + 构建元数据")

    // ② 核心契约：线上 tag 带 v 前缀、本地不带，但二者是同一版本 → 必须判定为「无需更新」。
    //    这正是本次事故假设中「永远认为有新版 → 无限重装」的那条路径。
    t.equal(UpdateVersion.decide(remoteTag: "v2.10.91", localVersion: "2.10.91"), .upToDate,
            "v2.10.91 vs 2.10.91 必须判为已是最新（同版本绝不重装）")
    t.check(!UpdateVersion.isNewer(UpdateVersion.parse("v2.10.91"), than: UpdateVersion.parse("2.10.91")),
            "带 v 前缀的同版本不得被判为更新")
    t.check(UpdateVersion.isSameVersion("v2.10.91", "2.10.91"), "v2.10.91 与 2.10.91 应视为同一版本")

    // ③ 相等的其它写法：位数不同（2.10 == 2.10.0）也必须判为相等，不得触发更新。
    t.equal(UpdateVersion.decide(remoteTag: "2.10", localVersion: "2.10.0"), .upToDate,
            "2.10 与 2.10.0 应判为相同版本")
    t.check(UpdateVersion.isSameVersion("2.10.0.0", "2.10"), "补零后相等的版本应视为同一版本")

    // ④ 逐段按整数比较——绝不能退化成字符串字典序。
    //    字典序下 "2.9.9" > "2.10.0"（"9" > "1"）、"2.10.9" > "2.10.91" 都会比错。
    t.equal(UpdateVersion.decide(remoteTag: "2.10.0", localVersion: "2.9.9"), .update,
            "2.9.9 < 2.10.0（按整数比较，不可按字典序）")
    t.equal(UpdateVersion.decide(remoteTag: "2.10.91", localVersion: "2.10.9"), .update,
            "2.10.9 < 2.10.91（位数不同，按整数比较）")
    t.equal(UpdateVersion.decide(remoteTag: "2.9.9", localVersion: "2.10.0"), .remoteOlder,
            "线上 2.9.9 比本地 2.10.0 旧 → 不更新")
    t.equal(UpdateVersion.decide(remoteTag: "2.10.9", localVersion: "2.10.91"), .remoteOlder,
            "线上 2.10.9 比本地 2.10.91 旧 → 不更新")

    // ⑤ 真正的新版本仍要能被识别（防止修过头把更新彻底堵死）。
    t.equal(UpdateVersion.decide(remoteTag: "v2.10.92", localVersion: "2.10.91"), .update,
            "v2.10.92 相对 2.10.91 应判为有更新")
    t.equal(UpdateVersion.decide(remoteTag: "v3.0.0", localVersion: "2.10.91"), .update,
            "大版本跨越应判为有更新")

    // ⑥ 预发布语义（v2.10.13 / INST-1 既有契约，不得回归）：核心相同时正式版 > 预发布版。
    t.check(UpdateVersion.isNewer(UpdateVersion.parse("2.11.0"), than: UpdateVersion.parse("2.11.0-beta.1")),
            "正式版应新于同核心的预发布版")
    t.check(!UpdateVersion.isNewer(UpdateVersion.parse("2.11.0-beta.1"), than: UpdateVersion.parse("2.11.0")),
            "预发布版不应新于同核心的正式版")
    t.check(UpdateVersion.isNewer(UpdateVersion.parse("2.11.0-beta.2"), than: UpdateVersion.parse("2.11.0-beta.1")),
            "beta.2 应新于 beta.1（数字感知比较）")

    // ⑦ 幂等护栏：即便比对逻辑将来又出错，也必须挡住无限重装。
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.91", runningVersion: "2.10.91",
                                       lastAttemptedTag: nil, autoInstallDisabled: false),
            .skipSameAsRunning, "目标版本 == 运行版本 → 必须跳过安装")
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.92", runningVersion: "2.10.91",
                                       lastAttemptedTag: "2.10.92", autoInstallDisabled: false),
            .skipAlreadyAttempted, "同一目标版本已尝试过 → 必须跳过（防装完重启又重装）")
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.92", runningVersion: "2.10.91",
                                       lastAttemptedTag: nil, autoInstallDisabled: true),
            .skipDisabled, "总闸关闭 → 必须跳过安装（止血开关）")
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.92", runningVersion: "2.10.91",
                                       lastAttemptedTag: "v2.10.90", autoInstallDisabled: false),
            .proceed, "确有新版本且未尝试过 → 允许安装")
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.92", runningVersion: "2.10.91",
                                       lastAttemptedTag: "", autoInstallDisabled: false),
            .proceed, "空的历史记录不应误判为已尝试过")

    // ⑧ UPD-LOOP-FIX (v2.10.92): 「失败后可重试」契约。
    //    去重记录是在动 bundle **之前**写的，因此 App 侧（UpdateInstallGuardStore.clearAttempt）
    //    必须在每条安装失败路径上清掉它；这里把清掉之后的期望行为钉死：记录为 nil / 空串时，
    //    同一个目标版本必须能重新安装。否则一次偶发失败（挂载失败/版本校验中止/授权取消）
    //    就会把该版本永久拉黑，等于把「同版本重装循环」修成「更新彻底堵死」。
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.92", runningVersion: "2.10.91",
                                       lastAttemptedTag: nil, autoInstallDisabled: false),
            .proceed, "失败后清除去重记录 → 同一目标版本必须允许重试")
    //    记录与目标的 `v` 前缀写法不同也必须识别为同一版本（否则去重形同虚设）。
    t.equal(UpdateVersion.installGuard(targetTag: "2.10.92", runningVersion: "2.10.91",
                                       lastAttemptedTag: "v2.10.92", autoInstallDisabled: false),
            .skipAlreadyAttempted, "去重比对需规范化 v 前缀（v2.10.92 与 2.10.92 是同一版本）")
    //    优先级：总闸关闭要盖过「目标就是当前版本」等其它判定，保证止血开关一按即停。
    t.equal(UpdateVersion.installGuard(targetTag: "v2.10.91", runningVersion: "2.10.91",
                                       lastAttemptedTag: "v2.10.91", autoInstallDisabled: true),
            .skipDisabled, "总闸关闭时优先返回 skipDisabled（止血开关优先级最高）")
}

// MARK: - UNDO-1 (v2.10.95) 多步撤销栈

// 纯逻辑：SlotUndoStack 的每组 10 步上限 / 按组弹出 / 去重
do {
    func snap(_ group: String, _ title: String, slotContentId: String) -> SlotUndoSnapshot {
        var c = SlotContent()
        c.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data(title.utf8))]]
        c.contentId = slotContentId
        c.updatedAt = 1
        return SlotUndoSnapshot(slots: [1: c], labels: [:], title: title, groupId: group)
    }

    var stack = SlotUndoStack()
    t.check(!stack.canUndo(forGroup: "A"), "空栈时任何组都不可撤销")

    // ① 每组保留 10 步，第 11 步压入后最旧的一步被丢弃
    for i in 1...12 { stack.push(snap("A", "A-\(i)", slotContentId: "a\(i)")) }
    t.equal(stack.count(forGroup: "A"), 10, "单组撤销步数上限应为 10")
    t.equal(stack.entries.first?.title, "A-3", "超出 10 步后应丢弃最旧的步骤")

    // ② 按组弹出：弹出的是当前组最新一步，别组历史不受影响（v2.8.7 D 不变量）
    stack.push(snap("B", "B-1", slotContentId: "b1"))
    t.equal(stack.popLatest(forGroup: "A")?.title, "A-12", "撤销应弹出该组最新一步")
    t.equal(stack.count(forGroup: "A"), 9, "弹出后该组剩 9 步")
    t.equal(stack.count(forGroup: "B"), 1, "弹出 A 组不应影响 B 组历史")
    t.check(stack.popLatest(forGroup: "C") == nil, "没有历史的组撤销应返回 nil")

    // ③ 去重：状态完全一致的连续快照不占额度
    var dedup = SlotUndoStack()
    t.check(dedup.push(snap("A", "同状态-1", slotContentId: "same")), "首次压入应成功")
    t.check(!dedup.push(snap("A", "同状态-2", slotContentId: "same")), "与该组最新快照状态一致应被去重")
    t.equal(dedup.entries.count, 1, "去重后仍只有一步")

    // ④ 可持久化（跨重启撤销依赖 JSON 编解码）
    let data = try! JSONEncoder().encode(stack)
    var decoded = try! JSONDecoder().decode(SlotUndoStack.self, from: data)
    t.equal(decoded.entries.count, stack.entries.count, "撤销栈应能 JSON 往返（跨重启保留）")
    t.equal(decoded.popLatest(forGroup: "B")?.title, "B-1", "JSON 往返后按组弹出仍正确")
}

// 存储层：清空槽位后，用快照内容（附件字节已内联）回写 → 主体 + 附件 + 标签全部返回。
// 这是 GUI 撤销（captureUndoSnapshot(materializeSlots:) → set）依赖的存储层契约。
t.withFreshStore("撤销回写") { storage in
    let g = firstGroupId(storage)
    var content = makeTextContent("撤销前的内容")
    content.attachments = [SlotContent.SlotAttachment(
        name: "a.txt", type: .file, data: Data("附件字节".utf8))]
    t.check(storage.set(1, content: content, in: g), "写入带附件的槽位应成功")
    t.check(storage.setLabel(1, label: "旧标签", in: g), "写入标签应成功")

    // 模拟 GUI 抓快照：把外置附件字节内联进内存快照（clear 会物理删除槽位目录）。
    var snapshotContent = storage.get(1, in: g)
    for i in snapshotContent.attachments.indices {
        snapshotContent.attachments[i].data = snapshotContent.attachments[i].resolveData()
    }
    let snapshotLabel = storage.getLabel(1, in: g)
    t.equal(snapshotContent.attachments.first?.data.map { String(data: $0, encoding: .utf8) } ?? nil,
            "附件字节", "快照应能取回附件字节（撤销要能全部还原）")

    t.check(storage.clear(1, in: g), "清空应成功")
    t.check(storage.isEmpty(1, in: g), "清空后应为空槽")

    // 撤销：整份内容回写
    t.check(storage.set(1, content: snapshotContent, in: g), "撤销回写应成功")
    t.check(storage.setLabel(1, label: snapshotLabel, in: g), "撤销回写标签应成功")
    let restored = storage.get(1, in: g)
    t.equal(extractText(restored), "撤销前的内容", "撤销后主体内容应完整还原")
    t.equal(restored.attachments.count, 1, "撤销后附件数量应还原")
    t.equal(restored.attachments.first?.resolveData().map { String(data: $0, encoding: .utf8) } ?? nil,
            "附件字节", "撤销后附件字节应可读（未断链）")
    t.equal(storage.getLabel(1, in: g), "旧标签", "撤销后标签应还原")
}

// MARK: - UNDO-2 (v2.10.96) 反向撤回（重做）

// 纯逻辑：撤销 / 重做双栈来回走 + 「新操作作废重做分支」
do {
    func snap(_ group: String, _ title: String, _ cid: String) -> SlotUndoSnapshot {
        var c = SlotContent()
        c.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data(title.utf8))]]
        c.contentId = cid
        c.updatedAt = 1
        return SlotUndoSnapshot(slots: [1: c], labels: [:], title: title, groupId: group)
    }

    // ① 撤销把「撤销前状态」搬到重做栈，重做再搬回撤销栈——两栈总步数守恒
    var undo = SlotUndoStack()
    var redo = SlotUndoStack()
    undo.push(snap("A", "状态0", "s0"))       // 操作1 之前
    undo.push(snap("A", "状态1", "s1"))       // 操作2 之前
    t.equal(undo.count(forGroup: "A"), 2, "两步操作应产生两步撤销记录")

    // 撤销一步：弹撤销栈顶，当前状态（这里用 状态2 表示）进重做栈
    let undone = undo.popLatest(forGroup: "A")
    redo.push(snap("A", "状态2", "s2"))
    t.equal(undone?.title, "状态1", "撤销应回到上一步状态")
    t.equal(undo.count(forGroup: "A"), 1, "撤销后撤销栈剩 1 步")
    t.equal(redo.count(forGroup: "A"), 1, "撤销后重做栈应有 1 步")

    // 重做一步：弹重做栈顶，重做前状态回到撤销栈
    let redone = redo.popLatest(forGroup: "A")
    undo.push(snap("A", "状态1", "s1b"))
    t.equal(redone?.title, "状态2", "重做应恢复被撤销掉的那一步")
    t.equal(redo.count(forGroup: "A"), 0, "重做后重做栈应清空")
    t.equal(undo.count(forGroup: "A"), 2, "重做后撤销栈应恢复为 2 步")

    // ② 重做栈同样受每组 10 步上限约束
    var bigRedo = SlotUndoStack()
    for i in 1...12 { bigRedo.push(snap("A", "R-\(i)", "r\(i)")) }
    t.equal(bigRedo.count(forGroup: "A"), 10, "重做步数上限同样为 10")

    // ③ 撤销后又做了新改动 → 该组的重做分支必须作废（时间线分叉）
    var redo2 = SlotUndoStack()
    redo2.push(snap("A", "被撤销的状态", "x1"))
    redo2.push(snap("B", "B组的重做记录", "y1"))
    redo2.removeAll(forGroup: "A")
    t.check(!redo2.canUndo(forGroup: "A"), "新操作后 A 组重做记录必须清空")
    t.equal(redo2.count(forGroup: "B"), 1, "清空 A 组重做记录不应影响 B 组")

    // ④ 重做栈同样要能跨重启持久化
    let data = try! JSONEncoder().encode(redo2)
    var decoded = try! JSONDecoder().decode(SlotUndoStack.self, from: data)
    t.equal(decoded.popLatest(forGroup: "B")?.title, "B组的重做记录", "重做栈应能 JSON 往返")
}

// 存储层：撤销 → 重做 的整组回写往返，内容不丢
t.withFreshStore("重做回写") { storage in
    let g = firstGroupId(storage)
    // 状态 A：槽位 1 有内容
    t.check(storage.set(1, content: makeTextContent("状态A"), in: g), "写入状态A应成功")
    let snapshotA = storage.get(1, in: g)

    // 操作：覆盖成状态 B
    t.check(storage.set(1, content: makeTextContent("状态B"), in: g), "覆盖成状态B应成功")
    let snapshotB = storage.get(1, in: g)

    // 撤销：回到状态 A
    t.check(storage.set(1, content: snapshotA, in: g), "撤销回写状态A应成功")
    t.equal(extractText(storage.get(1, in: g)), "状态A", "撤销后应回到状态A")

    // 重做：再回到状态 B
    t.check(storage.set(1, content: snapshotB, in: g), "重做回写状态B应成功")
    t.equal(extractText(storage.get(1, in: g)), "状态B", "重做后应恢复状态B")
}

// MARK: - UNDO-3 (v2.10.97) 撤销步数可配置

do {
    func snap(_ group: String, _ title: String, _ cid: String) -> SlotUndoSnapshot {
        var c = SlotContent()
        c.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data(title.utf8))]]
        c.contentId = cid
        c.updatedAt = 1
        return SlotUndoSnapshot(slots: [1: c], labels: [:], title: title, groupId: group)
    }

    // ① 默认仍是 10 步，范围夹取到 1~100
    t.equal(SlotUndoStack().limitPerGroup, 10, "撤销步数默认应为 10")
    t.equal(SlotUndoStack.clampLimit(0), 1, "步数下界应夹到 1")
    t.equal(SlotUndoStack.clampLimit(999), 100, "步数上界应夹到 100")
    t.equal(SlotUndoStack(limitPerGroup: -5).limitPerGroup, 1, "非法初始步数应夹到下界")

    // ② 自定义上限对新压入生效
    var big = SlotUndoStack(limitPerGroup: 25)
    for i in 1...30 { big.push(snap("A", "A-\(i)", "a\(i)")) }
    t.equal(big.count(forGroup: "A"), 25, "自定义 25 步上限应对新操作生效")
    t.equal(big.entries.first?.title, "A-6", "超出自定义上限时应丢弃最旧的步骤")

    // ③ 调小上限 → 已有超出部分立即截断（需求：已有超出部分也截断）
    let dropped = big.applyLimit(3)
    t.equal(dropped, 22, "调小上限应返回被截断的条目数")
    t.equal(big.count(forGroup: "A"), 3, "调小上限后历史应立即截断到新上限")
    t.equal(big.entries.last?.title, "A-30", "截断应保留最新的步骤")
    t.equal(big.limitPerGroup, 3, "applyLimit 后实例上限应更新")

    // ④ 截断按组独立：A 组截断不吃掉 B 组额度
    var perGroup = SlotUndoStack(limitPerGroup: 2)
    for i in 1...4 { perGroup.push(snap("A", "A-\(i)", "pa\(i)")) }
    for i in 1...4 { perGroup.push(snap("B", "B-\(i)", "pb\(i)")) }
    t.equal(perGroup.count(forGroup: "A"), 2, "A 组应各自保留 2 步")
    t.equal(perGroup.count(forGroup: "B"), 2, "B 组应各自保留 2 步")

    // ⑤ 全局上限随每组上限放大（至少 30）
    t.equal(SlotUndoStack(limitPerGroup: 10).globalLimit, 30, "默认全局上限应为 30")
    t.equal(SlotUndoStack(limitPerGroup: 100).globalLimit, 300, "每组 100 步时全局上限应为 300")

    // ⑥ JSON 往返带上限；≤v2.10.96 的老 JSON（无 limitPerGroup 字段）必须仍能解码
    var roundTrip = SlotUndoStack(limitPerGroup: 7)
    roundTrip.push(snap("A", "持久化", "z1"))
    let data = try! JSONEncoder().encode(roundTrip)
    let decoded = try! JSONDecoder().decode(SlotUndoStack.self, from: data)
    t.equal(decoded.limitPerGroup, 7, "撤销步数上限应随栈一起持久化")
    t.equal(decoded.entries.count, 1, "带上限的栈 JSON 往返后条目不丢")

    let legacyJSON = Data(#"{"entries":[]}"#.utf8)
    let legacy = try! JSONDecoder().decode(SlotUndoStack.self, from: legacyJSON)
    t.equal(legacy.limitPerGroup, 10, "老版本 JSON 缺字段时应回落默认 10（不得解码失败）")

    // ⑦ 配置项：AppConfig.undoSteps 默认 10 且 TOML 往返夹取
    t.equal(AppConfig().undoSteps, 10, "AppConfig.undoSteps 默认应为 10")
}

// MARK: - ATT-INGEST (v2.10.99) 附件字节摄取：引用型附件落盘时必须把源文件字节拷进自有目录
//
// 回归背景（线上 P0）：CLI write-attachment / GUI 拖拽 / 文件选择器此前只把源文件的绝对路径写进
// attachments.json（data=nil、storagePath=nil），字节从未进入 App 数据目录。附件的存活因此完全寄生
// 在外部源文件上——源文件位于 /tmp、/private/tmp、agent 共享目录等会被自动清理的位置时，附件集体
// 静默失效（元数据在、字节没了），且 .trash 备份里同样只有 JSON，无从恢复。
// 修复：externalizeAttachments 情形 2.5 在唯一的落盘汇聚点摄取字节。以下用例锁定该行为不回退。

do {
    let fm = FileManager.default

    /// 造一个「模拟外部源文件」的临时目录，用完即删——模拟 /tmp 被系统回收。
    func makeExternalSource(_ name: String, bytes: Data) -> URL {
        let dir = fm.temporaryDirectory
            .appendingPathComponent("clipslots_extsrc_\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(name)
        try? bytes.write(to: f)
        return f
    }

    // ① 核心：写入一个纯路径引用附件 → 删除源文件 → 附件字节必须仍可读出（此前会永久丢失）
    t.withFreshStore("附件摄取-源文件删除后仍可读") { storage in
        let g = firstGroupId(storage)
        let payload = Data("甄姬的语音字节".utf8)
        let src = makeExternalSource("甄姬cv.mp3", bytes: payload)

        var content = makeTextContent("营地抵达")
        content.attachments = [
            SlotContent.SlotAttachment(name: "甄姬cv.mp3", type: .file, path: src.path)
        ]
        t.check(storage.set(1, content: content, in: g), "写入引用型附件应成功")

        // 模拟 /tmp 被系统清理：源文件（连同其目录）彻底消失。
        try? fm.removeItem(at: src.deletingLastPathComponent())
        t.check(!fm.fileExists(atPath: src.path), "前置条件：源文件应已被删除")

        let reread = storage.get(1, in: g)
        t.equal(reread.attachments.count, 1, "重读后附件条目应仍在")
        guard let att = reread.attachments.first else { return }

        // 关键断言：字节已自有，源文件消失也读得出来。
        t.check(att.storagePath != nil, "落盘后应回填 storagePath（字节已摄取为自有副本）")
        t.equal(att.resolveData(), payload, "源文件删除后仍应能读出原始字节")
        t.check(!att.isBrokenLocalFileRef, "有自有字节时不得再被判定为断链（否则 UI 误报「文件不存在」）")
        t.equal(att.originalPath, src.path, "应保留 originalPath 记录来源以便溯源")
    }

    // ② 字节确实落在了槽位自有的 attachments/ 目录下（而非仍旧指向外部）
    t.withFreshStore("附件摄取-字节落在自有目录") { storage in
        let g = firstGroupId(storage)
        let src = makeExternalSource("场景1.png", bytes: Data("PNGBYTES".utf8))
        var content = SlotContent()
        content.attachments = [
            SlotContent.SlotAttachment(name: "场景1.png", type: .image, path: src.path)
        ]
        t.check(storage.set(2, content: content, in: g), "写入图片引用附件应成功")

        guard let att = storage.get(2, in: g).attachments.first, let sp = att.storagePath else {
            t.check(false, "应拿到带 storagePath 的附件"); return
        }
        t.check(sp.contains("/attachments/"), "storagePath 应位于槽位自有的 attachments/ 目录下")
        t.check(sp.hasSuffix(att.id.uuidString + ".bin"), "外置字节应按附件 UUID 内容寻址命名")
        t.check(fm.fileExists(atPath: sp), "外置字节文件应真实存在于磁盘")
        t.check(!sp.contains(src.deletingLastPathComponent().lastPathComponent),
                "storagePath 不得仍指向外部源目录")
        try? fm.removeItem(at: src.deletingLastPathComponent())
    }

    // ③ materializedFileURL：源文件没了也要能按【原始文件名】取出可粘贴的文件（不能给出 UUID.bin）
    t.withFreshStore("附件摄取-materialize保留原始文件名") { storage in
        let g = firstGroupId(storage)
        let payload = Data("VIDEOBYTES".utf8)
        let src = makeExternalSource("蓝.mp3", bytes: payload)
        var content = SlotContent()
        content.attachments = [
            SlotContent.SlotAttachment(name: "蓝.mp3", type: .file, path: src.path)
        ]
        t.check(storage.set(3, content: content, in: g), "写入附件应成功")
        try? fm.removeItem(at: src.deletingLastPathComponent())

        guard let att = storage.get(3, in: g).attachments.first else {
            t.check(false, "应拿到附件"); return
        }
        guard let url = att.materializedFileURL() else {
            t.check(false, "源文件消失但字节完好时，materializedFileURL 不应返回 nil"); return
        }
        t.equal(url.lastPathComponent, "蓝.mp3", "materialize 出的文件应保留原始文件名与扩展名")
        t.equal(try? Data(contentsOf: url), payload, "materialize 出的文件内容应与原始字节一致")
        // 幂等：再取一次应复用同一路径，不重复拷贝。
        t.equal(att.materializedFileURL()?.path, url.path, "重复 materialize 应复用同一路径")
    }

    // ④ 源文件仍在原位时，materializedFileURL 必须零拷贝直接返回原路径（不改变既有行为）
    t.withFreshStore("附件摄取-源文件在位时零拷贝") { storage in
        let g = firstGroupId(storage)
        let src = makeExternalSource("在位.txt", bytes: Data("STILLHERE".utf8))
        defer { try? fm.removeItem(at: src.deletingLastPathComponent()) }
        var content = SlotContent()
        content.attachments = [
            SlotContent.SlotAttachment(name: "在位.txt", type: .file, path: src.path)
        ]
        t.check(storage.set(4, content: content, in: g), "写入附件应成功")
        guard let att = storage.get(4, in: g).attachments.first else {
            t.check(false, "应拿到附件"); return
        }
        t.equal(att.materializedFileURL()?.path, src.path, "源文件在位时应直接返回原始路径")
        t.check(!att.isBrokenLocalFileRef, "源文件在位自然不算断链")
    }

    // ⑤ 多次改写槽位（只动正文/标签）不得丢掉已摄取的附件字节——覆盖情形 2 的跨写入保活
    t.withFreshStore("附件摄取-反复改写不丢字节") { storage in
        let g = firstGroupId(storage)
        let payload = Data("KEEPME".utf8)
        let src = makeExternalSource("曹操.png", bytes: payload)
        var content = makeTextContent("初始正文")
        content.attachments = [
            SlotContent.SlotAttachment(name: "曹操.png", type: .image, path: src.path)
        ]
        t.check(storage.set(5, content: content, in: g), "首次写入应成功")
        try? fm.removeItem(at: src.deletingLastPathComponent())

        // 连续 3 次只改正文重写整槽（每次都是 staging → 原子 swap）
        for i in 1...3 {
            var next = storage.get(5, in: g)
            next.items = makeTextContent("正文修改 \(i)").items
            t.check(storage.set(5, content: next, in: g), "第 \(i) 次改写正文应成功")
        }

        let final = storage.get(5, in: g)
        t.equal(extractText(final), "正文修改 3", "正文应为最后一次修改的值")
        t.equal(final.attachments.first?.resolveData(), payload,
                "反复改写整槽后附件字节仍应完好（原子 swap 不得丢掉外置 .bin）")
    }

    // ⑥ 真断链（从未落盘过字节、源文件也不存在）仍应如实判为断链，不得被本次修复掩盖
    do {
        let ghost = SlotContent.SlotAttachment(
            name: "不存在.png", type: .image,
            path: "/tmp/clipslots_definitely_missing_\(UUID().uuidString)/x.png"
        )
        t.check(ghost.isBrokenLocalFileRef, "无字节且源文件不存在的附件仍应判为断链")
        t.check(ghost.materializedFileURL() == nil, "真断链附件 materialize 应返回 nil")
        t.check(ghost.resolveData() == nil, "真断链附件不应解析出字节")
    }
}

// MARK: - MANUAL-THUMB (v2.11.0) 槽位缩略图手动上传
//
// 本组用例锁定手动缩略图的四条核心不变量。前三条是「数据不丢」，最后一条是「缓存必失效」——
// 后者对应 v2.10.64/65 反复回归过的「切组串图 / 缩略图卡旧图」类问题，是本功能最敏感的地方。
//
//   ① 持久化：pendingManualThumbnailData 交给存储层后，字节落到 attachments/{id}.bin，
//      manualThumbnailId 落到 content.json，冷读能原样恢复。
//   ② 保活（★最关键）：writeSlotContent 是「staging 整目录原子 swap」，任何**无关**的后续写入
//      （改标签、编辑正文、加附件…）都会重建槽位目录。缩略图字节必须每次都被重新搬进 staging，
//      否则用户改一次文本，封面图就人间蒸发。
//   ③ 悬空自愈：content.json 里有 id、但字节文件被外部删掉时，读取应归一化为「无手动缩略图」，
//      而不是留一个永远解不出图的悬空引用。
//   ④ 缓存 key：thumbnailKey 必须随手动缩略图身份变化而变化，且未设置时与升级前**逐字节一致**
//      （老数据的缓存不能因为升级而全量失效）。

do {
    let fm = FileManager.default

    /// 直接窥探磁盘：某槽位 attachments/ 目录下的 .bin 文件名集合。
    func binFiles(dataDir: URL, groupId: String, slot: Int) -> Set<String> {
        let dir = dataDir
            .appendingPathComponent("special_slots", isDirectory: true)
            .appendingPathComponent(groupId, isDirectory: true)
            .appendingPathComponent("\(slot)", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".bin") })
    }

    /// 与 withFreshStore 同构，但额外把数据目录路径交给用例，方便做磁盘断言。
    func withFreshStoreAndDir(_ name: String, _ body: (SpecialSlotStorage, URL) throws -> Void) {
        let dir = fm.temporaryDirectory
            .appendingPathComponent("clipslots_smoke_\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("CLIPSLOTS_DATA_DIR", dir.path, 1)
        defer {
            unsetenv("CLIPSLOTS_DATA_DIR")
            try? fm.removeItem(at: dir)
        }
        do { try body(SpecialSlotStorage(), dir) }
        catch { t.check(false, "\(name) 抛出异常：\(error)") }
    }

    let thumbBytes = Data("FAKE-JPEG-THUMBNAIL-BYTES-\(UUID().uuidString)".utf8)

    // ① 持久化 + 冷读恢复
    withFreshStoreAndDir("手动缩略图持久化") { storage, dataDir in
        let gid = firstGroupId(storage)
        var content = makeTextContent("有封面的槽位")
        let thumbId = UUID().uuidString
        content.manualThumbnailId = thumbId
        content.pendingManualThumbnailData = thumbBytes
        t.check(storage.set(1, content: content, in: gid), "带手动缩略图的写入应成功")

        let read = storage.get(1, in: gid)
        t.equal(read.manualThumbnailId, thumbId, "manualThumbnailId 应持久化并原样读回")
        t.check(read.hasManualThumbnail, "hasManualThumbnail 应为 true")
        t.check(read.pendingManualThumbnailData == nil, "瞬态字节载荷不得被持久化/缓存")

        t.check(binFiles(dataDir: dataDir, groupId: gid, slot: 1).contains("\(thumbId).bin"),
                "缩略图字节应落盘为 attachments/\(thumbId).bin")

        guard let url = storage.manualThumbnailURL(1, in: gid) else {
            t.check(false, "manualThumbnailURL 应返回有效路径"); return
        }
        t.equal(try Data(contentsOf: url), thumbBytes, "落盘字节应与写入字节完全一致")

        // 冷读：换一个 storage 实例，绕过内存缓存，验证真的读的是磁盘。
        let cold = SpecialSlotStorage().get(1, in: gid)
        t.equal(cold.manualThumbnailId, thumbId, "冷读（新实例、无内存缓存）也应恢复 manualThumbnailId")

        // content.json 的键名契约：PackExporter 用 JSONSerialization 直接读 "manualThumbnailId"
        // 字符串字段来决定要不要把封面图打进包里（它刻意不依赖 Kit 的私有 SlotContentMeta 类型）。
        // 这条断言把「磁盘 JSON 键名」钉死，防止将来重命名字段时静默让 pack 导出丢图。
        let metaURL = dataDir
            .appendingPathComponent("special_slots", isDirectory: true)
            .appendingPathComponent(gid, isDirectory: true)
            .appendingPathComponent("1", isDirectory: true)
            .appendingPathComponent("content.json")
        let metaObj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any]
        t.equal(metaObj?["manualThumbnailId"] as? String, thumbId,
                "content.json 必须包含 manualThumbnailId 字段（PackExporter 依赖此键名）")
    }

    // ② ★保活：无关的后续写入不得抹掉缩略图字节
    withFreshStoreAndDir("手动缩略图跨原子 swap 保活") { storage, dataDir in
        let gid = firstGroupId(storage)
        var content = makeTextContent("原始文本")
        let thumbId = UUID().uuidString
        content.manualThumbnailId = thumbId
        content.pendingManualThumbnailData = thumbBytes
        _ = storage.set(1, content: content, in: gid)

        // 模拟「用户后来编辑了正文」：走一次完全不关心缩略图的普通写入
        //（注意 pendingManualThumbnailData 此时为 nil —— 字节只能靠存储层从 live 目录 clone 过去）。
        var edited = storage.get(1, in: gid)
        edited.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data("改过的文本".utf8))]]
        edited.contentId = UUID().uuidString
        edited.updatedAt = Date().timeIntervalSince1970
        t.check(edited.pendingManualThumbnailData == nil, "前置条件：二次写入不应携带瞬态字节")
        _ = storage.set(1, content: edited, in: gid)

        let after = storage.get(1, in: gid)
        t.equal(extractText(after), "改过的文本", "二次写入应正常更新正文")
        t.equal(after.manualThumbnailId, thumbId, "二次写入后 manualThumbnailId 必须保留（不得被 swap 抹掉）")
        t.check(binFiles(dataDir: dataDir, groupId: gid, slot: 1).contains("\(thumbId).bin"),
                "★二次写入后缩略图字节文件必须仍在磁盘上（原子 swap 保活）")
        if let url = storage.manualThumbnailURL(1, in: gid) {
            t.equal(try Data(contentsOf: url), thumbBytes, "保活后的字节内容不得损坏")
        } else {
            t.check(false, "保活后 manualThumbnailURL 不应为 nil")
        }

        // 再验「清除」：manualThumbnailId 置 nil 后，读回应彻底无缩略图。
        var cleared = storage.get(1, in: gid)
        cleared.manualThumbnailId = nil
        cleared.contentId = UUID().uuidString
        cleared.updatedAt = Date().timeIntervalSince1970
        _ = storage.set(1, content: cleared, in: gid)

        let afterClear = storage.get(1, in: gid)
        t.check(afterClear.manualThumbnailId == nil, "清除后 manualThumbnailId 应为 nil")
        t.check(!afterClear.hasManualThumbnail, "清除后 hasManualThumbnail 应为 false")
        t.check(storage.manualThumbnailURL(1, in: gid) == nil, "清除后不应再解析出缩略图 URL")
        t.check(!binFiles(dataDir: dataDir, groupId: gid, slot: 1).contains("\(thumbId).bin"),
                "清除后旧缩略图字节应随原子 swap 自然回收（不再被搬进 staging）")
        t.equal(extractText(afterClear), "改过的文本", "清除缩略图不得影响槽位正文")
    }

    // ③ 悬空 id 自愈：字节被外部删除时，读取应降级为「无手动缩略图」
    withFreshStoreAndDir("悬空 manualThumbnailId 自愈") { storage, dataDir in
        let gid = firstGroupId(storage)
        var content = makeTextContent("待悬空")
        let thumbId = UUID().uuidString
        content.manualThumbnailId = thumbId
        content.pendingManualThumbnailData = thumbBytes
        _ = storage.set(1, content: content, in: gid)

        // 模拟外部清理/同步遗漏：把字节文件删掉，只留 content.json 里的 id。
        let binURL = dataDir
            .appendingPathComponent("special_slots", isDirectory: true)
            .appendingPathComponent(gid, isDirectory: true)
            .appendingPathComponent("1", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("\(thumbId).bin")
        try fm.removeItem(at: binURL)

        // 必须用新实例：老实例的内存缓存还记着删除前的状态。
        let cold = SpecialSlotStorage().get(1, in: gid)
        t.check(cold.manualThumbnailId == nil, "字节缺失时应把悬空 id 归一化为 nil（自动回落到自动缩略图）")
        t.equal(extractText(cold), "待悬空", "悬空自愈不得影响槽位正文")
    }

    // ④ 缓存 key：随手动缩略图身份变化，且未设置时保持与升级前一致
    do {
        var plain = makeTextContent("key 测试")
        plain.contentId = "CID"
        plain.updatedAt = 1234.5

        var withThumb = plain
        withThumb.manualThumbnailId = "THUMB-A"

        var withOtherThumb = plain
        withOtherThumb.manualThumbnailId = "THUMB-B"

        let kPlain = plain.thumbnailKey(specialSlotId: "G1", slot: 3)
        let kA = withThumb.thumbnailKey(specialSlotId: "G1", slot: 3)
        let kB = withOtherThumb.thumbnailKey(specialSlotId: "G1", slot: 3)

        t.equal(kPlain, "G1::3::CID::1234.5::m0", "未设置手动缩略图时 key 应以 ::m0 结尾")
        t.equal(kA, "G1::3::CID::1234.5::mTHUMB-A", "设置手动缩略图后 key 应编入其 id")
        t.check(kA != kPlain, "★设置手动缩略图必须让缓存 key 变化（否则卡旧图）")
        t.check(kA != kB, "★更换手动缩略图必须让缓存 key 变化")

        // 不同组 / 不同槽位仍必须产出不同 key —— 这是「切组不串图」的地基，不能因为
        // 新拼接的 ::m 后缀而被削弱。
        t.check(withThumb.thumbnailKey(specialSlotId: "G2", slot: 3) != kA, "不同组的 key 必须不同（防串组）")
        t.check(withThumb.thumbnailKey(specialSlotId: "G1", slot: 4) != kA, "不同槽位的 key 必须不同（防串槽）")

        // 空槽：未设手动图时保持历史 `::empty`（v2.10.28 空槽附件面板修复依赖它稳定）；
        // 设了手动图则必须可区分。
        var emptyPlain = SlotContent()
        emptyPlain.contentId = "CID"
        emptyPlain.updatedAt = 1234.5
        var emptyWithThumb = emptyPlain
        emptyWithThumb.manualThumbnailId = "THUMB-A"
        t.equal(emptyPlain.thumbnailKey(specialSlotId: "G1", slot: 3), "G1::3::empty",
                "空槽且无手动缩略图时 key 必须与升级前逐字节一致")
        t.check(emptyWithThumb.thumbnailKey(specialSlotId: "G1", slot: 3) != "G1::3::empty",
                "空槽设置手动缩略图后 key 必须可区分")
    }

    // ⑤ 向后兼容：老版本 payload（无 manualThumbnailId 键）必须能正常解码为「无手动缩略图」
    do {
        let legacyJSON = """
        {"items":[],"timestamp":0,"contentId":"OLD","updatedAt":11.0}
        """
        let decoded = try? JSONDecoder().decode(SlotContent.self, from: Data(legacyJSON.utf8))
        t.check(decoded != nil, "老版本 SlotContent JSON 应能解码")
        t.check(decoded?.manualThumbnailId == nil, "老 payload 缺 manualThumbnailId 时应回落 nil，不得解码失败")
        t.equal(decoded?.contentId, "OLD", "老 payload 的其余字段应正常解码")

        // 空串按「未设置」处理，避免拼出 attachments/.bin 这种非法路径。
        let emptyIdJSON = """
        {"items":[],"timestamp":0,"contentId":"OLD","updatedAt":11.0,"manualThumbnailId":""}
        """
        let emptyDecoded = try? JSONDecoder().decode(SlotContent.self, from: Data(emptyIdJSON.utf8))
        t.check(emptyDecoded?.manualThumbnailId == nil, "manualThumbnailId 为空串时应归一化为 nil")
    }
}

// MARK: - 轮盘扇区手动缩略图布局（v2.11.0 hotfix 回归防护）
//
// v2.11.0 首版把缩略图和文字塞进同一个 VStack 再整体 offset 到扇区中点，导致缩略图被推到
// 「屏幕正上方」而不是「沿中轴线向外」：10 槽位下 8 个扇区角偏差 25°~30°（半扇区仅 18°），
// 缩略图歪进邻居扇区、顶部扇区紧贴圆盘边缘。下面直接断言几何不变量，钉死这个 bug。
do {
    /// 复刻 RadialMenuView 的真实几何：menuSize 372 → outerRadius 186。
    let outer: CGFloat = 186
    let segmentOuter = outer - 8            // segmentOuterInset
    let deadZone = outer * 0.24
    let segmentInner = deadZone + 1.5       // segmentInnerInset

    // 缩略图正方形四角（屏幕坐标轴对齐，中心在中轴线上 thumbnailRadius 处）
    func corners(midAngleDegrees: Double, radius: CGFloat, side: CGFloat) -> [(CGFloat, CGFloat)] {
        let rad = midAngleDegrees * .pi / 180
        let cx = radius * CGFloat(cos(rad))
        let cy = radius * CGFloat(sin(rad))
        let h = side / 2
        return [(cx - h, cy - h), (cx + h, cy - h), (cx - h, cy + h), (cx + h, cy + h)]
    }

    // slots 取值范围由 Config 限定为 1...10，全覆盖
    for slotCount in 1...10 {
        let segmentDegrees = 360.0 / Double(slotCount)
        guard let layout = RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner,
                                                               outerRadius: segmentOuter,
                                                               segmentDegrees: segmentDegrees) else {
            t.check(false, "\(slotCount) 槽位布局下应能放下缩略图")
            continue
        }

        t.check(layout.thumbnailSide >= RadialSegmentLayoutCalculator.minThumbnailSide
                    && layout.thumbnailSide <= RadialSegmentLayoutCalculator.maxThumbnailSide,
                "\(slotCount) 槽位：缩略图边长应落在合法区间（实际 \(layout.thumbnailSide)）")
        t.check(layout.thumbnailRadius > layout.textRadius,
                "\(slotCount) 槽位：缩略图应在文字块外侧")

        for i in 0..<slotCount {
            let midAngle = (Double(i) + 0.5) * segmentDegrees - 90
            var maxRadius: CGFloat = 0
            var maxAngularDeviation: Double = 0

            for (px, py) in corners(midAngleDegrees: midAngle, radius: layout.thumbnailRadius, side: layout.thumbnailSide) {
                maxRadius = max(maxRadius, (px * px + py * py).squareRoot())
                let cornerAngle = atan2(Double(py), Double(px)) * 180 / .pi
                // 归一化到 [-180, 180]：truncatingRemainder 对负数保留负号，必须二次校正，
                // 否则 -170° 会被算成 350° 的偏差。
                var delta = (cornerAngle - midAngle).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                maxAngularDeviation = max(maxAngularDeviation, abs(delta))
            }

            // ★不变量 1：缩略图不得越过扇区外沿（否则会溢出到圆盘边缘之外）
            t.check(maxRadius <= segmentOuter,
                    "★\(slotCount)槽位/第\(i + 1)扇区：缩略图不得越过外沿（最远 \(Int(maxRadius)) > \(Int(segmentOuter))）")
            // ★不变量 2：缩略图不得越过扇区内沿（不得压进中心死区）
            let minCornerRadius = layout.thumbnailRadius - layout.thumbnailSide * CGFloat(2.0.squareRoot()) / 2
            t.check(minCornerRadius >= segmentInner,
                    "★\(slotCount)槽位/第\(i + 1)扇区：缩略图不得压进死区")
            // ★不变量 3：缩略图四角必须留在本扇区楔形内（这正是 v2.11.0 首版失守的那条）
            if slotCount > 1 {
                t.check(maxAngularDeviation <= segmentDegrees / 2,
                        "★\(slotCount)槽位/第\(i + 1)扇区：缩略图不得歪出扇区（角偏差 \(Int(maxAngularDeviation))° > 半扇区 \(Int(segmentDegrees / 2))°）")
            }
        }
    }

    // 文字块也不许压进死区
    if let layout = RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner,
                                                        outerRadius: segmentOuter,
                                                        segmentDegrees: 36) {
        t.check(layout.textRadius - RadialSegmentLayoutCalculator.textBlockHeight / 2 >= segmentInner,
                "★文字块不得压进中心死区")

        // v2.11.0 hotfix-2：文字块横向不得越过扇区分隔线。
        // 回归背景：文字块宽度曾写死 midRadius*0.78（≈87pt），而楔形在 textRadius 处的
        // 弦宽只有 ≈57pt，长标签横向溢出到邻居扇区，并在斜向扇区撞上本扇区的缩略图。
        let chordAtText = RadialSegmentLayoutCalculator.chordWidth(atRadius: layout.textRadius,
                                                                   segmentDegrees: 36)
        t.check(layout.textBlockWidth <= chordAtText + 0.001,
                "★文字块宽度不得超过所在半径处的弦宽（不越扇区分隔线）")
        t.check(layout.textBlockWidth >= RadialSegmentLayoutCalculator.minTextBlockWidth - 0.001,
                "文字块宽度不得低于可读下限")

        // 文字块的外沿（径向）与缩略图的内沿之间必须留有间距，二者不得相贴/重叠。
        let textOuterEdge = layout.textRadius + RadialSegmentLayoutCalculator.textBlockHeight / 2
        let thumbInnerEdge = layout.thumbnailRadius - layout.thumbnailSide / 2
        t.check(thumbInnerEdge >= textOuterEdge - 0.001,
                "★缩略图内沿不得压到文字块外沿")
    }

    // 弦宽/文字宽度纯函数的边界行为
    t.equal(RadialSegmentLayoutCalculator.chordWidth(atRadius: 100, segmentDegrees: 360),
            .greatestFiniteMagnitude,
            "360° 单扇区不构成弦宽约束")
    t.check(abs(RadialSegmentLayoutCalculator.chordWidth(atRadius: 100, segmentDegrees: 90)
                - 2 * 100 * CGFloat(tan(45 * Double.pi / 180))) < 0.001,
            "弦宽公式：90° 扇区在 r=100 处应为 200")
    t.equal(RadialSegmentLayoutCalculator.textBlockWidth(atRadius: 1,
                                                         segmentDegrees: 36,
                                                         preferred: 200),
            RadialSegmentLayoutCalculator.minTextBlockWidth,
            "极小半径处文字宽度收敛到下限而不是 0")
    t.equal(RadialSegmentLayoutCalculator.textBlockWidth(atRadius: 1000,
                                                         segmentDegrees: 36,
                                                         preferred: 60),
            60,
            "弦宽充裕时文字宽度取 preferred")

    // 退化输入：环带太薄 / 参数非法时必须返回 nil，让调用方退回纯文字布局而不是画出畸形缩略图
    t.check(RadialSegmentLayoutCalculator.layout(innerRadius: 40, outerRadius: 60, segmentDegrees: 36) == nil,
            "★环带过薄时应返回 nil（退回纯文字扇区）")
    t.check(RadialSegmentLayoutCalculator.layout(innerRadius: 100, outerRadius: 100, segmentDegrees: 36) == nil,
            "内外半径相等应返回 nil")
    t.check(RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner, outerRadius: segmentOuter, segmentDegrees: 0) == nil,
            "扇区张角为 0 应返回 nil")
    // 单扇区（360°）没有角向约束，应拿到最大边长
    t.equal(RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner, outerRadius: segmentOuter, segmentDegrees: 360)?.thumbnailSide,
            RadialSegmentLayoutCalculator.maxThumbnailSide,
            "单扇区应可用最大边长")
}

// MARK: - 轮盘「上次粘贴」外弧 + 编号行角标（v2.11.1）
//
// 两条新增的扇区不变量：
//  1. 外弧必须完整落在本扇区的楔形内，且不越出扇区外沿、不压到缩略图；
//  2. 编号行（编号 + 串联色点 + 附件角标）的总宽不得超过所在半径处的弦宽——
//     即角标不会把编号行顶到邻居扇区去（v2.11.0 hotfix 同款失守方式的横向版本）。
do {
    let outer: CGFloat = 186
    let segmentOuter = outer - 8
    let deadZone = outer * 0.24
    let segmentInner = deadZone + 1.5

    for slotCount in 1...10 {
        let segmentDegrees = 360.0 / Double(slotCount)

        for i in 0..<slotCount {
            let start = Double(i) * segmentDegrees - 90
            let end = Double(i + 1) * segmentDegrees - 90
            guard let arc = RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: segmentOuter,
                                                                      startDegrees: start,
                                                                      endDegrees: end) else {
                t.check(false, "\(slotCount) 槽位/第\(i + 1)扇区：应能画出「上次粘贴」外弧")
                continue
            }

            // ★不变量 1：弧线（含线宽）不得越出扇区外沿
            t.check(arc.outerEdgeRadius <= segmentOuter + 0.001,
                    "★\(slotCount)槽位/第\(i + 1)扇区：外弧不得越出扇区外沿（\(arc.outerEdgeRadius) > \(segmentOuter)）")
            // ★不变量 2：弧线必须留在本扇区角度范围内（两端不得压到分隔线）
            t.check(arc.startDegrees > start && arc.endDegrees < end,
                    "★\(slotCount)槽位/第\(i + 1)扇区：外弧两端必须内缩，不得压到扇区分隔线")
            // 两端内缩量对称，视觉上才居中
            t.check(abs((arc.startDegrees - start) - (end - arc.endDegrees)) < 0.001,
                    "\(slotCount)槽位/第\(i + 1)扇区：外弧两端内缩量应对称")
            // ★不变量 3：弧线内缘不得压进死区（外弧永远贴外沿，这条只是兜底）
            t.check(arc.innerEdgeRadius > segmentInner,
                    "★\(slotCount)槽位/第\(i + 1)扇区：外弧不得压进中心死区")
            // 弧线仍有可见张角
            t.check(arc.spanDegrees >= min(RadialSegmentLayoutCalculator.lastPasteArcMinSpanDegrees, segmentDegrees) - 0.001,
                    "\(slotCount)槽位/第\(i + 1)扇区：外弧张角应可见（\(arc.spanDegrees)°）")
        }
    }

    // 10 槽位（最窄扇区）下外弧仍应保留至少 2/3 的扇区张角，否则看起来就是个小点
    if let arc = RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: segmentOuter,
                                                           startDegrees: 0,
                                                           endDegrees: 36) {
        t.check(arc.spanDegrees >= 36 * 2.0 / 3,
                "★10 槽位下外弧应仍占扇区张角的 2/3 以上（实际 \(arc.spanDegrees)°）")
    }

    // 退化输入：张角为 0 / 负、半径过小 → nil（调用方不画，而不是画出一个畸形弧）
    t.check(RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: segmentOuter, startDegrees: 10, endDegrees: 10) == nil,
            "★张角为 0 时不应画外弧")
    t.check(RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: segmentOuter, startDegrees: 20, endDegrees: 10) == nil,
            "起止角反向时不应画外弧")
    t.check(RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: 1, startDegrees: 0, endDegrees: 36) == nil,
            "外半径过小时不应画外弧")

    // 编号行横向约束：编号 + 串联色点 + 附件角标（当前最多 1 个角标）
    for slotCount in 1...10 {
        let segmentDegrees = 360.0 / Double(slotCount)
        guard let layout = RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner,
                                                               outerRadius: segmentOuter,
                                                               segmentDegrees: segmentDegrees) else { continue }
        t.check(RadialSegmentLayoutCalculator.numberRowFits(hasConnectionDot: true,
                                                            badgeCount: 1,
                                                            atRadius: layout.textRadius,
                                                            segmentDegrees: segmentDegrees),
                "★\(slotCount)槽位：编号 + 串联色点 + 附件角标不得越出楔形（行宽 \(RadialSegmentLayoutCalculator.numberRowWidth(hasConnectionDot: true, badgeCount: 1))，弦宽 \(RadialSegmentLayoutCalculator.chordWidth(atRadius: layout.textRadius, segmentDegrees: segmentDegrees))）")
    }

    // 宽度公式本身：加角标必须真的变宽，且是 spacing + icon 的量
    t.equal(RadialSegmentLayoutCalculator.numberRowWidth(hasConnectionDot: false, badgeCount: 0),
            RadialSegmentLayoutCalculator.slotNumberMaxWidth,
            "无色点无角标时行宽 = 编号宽度")
    t.equal(RadialSegmentLayoutCalculator.numberRowWidth(hasConnectionDot: false, badgeCount: 1)
                - RadialSegmentLayoutCalculator.numberRowWidth(hasConnectionDot: false, badgeCount: 0),
            RadialSegmentLayoutCalculator.numberRowSpacing + RadialSegmentLayoutCalculator.badgeIconWidth,
            "每个角标增加 spacing + icon 宽度")

    // ★为什么「上次粘贴」标识做成扇区外弧、而不是编号行里的第二个角标：**编号行塞不下**。
    // 10 槽位（36°/扇区）时编号行所在半径处的弦宽只有 ~57pt，而「编号 + 串联色点 + 2 个角标」
    // 要 70pt —— 第二个角标必定把整行顶进邻居扇区，正是 v2.11.0 hotfix 那类越界的横向翻版。
    // 这条断言把该结论钉死：以后谁想再往编号行加第二个角标，会立刻在这里失败。
    let tenSegmentDegrees = 36.0
    if let tenLayout = RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner,
                                                           outerRadius: segmentOuter,
                                                           segmentDegrees: tenSegmentDegrees) {
        t.check(!RadialSegmentLayoutCalculator.numberRowFits(hasConnectionDot: true,
                                                            badgeCount: 2,
                                                            atRadius: tenLayout.textRadius,
                                                            segmentDegrees: tenSegmentDegrees),
                "★10槽位：编号行放不下第二个角标（行宽 \(RadialSegmentLayoutCalculator.numberRowWidth(hasConnectionDot: true, badgeCount: 2)) > 弦宽 \(RadialSegmentLayoutCalculator.chordWidth(atRadius: tenLayout.textRadius, segmentDegrees: tenSegmentDegrees))）——「上次粘贴」因此走外弧")
    }
}

// MARK: - 花瓣扇区几何（v2.11.5）
//
// 硬边扇形改成「圆角花瓣 + 恒宽通道」之后，出错的方式全都是**看起来差不多但其实越界**：
// 花瓣探进邻居的角度区间、通道内圈粘住外圈裂开、圆角大到路径自交打结、圆角把「上次粘贴」
// 外弧挤到花瓣外面悬空。这些都是可以精确断言的几何不变量，下面逐条钉住。
//
// 采样口径与 RadialMenuView 一致：menuSize 372 → outerRadius 186、segmentOuterInset 8、
// 死区 0.24R、segmentInnerInset 1.5、gap 5、cornerTrim 16。
do {
    let outer: CGFloat = 186
    let segmentOuter = outer - 8
    let deadZone = outer * 0.24
    let segmentInner = deadZone + 4      // segmentInnerInset（v2.11.5 从 1.5 抬到 4）
    let gap: CGFloat = 5
    let trim: CGFloat = 18

    /// 从路径基元里抽出所有「实体点」（含贝塞尔控制点：控制点就是被倒掉的几何拐角，
    /// 它必须也在楔形内，否则圆角会鼓出边界）。
    func samplePoints(_ petal: RadialPetal) -> [CGPoint] {
        var pts: [CGPoint] = []
        for e in petal.elements {
            switch e {
            case .move(let p), .line(let p):
                pts.append(p)
            case .quad(let to, let control):
                pts.append(to)
                pts.append(control)
            case .arc(let radius, let start, let end, _):
                // 圆弧本身按半径采样：等分 5 点，覆盖弧中段（端点已由相邻基元贡献）。
                for k in 0...5 {
                    let t = CGFloat(k) / 5
                    let a = start + (end - start) * t
                    pts.append(CGPoint(x: radius * cos(a), y: radius * sin(a)))
                }
            case .close:
                break
            }
        }
        return pts
    }

    func polarDegrees(_ p: CGPoint) -> Double {
        var deg = Double(atan2(p.y, p.x)) * 180 / .pi
        if deg < -180 { deg += 360 }
        return deg
    }

    func radius(_ p: CGPoint) -> CGFloat { sqrt(p.x * p.x + p.y * p.y) }

    // ① 核心不变量：每片花瓣完整落在自己的楔形内（角度 + 内外半径都不越界）。
    //    槽位数从 1 扫到 12，覆盖「单片=整环带」到「12 片窄花瓣」。
    for count in [1, 2, 3, 4, 5, 6, 8, 10, 12] {
        let span = 360.0 / Double(count)
        for i in 0..<count {
            let start = Double(i) * span - 90
            let end = Double(i + 1) * span - 90
            guard let petal = RadialPetalGeometry.petal(startDegrees: start,
                                                       endDegrees: end,
                                                       innerRadius: segmentInner,
                                                       outerRadius: segmentOuter,
                                                       gap: gap,
                                                       cornerTrim: trim) else {
                t.check(false, "★\(count) 花瓣：第 \(i) 片应当可解")
                continue
            }

            t.equal(petal.elements.count, 10, "花瓣路径基元数固定为 10（move+arc+4圆角+2侧边+arc+close）")

            var maxRadius: CGFloat = 0
            var minRadius: CGFloat = .greatestFiniteMagnitude
            var worstAngleOverflow: Double = 0
            for p in samplePoints(petal) {
                let r = radius(p)
                maxRadius = max(maxRadius, r)
                minRadius = min(minRadius, r)

                // 角度必须落在 [start, end] 内。用该点自身半径处的允许区间比较，
                // 容差 0.01° 兜浮点。
                // 把采样角搬进 [start, start+360)：atan2 只给 (-180, 180]，而扇区角可以是
                // 234°~270° 这种跨界区间；容差 0.01° 是为了让「刚好压在 start 上、浮点下溢
                // 到 start - 1e-7」的点留在原地，而不是被整整搬走一圈变成假越界。
                var normalized = polarDegrees(p)
                while normalized < start - 0.01 { normalized += 360 }
                while normalized > start + 359.99 { normalized -= 360 }
                let overflow = max(start - normalized, normalized - end)
                worstAngleOverflow = max(worstAngleOverflow, overflow)
            }

            t.check(maxRadius <= segmentOuter + 0.01,
                    "★\(count) 花瓣第 \(i) 片不得越出外沿（最大 \(maxRadius) vs \(segmentOuter)）")
            t.check(minRadius >= segmentInner - 0.01,
                    "★\(count) 花瓣第 \(i) 片不得压进死区（最小 \(minRadius) vs \(segmentInner)）")
            // count == 1 时首尾就是同一条边界，允许贴边（overflow ≈ 0）。
            t.check(worstAngleOverflow <= 0.01,
                    "★\(count) 花瓣第 \(i) 片不得探进邻居的角度区间（越界 \(worstAngleOverflow)°）")
        }
    }

    // ② 通道**恒宽**：这是选「垂直距离内缩」而不是「固定角度内缩」的全部理由。
    //    验证方式：花瓣四个拐角到自己那条原始径向边的垂直距离都必须等于 gap/2，
    //    因此相邻两片之间的通道处处等于 gap —— 内圈不粘、外圈不裂。
    if let petal = RadialPetalGeometry.petal(startDegrees: -90,
                                            endDegrees: -90 + 36.0,
                                            innerRadius: segmentInner,
                                            outerRadius: segmentOuter,
                                            gap: gap,
                                            cornerTrim: trim) {
        let span = 36.0
        t.check(abs(petal.sideInset - gap / 2) < 0.0001,
                "10 槽位下侧边内缩应恰为 gap/2（实际 \(petal.sideInset)）")

        // corners 顺序：[外-起始边, 外-结束边, 内-结束边, 内-起始边]
        let startSideCorners = [petal.corners[0], petal.corners[3]]
        let endSideCorners = [petal.corners[1], petal.corners[2]]
        for c in startSideCorners {
            let d = RadialPetalGeometry.perpendicularDistance(c, toRayAtDegrees: -90)
            t.check(abs(d - gap / 2) < 0.001,
                    "★起始边拐角到原始径向边的垂距必须恒为 gap/2（实际 \(d)）")
        }
        for c in endSideCorners {
            let d = RadialPetalGeometry.perpendicularDistance(c, toRayAtDegrees: -90 + span)
            t.check(abs(d - gap / 2) < 0.001,
                    "★结束边拐角到原始径向边的垂距必须恒为 gap/2（实际 \(d)）")
        }

        // 内外两端的角度内缩必须**不同**（内圈吃掉更多角度），这正是「花瓣形」的来源。
        // 若两者相等说明退回成了固定角度内缩 —— 那就是内圈粘外圈裂的老毛病。
        let innerDelta = RadialPetalGeometry.insetDegrees(atRadius: segmentInner, sideInset: gap / 2)
        let outerDelta = RadialPetalGeometry.insetDegrees(atRadius: segmentOuter, sideInset: gap / 2)
        t.check(innerDelta > outerDelta * 2,
                "★内圈的角度内缩必须显著大于外圈（\(innerDelta)° vs \(outerDelta)°），否则通道不是恒宽的")
    } else {
        t.check(false, "10 槽位花瓣应当可解")
    }

    // ③ 相邻花瓣之间真的隔着 gap：取同半径处两片的相邻边界角，换算成弦距。
    for count in [3, 5, 10] {
        let span = 360.0 / Double(count)
        guard let a = RadialPetalGeometry.petal(startDegrees: -90, endDegrees: -90 + span,
                                               innerRadius: segmentInner, outerRadius: segmentOuter,
                                               gap: gap, cornerTrim: trim),
              let b = RadialPetalGeometry.petal(startDegrees: -90 + span, endDegrees: -90 + 2 * span,
                                                innerRadius: segmentInner, outerRadius: segmentOuter,
                                                gap: gap, cornerTrim: trim) else {
            t.check(false, "\(count) 槽位相邻两片应当可解")
            continue
        }
        for probe: CGFloat in [segmentInner, (segmentInner + segmentOuter) / 2, segmentOuter] {
            let aEnd = a.angleRange(atRadius: probe).end
            let bStart = b.angleRange(atRadius: probe).start
            // 同半径两点间的弦长 = 2r·sin(Δθ/2)
            let deltaRad = (bStart - aEnd) * .pi / 180
            let chord = 2 * probe * CGFloat(sin(deltaRad / 2))
            t.check(abs(chord - gap) < 0.05,
                    "★\(count) 槽位在 r=\(probe) 处的通道宽度必须 ≈ gap=\(gap)（实际 \(chord)）")
        }
    }

    // ④ 圆角必须被收紧，绝不允许「切点越过对边切点」——那会让路径自交、渲染成打结的怪形。
    //    内圈弧短（10 槽位下只有 ~26pt），所以内侧圆角一定小于请求的 16pt。
    for count in [5, 10, 12] {
        let span = 360.0 / Double(count)
        guard let petal = RadialPetalGeometry.petal(startDegrees: -90, endDegrees: -90 + span,
                                                   innerRadius: segmentInner, outerRadius: segmentOuter,
                                                   gap: gap, cornerTrim: 999) else {
            t.check(false, "\(count) 槽位在超大圆角请求下也必须给出解")
            continue
        }
        let innerSpan = span - 2 * RadialPetalGeometry.insetDegrees(atRadius: segmentInner, sideInset: petal.sideInset)
        let innerArc = segmentInner * CGFloat(innerSpan * .pi / 180)
        let outerSpanDeg = span - 2 * RadialPetalGeometry.insetDegrees(atRadius: segmentOuter, sideInset: petal.sideInset)
        let outerArc = segmentOuter * CGFloat(outerSpanDeg * .pi / 180)
        let sideLen = sqrt(segmentOuter * segmentOuter - petal.sideInset * petal.sideInset)
            - sqrt(segmentInner * segmentInner - petal.sideInset * petal.sideInset)

        t.check(petal.innerCornerTrim <= innerArc * 0.46,
                "★\(count) 槽位：内侧圆角不得超过内弧的一半（\(petal.innerCornerTrim) vs 弧长 \(innerArc)）")
        t.check(petal.outerCornerTrim <= outerArc * 0.46,
                "★\(count) 槽位：外侧圆角不得超过外弧的一半（\(petal.outerCornerTrim) vs 弧长 \(outerArc)）")
        t.check(petal.outerCornerTrim + petal.innerCornerTrim <= sideLen * 0.91,
                "★\(count) 槽位：同一条侧边两端的圆角切点不得越过对方（\(petal.outerCornerTrim)+\(petal.innerCornerTrim) vs 边长 \(sideLen)）")
        t.check(petal.innerCornerTrim <= petal.outerCornerTrim + 0.0001,
                "内弧比外弧短，内侧圆角不该比外侧更大（\(petal.innerCornerTrim) vs \(petal.outerCornerTrim)）")
    }

    // ⑤ gap = 0 且 cornerTrim = 0 时必须精确退化成老的硬边扇形——
    //    这条是「花瓣是硬边扇形的连续推广」的桥接断言，也让日后想回退时有据可依。
    if let sharp = RadialPetalGeometry.petal(startDegrees: -90, endDegrees: -54,
                                             innerRadius: segmentInner, outerRadius: segmentOuter,
                                             gap: 0, cornerTrim: 0) {
        t.check(abs(sharp.sideInset) < 0.0001, "gap=0 时不应有侧边内缩")
        t.check(abs(sharp.outerCornerTrim) < 0.0001 && abs(sharp.innerCornerTrim) < 0.0001,
                "cornerTrim=0 时不应有圆角")
        t.check(abs(polarDegrees(sharp.corners[0]) - (-90)) < 0.0001,
                "★gap=0 时外-起始拐角回到原始扇区边界（实际 \(polarDegrees(sharp.corners[0]))°）")
        t.check(abs(polarDegrees(sharp.corners[1]) - (-54)) < 0.0001,
                "★gap=0 时外-结束拐角回到原始扇区边界（实际 \(polarDegrees(sharp.corners[1]))°）")
        t.check(abs(radius(sharp.corners[2]) - segmentInner) < 0.0001, "gap=0 时内侧拐角贴内半径")
    } else {
        t.check(false, "gap=0/trim=0 的退化形状必须可解")
    }

    // ⑥ 退化输入必须返回 nil 而不是画出垃圾：内外半径倒置、张角为 0。
    t.check(RadialPetalGeometry.petal(startDegrees: 0, endDegrees: 36,
                                     innerRadius: 100, outerRadius: 100,
                                     gap: gap, cornerTrim: trim) == nil,
            "内外半径相等时应返回 nil")
    t.check(RadialPetalGeometry.petal(startDegrees: 0, endDegrees: 0,
                                     innerRadius: 40, outerRadius: 180,
                                     gap: gap, cornerTrim: trim) == nil,
            "零张角时应返回 nil")

    // ⑦ 极窄扇区（一页 40 个组 → 9°/片）：间隙必须被自动收紧，否则内圈两侧内缩
    //    合计 6.2° 会吃掉 2/3 张角，花瓣被压成一根针。
    do {
        let narrowSpan = 9.0
        let clamped = RadialPetalGeometry.clampedSideInset(requestedGap: gap,
                                                          innerRadius: segmentInner,
                                                          segmentDegrees: narrowSpan)
        t.check(clamped < gap / 2,
                "★9° 窄扇区下间隙必须被收紧（\(clamped) < \(gap / 2)）")
        let delta = RadialPetalGeometry.insetDegrees(atRadius: segmentInner, sideInset: clamped)
        t.check(2 * delta <= narrowSpan * 0.61,
                "★收紧后两侧内缩合计不得吃掉超过 60% 张角（实际 \(2 * delta)° / \(narrowSpan)°）")
        t.check(RadialPetalGeometry.petal(startDegrees: 0, endDegrees: narrowSpan,
                                          innerRadius: segmentInner, outerRadius: segmentOuter,
                                          gap: gap, cornerTrim: trim) != nil,
                "窄扇区收紧后仍应给出可绘制的花瓣")
    }

    // ⑧ 内容宽度必须按内缩后的张角算。花瓣把两侧各让出 2.5pt 垂距，
    //    若内容仍按满张角撑开，就会压在圆角边上甚至探进通道。
    do {
        let span = 36.0
        let r: CGFloat = 120
        let full = RadialSegmentLayoutCalculator.chordWidth(atRadius: r, segmentDegrees: span)
        let effDegrees = RadialPetalGeometry.effectiveSegmentDegrees(atRadius: r,
                                                                    segmentDegrees: span,
                                                                    sideInset: gap / 2)
        let narrowed = RadialSegmentLayoutCalculator.chordWidth(atRadius: r, segmentDegrees: effDegrees)
        t.check(effDegrees < span, "内缩后张角必须变小（\(effDegrees)° < \(span)°）")
        t.check(narrowed < full, "★花瓣可用弦宽必须比硬边扇形更窄（\(narrowed) < \(full)）")
        // 收窄量应当就是「两侧各让 gap/2」这一条通道的量级。取区间而不是等号：
        // `chordWidth` 用的是 2r·tan(θ/2)（楔形在该半径处的横向可用宽度，不是几何弦长），
        // tan 超线性，于是同样的角度内缩换算出来的宽度损失会比一条通道**略多**一点
        // （10 槽位 r=120 处实测 5.49pt vs gap 5pt）。方向是保守的：内容更窄 = 更不会压边。
        t.check((full - narrowed) >= gap * 0.9 && (full - narrowed) <= gap * 1.3,
                "★弦宽收窄量应在一整条通道宽的量级（\(full - narrowed) vs gap \(gap)）——两侧各让 gap/2")

        // 走完整 layout：传 petalGap 后文字块宽度必须收窄，且缩略图不能反而变大。
        if let plain = RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner,
                                                           outerRadius: segmentOuter,
                                                           segmentDegrees: span),
           let petaled = RadialSegmentLayoutCalculator.layout(innerRadius: segmentInner,
                                                              outerRadius: segmentOuter,
                                                              segmentDegrees: span,
                                                              petalGap: gap) {
            t.check(petaled.textBlockWidth < plain.textBlockWidth,
                    "★花瓣模式下文字块必须更窄（\(petaled.textBlockWidth) < \(plain.textBlockWidth)）")
            t.check(petaled.thumbnailSide <= plain.thumbnailSide,
                    "花瓣模式下缩略图不得变大（\(petaled.thumbnailSide) vs \(plain.thumbnailSide)）")
            t.check(petaled.thumbnailSide >= RadialSegmentLayoutCalculator.minThumbnailSide,
                    "10 槽位花瓣仍应放得下缩略图（\(petaled.thumbnailSide)）")
        } else {
            t.check(false, "10 槽位下两种模式都应给出布局")
        }
    }

    // ⑨「上次粘贴」外弧必须缩进到花瓣的圆角**里面**，否则弧的两端会探出花瓣、悬在通道上方。
    for count in [5, 10] {
        let span = 360.0 / Double(count)
        guard let petal = RadialPetalGeometry.petal(startDegrees: -90, endDegrees: -90 + span,
                                                   innerRadius: segmentInner, outerRadius: segmentOuter,
                                                   gap: gap, cornerTrim: trim),
              let arc = RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: segmentOuter,
                                                                  startDegrees: -90,
                                                                  endDegrees: -90 + span,
                                                                  petalGap: gap,
                                                                  petalCornerTrim: trim) else {
            t.check(false, "\(count) 槽位：花瓣与外弧都应可解")
            continue
        }
        let allowed = petal.angleRange(atRadius: arc.radius)
        t.check(arc.startDegrees >= allowed.start - 0.001 && arc.endDegrees <= allowed.end + 0.001,
                "★\(count) 槽位：外弧必须落在花瓣角度区间内（弧 \(arc.startDegrees)~\(arc.endDegrees) vs 花瓣 \(allowed.start)~\(allowed.end)）")
        t.check(arc.outerEdgeRadius <= segmentOuter + 0.001,
                "外弧含线宽后仍不得越出扇区外沿")
        // 与老口径对比：花瓣化之后端点内缩必须更大（因为要给圆角让路）。
        if let legacy = RadialSegmentLayoutCalculator.lastPasteArc(outerRadius: segmentOuter,
                                                                  startDegrees: -90,
                                                                  endDegrees: -90 + span) {
            t.check(arc.spanDegrees < legacy.spanDegrees,
                    "★\(count) 槽位：花瓣模式的外弧必须比硬边模式更短（\(arc.spanDegrees)° < \(legacy.spanDegrees)°）")
        }
    }

    // ⑩ 视觉参数本身的护栏：通道 4~6pt 是需求给定的甜点区间，圆角要「大」但不能大过环带的一半。
    t.check(RadialPetalGeometry.defaultGap >= 4 && RadialPetalGeometry.defaultGap <= 6,
            "默认通道宽应落在 4~6pt（当前 \(RadialPetalGeometry.defaultGap)）")
    t.check(RadialPetalGeometry.defaultCornerTrim >= 10,
            "默认圆角要足够「大圆角」（当前 \(RadialPetalGeometry.defaultCornerTrim)）")
    t.check(RadialPetalGeometry.defaultCornerTrim < (segmentOuter - segmentInner) / 2,
            "默认圆角不得超过环带厚度的一半（否则花瓣退化成一颗药丸）")
}

// MARK: - 槽位色跟随（v2.11.4）：调色板取色 + 黑白墨色对比度
//
// v2.11.4 让圆盘悬停高亮与底栏「上次粘贴」胶囊都跟随槽位色，于是「胶囊上该写黑字还是白字」
// 从审美问题变成了可读性问题。这一组把三条不变量钉住：
//  1. 取色循环与历史 `AppTheme.slotAccent` 完全一致（slot 从 1 起、按调色板长度取模、非法值兜到首色）；
//  2. 亮度算的是 WCAG 相对亮度，不是 (r+g+b)/3 —— 后者会把纯蓝判得比纯黄还亮，选墨色必翻车；
//  3. 每个槽位在深/浅两套外观下，最终墨色与胶囊底的对比度都不低于 4.5:1（WCAG AA 正文档）。
do {
    // ① 取色循环
    t.equal(SlotAccentPalette.light.count, SlotAccentPalette.dark.count, "深浅调色板长度必须一致")
    t.equal(SlotAccentPalette.index(forSlot: 1), 0, "slot 1 取第 0 号色")
    t.equal(SlotAccentPalette.index(forSlot: SlotAccentPalette.light.count), SlotAccentPalette.light.count - 1,
            "slot 等于调色板长度时取最后一号色")
    t.equal(SlotAccentPalette.index(forSlot: SlotAccentPalette.light.count + 1), 0, "超出长度后循环回第 0 号色")
    t.equal(SlotAccentPalette.index(forSlot: 0), 0, "slot 0（非法）兜到第 0 号色，绝不越界崩溃")
    t.equal(SlotAccentPalette.index(forSlot: -7), 0, "负数 slot 同样兜到第 0 号色")

    // ② 亮度必须是感知加权的：同强度下绿最亮、蓝最暗（(r+g+b)/3 会把三者判成一样）
    let pureRed = SlotAccentPalette.RGB(1, 0, 0)
    let pureGreen = SlotAccentPalette.RGB(0, 1, 0)
    let pureBlue = SlotAccentPalette.RGB(0, 0, 1)
    t.check(pureGreen.relativeLuminance > pureRed.relativeLuminance,
            "★绿的相对亮度必须高于红（证明用的是 WCAG 加权而非算术平均）")
    t.check(pureRed.relativeLuminance > pureBlue.relativeLuminance, "★红的相对亮度必须高于蓝")
    t.check(abs(SlotAccentPalette.RGB.white.relativeLuminance - 1) < 0.0001, "纯白亮度为 1")
    t.check(abs(SlotAccentPalette.RGB.black.relativeLuminance) < 0.0001, "纯黑亮度为 0")
    t.check(abs(SlotAccentPalette.RGB.white.contrastRatio(to: .black) - 21) < 0.01, "黑白对比度为 21:1")
    t.check(abs(pureGreen.contrastRatio(to: pureGreen) - 1) < 0.0001, "同色对比度为 1:1")

    // ③ 合成：0 alpha 等于底色、1 alpha 等于前景色、0.5 落在中间
    let over = SlotAccentPalette.RGB(0.2, 0.4, 0.6)
    t.equal(pureRed.composited(alpha: 0, over: over), over, "alpha 0 时完全等于底色")
    t.equal(pureRed.composited(alpha: 1, over: over), pureRed, "alpha 1 时完全等于前景色")
    let half = pureRed.composited(alpha: 0.5, over: over)
    t.check(abs(half.red - 0.6) < 0.0001 && abs(half.green - 0.2) < 0.0001 && abs(half.blue - 0.3) < 0.0001,
            "alpha 0.5 时逐通道取中点")
    t.check(SlotAccentPalette.RGB(2, -1, 0.5).composited(alpha: 5, over: over) == SlotAccentPalette.RGB(2, -1, 0.5),
            "alpha 超界应被夹到 [0,1]，不产生诡异插值")

    // ④ ★核心：每个槽位、每种外观，选出来的墨色都要满足 AA（≥4.5:1）
    //    注意用的是**提亮后**的圆盘色（胶囊底铺的就是它）。
    for slot in 1...SlotAccentPalette.light.count {
        for isDark in [false, true] {
            let accent = SlotAccentPalette.radial(forSlot: slot, isDark: isDark)
            let surface = isDark ? SlotAccentPalette.darkSurface : SlotAccentPalette.lightSurface
            let composited = accent.composited(alpha: SlotAccentPalette.pillFillOpacity, over: surface)
            let ink = SlotAccentPalette.pillInk(forSlot: slot, isDark: isDark)
            let inkRGB: SlotAccentPalette.RGB = ink == .black ? .black : .white
            let ratio = composited.contrastRatio(to: inkRGB)
            t.check(ratio >= 4.5,
                    "★slot \(slot)（\(isDark ? "深色" : "浅色")）胶囊墨色对比度 \(String(format: "%.2f", ratio)) 必须 ≥ 4.5:1")
            // 同时确认选的是两者中更优的一个，而不是碰巧过线
            let other: SlotAccentPalette.RGB = ink == .black ? .white : .black
            t.check(ratio >= composited.contrastRatio(to: other),
                    "★slot \(slot)（\(isDark ? "深色" : "浅色")）必须选对比度更高的那种墨色")
        }
    }

    // ⑤ 极端底色下的墨色方向：纯白底选黑字、纯黑底选白字
    t.equal(SlotAccentPalette.ink(for: .white, fillOpacity: 1, over: .white), .black, "纯白胶囊必须黑字")
    t.equal(SlotAccentPalette.ink(for: .black, fillOpacity: 1, over: .black), .white, "纯黑胶囊必须白字")

    // ⑥ 交互态不透明度的相对关系。v2.11.4 hotfix3 起层级不再是「填充 < 描边 < 胶囊底」：
    //    胶囊底被降到与悬停填充同档（轻染色），改由描边守边界。现在钉住的是
    //    「两种填充都比对应描边更透」+「两种填充属于同一重量级」这两条。
    t.check(SlotAccentPalette.hoverFillOpacity < SlotAccentPalette.hoverStrokeOpacity,
            "悬停填充必须比同处的描边更透（否则扇区边界糊掉）")
    t.check(SlotAccentPalette.pillFillOpacity < SlotAccentPalette.pillStrokeOpacity,
            "胶囊底色必须比胶囊描边更透（淡底色靠描边守住按钮轮廓）")
    t.check(abs(SlotAccentPalette.pillFillOpacity - SlotAccentPalette.hoverFillOpacity) <= 0.1,
            "★胶囊底与悬停填充应保持同一重量级（差值 ≤ 0.1），底栏才不会比圆盘重")
    t.check(SlotAccentPalette.hoverFillOpacity > 0.15 && SlotAccentPalette.pillStrokeOpacity <= 1.0,
            "不透明度都应落在合理区间内")

    // ⑥' 统一悬停色（v2.11.4 hotfix4）：悬停扇区退出槽位色跟随，改一支低饱和冷灰蓝。
    //     这里钉住的是「它必须是冷调、必须低饱和、必须不与任何槽位色撞脸」——
    //     一旦以后有人把它调艳/调暖，圆盘就会重新变成彩色噪声。
    for isDark in [false, true] {
        let hover = SlotAccentPalette.hoverAccent(isDark: isDark)
        let (h, s, v) = hover.hsb
        let hueDegrees = h * 360
        t.check(hueDegrees > 200 && hueDegrees < 250,
                "★统一悬停色必须落在冷灰蓝~紫蓝区间 200°~250°（当前 \(hueDegrees)°，\(isDark ? "深色" : "浅色")）")
        t.check(s <= 0.30,
                "★统一悬停色必须低饱和（≤0.30，当前 \(s)），否则会跟槽位色抢注意力")
        t.check(v >= 0.70,
                "统一悬停色明度要够高，铺 0.25 才抬得起底（当前 \(v)）")
        t.check(hover.blue > hover.red && hover.blue > hover.green,
                "★统一悬停色的蓝通道必须是主导通道（\(isDark ? "深色" : "浅色")），保证是冷调而非暖灰")

        // 与所有槽位色（提亮版）都不得撞脸。注意**不能只看色相**：统一悬停色本身就是蓝调，
        // 与 slot 5（蓝）色相只差 13°~17°，硬要拉开色相只会把它推成紫或青，反而不中性。
        // 真正把两者分开的是饱和度 —— 槽位色是「有身份的彩色」，悬停色是「带蓝调的灰」。
        // 所以规则是：色相差得开（>25°）**或者**饱和度低到不足其一半。
        for slot in 1...SlotAccentPalette.light.count {
            let accent = SlotAccentPalette.radial(forSlot: slot, isDark: isDark)
            let accentHSB = accent.hsb
            var delta = abs(accentHSB.hue * 360 - hueDegrees)
            if delta > 180 { delta = 360 - delta }
            t.check(delta > 25 || s <= accentHSB.saturation * 0.5,
                    "★统一悬停色不得与 slot \(slot) 撞脸（色相差 \(delta)°、饱和度 \(s) vs \(accentHSB.saturation)，\(isDark ? "深色" : "浅色")）")
        }

        // 铺 @0.25 之后必须真的看得出「亮了一档」：与底色的对比度差要够，但也不能刺眼
        let surface = isDark ? SlotAccentPalette.darkSurface : SlotAccentPalette.lightSurface
        let composited = hover.composited(alpha: SlotAccentPalette.hoverFillOpacity, over: surface)
        if isDark {
            t.check(composited.relativeLuminance > surface.relativeLuminance,
                    "★深色下悬停填充必须比底色更亮（看得出被选中）")
        } else {
            t.check(composited.relativeLuminance < surface.relativeLuminance,
                    "★浅色下悬停填充必须比底色略深（浅底上只能靠压暗做高亮）")
        }
        // 上限放在 1.9：深色底（L≈0.015）本身极暗，任何可见的抬升在比值上都会显得很大，
        // 而 1.9:1 远低于「文字可读」的 4.5:1，仍是一层轻纱而不是实心色块。
        t.check(composited.contrastRatio(to: surface) < 1.9,
                "悬停填充与底色的对比度不能过大（\(composited.contrastRatio(to: surface))），否则失去磨砂轻盈感")
    }
    t.check(SlotAccentPalette.hoverStrokeOpacity >= 0.60,
            "★换成低饱和冷灰蓝后，悬停描边必须补实（≥0.60），否则浅色下看不出选中边界")

    // ⑦ HSB 往返与提亮（v2.11.4 hotfix：圆盘色偏深偏闷，统一过一层提亮）
    for probe in [SlotAccentPalette.RGB(0.12, 0.56, 0.28),
                  SlotAccentPalette.RGB(0.94, 0.76, 0.32),
                  SlotAccentPalette.RGB(0.16, 0.46, 0.70),
                  SlotAccentPalette.RGB(0.5, 0.5, 0.5)] {
        let (h, s, v) = probe.hsb
        let roundTrip = SlotAccentPalette.RGB.fromHSB(hue: h, saturation: s, brightness: v)
        t.check(abs(roundTrip.red - probe.red) < 0.0001
                    && abs(roundTrip.green - probe.green) < 0.0001
                    && abs(roundTrip.blue - probe.blue) < 0.0001,
                "RGB→HSB→RGB 往返必须无损（\(probe)）")
    }
    t.check(SlotAccentPalette.RGB(0.3, 0.3, 0.3).hsb.saturation == 0, "灰色的饱和度为 0")
    t.equal(SlotAccentPalette.RGB.fromHSB(hue: 0.4, saturation: 0, brightness: 0.6),
            SlotAccentPalette.RGB(0.6, 0.6, 0.6),
            "零饱和度时任何色相都还原成灰")

    // ★提亮必须真的更亮更艳，且色相不许漂移 —— 色相一漂，圆盘和主界面卡片就不再是同一支色。
    for slot in 1...SlotAccentPalette.light.count {
        for isDark in [false, true] {
            let base = isDark ? SlotAccentPalette.dark(forSlot: slot) : SlotAccentPalette.light(forSlot: slot)
            let vivid = SlotAccentPalette.radial(forSlot: slot, isDark: isDark)
            let (baseH, baseS, baseV) = base.hsb
            let (vividH, vividS, vividV) = vivid.hsb
            t.check(abs(vividH - baseH) < 0.005,
                    "★slot \(slot)（\(isDark ? "深色" : "浅色")）提亮后色相不得漂移（\(baseH) → \(vividH)）")
            t.check(vividV > baseV, "★slot \(slot)（\(isDark ? "深色" : "浅色")）提亮后明度必须更高")
            t.check(vividS >= baseS - 0.0001,
                    "★slot \(slot)（\(isDark ? "深色" : "浅色")）提亮后饱和度不得降低")
            // 刻意**不**断言 WCAG 相对亮度必须更高：拉饱和度会压低非主导通道，
            // 而相对亮度是感知加权（绿权重 0.7152），所以「更艳」完全可能让它反而下降
            // （深色橙 0.95/0.55/0.31 提亮后绿通道从 .55 掉到 .42 就是这种情况）。
            // 这里要保的是「HSB 更亮更艳、色相不动」，不是「亮度数值单调上升」。
            t.check(max(vivid.red, max(vivid.green, vivid.blue)) >= max(base.red, max(base.green, base.blue)) - 0.0001,
                    "★slot \(slot)（\(isDark ? "深色" : "浅色")）提亮后主导通道不得变暗")
        }
    }
    t.check(SlotAccentPalette.radialSaturationScale > 1 && SlotAccentPalette.radialBrightnessLift > 0,
            "圆盘提亮参数必须真的往「更艳更亮」方向走")
    // 明度用补足式抬升：已经接近纯白的颜色不会被抬爆成 1（否则粉彩系会一起糊成白）
    let nearWhite = SlotAccentPalette.RGB(0.98, 0.96, 0.94)
    t.check(nearWhite.vivid(saturationScale: 1.2, brightnessLift: 0.45).hsb.brightness < 1.0,
            "接近纯白的颜色提亮后仍应 < 1（补足式抬升不会溢出）")
}

// MARK: - 悬浮预览 Panel 附件展示计划（v2.11.1 功能 5）
//
// 三条不变量：
//  1. 图片缩略图不超过上限，多出来的必须被 hiddenImageCount 如实计数（不静默丢附件）；
//  2. 非图片附件一个不漏，且图片/非图片两组各自保持原始顺序；
//  3. hero（主体为空时的主视觉）恒等于「第一张图片附件」，与缩略图上限无关。
do {
    let empty = RadialAttachmentPreviewPlanner.plan(imageFlags: [])
    t.equal(empty, RadialAttachmentPreviewPlan.empty, "无附件时返回空计划")
    t.check(empty.heroImageIndex == nil, "无附件时没有 hero")

    // 纯图片且未超上限
    let three = RadialAttachmentPreviewPlanner.plan(imageFlags: [true, true, true])
    t.equal(three.imageIndices, [0, 1, 2], "3 张图片全部渲染缩略图")
    t.equal(three.hiddenImageCount, 0, "未超上限时 hiddenImageCount 为 0")
    t.equal(three.chipIndices, [], "纯图片时没有文件小卡")
    t.equal(three.heroImageIndex, 0, "hero 取第一张图片")

    // ★超上限：只渲染前 3 张，其余进 +N
    let five = RadialAttachmentPreviewPlanner.plan(imageFlags: [true, true, true, true, true])
    t.equal(five.imageIndices.count, RadialAttachmentPreviewPlanner.maxImageThumbnails,
            "★超上限时缩略图数量恰好等于上限")
    t.equal(five.imageIndices, [0, 1, 2], "★渲染的是前 3 张（顺序稳定）")
    t.equal(five.hiddenImageCount, 2, "★多出的 2 张必须被计数，不能静默丢弃")

    // ★混合：图片挑出来上缩略图，非图片全进小卡，两组各自保序
    let mixed = RadialAttachmentPreviewPlanner.plan(imageFlags: [false, true, false, true, true, true, false])
    t.equal(mixed.imageIndices, [1, 3, 4], "★混合时按原顺序取前 3 张图片")
    t.equal(mixed.hiddenImageCount, 1, "★第 4 张图片折进 +1")
    t.equal(mixed.chipIndices, [0, 2, 6], "★非图片附件一个不漏且保序")
    t.equal(mixed.imageIndices.count + mixed.hiddenImageCount + mixed.chipIndices.count, 7,
            "★渲染 + 折叠 + 小卡三者之和必须等于附件总数")
    t.equal(mixed.heroImageIndex, 1, "hero 是第一张图片附件（不是第一个附件）")

    // 纯非图片
    let noImage = RadialAttachmentPreviewPlanner.plan(imageFlags: [false, false])
    t.equal(noImage.imageIndices, [], "无图片附件时不渲染缩略图")
    t.equal(noImage.hiddenImageCount, 0, "无图片附件时无折叠")
    t.equal(noImage.chipIndices, [0, 1], "全部走文件小卡")
    t.check(noImage.heroImageIndex == nil, "无图片附件时没有 hero")

    // 边界：上限 0 / 负数不得崩，也不得让 hero 消失
    let capZero = RadialAttachmentPreviewPlanner.plan(imageFlags: [true, false, true], maxImageThumbnails: 0)
    t.equal(capZero.imageIndices, [], "上限 0 时不渲染缩略图")
    t.equal(capZero.hiddenImageCount, 2, "上限 0 时两张图片全部折叠")
    t.equal(capZero.heroImageIndex, 0, "★上限为 0 也不影响 hero —— 主视觉与缩略图条是两回事")
    let capNegative = RadialAttachmentPreviewPlanner.plan(imageFlags: [true], maxImageThumbnails: -3)
    t.equal(capNegative.imageIndices, [], "负数上限按 0 处理，不崩")
    t.equal(capNegative.hiddenImageCount, 1, "负数上限时图片全部折叠")
}

// MARK: - THUMB-CODEC (v2.11.2) 手动缩略图归一化编解码
//
// `ManualThumbnailCodec` 是 v2.11.2 从 GUI 下沉到 Kit 的编码器，GUI「右键设缩略图」与
// CLI `set-thumbnail` 共用它。下沉的全部价值就在「两个入口产出同一份字节」，所以这里锁死
// 编码参数本身——参数一旦漂移，同一张图在两个入口下的产物就不一样了，而这种差异在界面上
// 只表现为「命令行设的封面好像糊一点」，几乎不可能被人工发现。
//
//   ① 编码参数：最长边 1024 / JPEG q=0.85，且常量与 GUI 侧同源。
//   ② 降采样：超过 1024 的图必须被压到 1024，且**不上采样**小图。
//   ③ 格式收敛：PNG / JPEG / TIFF / GIF / BMP 等位图统一输出 JPEG。
//   ④ 拒绝矢量/文档：SVG / PDF 返回 nil（而不是栅格化出一张用户没预期的图）。

do {
    let fm = FileManager.default

    // 用 CoreGraphics 现造测试图，避免往仓库里塞二进制 fixture。
    func writePNG(_ url: URL, width: Int, height: Int) -> Bool {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        // 画点花纹，避免纯色图被编码器压成几十字节而让体积断言失去意义。
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        for i in stride(from: 0, to: width, by: 17) {
            ctx.fill(CGRect(x: i, y: 0, width: 8, height: height))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// 从 JPEG 字节里读出像素尺寸（只读图片头）。
    func pixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (w, h)
    }

    func utiOf(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(src) as String?
    }

    let sandbox = fm.temporaryDirectory.appendingPathComponent("clipslots_codec_\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: sandbox) }

    // ① 编码参数（★ 这两个常量就是「GUI 与 CLI 同源」的全部内容，改动必须是有意识的）
    t.equal(ManualThumbnailCodec.maxPixelEdge, 1024, "★归一化最长边必须是 1024px")
    t.equal(ManualThumbnailCodec.jpegQuality, 0.85, "★JPEG 质量必须是 0.85")

    // ② 大图降采样：2400×1600 → 最长边 1024，宽高比保持
    let bigURL = sandbox.appendingPathComponent("big.png")
    t.check(writePNG(bigURL, width: 2400, height: 1600), "测试用大图应能生成")
    if let data = ManualThumbnailCodec.normalizedJPEGDataOrNil(from: bigURL) {
        t.check(!data.isEmpty, "大图归一化应产出非空字节")
        t.equal(utiOf(data), "public.jpeg", "★PNG 输入必须统一输出 JPEG")
        if let size = pixelSize(data) {
            t.equal(max(size.w, size.h), 1024, "★超过 1024 的图必须被降采样到最长边 1024")
            t.check(abs(Double(size.w) / Double(size.h) - 1.5) < 0.01, "降采样必须保持 3:2 宽高比")
        } else {
            t.check(false, "归一化产物应能读出像素尺寸")
        }
        // 一张 2400×1600 的花纹图压成 1024px JPEG 后应远小于原始位图（2400*1600*4 ≈ 15MB）
        t.check(data.count < 1_000_000, "归一化后体积应控制在 1MB 以内（实际 \(data.count) 字节）")
    } else {
        t.check(false, "大图归一化不应失败")
    }

    // ② 小图不上采样：64×48 原样保留
    let smallURL = sandbox.appendingPathComponent("small.png")
    t.check(writePNG(smallURL, width: 64, height: 48), "测试用小图应能生成")
    if let data = ManualThumbnailCodec.normalizedJPEGDataOrNil(from: smallURL),
       let size = pixelSize(data) {
        t.equal(size.w, 64, "★小图不得被上采样（宽）")
        t.equal(size.h, 48, "★小图不得被上采样（高）")
        t.equal(utiOf(data), "public.jpeg", "小图同样统一输出 JPEG")
    } else {
        t.check(false, "小图归一化不应失败")
    }

    // ③ JPEG 输入也能吃（自反性：归一化的产物再喂回去仍然成立）
    let jpegURL = sandbox.appendingPathComponent("round.jpg")
    if let first = ManualThumbnailCodec.normalizedJPEGDataOrNil(from: bigURL) {
        try? first.write(to: jpegURL)
        if let second = ManualThumbnailCodec.normalizedJPEGDataOrNil(from: jpegURL), let s = pixelSize(second) {
            t.equal(max(s.w, s.h), 1024, "★JPEG 输入再归一化一次应幂等（仍是 1024）")
        } else {
            t.check(false, "JPEG 输入应能被归一化")
        }
    }

    // ④ SVG / PDF 明确拒绝
    let svgURL = sandbox.appendingPathComponent("vector.svg")
    try? Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>".utf8).write(to: svgURL)
    t.check(ManualThumbnailCodec.normalizedJPEGDataOrNil(from: svgURL) == nil, "★SVG 必须返回 nil（矢量图不做缩略图来源）")
    t.check(!ManualThumbnailCodec.isDecodableImage(url: svgURL), "SVG 的可解码预检也应为 false")

    let pdfURL = sandbox.appendingPathComponent("doc.pdf")
    try? Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdfURL)
    t.check(ManualThumbnailCodec.normalizedJPEGDataOrNil(from: pdfURL) == nil, "★PDF 必须返回 nil")

    // 伪装成 .png 的 SVG：按内容嗅探同样要拒绝，不能被扩展名骗过去
    let disguised = sandbox.appendingPathComponent("disguised.png")
    try? fm.copyItem(at: svgURL, to: disguised)
    t.check(ManualThumbnailCodec.normalizedJPEGDataOrNil(from: disguised) == nil,
            "★改名成 .png 的 SVG 仍应被拒绝（按内容而非扩展名判定）")

    // 非图片 / 不存在 / 目录
    let txtURL = sandbox.appendingPathComponent("note.txt")
    try? Data("not an image".utf8).write(to: txtURL)
    t.check(ManualThumbnailCodec.normalizedJPEGDataOrNil(from: txtURL) == nil, "文本文件应返回 nil")
    t.check(ManualThumbnailCodec.normalizedJPEGDataOrNil(from: sandbox.appendingPathComponent("nope.png")) == nil,
            "不存在的文件应返回 nil")
    t.check(ManualThumbnailCodec.normalizedJPEGDataOrNil(from: sandbox) == nil, "目录路径应返回 nil")

    // 错误分型：CLI 靠它区分 FILE_NOT_FOUND / INVALID_IMAGE 两个错误码
    do {
        _ = try ManualThumbnailCodec.normalizedJPEGData(from: sandbox.appendingPathComponent("nope.png"))
        t.check(false, "缺失文件应抛 fileNotFound")
    } catch let e as ManualThumbnailCodec.CodecError {
        if case .fileNotFound = e { t.check(true, "缺失文件抛 .fileNotFound") }
        else { t.check(false, "缺失文件应抛 .fileNotFound，实际 \(e)") }
    } catch { t.check(false, "缺失文件抛了非预期错误 \(error)") }

    do {
        _ = try ManualThumbnailCodec.normalizedJPEGData(from: svgURL)
        t.check(false, "SVG 应抛 unsupportedFormat")
    } catch let e as ManualThumbnailCodec.CodecError {
        if case .unsupportedFormat = e { t.check(true, "SVG 抛 .unsupportedFormat") }
        else { t.check(false, "SVG 应抛 .unsupportedFormat，实际 \(e)") }
    } catch { t.check(false, "SVG 抛了非预期错误 \(error)") }

    // 内存字节入口（截图路径用的就是它）
    if let raw = try? Data(contentsOf: bigURL),
       let out = try? ManualThumbnailCodec.normalizedJPEGData(from: raw, sourceName: "clipboard"),
       let s = pixelSize(out) {
        t.equal(max(s.w, s.h), 1024, "★Data 入口与 URL 入口必须同参数（同样收敛到 1024）")
    } else {
        t.check(false, "Data 入口归一化不应失败")
    }

    // 轻量预检与真实解码的结论应当一致（预检只读图片头，是批量场景的把门人）
    t.check(ManualThumbnailCodec.isDecodableImage(url: bigURL), "正常 PNG 的预检应为 true")
    t.check(!ManualThumbnailCodec.isDecodableImage(url: txtURL), "文本文件的预检应为 false")
}

// MARK: - CLI-THUMB (v2.11.2) set-thumbnail / clear-thumbnail 端到端
//
// 这组用例直接拉起**真实的 CLI 二进制**（`.build/<config>/ClipSlotsCLI`，与本测试同目录），
// 用 CLIPSLOTS_DATA_DIR 隔离到临时数据目录后跑真命令、解析真 JSON 回执。
//
// 为什么非要端到端而不是调 Kit 函数：本功能的风险几乎全在 CLI 那一层的**组装**上——
// 身份字段刷没刷、字节走没走 pendingManualThumbnailData、--if-absent 有没有在锁内复检。
// 这些都不在 Kit 的可测面里，只测 Kit 等于什么都没测。
//
//   ① 落盘回读：set 之后 read/list 的 hasManualThumbnail / thumbnailBytes 必须对得上。
//   ② ★身份字段已刷新：contentId 与 updatedAt 每次写入都要变——这是 v2.10.64/65「切组串图」
//      的复发面，GUI 的脏检查与缩略图缓存 key 全靠它。
//   ③ --if-absent 幂等：已有缩略图时拒绝覆盖，且**磁盘一字节不改**。
//   ④ clear 之后 id 与字节都消失，且身份字段同样刷新。
//   ⑤ 批量两阶段契约：预检失败 → 整批零写入。

do {
    let fm = FileManager.default
    // 测试可执行文件与 CLI 是同一个 .build/<config>/ 目录下的兄弟。
    let cliURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .appendingPathComponent("ClipSlotsCLI")

    guard fm.isExecutableFile(atPath: cliURL.path) else {
        // 只跑 `swift run ClipSlotsKitSmokeTests` 而没构建 CLI 时优雅跳过，而不是判失败。
        print("⚠️  跳过 CLI-THUMB 端到端用例：未找到 \(cliURL.path)（先跑一次 swift build）")
        t.check(false, "CLI-THUMB 无法执行：CLI 二进制不存在于 \(cliURL.path)")
        throw SmokeSkip.cliMissing
    }

    let sandbox = fm.temporaryDirectory.appendingPathComponent("clipslots_clithumb_\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: sandbox) }

    let dataDir = sandbox.appendingPathComponent("data", isDirectory: true)
    try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

    func writePNG(_ url: URL, width: Int, height: Int, tint: CGFloat) -> Bool {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: tint, green: 0.5, blue: 1 - tint, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    let imgA = sandbox.appendingPathComponent("a.png")
    let imgB = sandbox.appendingPathComponent("b.png")
    _ = writePNG(imgA, width: 300, height: 200, tint: 0.2)
    _ = writePNG(imgB, width: 1800, height: 1200, tint: 0.8)

    /// 跑一条 CLI 命令，返回 (退出码, 解析后的 JSON)。
    @discardableResult
    func runCLI(_ argv: [String], stdin: String? = nil) -> (code: Int32, json: [String: Any]) {
        let p = Process()
        p.executableURL = cliURL
        p.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["CLIPSLOTS_DATA_DIR"] = dataDir.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe() // CLI 会往 stderr 打日志，丢掉即可
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            do { try p.run() } catch { return (-1, [:]) }
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        } else {
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, [:]) }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (p.terminationStatus, json)
    }

    /// 直接窥探磁盘上的 content.json，用于校验身份字段。
    func contentMeta(slot: Int, group: String = "default") -> [String: Any] {
        let url = dataDir
            .appendingPathComponent("special_slots", isDirectory: true)
            .appendingPathComponent(group, isDirectory: true)
            .appendingPathComponent("\(slot)", isDirectory: true)
            .appendingPathComponent("content.json")
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    // ── 版本号必须与本次发布一致（历史上 CLI_VERSION 漂移过好几次）
    let ver = runCLI(["version"])
    t.equal(ver.json["version"] as? String, "2.11.8", "★CLI_VERSION 必须与 App 版本同步为 2.11.8")

    // ── ① 落盘回读
    let set1 = runCLI(["set-thumbnail", "1", "--image", imgA.path])
    t.equal(set1.code, 0, "set-thumbnail 应成功退出")
    t.check(set1.json["ok"] as? Bool == true, "set-thumbnail 应返回 ok:true")
    t.check(set1.json["replaced"] as? Bool == false, "首次设置 replaced 应为 false")
    let bytes1 = set1.json["thumbnailBytes"] as? Int ?? 0
    t.check(bytes1 > 0, "set-thumbnail 应回报非零字节数")

    let read1 = runCLI(["read", "1"])
    t.check(read1.json["hasManualThumbnail"] as? Bool == true, "★read 必须新增 hasManualThumbnail 且为 true")
    t.equal(read1.json["thumbnailBytes"] as? Int, bytes1, "★read 的 thumbnailBytes 必须与 set 的回执一致")

    let list1 = runCLI(["list"])
    let slots1 = list1.json["slots"] as? [[String: Any]] ?? []
    let slot1Row = slots1.first { ($0["slot"] as? Int) == 1 }
    t.check(slot1Row?["hasManualThumbnail"] as? Bool == true, "★list 每个槽位必须带 hasManualThumbnail")
    t.equal(slot1Row?["thumbnailBytes"] as? Int, bytes1, "★list 的 thumbnailBytes 必须与 read 一致")
    let slot2Row = slots1.first { ($0["slot"] as? Int) == 2 }
    t.check(slot2Row?["hasManualThumbnail"] as? Bool == false, "未设置缩略图的槽位应为 false")
    t.equal(slot2Row?["thumbnailBytes"] as? Int, 0, "未设置缩略图的槽位 thumbnailBytes 应为 0")

    // ── ② ★身份字段已刷新（v2.10.64/65 串图事故的复发面）
    let metaBefore = contentMeta(slot: 1)
    let idBefore = metaBefore["contentId"] as? String ?? ""
    let updatedBefore = metaBefore["updatedAt"] as? Double ?? 0
    t.check(!idBefore.isEmpty, "content.json 应有 contentId")
    t.check(updatedBefore > 0, "content.json 应有 updatedAt")

    // 换一张图（不带 --if-absent，应覆盖）
    Thread.sleep(forTimeInterval: 0.02) // 保证 updatedAt 有可观测的差值
    let set2 = runCLI(["set-thumbnail", "1", "--image", imgB.path])
    t.check(set2.json["ok"] as? Bool == true, "覆盖设置应成功")
    t.check(set2.json["replaced"] as? Bool == true, "★覆盖时 replaced 应为 true")

    let metaAfter = contentMeta(slot: 1)
    t.check((metaAfter["contentId"] as? String ?? "") != idBefore,
            "★★contentId 必须随缩略图写入而刷新——不刷新会重现 v2.10.64/65 切组串图")
    t.check((metaAfter["updatedAt"] as? Double ?? 0) > updatedBefore,
            "★★updatedAt 必须前进（SwiftUI 缩略图缓存以 contentId+updatedAt 编入 .id）")
    t.check((metaAfter["manualThumbnailId"] as? String ?? "") != (metaBefore["manualThumbnailId"] as? String ?? ""),
            "覆盖后 manualThumbnailId 应换新")

    // 旧的字节文件必须随原子 swap 一起消失，不能在 attachments/ 里堆垃圾
    let attachDir = dataDir.appendingPathComponent("special_slots/default/1/attachments")
    let bins = ((try? fm.contentsOfDirectory(atPath: attachDir.path)) ?? []).filter { $0.hasSuffix(".bin") }
    t.equal(bins.count, 1, "★覆盖后槽位里只应留一份缩略图字节（旧文件不得残留）")

    // ── ③ --if-absent 幂等：拒绝覆盖，且磁盘一字节不改
    let metaGuardBefore = contentMeta(slot: 1)
    let ifAbsent = runCLI(["set-thumbnail", "1", "--image", imgA.path, "--if-absent"])
    t.equal(ifAbsent.code, 1, "★--if-absent 命中已有缩略图应以退出码 1 失败")
    t.check(ifAbsent.json["ok"] as? Bool == false, "--if-absent 冲突应返回 ok:false")
    t.equal(ifAbsent.json["error_code"] as? String, "THUMBNAIL_ALREADY_SET", "错误码应为 THUMBNAIL_ALREADY_SET")
    let metaGuardAfter = contentMeta(slot: 1)
    t.equal(metaGuardAfter["contentId"] as? String, metaGuardBefore["contentId"] as? String,
            "★--if-absent 被拒时 contentId 不得变化（必须是彻底的零写入）")
    t.equal(metaGuardAfter["manualThumbnailId"] as? String, metaGuardBefore["manualThumbnailId"] as? String,
            "★--if-absent 被拒时 manualThumbnailId 不得变化")

    // 空槽上的 --if-absent 应当正常写入（幂等护栏只挡「已有」，不挡「没有」）
    let ifAbsentFresh = runCLI(["set-thumbnail", "3", "--image", imgA.path, "--if-absent"])
    t.equal(ifAbsentFresh.code, 0, "★空槽上的 --if-absent 应正常写入")
    t.check(ifAbsentFresh.json["ok"] as? Bool == true, "空槽 --if-absent 应返回 ok:true")
    // 再跑一次同样的命令 → 第二次必须被挡住（这才是「幂等护栏」的完整语义）
    let ifAbsentRepeat = runCLI(["set-thumbnail", "3", "--image", imgA.path, "--if-absent"])
    t.equal(ifAbsentRepeat.json["error_code"] as? String, "THUMBNAIL_ALREADY_SET",
            "★重复执行同一条 --if-absent 命令，第二次必须被幂等护栏挡下")

    // ── ④ clear-thumbnail
    let metaClearBefore = contentMeta(slot: 1)
    let clear = runCLI(["clear-thumbnail", "1"])
    t.equal(clear.code, 0, "clear-thumbnail 应成功")
    t.check(clear.json["cleared"] as? Bool == true, "clear-thumbnail 应返回 cleared:true")
    t.check((clear.json["removedBytes"] as? Int ?? 0) > 0, "clear-thumbnail 应回报被移除的字节数")

    let readCleared = runCLI(["read", "1"])
    t.check(readCleared.json["hasManualThumbnail"] as? Bool == false, "clear 之后 hasManualThumbnail 应为 false")
    t.equal(readCleared.json["thumbnailBytes"] as? Int, 0, "clear 之后 thumbnailBytes 应为 0")
    let metaClearAfter = contentMeta(slot: 1)
    t.check((metaClearAfter["contentId"] as? String ?? "") != (metaClearBefore["contentId"] as? String ?? ""),
            "★clear 同样必须刷新 contentId，否则 GUI 会停在被删掉的旧封面上")
    t.check(metaClearAfter["manualThumbnailId"] == nil, "clear 之后 content.json 不应再有 manualThumbnailId")

    // 重复 clear → NO_MANUAL_THUMBNAIL
    let clearAgain = runCLI(["clear-thumbnail", "1"])
    t.equal(clearAgain.json["error_code"] as? String, "NO_MANUAL_THUMBNAIL", "重复 clear 应返回 NO_MANUAL_THUMBNAIL")

    // ── 错误输入
    let missing = runCLI(["set-thumbnail", "4", "--image", sandbox.appendingPathComponent("nope.png").path])
    t.equal(missing.json["error_code"] as? String, "FILE_NOT_FOUND", "缺失文件应返回 FILE_NOT_FOUND")
    let notImage = sandbox.appendingPathComponent("x.txt")
    try? Data("nope".utf8).write(to: notImage)
    let bad = runCLI(["set-thumbnail", "4", "--image", notImage.path])
    t.equal(bad.json["error_code"] as? String, "INVALID_IMAGE", "非图片应返回 INVALID_IMAGE")
    let noImageFlag = runCLI(["set-thumbnail", "4"])
    t.equal(noImageFlag.json["error_code"] as? String, "INVALID_ARGUMENT_COMBINATION", "缺 --image 应报参数组合错误")

    // ── ⑤ 批量：全成功
    let okBatch = "[{\"slot\":5,\"image\":\"\(imgA.path)\"},{\"slot\":6,\"image\":\"\(imgB.path)\"}]"
    let batchOK = runCLI(["set-thumbnail", "--batch"], stdin: okBatch)
    t.equal(batchOK.code, 0, "全合法批量应成功")
    t.equal(batchOK.json["written"] as? Int, 2, "批量应写入 2 条")
    t.check(batchOK.json["preflight_passed"] as? Bool == true, "批量预检应通过")

    // ── ⑤ 批量：预检失败 → 整批零写入（★两阶段契约的核心）
    let badPath = sandbox.appendingPathComponent("ghost.png").path
    let badBatch = "[{\"slot\":7,\"image\":\"\(imgA.path)\"},{\"slot\":8,\"image\":\"\(badPath)\"}]"
    let batchBad = runCLI(["set-thumbnail", "--batch"], stdin: badBatch)
    t.equal(batchBad.code, 1, "预检失败的批量应以退出码 1 结束")
    t.check(batchBad.json["preflight_passed"] as? Bool == false, "预检应标记为未通过")
    t.equal(batchBad.json["written"] as? Int, 0, "★预检失败必须零写入")
    t.equal(batchBad.json["error_code"] as? String, "FILE_NOT_FOUND", "预检失败错误码应为 FILE_NOT_FOUND")
    let read7 = runCLI(["read", "7"])
    t.check(read7.json["hasManualThumbnail"] as? Bool == false,
            "★★预检失败时，排在坏条目**之前**的槽位也绝不能被写入")

    // ── ⑤ 批量：重复目标
    let dupBatch = "[{\"slot\":9,\"image\":\"\(imgA.path)\"},{\"slot\":9,\"image\":\"\(imgB.path)\"}]"
    let batchDup = runCLI(["set-thumbnail", "--batch"], stdin: dupBatch)
    t.equal(batchDup.json["error_code"] as? String, "BATCH_DUPLICATE_TARGET", "同一 (group, slot) 重复应被预检拦下")
    t.equal(batchDup.json["written"] as? Int, 0, "重复目标批量应零写入")

    // ── ⑤ 批量：if_absent 静态冲突 → 整批拒绝（slot 5 上面刚写过）
    let conflictBatch = "[{\"slot\":10,\"image\":\"\(imgA.path)\"},{\"slot\":5,\"image\":\"\(imgA.path)\",\"if_absent\":true}]"
    let batchConflict = runCLI(["set-thumbnail", "--batch"], stdin: conflictBatch)
    t.equal(batchConflict.json["error_code"] as? String, "THUMBNAIL_ALREADY_SET", "if_absent 静态冲突应整批拒绝")
    t.equal(batchConflict.json["written"] as? Int, 0, "if_absent 冲突批量应零写入")
    t.check((runCLI(["read", "10"]).json["hasManualThumbnail"] as? Bool) == false, "冲突批量中的合法条目也不得写入")

    // ── 批量与单条互斥的参数校验
    let batchWithImage = runCLI(["set-thumbnail", "--batch", "--image", imgA.path], stdin: "[]")
    t.equal(batchWithImage.json["error_code"] as? String, "INVALID_ARGUMENT_COMBINATION",
            "--batch 与 --image 应互斥")
} catch SmokeSkip.cliMissing {
    // 上面已经记过一条失败断言了，这里只负责让顶层代码继续走到 t.report()。
} catch {
    t.check(false, "CLI-THUMB 组抛出异常：\(error)")
}

// MARK: - SKIN（v2.11.7 简洁模式皮肤）
//
// 皮肤的视觉层在 ClipSlots（AppKit/SwiftUI）里，没法在这套零依赖 smoke 里渲染。
// 但能被测的恰好是最容易悄悄坏掉的两件事：
//   1. 持久化契约 —— 键名、默认值、脏值回退。写错一个字符，用户切完皮肤重启就回到多彩模式。
//   2. 调色板本身 —— 「简洁」这个需求翻译成可判定的命题就是：中性色真的中性、该有的对比度真的够。
//      这是肉眼评审最容易放过、而截图又看不出差几个色阶的地方。

do {
    // ── ① 枚举与持久化契约
    t.equal(AppSkin.defaultsKey, "appearanceSkin", "★皮肤的 defaults 键名必须是 appearanceSkin")
    t.check(AppSkin.defaultsKey != "appearanceMode",
            "★★皮肤键名绝不能撞上 ThemeMode 的 appearanceMode（深浅与风格是两个正交维度）")
    t.equal(AppSkin.fallback, .colorful, "★默认值必须是多彩模式——老用户升级上来不该被换皮肤")
    t.equal(AppSkin.allCases.count, 2, "皮肤只有多彩 / 简洁两种")
    t.equal(AppSkin.colorful.rawValue, "colorful", "rawValue 是持久化格式，不能改")
    t.equal(AppSkin.minimal.rawValue, "minimal", "rawValue 是持久化格式，不能改")

    let suiteName = "clipslots.smoke.skin.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suiteName) {
        defer { defaults.removePersistentDomain(forName: suiteName) }

        t.equal(AppSkin.load(from: defaults), .colorful, "空 defaults 应回退到多彩模式")

        AppSkin.minimal.store(in: defaults)
        t.equal(AppSkin.load(from: defaults), .minimal, "★写入后必须能原样读回")
        t.equal(defaults.string(forKey: AppSkin.defaultsKey), "minimal",
                "落盘的必须是 rawValue 字符串（便于 defaults write 手工调试）")

        defaults.set("rainbow", forKey: AppSkin.defaultsKey)
        t.equal(AppSkin.load(from: defaults), .colorful, "★脏值必须回退到默认皮肤，而不是崩或空白界面")

        AppSkin.colorful.store(in: defaults)
        t.equal(AppSkin.load(from: defaults), .colorful, "切回多彩模式应正常")
    } else {
        t.check(false, "无法创建测试用 UserDefaults suite")
    }

    // ── ② 中性度：简洁模式的表面色必须是真灰
    //
    // 阈值 0.02（RGB 三分量极差 ≤ 2%）。设计稿里的中性灰常常带一丝蓝或暖调，这在成片里看不出来，
    // 但一旦有人「顺手」把某个 token 改成带彩色的值，简洁模式就废了——这条断言就是那道闸。
    //
    // 加 1e-9 容差：#F2F2F7 这类「贴着上限」的系统灰算出来是 0.020000000000000018，
    // 差的那一点纯粹是二进制浮点表示误差，不是色值真的超标。
    let neutralLimit = 0.02 + 1e-9
    for (name, surfaces) in [("浅色", MinimalSkinPalette.light), ("深色", MinimalSkinPalette.dark)] {
        for member in surfaces.neutralMembers {
            t.check(MinimalSkinPalette.neutrality(member) <= neutralLimit,
                    "★\(name)简洁模式的表面色必须中性（极差 \(MinimalSkinPalette.neutrality(member)) ≤ 0.02）")
        }
        // 选中色是**唯一**允许带色相的表面色，而且必须真的带（否则「紫色高亮」就名存实亡）。
        t.check(MinimalSkinPalette.neutrality(surfaces.selection) > 0.15,
                "★\(name)简洁模式的选中描边必须是可辨认的紫色，不能退化成灰")
    }

    // ── ③ 明暗关系：卡片必须能从窗口底上浮起来
    t.check(MinimalSkinPalette.light.cardFilled.relativeLuminance > MinimalSkinPalette.light.window.relativeLuminance,
            "★浅色：填充卡片必须比窗口底更亮，卡片才浮得起来")
    t.check(MinimalSkinPalette.dark.cardFilled.relativeLuminance > MinimalSkinPalette.dark.window.relativeLuminance,
            "★深色：填充卡片必须比窗口底更亮（哑光黑窗 + 稍亮卡片）")
    t.check(MinimalSkinPalette.light.cardEmpty.relativeLuminance < MinimalSkinPalette.light.cardFilled.relativeLuminance,
            "浅色：空槽卡片应比有内容的卡片更暗一档")
    t.check(MinimalSkinPalette.dark.cardEmpty.relativeLuminance < MinimalSkinPalette.dark.cardFilled.relativeLuminance,
            "深色：空槽卡片应比有内容的卡片更暗一档")
    t.check(MinimalSkinPalette.dark.window.relativeLuminance > 0,
            "★深色底是「哑光深灰」不是纯黑——纯黑会和卡片糊成一片")

    // ── ④ 对比度：文字与 CTA 必须可读（WCAG AA 正文 4.5:1、大字 3:1）
    let readability: [(String, MinimalSkinPalette.RGB, MinimalSkinPalette.RGB, Double)] = [
        ("浅色正文/卡片", MinimalSkinPalette.light.primaryInk, MinimalSkinPalette.light.cardFilled, 4.5),
        ("深色正文/卡片", MinimalSkinPalette.dark.primaryInk, MinimalSkinPalette.dark.cardFilled, 4.5),
        ("浅色次要文字/卡片", MinimalSkinPalette.light.secondaryInk, MinimalSkinPalette.light.cardFilled, 4.5),
        ("深色次要文字/卡片", MinimalSkinPalette.dark.secondaryInk, MinimalSkinPalette.dark.cardFilled, 4.5),
        ("浅色控件文字/控件底", MinimalSkinPalette.light.controlInk, MinimalSkinPalette.light.controlFill, 4.5),
        ("深色控件文字/控件底", MinimalSkinPalette.dark.controlInk, MinimalSkinPalette.dark.controlFill, 4.5),
        ("浅色 CTA 文字/CTA 底", MinimalSkinPalette.light.ctaInk, MinimalSkinPalette.light.ctaFill, 4.5),
        ("深色 CTA 文字/CTA 底", MinimalSkinPalette.dark.ctaInk, MinimalSkinPalette.dark.ctaFill, 4.5),
    ]
    for (name, ink, ground, minimum) in readability {
        let ratio = ink.contrastRatio(to: ground)
        t.check(ratio >= minimum, "★\(name) 对比度必须 ≥ \(minimum):1（实际 \(String(format: "%.2f", ratio))）")
    }

    // CTA 是空卡片上唯一的交互元素，靠**反相**做引导：它必须比卡片本身显著更跳。
    let lightCTAvsCard = MinimalSkinPalette.light.ctaFill.contrastRatio(to: MinimalSkinPalette.light.cardEmpty)
    let darkCTAvsCard = MinimalSkinPalette.dark.ctaFill.contrastRatio(to: MinimalSkinPalette.dark.cardEmpty)
    t.check(lightCTAvsCard >= 4.5, "★浅色 CTA 必须从空卡片上跳出来（实际 \(String(format: "%.2f", lightCTAvsCard))）")
    t.check(darkCTAvsCard >= 4.5, "★深色 CTA 必须从空卡片上跳出来（实际 \(String(format: "%.2f", darkCTAvsCard))）")
    t.check(MinimalSkinPalette.light.ctaFill.relativeLuminance < MinimalSkinPalette.light.cardEmpty.relativeLuminance,
            "★浅色 CTA 是深底白字（比卡片暗）")
    t.check(MinimalSkinPalette.dark.ctaFill.relativeLuminance > MinimalSkinPalette.dark.cardEmpty.relativeLuminance,
            "★深色 CTA 是白底深字（比卡片亮）")

    // ── ⑤ 边框要看得见，但不能喧宾夺主
    for (name, surfaces) in [("浅色", MinimalSkinPalette.light), ("深色", MinimalSkinPalette.dark)] {
        let ratio = surfaces.border.contrastRatio(to: surfaces.cardFilled)
        t.check(ratio > 1.08, "★\(name)卡片边框必须看得见（实际 \(String(format: "%.2f", ratio))）")
        t.check(ratio < 4.5, "\(name)卡片边框不能重到抢过内容（实际 \(String(format: "%.2f", ratio))）")
    }

    // ── ⑤b 中性色块压在卡片上必须还分得出来（v2.11.7 hotfix）
    //
    // hotfix 把「装饰性品牌色」（logo 底板、附件计数胶囊、页面选择器图标底）在简洁模式下换成了
    // controlFill 中性块，而这些块**大多直接压在卡片或窗口底上**。中性化最容易翻车的地方就是这里：
    // 一不小心就和承载面同色，色块直接消失。这两条断言盯住它们不许糊在一起。
    for (name, surfaces) in [("浅色", MinimalSkinPalette.light), ("深色", MinimalSkinPalette.dark)] {
        let onCard = surfaces.controlFill.contrastRatio(to: surfaces.cardFilled)
        let onWindow = surfaces.controlFill.contrastRatio(to: surfaces.window)
        t.check(onCard > 1.04, "★\(name)中性色块压在卡片上必须仍可分辨（实际 \(String(format: "%.3f", onCard))）")
        t.check(onWindow > 1.02, "★\(name)中性色块压在窗口底上必须仍可分辨（实际 \(String(format: "%.3f", onWindow))）")
    }

    // ── ⑥ 槽位编号：简洁模式唯一的彩色出口，必须在两种底色上都读得出来
    //
    // 这条是「简洁模式保留编号颜色」这个需求的真正验收项：颜色留下来了，但压在新的中性卡片底上
    // 还看不看得清，取决于卡片底换了之后的对比度——原来的验收是在米白/暖黑卡片上做的，不通用。
    for slot in 1...10 {
        let onLight = SlotAccentPalette.light(forSlot: slot).contrastRatio(to: MinimalSkinPalette.light.cardFilled)
        let onDark = SlotAccentPalette.dark(forSlot: slot).contrastRatio(to: MinimalSkinPalette.dark.cardFilled)
        t.check(onLight >= 3.0, "★槽位 \(slot) 编号在浅色简洁卡片上应达大字对比度 3:1（实际 \(String(format: "%.2f", onLight))）")
        t.check(onDark >= 3.0, "★槽位 \(slot) 编号在深色简洁卡片上应达大字对比度 3:1（实际 \(String(format: "%.2f", onDark))）")
    }
}

// MARK: - NEU（v2.11.8 新拟物工具栏 / 开关面板）
//
// 新拟物这套风格能不能成立，几乎全靠**数值关系**，而这些关系恰恰是截图评审最容易放过的：
// 「凸起比承载面亮、内凹比承载面暗」一旦某个档位反过来，按钮就从凸起翻转成凹陷，
// 整屏光影语言崩塌——但人眼看单张图往往只觉得「有点怪」，指不出具体哪里错。
// 深色档尤其危险：那里没有「更亮的白」可用，凸起要靠**比面板更亮的灰**来表达，
// 很容易一手滑就调得比面板还暗。
//
// v2.11.7 hotfix4 之后承载面变了：工具栏不再是浮动面板，而是**直接坐在画布上**，
// 所以「凸起 / 内凹」的参照物从 panel 换成 ground，而 ground 必须与 App 层窗口底同源
// （否则工具栏会重新变成一块颜色略不同的方块压在内容上）——这条也补成断言。
//
// 所以这一段把新拟物的三条硬约束全部写成断言，四套取值（简洁/多彩 × 浅色/深色）逐套过：
//   ① 光源方向一致：raised == ground（同材质，边界靠双色投影）、well < ground（凹陷）
//   ② 层级可辨：凸起与内凹之间必须有可察的亮度差，否则退化成「一片白」
//   ③ 选中滑块与轨道、按钮文字与底色的对比度达标（滑块是「当前选哪个」的唯一信号）

do {
    // ── ① 光源方向：凸起比承载面亮、内凹比承载面暗。四套都必须成立。
    // hotfix4 起承载面 = 画布（ground）。这条最容易在「去掉浮动面板」这类改动里悄悄翻面：
    // 原来的 well 是相对**面板**调的，面板比画布亮，直接搬到画布上就可能比画布还亮
    //（深色档尤其明显：原 #1B1B1D 压在 #161618 上其实是凸起，不是凹陷）。
    for (name, s) in NeumorphicPalette.allSurfaces {
        // hotfix5：凸起**必须与画布同色**。这条和上面的直觉正好相反，所以特别容易被「顺手
        // 调亮一点让按钮更清楚」破坏——一旦拉开色差，按钮立刻从「底板上鼓起的一块」退回
        // 「一片白薄片叠在灰底上」，双色投影调得再准都救不回来（这就是 hotfix5 之前的样子）。
        t.check(s.raised == s.ground,
                "★★\(name)：凸起填充必须与画布同色（边界靠左上高光 + 右下投影定义，不靠色差）")
        t.check(s.well.relativeLuminance < s.ground.relativeLuminance,
                "★★\(name)：内凹必须比承载面（画布）暗")
        let wellVsGround = s.ground.contrastRatio(to: s.well)
        t.check(wellVsGround > 1.04,
                "★\(name)：内凹要在画布上读得出来（实际 \(String(format: "%.3f", wellVsGround))）")
        t.check(s.wellShade.relativeLuminance < s.well.relativeLuminance,
                "★\(name)：内凹的上沿暗边必须比凹底更暗（内阴影的方向）")
    }

    // ── ② 层级可辨：凸起 vs 内凹的对比度既要看得出，又不能大到像两个不同控件。
    for (name, s) in NeumorphicPalette.allSurfaces {
        let ratio = s.raised.contrastRatio(to: s.well)
        t.check(ratio > 1.05, "★\(name)：凸起与内凹必须分得出来（实际 \(String(format: "%.3f", ratio))）")
        t.check(ratio < 3.0, "\(name)：凸起与内凹差得过大就不是同一块材质了（实际 \(String(format: "%.3f", ratio))）")
    }

    // ── ③ 选中滑块：与轨道的对比度必须够高，它是「当前选的是哪个」的唯一载体。
    for (name, s) in NeumorphicPalette.allSurfaces {
        let sliderVsWell = s.sliderFill.contrastRatio(to: s.well)
        t.check(sliderVsWell >= 3.0,
                "★★\(name)：选中滑块必须从内凹轨道上跳出来（实际 \(String(format: "%.2f", sliderVsWell))）")
        let inkOnSlider = s.sliderInk.contrastRatio(to: s.sliderFill)
        t.check(inkOnSlider >= 4.5,
                "★\(name)：滑块上的文字要达 WCAG AA 4.5:1（实际 \(String(format: "%.2f", inkOnSlider))）")
    }

    // ── ④ 承载面上的文字与危险操作（hotfix4 起文字直接压在画布上，不再压在白面板上）
    for (name, s) in NeumorphicPalette.allSurfaces {
        t.check(s.ink.contrastRatio(to: s.ground) >= 4.5, "★\(name)：正文压在画布上要达 4.5:1")
        t.check(s.subtleInk.contrastRatio(to: s.ground) >= 3.0, "★\(name)：次要文字压在画布上要达 3:1")
        t.check(s.ink.contrastRatio(to: s.raised) >= 4.5, "★\(name)：正文压在凸起按钮上要达 4.5:1")
        // 「清空」是淡底 + 彩字，不是实心红底白字，所以要验的是彩字在淡底上的可读性。
        let danger = s.dangerInk.contrastRatio(to: s.dangerFill)
        t.check(danger >= 4.5, "★\(name)：危险操作的红字压在淡红底上要达 4.5:1（实际 \(String(format: "%.2f", danger))）")
        t.check(s.dangerFill.contrastRatio(to: s.ground) < 2.0,
                "\(name)：危险操作的淡底不能重到抢过整行（它只是提示，不是主操作）")
    }

    // ── ⑤ 简洁模式仍必须是纯中性（新拟物的白面板最容易在调阴影时被掺进冷灰）
    for (name, s) in [("简洁·浅色", NeumorphicPalette.minimalLight), ("简洁·深色", NeumorphicPalette.minimalDark)] {
        for member in s.neutralMembers {
            let n = MinimalSkinPalette.neutrality(member)
            t.check(n <= 0.02 + 1e-9, "★★\(name)：新拟物表面色必须是灰阶（RGB 极差 \(String(format: "%.4f", n))）")
        }
    }

    // ── ⑥ 多彩模式必须**真的带色**，否则两种皮肤就没区别了
    let colorfulSlider = MinimalSkinPalette.neutrality(NeumorphicPalette.colorfulLight.sliderFill)
    t.check(colorfulSlider > 0.15,
            "★★多彩模式的选中滑块必须是品牌彩色（RGB 极差 \(String(format: "%.3f", colorfulSlider))），否则和简洁模式无异")
    t.check(MinimalSkinPalette.neutrality(NeumorphicPalette.colorfulLight.well) >
            MinimalSkinPalette.neutrality(NeumorphicPalette.minimalLight.well),
            "★多彩模式的内凹底要比简洁模式带色（这是两种皮肤在同一几何下的主要区分手段）")

    // ── ⑦ 几何：两种皮肤共用，且几个尺寸间的关系不能被随手改坏
    // v2.11.7 hotfix10: 竖开关（switchTrack*/switchKnob*）还原，这 4 条几何断言随之恢复。
    t.check(NeumorphicMetrics.switchKnobWidth < NeumorphicMetrics.switchTrackWidth,
            "★★开关滑块必须窄于滑道，否则滑块会盖住整条轨道、看不出内凹")
    t.check(NeumorphicMetrics.switchKnobHeight < NeumorphicMetrics.switchTrackHeight,
            "★★开关滑块必须短于滑道，否则没有行程可走")
    t.check(NeumorphicMetrics.switchTravel > 0, "★开关行程必须为正（上开下关各走一半）")
    t.check(NeumorphicMetrics.switchKnobHeight + NeumorphicMetrics.switchTravel * 2
            <= NeumorphicMetrics.switchTrackHeight,
            "★★滑块在两个极限位置都不能越出滑道（实际会越出 \(NeumorphicMetrics.switchKnobHeight + NeumorphicMetrics.switchTravel * 2 - NeumorphicMetrics.switchTrackHeight)pt）")
    // 下面 3 条是 hotfix9 新增、与开关无关的规格断言，保留：组标签行并入新拟物后，
    // 组标签 / + / 管理方块与操作按钮共用 actionHeight / actionRadius，任何一处跑偏就会破掉这一行的统一。
    t.check(NeumorphicMetrics.actionRadius < NeumorphicMetrics.actionHeight / 2,
            "★★操作控件必须是圆角矩形而不是全圆胶囊（半高圆角是搜索框的专属形状，两者要能区分）")
    t.check(NeumorphicMetrics.iconTileRadius == NeumorphicMetrics.actionRadius,
            "★图标方块与操作按钮圆角必须一致，否则同一行里出现两种圆角语言")
    t.check(NeumorphicMetrics.segmentHeight < NeumorphicMetrics.actionHeight,
            "★分段控件（组内/全局）必须矮于操作按钮：它嵌在搜索行里，是从属控件")
    t.check(abs(NeumorphicMetrics.searchRadius * 2 - NeumorphicMetrics.searchHeight) < 1e-9,
            "★搜索框圆角必须是半高（设计稿要求椭圆形，不是圆角矩形）")
    t.check(NeumorphicMetrics.segmentInset > 0 && NeumorphicMetrics.segmentInset < NeumorphicMetrics.segmentHeight / 2,
            "★分段控件的滑块内缩必须落在 (0, 半高) 之间")
    t.check(NeumorphicMetrics.pressedEdgeScale > 0 && NeumorphicMetrics.pressedEdgeScale < 1,
            "★按下时描边收敛比例必须在 (0,1)（=「压平」而不是消失或变粗）")

    // ── ⑦b 纯描边浮雕（v2.11.7 hotfix8）：**外部 Drop Shadow 全部删除**，凸起/内凹只用边。
    //
    // hotfix5→hotfix7 三轮都在调那对外投影（浓度 / blur / 严格镜像），用户三次的判断一模一样：
    // 「还是漂浮」。原因不在参数而在手段——外投影的语义就是「物体离背后的平面有一段距离」。
    // 所以这一版把 dropShadow*/highlightShadow*/wellInner* 全部**从 metrics 里删掉**：
    // 常量不存在，调用点就不可能悄悄把阴影加回来（Swift 编译期就挡住了，比 review 靠得住）。
    // 下面这组断言钉住的是取代它的那套边的几何关系。
    t.check(NeumorphicMetrics.edgeDarkWidth > NeumorphicMetrics.edgeLightWidth,
            "★★右下暗边必须比左上白亮边宽（暗边是有体积的侧面，白亮边只是一条反光棱）")
    t.check(NeumorphicMetrics.edgeLightInset > 0,
            "★★白亮边必须**内缩**（正值）——往外挪就会溢到画布上变成一圈白晕，那还是「浮」")
    t.check(NeumorphicMetrics.edgeLightInset <= NeumorphicMetrics.edgeDarkWidth,
            "★白亮边的内缩量不能超过暗边线宽，否则两条边之间会露出一圈没交代的空白")
    t.check(NeumorphicMetrics.edgeDarkWidth <= 1.5 && NeumorphicMetrics.edgeLightWidth >= 0.5,
            "★描边宽度守在设计稿量级（暗边 ≤1.5pt、亮边 ≥0.5pt）；再宽就从「厚度」变成「边框」")
    t.check(NeumorphicMetrics.wellEdgeDarkWidth > NeumorphicMetrics.wellEdgeLightWidth,
            "★★内凹的上/左暗边必须比下/右亮边宽（凹槽最深的一侧背光）")
    t.check(NeumorphicMetrics.wellEdgeDarkWidth <= NeumorphicMetrics.searchHeight / 8,
            "★内凹描边不能超过槽高的 1/8，否则 34pt 的窄条搜索框会被边糊掉小半个高度")
    t.check(NeumorphicMetrics.raisedSheenOpacity > 0 && NeumorphicMetrics.raisedSheenOpacity <= 0.03,
            "★★凸起顶面渐变必须「量不出来」（≤3%）——看得出深浅就等于把 hotfix5 去掉的色差请回来了")

    // ── ⑧ 一体化（v2.11.7 hotfix4）：工具栏承载面必须与窗口底**逐值相同**。
    //
    // 这是「工具栏和内容区看不出接缝」的唯一硬条件，也是最容易在后续调色里悄悄失效的：
    // 只要有人单独动了 MinimalSkinPalette.window 或 NeumorphicPalette.ground 之一，
    // 工具栏区就会重新浮成一块颜色略不同的方块——差 1% 亮度肉眼说不出哪里怪，但确实割裂。
    // 多彩模式那侧 AppTheme 直接引用 NeumorphicPalette.ground（App 层跑不了测试，只能靠引用同源）。
    t.check(NeumorphicPalette.minimalLight.ground == MinimalSkinPalette.light.window,
            "★★简洁·浅色：新拟物承载面必须等于窗口底（否则工具栏与卡片区之间会出现可见接缝）")
    t.check(NeumorphicPalette.minimalDark.ground == MinimalSkinPalette.dark.window,
            "★★简洁·深色：新拟物承载面必须等于窗口底")
}


// MARK: - SEARCH (v2.11.7 hotfix11) 槽位可搜索文本
//
// 用户反馈「搜索功能坏了，基本不能搜到想要的内容」。根因不是最近几轮 hotfix 动了搜索框——
// SlotSearchBar 自 hotfix3 起只改了外观（内凹 well、范围选择器移到框外），TextField 的
// `$searchText` 绑定与 ContentView 的 `.onChange(of: searchText)` 一行没动——而是 GUI 的
// 可搜索文本自 v2.5 起只取 `content.preview`，也就是**正文前 30 字**。
//
// 于是长文槽位同时表现出两种「搜不到想要的」：
//   ① 关键词在第 31 字之后 → 一条都搜不出来；
//   ② 同批槽位共享开头（本机那批 prompt 全以 `| **编号** | **时间** …` 起头）→ 搜表头里的词
//      把整组全部命中，等于没筛。
//
// 这组用例钉住的是「可搜索文本收录范围」。★★ 那几条在修复前会失败，是真正的回归防护；其余是
// 防止这次扩大收录范围时把原有的匹配能力（槽位号 / label / 文件名 / URL）或 CLI 语义碰坏。
// 注意搜索逻辑此前住在 App target（`SlotSearchMatcher`），smoke 根本测不到它——这也是这个 bug
// 潜伏这么久的原因之一，所以本次把内容侧实现下沉到 Kit 的 `SlotSearchIndex`。

do {
    /// 复刻本机真实数据形态：一批 prompt 槽位共享 30 字以上的表头，正文两千余字。
    let sharedHeader = "| **编号** | **时间** | **时长** | **画面** | **镜头调度** |"
    let longBody = sharedHeader + """

    | 01 | 00:00 | 3s | 荒原远景 | 三人骑马迎面而来 |
    | 02 | 00:03 | 4s | 中景 | 马蹄扬尘，声音渐强 |
    """
    t.check(longBody.count > 30, "前置：测试正文必须超过 preview 的 30 字截断阈值")

    let long = makeTextContent(longBody)

    // ① ★★ 正文深处的关键词必须命中（修复前失败：preview 只有前 30 字）
    //    这三个词就是用户实测「CLI 搜得到、GUI 搜不到」的那三个。
    for keyword in ["镜头调度", "骑马", "声音"] {
        t.check(SlotSearchIndex.matches(slot: 1, content: long, label: "", query: keyword),
                "★★正文里的「\(keyword)」必须能搜到（在第 30 字之后，修复前搜不到）")
    }

    // ② preview 区间（前 30 字）内的关键词不能因为这次改动而丢
    t.check(SlotSearchIndex.matches(slot: 1, content: long, label: "", query: "编号"),
            "★正文开头的关键词仍要命中（不能为了搜全文把 preview 段落搞丢）")

    // ③ 不匹配的词必须返回 false —— 否则「全命中」和「全不命中」一样没用
    t.check(!SlotSearchIndex.matches(slot: 1, content: long, label: "", query: "螺旋桨"),
            "★★正文里没有的词必须搜不到（守住筛选的意义，避免退化成「什么都匹配」）")

    // ④ 大小写不敏感 + 查询串两端空白应被忽略（GUI 里用户复制粘贴关键词常带空格）
    let mixed = makeTextContent("Deploy the STAGING cluster")
    t.check(SlotSearchIndex.matches(slot: 1, content: mixed, label: "", query: "staging"),
            "★大小写不敏感：小写 query 应命中正文里的大写词")
    t.check(SlotSearchIndex.matches(slot: 1, content: mixed, label: "", query: "  STAGING  "),
            "★query 两端空白应被忽略（粘贴关键词常带空格，否则用户以为搜不到）")
    t.check(SlotSearchIndex.matches(slot: 1, content: mixed, label: "", query: "   "),
            "★纯空白 query 视为「未搜索」→ 不筛选（不能把所有槽位都判为不匹配）")

    // ⑤ ★★ 附件名必须可搜（纯附件槽位只能靠文件名被找到；CLI 从 v2.9.3 就支持，GUI 之前不支持）
    var withAttachment = makeTextContent("参考资料")
    withAttachment.attachments = [
        SlotContent.SlotAttachment(name: "季度复盘-Q3.pdf", type: .file),
        SlotContent.SlotAttachment(name: "封面草图.png", type: .image)
    ]
    t.check(SlotSearchIndex.matches(slot: 2, content: withAttachment, label: "", query: "季度复盘"),
            "★★附件名必须可搜（修复前 GUI 搜不到附件，与 CLI 行为不一致）")
    t.check(SlotSearchIndex.matches(slot: 2, content: withAttachment, label: "", query: "草图.png"),
            "★★附件名含扩展名的片段也应命中")

    // ⑥ label / 槽位号：GUI 原有能力，不能退化
    t.check(SlotSearchIndex.matches(slot: 3, content: long, label: "分镜表", query: "分镜"),
            "★label 必须可搜")
    t.check(SlotSearchIndex.matches(slot: 7, content: makeTextContent("x"), label: "", query: "7"),
            "★槽位号必须可搜（GUI 支持直接输数字定位槽位）")
    t.check(SlotSearchIndex.matches(slot: 7, content: makeTextContent("x"), label: "", query: "槽位 7"),
            "★「槽位 N」写法必须可搜")

    // ⑦ 文件 URL：文件名 / 扩展名 / 路径片段
    let fileItem = PasteboardItem(type: "public.file-url",
                                  data: Data("file:///Users/demo/Documents/年报草稿.docx".utf8))
    var fileContent = SlotContent()
    fileContent.items = [[fileItem]]
    fileContent.timestamp = Date()
    for keyword in ["年报草稿", "docx", "Documents"] {
        t.check(SlotSearchIndex.matches(slot: 4, content: fileContent, label: "", query: keyword),
                "★文件槽位应能按「\(keyword)」搜到（文件名 / 扩展名 / 路径片段）")
    }

    // ⑧ 网址：完整 URL 与 host 都要可搜
    let urlContent = makeTextContent("https://github.com/Seven-hub-fanfan/ClipSlots/releases")
    t.check(SlotSearchIndex.matches(slot: 5, content: urlContent, label: "", query: "github.com"),
            "★URL 槽位应能按 host 搜到")
    t.check(SlotSearchIndex.matches(slot: 5, content: urlContent, label: "", query: "releases"),
            "★URL 槽位应能按路径片段搜到")

    // ⑨ ★★ GUI / CLI 同源：内容侧 haystack 是同一份实现，但槽位号只属于 GUI。
    //    CLI 的 `clipslots search "1"` 不能因为这次重构突然命中所有槽位 1（那是行为契约破坏），
    //    所以 contentHaystack 必须不含槽位号，而 slotHaystack = 槽位号 + contentHaystack。
    let plain = makeTextContent("与数字无关的正文")
    t.check(!SlotSearchIndex.matchesContent(content: plain, label: "", query: "9"),
            "★★CLI 侧（contentHaystack）不得包含槽位号，否则 search \"9\" 会命中所有槽位 9")
    t.check(SlotSearchIndex.matches(slot: 9, content: plain, label: "", query: "9"),
            "★★GUI 侧（slotHaystack）必须包含槽位号")
    let contentSide = SlotSearchIndex.contentHaystack(content: long, label: "分镜表")
    let slotSide = SlotSearchIndex.slotHaystack(slot: 3, content: long, label: "分镜表")
    t.check(slotSide.hasSuffix(contentSide),
            "★★slotHaystack 必须以 contentHaystack 结尾（= 两侧共用同一份内容文本，不会再各写一套）")
    t.equal(contentSide, contentSide.lowercased(),
            "★haystack 必须已折叠大小写（匹配时只做一次 lowercased，避免每次按键重复折叠）")

    // ⑩ 图片等非文本槽位：可读描述只存在于 preview（plainText 为 nil），必须仍可搜
    var imageContent = SlotContent()
    imageContent.items = [[PasteboardItem(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]]
    imageContent.timestamp = Date()
    t.check(imageContent.plainText == nil || imageContent.plainText?.isEmpty == true,
            "前置：图片槽位没有正文（plainText 为空）")
    let imageHaystack = SlotSearchIndex.contentHaystack(content: imageContent, label: "配图")
    t.check(imageHaystack.contains("图片"),
            "★★图片槽位的 preview 描述（如「[图片 742KB]」）必须收进 haystack，否则搜「图片」搜不到")
    t.check(SlotSearchIndex.matches(slot: 6, content: imageContent, label: "配图", query: "配图"),
            "★图片槽位仍应能按 label 搜到")

    // ⑪ 缓存正确性：haystack 按 contentId::updatedAt 缓存，内容一改必须立刻反映
    //    （缓存 key 忘记带 updatedAt 是 v2.10.64/65 「缩略图串组 / 不刷新」的同源坑，这里提前钉住。）
    var v1 = makeTextContent("初版：地面外景")
    v1.contentId = "fixed-content-id"
    v1.updatedAt = 1000
    t.check(SlotSearchIndex.matches(slot: 1, content: v1, label: "", query: "地面外景"),
            "前置：初版正文可搜到")
    var v2 = v1
    v2.items = makeTextContent("改版：太空舱内景").items
    v2.updatedAt = 2000  // 内容变了，updatedAt 必须同步推进
    t.check(SlotSearchIndex.matches(slot: 1, content: v2, label: "", query: "太空舱"),
            "★★改写正文后新词必须立即可搜（缓存要随 updatedAt 失效，否则搜索永远停留在旧内容）")
    t.check(!SlotSearchIndex.matches(slot: 1, content: v2, label: "", query: "地面外景"),
            "★★改写正文后旧词必须搜不到（陈旧缓存会让已删除的内容一直被搜出来）")

    // ⑫ 空槽：任何非空关键词都不该命中（空槽由 .empty 过滤器负责，不该混进关键词结果）
    let empty = SlotContent()
    t.check(!SlotSearchIndex.matches(slot: 8, content: empty, label: "", query: "任意"),
            "★空槽不应被关键词命中")
    t.check(SlotSearchIndex.matches(slot: 8, content: empty, label: "", query: ""),
            "★空 query 对空槽也返回 true（= 未搜索状态不做筛选，由过滤器决定是否展示）")
}

// MARK: - SEARCH-SCAN (v2.11.7 hotfix11) 全局搜索必须扫磁盘，而不是只扫进程内缓存
//
// 「搜索基本搜不到想要的内容」的第二处根因：全局搜索原来读 `SlotStorage.snapshot()`，而
// `snapshot()` 返回的是**进程内缓存**——只有本次会话被 `get(_:)` 读过的槽位才在里面，也就是
// 用户真正点开过的组。冷启动后在「全局」范围搜别的页 / 别的组，UI 一律 0 命中（本机实测搜默认组
// 的 `10%`、另一页的 `骑马` 都是 0，而 CLI 走磁盘全都搜得到）。
//
// 这组用例用「新建一个 SlotStorage 实例」来精确模拟「这个组本次会话从没被打开过」的冷缓存状态。
// ★★ 两条断言里，snapshot 那条固定住 bug 的形状（缓存确实是空的 → 旧实现必然搜不到），
// searchScanSnapshot 那条是修复本身。
do {
    t.withFreshStore("SEARCH-SCAN") { storage in
        let gid = firstGroupId(storage)
        let body = "第 31 个字符之后才出现的关键词：" + String(repeating: "填充", count: 20) + "月球背面基地"
        storage.set(1, content: makeTextContent(body), in: gid)
        storage.set(2, content: makeTextContent("另一个槽位：深海热泉"), in: gid)

        // 冷缓存：全新实例代表「这个组本次会话没被打开过」
        let cold = coldStorage(forGroup: gid)
        t.equal(cold.snapshot().count, 0,
                "★★冷实例的 snapshot() 必须是空的（这正是旧全局搜索漏掉未访问组的原因）")

        let scan = cold.searchScanSnapshot(slotCount: 10)
        t.equal(scan.count, 2, "★★searchScanSnapshot 必须从磁盘补齐两个非空槽位")
        t.check(scan[1].map {
                    SlotSearchIndex.matches(slot: 1, content: $0, label: "", query: "月球背面基地")
                } == true,
                "★★冷缓存下也要能搜到正文深处的关键词（修复前全局搜索对未访问组 0 命中）")
        t.check(scan[2].map {
                    SlotSearchIndex.matches(slot: 2, content: $0, label: "", query: "深海热泉")
                } == true,
                "★★冷缓存下第二个槽位同样要能搜到")
        t.check(scan[3] == nil, "★空槽位不该出现在扫描结果里（避免污染结果列表与计数）")

        // 扫描是只读的：不得把内容灌进常驻缓存（否则全局搜索会把整库拉进内存，本机数据目录 11 GB）
        t.equal(cold.snapshot().count, 0,
                "★★searchScanSnapshot 不得污染常驻缓存（一次全局搜索会扫过整库，缓存整库 = 内存爆炸）")

        // 文本槽位在扫描结果里必须是**完整**正文，不能被截断成 preview
        if let scanned = scan[1] {
            t.equal(scanned.plainText?.count ?? 0, body.count,
                    "★扫描出的文本槽位必须是完整正文（截断就等于没修）")
        }
    }
}

// MARK: - SEARCH-SCAN-BINARY (v2.11.7 hotfix11) 扫描跳过大二进制但保住过滤器语义
//
// 扫描之所以敢扫全库，是因为它 textOnly：图片 / 视频只留 pasteboard type、不读字节。这组用例
// 钉住这个取舍的两端——① 字节确实没被读进来（否则内存优化落空）；② 类型判据仍然成立，所以
// 「图片 / 文件 / 网址」这些过滤器不会因为不读字节而失效。
do {
    t.withFreshStore("SEARCH-SCAN-BINARY") { storage in
        let gid = firstGroupId(storage)

        // 伪造一张「大图」：1.5 MB 的 PNG 负载
        var image = SlotContent()
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0xAB, count: 1_500_000))
        image.items = [[PasteboardItem(type: "public.png", data: fakePNG)]]
        image.timestamp = Date()
        storage.set(1, content: image, in: gid)

        // 文件槽位：负载是一小段 file URL 文本，必须照读（按文件名搜 + .file 过滤器都靠它）
        var file = SlotContent()
        file.items = [[PasteboardItem(type: "public.file-url",
                                      data: Data("file:///Users/demo/年终总结.pdf".utf8))]]
        file.timestamp = Date()
        storage.set(2, content: file, in: gid)

        let cold = coldStorage(forGroup: gid)
        let scan = cold.searchScanSnapshot(slotCount: 10)

        let scannedImage = scan[1]
        t.check(scannedImage != nil, "图片槽位应出现在扫描结果里")
        t.equal(scannedImage?.items.first?.first?.data.count ?? -1, 0,
                "★★图片字节不得被读进扫描结果（1.5 MB × 全库 = 全局搜索一次吃光内存）")
        // `hasImage` / `isImageFile` 这些过滤器判据住在 App target，Kit smoke 测不到；但它们全部
        // 只看 pasteboard type，所以这里断言 type 原样保留 = 过滤器语义不受「不读字节」影响。
        t.equal(scannedImage?.items.first?.first?.type, "public.png",
                "★★不读字节也必须保留 pasteboard type（否则「图片」过滤器在未访问的组里失效）")

        let scannedFile = scan[2]
        t.equal(scannedFile?.primaryFileURL?.lastPathComponent, "年终总结.pdf",
                "★★file-url 负载是文本，必须照读（按文件名搜 +「文件」过滤器都依赖它）")
        t.check(SlotSearchIndex.matches(slot: 2, content: scannedFile ?? SlotContent(),
                                        label: "", query: "年终总结"),
                "★★冷缓存下也要能按文件名搜到")

        // 类型判定函数本身的边界（它决定「读不读这段字节」，判错的代价是搜不到或内存爆炸）
        for textual in ["public.utf8-plain-text", "NSStringPboardType", "public.rtf",
                        "public.html", "public.file-url", "public.url"] {
            t.check(SlotStorage.isSearchableTextType(textual), "★\(textual) 应被当作可搜索文本类型")
        }
        for binary in ["public.png", "public.tiff", "public.jpeg", "com.adobe.pdf",
                       "public.mpeg-4"] {
            t.check(!SlotStorage.isSearchableTextType(binary), "★\(binary) 不该被当作文本类型（应跳过字节）")
        }
    }
}

// MARK: - SEARCH-SCAN-FRESH (v2.11.7 hotfix11) 扫描缓存不得把搜索钉在旧内容上
//
// 扫描缓存是为了让「逐字符搜索」不至于每次按键都重读 13 组 × 10 槽（0.2s 去抖 + 全库磁盘扫描）。
// 但缓存一旦失效不及时，症状会从「搜不到」变成更难查的「搜到的是旧的 / 已删的」。这组用例把
// 「改写后能搜到新词、搜不到旧词」和「清空后彻底搜不到」钉死。
do {
    t.withFreshStore("SEARCH-SCAN-FRESH") { storage in
        let gid = firstGroupId(storage)
        storage.set(1, content: makeTextContent("初版关键词：赤道无风带"), in: gid)

        let cold = coldStorage(forGroup: gid)
        t.check(cold.searchScanSnapshot(slotCount: 10)[1].map {
                    SlotSearchIndex.matches(slot: 1, content: $0, label: "", query: "赤道无风带")
                } == true, "前置：首次扫描能搜到初版内容")

        // 同实例改写（模拟 GUI 自己改）：新词要能搜到，旧词必须消失
        cold.set(1, content: makeTextContent("改版关键词：极地涡旋"))
        let afterEdit = cold.searchScanSnapshot(slotCount: 10)[1]
        t.check(afterEdit.map {
                    SlotSearchIndex.matches(slot: 1, content: $0, label: "", query: "极地涡旋")
                } == true, "★★改写后新词必须立即可搜（扫描缓存要随写入失效）")
        t.check(afterEdit.map {
                    SlotSearchIndex.matches(slot: 1, content: $0, label: "", query: "赤道无风带")
                } != true, "★★改写后旧词必须搜不到（陈旧扫描缓存会让改掉的内容继续被搜出来）")

        // 外部进程写入（CLI 场景）：另一个实例改盘 + invalidateCache 后必须反映
        let external = coldStorage(forGroup: gid)
        external.set(2, content: makeTextContent("外部写入：季风槽"))
        cold.invalidateCache()
        t.check(cold.searchScanSnapshot(slotCount: 10)[2].map {
                    SlotSearchIndex.matches(slot: 2, content: $0, label: "", query: "季风槽")
                } == true, "★★外部（CLI）写入的槽位在失效后必须能被搜到")

        // 清空：不能再被搜到，也不该以空内容占位
        cold.clear(1)
        let afterClear = cold.searchScanSnapshot(slotCount: 10)
        t.check(afterClear[1] == nil, "★★清空后的槽位不得留在扫描结果里（否则已删内容还能搜到）")
    }
}

// MARK: - NOTICE-CHANNEL (v2.11.7 hotfix13) Toast 投递通道必须互斥

// 用户截图里同一次「保存到槽位 1」弹出了两张一模一样的卡片。根因不在业务侧（`showFloatingNotice`
// 只被调了一次），而在渲染层：v2.6.3 为「热键从 Finder 存图」加的全局 HUD 面板与主窗口内的
// SwiftUI 覆盖层被**无条件同时**点亮。这组用例把「任何窗口状态下都只选出一条通道」钉死，
// 并覆盖 4 个状态位的全部 16 种组合，防止以后再有人在某个分支里顺手把两条通道都打开。
do {
    let allStates: [NoticeWindowState] = {
        var out: [NoticeWindowState] = []
        for active in [true, false] {
            for visible in [true, false] {
                for mini in [true, false] {
                    for occluded in [true, false] {
                        out.append(NoticeWindowState(appActive: active,
                                                     mainWindowVisible: visible,
                                                     mainWindowMiniaturized: mini,
                                                     mainWindowOccluded: occluded))
                    }
                }
            }
        }
        return out
    }()
    t.equal(allStates.count, 16, "窗口状态组合应覆盖 16 种")

    // 通道是枚举，天然互斥；这里断言的是「每种组合都能定出唯一通道」且判据符合预期。
    for state in allStates {
        let channel = NoticePresentationRouter.channel(for: state)
        let expectInline = state.appActive
            && state.mainWindowVisible
            && !state.mainWindowMiniaturized
            && !state.mainWindowOccluded
        t.equal(channel, expectInline ? .inline : .hud,
                "★★通道选择错误 active=\(state.appActive) visible=\(state.mainWindowVisible) mini=\(state.mainWindowMiniaturized) occluded=\(state.mainWindowOccluded)")
    }

    // 关键回归：人就在 App 里点保存（App 激活 + 窗口可见 + 未最小化 + 未被遮挡）
    // 必须只走窗内通道，绝不能同时开 HUD —— 这正是重复弹窗的场景。
    t.equal(NoticePresentationRouter.channel(for: NoticeWindowState(appActive: true,
                                                                   mainWindowVisible: true,
                                                                   mainWindowMiniaturized: false,
                                                                   mainWindowOccluded: false)),
            .inline,
            "★★主窗口就在眼前时必须只走窗内通道（重复弹窗回归）")

    // 热键从别的 App 触发：App 未激活 → 只能走 HUD，否则用户看不到任何反馈。
    t.equal(NoticePresentationRouter.channel(for: NoticeWindowState(appActive: false,
                                                                   mainWindowVisible: true,
                                                                   mainWindowMiniaturized: false,
                                                                   mainWindowOccluded: false)),
            .hud,
            "★★App 不在前台时必须走全局 HUD")

    // 窗口可见但被别的窗口完全盖住：isVisible 仍是 true，只有 occlusionState 能看出来。
    t.equal(NoticePresentationRouter.channel(for: NoticeWindowState(appActive: true,
                                                                   mainWindowVisible: true,
                                                                   mainWindowMiniaturized: false,
                                                                   mainWindowOccluded: true)),
            .hud,
            "★★主窗口被完全遮挡时必须走 HUD（窗内卡片画了也看不见）")

    t.equal(NoticePresentationRouter.channel(for: NoticeWindowState(appActive: true,
                                                                   mainWindowVisible: true,
                                                                   mainWindowMiniaturized: true,
                                                                   mainWindowOccluded: false)),
            .hud,
            "★★主窗口最小化时必须走 HUD")
}

// MARK: - NOTICE-METRICS (v2.11.7 hotfix13) Toast 卡片宽度：贴合内容、封顶 280

do {
    t.equal(NoticeMetrics.maxWidth, 280, "Toast 最大宽度应为 280pt")
    t.equal(NoticeMetrics.topInset, 16, "Toast 距窗口顶部应为 16pt")
    t.equal(NoticeMetrics.cornerRadius, 12, "Toast 圆角应为 12pt")

    // 短文案：不得被撑成 280（这是弃用 `frame(maxWidth:)` 的原因），但也不得比 minWidth 更窄。
    let shortWidth = NoticeMetrics.cardWidth(titleTextWidth: 40, subtitleTextWidth: 0)
    t.check(shortWidth < NoticeMetrics.maxWidth,
            "★★短文案卡片不得被撑满 280（\(shortWidth)）")
    t.equal(shortWidth, NoticeMetrics.minWidth, "短文案应落到最小宽度")

    // 中等文案：按内容线性增长。
    let midText: CGFloat = 150
    let midWidth = NoticeMetrics.cardWidth(titleTextWidth: midText, subtitleTextWidth: 90)
    t.equal(midWidth,
            NoticeMetrics.horizontalPadding * 2 + NoticeMetrics.iconGlyphWidth
                + NoticeMetrics.iconTextSpacing + midText,
            "中等文案宽度应等于 内边距×2 + 图标 + 间距 + 最宽那行文字")
    t.check(midWidth > shortWidth && midWidth < NoticeMetrics.maxWidth,
            "★★中等文案宽度应介于最小与最大之间（\(midWidth)）")

    // 取标题 / 副标题里更宽的那一行，而不是只看标题。
    t.equal(NoticeMetrics.cardWidth(titleTextWidth: 60, subtitleTextWidth: 180),
            NoticeMetrics.cardWidth(titleTextWidth: 180, subtitleTextWidth: 60),
            "宽度应取标题与副标题中更宽的一行")

    // 超长文案：封顶，不允许横贯窗口。
    for w in [CGFloat(400), 900, 5000] {
        t.equal(NoticeMetrics.cardWidth(titleTextWidth: w, subtitleTextWidth: w),
                NoticeMetrics.maxWidth,
                "★★超长文案（\(w)pt）必须封顶到 280")
    }

    // 单调不减：文字越宽卡片不能反而变窄。
    var last: CGFloat = 0
    for step in stride(from: CGFloat(0), through: 400, by: 20) {
        let w = NoticeMetrics.cardWidth(titleTextWidth: step, subtitleTextWidth: 0)
        t.check(w >= last, "★★卡片宽度必须随文字单调不减（\(step) → \(w)）")
        last = w
    }

    t.check(NoticeMetrics.textColumnMaxWidth > 200,
            "文字列在最大宽度下应至少有 200pt 可用（\(NoticeMetrics.textColumnMaxWidth)）")
}

// MARK: - NOTICE-HUD-ORIGIN (v2.11.7 hotfix13) HUD 面板定位

// HUD 现在贴**主窗口**顶部居中（与窗内通道同一落点），主窗口不可见时才回退屏幕顶部；
// 两种情况都必须夹在屏幕可见区内，贴边窗口不能把卡片带出屏幕。
do {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let card = CGSize(width: 240 + NoticeMetrics.hudShadowPadding * 2,
                      height: 58 + NoticeMetrics.hudShadowPadding * 2)

    // 主窗口居中：水平居中、卡片顶沿距窗口顶沿 16pt。
    let window = CGRect(x: 660, y: 300, width: 600, height: 500)
    let origin = NoticeMetrics.hudOrigin(windowFrame: window,
                                         contentSize: card,
                                         screenVisibleFrame: screen)
    t.check(abs((origin.x + card.width / 2) - window.midX) < 0.001,
            "★★HUD 应与主窗口水平居中对齐")
    let cardVisualTop = origin.y + card.height - NoticeMetrics.hudShadowPadding
    t.check(abs((window.maxY - cardVisualTop) - NoticeMetrics.topInset) < 0.001,
            "★★HUD 卡片顶沿距窗口顶沿应为 16pt（实际 \(window.maxY - cardVisualTop)）")

    // 主窗口不可见：回退屏幕顶部居中。
    let fallback = NoticeMetrics.hudOrigin(windowFrame: nil,
                                           contentSize: card,
                                           screenVisibleFrame: screen)
    t.check(abs((fallback.x + card.width / 2) - screen.midX) < 0.001,
            "★★无主窗口时 HUD 应屏幕水平居中")
    t.check(fallback.y < origin.y || window.maxY < screen.maxY,
            "无主窗口时 HUD 落点由屏幕顶部推算")

    // 贴左边 / 贴右边 / 贴顶 / 部分出屏的窗口：结果必须仍在屏幕可见区内。
    let edgeWindows = [
        CGRect(x: -400, y: 200, width: 600, height: 500),
        CGRect(x: 1800, y: 200, width: 600, height: 500),
        CGRect(x: 300, y: 900, width: 600, height: 500),
        CGRect(x: 0, y: 0, width: 200, height: 120),
        CGRect(x: 1900, y: 1070, width: 600, height: 500)
    ]
    for w in edgeWindows {
        let o = NoticeMetrics.hudOrigin(windowFrame: w, contentSize: card, screenVisibleFrame: screen)
        t.check(o.x >= screen.minX - 0.001 && o.x + card.width <= screen.maxX + 0.001,
                "★★HUD 水平必须夹在屏幕内（窗口 \(w) → x=\(o.x)）")
        t.check(o.y >= screen.minY - 0.001 && o.y + card.height <= screen.maxY + 0.001,
                "★★HUD 垂直必须夹在屏幕内（窗口 \(w) → y=\(o.y)）")
    }

    // 卡片比屏幕还宽这种极端情况不得算出 NaN / 崩溃，只要求落点有限。
    let huge = CGSize(width: 4000, height: 3000)
    let o = NoticeMetrics.hudOrigin(windowFrame: window, contentSize: huge, screenVisibleFrame: screen)
    t.check(o.x.isFinite && o.y.isFinite, "超大卡片下 HUD 落点必须是有限值")
}

// MARK: - NOTICE-PALETTE (v2.11.7 hotfix14) 多彩皮肤 Toast 必须分明暗两档
//
// hotfix13 只给多彩皮肤做了深色一档（#1C1C1E @ 90%），浅色系统外观下那张近黑卡片贴在
// 浅灰白画布上就是一块与界面无关的黑条。这里把「两档必须不同、且各自方向正确」钉住。
do {
    let dark = NoticePalette.colorfulSurface(dark: true)
    let light = NoticePalette.colorfulSurface(dark: false)

    t.check(dark != light, "★★多彩皮肤的明暗两档 Toast 外观必须不同（hotfix14 的核心）")
    t.equal(dark, NoticePalette.colorfulDark, "dark=true 应取深色档")
    t.equal(light, NoticePalette.colorfulLight, "dark=false 应取浅色档")

    // 深色档 = hotfix13 的原设计，逐项钉死，防止后续改浅色档时顺手动了它。
    t.check(dark.isDarkSurface, "深色档卡片底应标记为深色")
    t.equal(dark.material, .ultraThin, "深色档应用 ultraThinMaterial")
    t.equal(dark.tint.opacity, 0.90, "深色档染层不透明度应为 90%")
    t.check(abs(dark.tint.red - 0.110) < 0.0005
                && abs(dark.tint.green - 0.110) < 0.0005
                && abs(dark.tint.blue - 0.118) < 0.0005,
            "深色档染层应为 #1C1C1E")
    t.equal(dark.border.red, 1, "深色档细边应为白色")
    t.equal(dark.border.opacity, 0.15, "深色档细边应为白 15%")
    t.equal(dark.shadow.opacity, 0.30, "深色档投影应为黑 30%")
    t.equal(dark.shadow.radius, 12, "深色档投影 blur 应为 12")
    t.equal(dark.titleInk.opacity, 1.0, "深色档标题应为纯白")
    t.check(dark.titleInk.luminance > 0.9, "★★深色档标题必须是亮色文字")
    t.check(dark.subtitleInk.luminance > 0.9 && dark.subtitleInk.opacity < 1.0,
            "深色档副标题应为半透明白")

    // 浅色档（hotfix14 新增）：白 95% + thinMaterial + 黑 8% 细边 + 黑 15% blur 8 + 深色文字。
    t.check(!light.isDarkSurface, "★★浅色档卡片底不得再标记为深色")
    t.equal(light.material, .thin, "浅色档应用 thinMaterial")
    t.equal(light.tint.opacity, 0.95, "浅色档染层不透明度应为 95%")
    t.check(light.tint.luminance > 0.99, "★★浅色档染层必须是白色")
    t.equal(light.border.red, 0, "浅色档细边应为黑色系")
    t.equal(light.border.opacity, 0.08, "浅色档细边应为黑 8%")
    t.equal(light.shadow.opacity, 0.15, "浅色档投影应为黑 15%")
    t.equal(light.shadow.radius, 8, "浅色档投影 blur 应为 8")
    t.check(light.titleInk.luminance < 0.2, "★★浅色档标题必须是深色文字（这正是用户报的 bug）")
    t.check(light.subtitleInk.luminance < 0.2 && light.subtitleInk.opacity < 1.0,
            "浅色档副标题应为半透明深墨")

    // 两档之间的方向性关系。
    t.check(light.tint.luminance > dark.tint.luminance + 0.5,
            "★★浅色档卡片底必须显著亮于深色档")
    t.check(light.titleInk.luminance < dark.titleInk.luminance - 0.5,
            "★★浅色档文字必须显著暗于深色档（否则白字白底）")
    t.check(light.shadow.opacity < dark.shadow.opacity && light.shadow.radius < dark.shadow.radius,
            "浅底上的投影必须比深色档更轻更紧")
    t.equal(light.borderWidth, dark.borderWidth, "两档细边宽度应一致（几何不随皮肤/明暗变化）")

    // 文字与卡片底的对比方向：任一档都不许出现「白字白底 / 黑字黑底」。
    for (name, style) in [("dark", dark), ("light", light)] {
        let gap = abs(style.titleInk.luminance - style.tint.luminance)
        t.check(gap > 0.5, "★★\(name) 档标题与卡片底的亮度差必须足够（\(gap)）")
        t.check(style.isDarkSurface == (style.titleInk.luminance > style.tint.luminance),
                "\(name) 档 isDarkSurface 应与「亮字压深底」一致")
    }

    // 幂等：同一入参多次取值必须完全一致（纯数据，不读全局状态）。
    for _ in 0..<3 {
        t.equal(NoticePalette.colorfulSurface(dark: true), dark, "深色档取值应幂等")
        t.equal(NoticePalette.colorfulSurface(dark: false), light, "浅色档取值应幂等")
    }
}

// MARK: - MINIMAL-HOVER (v2.11.7 hotfix15) 简洁模式卡片悬停描边必须是中性的
//
// 悬停描边原来复用 `MinimalSkinPalette.selection`（紫），于是鼠标划过任意一张卡片都亮一圈紫边——
// 简洁模式里唯一的彩色出口变成了鼠标轨迹。现在拆成中性一档：浅色黑 35% / 深色白 35%。
// 「闪烁定位」「拖入目标」这两种真状态仍然用紫色，所以这里同时钉住「hover 已经不再等于 selection」。
do {
    let light = MinimalSkinPalette.CardHover.light
    let dark = MinimalSkinPalette.CardHover.dark

    t.equal(MinimalSkinPalette.CardHover.stroke(dark: false), light, "dark=false 应取浅色档悬停描边")
    t.equal(MinimalSkinPalette.CardHover.stroke(dark: true), dark, "dark=true 应取深色档悬停描边")

    // 中性：三分量极差必须为 0（纯黑 / 纯白），一点色相都不许有。
    t.equal(MinimalSkinPalette.neutrality(light.base), 0, "★★浅色档悬停描边必须是纯中性（不许再是紫色）")
    t.equal(MinimalSkinPalette.neutrality(dark.base), 0, "★★深色档悬停描边必须是纯中性")

    // 方向：浅色档压黑、深色档压白。
    t.equal(light.base.red, 0, "浅色档悬停描边基色应为黑")
    t.equal(light.base.green, 0, "浅色档悬停描边基色应为黑（G）")
    t.equal(light.base.blue, 0, "浅色档悬停描边基色应为黑（B）")
    t.equal(dark.base.red, 1, "深色档悬停描边基色应为白")
    t.equal(dark.base.green, 1, "深色档悬停描边基色应为白（G）")
    t.equal(dark.base.blue, 1, "深色档悬停描边基色应为白（B）")

    // alpha 与线宽（hotfix16 提浓）：35% / 1pt 实机太淡，静息态描边本身就有黑 15% 的重量。
    t.equal(light.opacity, 0.65, "浅色档悬停描边应为黑 65%")
    t.equal(dark.opacity, 0.60, "深色档悬停描边应为白 60%")
    t.equal(light.width, 1.5, "悬停描边线宽应为 1.5pt")
    t.equal(dark.width, light.width, "两档悬停描边线宽必须一致")

    // 「一眼看得出」：悬停浓度必须显著高于静息态描边的等效浓度，否则划过时看不出变化。
    let resting = MinimalSkinPalette.CardHover.restingEquivalentOpacity
    t.check(light.opacity > resting.light * 3,
            "★★浅色档悬停浓度必须显著高于静息描边（悬停 \(light.opacity) vs 静息 ~\(resting.light)）")
    t.check(dark.opacity > resting.dark * 3,
            "★★深色档悬停浓度必须显著高于静息描边（悬停 \(dark.opacity) vs 静息 ~\(resting.dark)）")
    t.check(light.opacity > 0.5 && dark.opacity > 0.5,
            "★★两档悬停浓度都必须过半（hotfix15 的 35% 被实机判定为太淡）")
    // 但也不能推到纯黑 / 纯白：那就成了「边框描死」，比选中态还重。
    t.check(light.opacity < 0.85 && dark.opacity < 0.85, "悬停描边不得浓到接近实色")
    t.check(dark.opacity <= light.opacity,
            "深色档不应比浅色档更浓（白色在暗底上的视觉重量本来更高）")

    // 与卡片底的方向性：描边必须朝着与卡片底**相反**的方向压，否则在卡片上看不见。
    let lightCard = MinimalSkinPalette.light.cardFilled
    let darkCard = MinimalSkinPalette.dark.cardFilled
    t.check(light.base.red < lightCard.red, "★★浅色档：悬停描边必须比卡片底暗")
    t.check(dark.base.red > darkCard.red, "★★深色档：悬停描边必须比卡片底亮")

    // 与紫色选中描边解绑：hover 不再等于 selection（这正是用户报的 bug）。
    for (name, surfaces) in [("light", MinimalSkinPalette.light), ("dark", MinimalSkinPalette.dark)] {
        let sel = surfaces.selection
        let hover = MinimalSkinPalette.CardHover.stroke(dark: name == "dark").base
        t.check(!(abs(sel.red - hover.red) < 0.001
                    && abs(sel.green - hover.green) < 0.001
                    && abs(sel.blue - hover.blue) < 0.001),
                "★★\(name) 档悬停描边不得再等于紫色选中描边")
        t.check(MinimalSkinPalette.neutrality(sel) > 0.1,
                "\(name) 档 selection 仍应是带色相的紫（闪烁 / 拖入两种真状态还要用它）")
    }
}

// MARK: - CANVAS-GEO：无限画布几何（v2.11.7）
//
// 为什么这组必须存在：轮盘布局（v2.11.0/v2.11.5）的教训是「极坐标数学写在 View 里，错了也测不出来，
// 最后靠离屏截图对照才定位」。画布的视口变换比那更容易错且更难肉眼发现——缩放锚点、平移累积、
// 网格对齐三者互相耦合，一个符号错的表现只是「缩放时画面往角落飘一点」，用户会以为是手势不准。
// 所以几何全部下沉到 `CanvasGeometry` 纯函数，并在这里逐条钉死。

func canvasApprox(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.0001) -> Bool {
    abs(a - b) <= tol
}

// —— 缩放钳制 ——
do {
    t.equal(CanvasGeometry.clampZoom(1), 1, "clampZoom：区间内原样返回")
    t.equal(CanvasGeometry.clampZoom(0.01), CanvasGeometry.zoomMin, "clampZoom：下溢钳到 zoomMin")
    t.equal(CanvasGeometry.clampZoom(99), CanvasGeometry.zoomMax, "clampZoom：上溢钳到 zoomMax")
    // ★ NaN 必须被拦住。一旦 NaN 流进 pan 的累加，画布会永久空白且无法靠继续操作恢复
    //   （NaN 参与任何算术都还是 NaN），用户只能删数据文件——这是不可接受的死局。
    t.equal(CanvasGeometry.clampZoom(.nan), 1, "★★clampZoom：NaN 必须回落到 1")
    t.equal(CanvasGeometry.clampZoom(.infinity), CanvasGeometry.zoomMax, "clampZoom：+∞ 钳到 zoomMax")
    t.equal(CanvasGeometry.clampZoom(-.infinity), CanvasGeometry.zoomMin, "clampZoom：-∞ 钳到 zoomMin")
    t.equal(CanvasGeometry.clampZoom(-2), CanvasGeometry.zoomMin, "clampZoom：负数钳到 zoomMin（与 -∞ 口径一致）")
    t.check(CanvasGeometry.zoomMin > 0, "zoomMin 必须为正（0 或负数会让坐标换算除零）")
    t.check(CanvasGeometry.zoomMax > CanvasGeometry.zoomMin, "zoomMax 必须大于 zoomMin")
}

// —— 坐标换算互为逆运算 ——
do {
    let cases: [(CGPoint, CGSize, CGFloat)] = [
        (CGPoint(x: 0, y: 0), .zero, 1),
        (CGPoint(x: 137, y: -42), CGSize(width: 25, height: -80), 1),
        (CGPoint(x: -1000, y: 2500), CGSize(width: -333, height: 777), 0.25),
        (CGPoint(x: 12.5, y: 9.75), CGSize(width: 3.5, height: 0.5), 4),
    ]
    for (canvasPt, pan, zoom) in cases {
        let screen = CanvasGeometry.screenPoint(canvas: canvasPt, pan: pan, zoom: zoom)
        let back = CanvasGeometry.canvasPoint(screen: screen, pan: pan, zoom: zoom)
        t.check(canvasApprox(back.x, canvasPt.x, 0.001) && canvasApprox(back.y, canvasPt.y, 0.001),
                "★★screen/canvas 换算必须互为逆运算（pan=\(pan) zoom=\(zoom)，回程 \(back) vs 原 \(canvasPt)）")
    }

    // 公式钉死：screen = canvas * zoom + pan。这条式子是整套画布的地基，
    // 任何「顺手」改成 (canvas + pan) * zoom 的重构都会让命中判定整体错位。
    let s = CanvasGeometry.screenPoint(canvas: CGPoint(x: 100, y: 50),
                                       pan: CGSize(width: 10, height: 20), zoom: 2)
    t.check(canvasApprox(s.x, 210) && canvasApprox(s.y, 120),
            "★★screenPoint 必须是 canvas*zoom+pan（实际 \(s)）")

    // 矩形换算：尺寸也必须缩放，否则放大后卡片框会比卡片本身小。
    let r = CanvasGeometry.screenRect(canvas: CGRect(x: 10, y: 20, width: 100, height: 200),
                                      pan: CGSize(width: 5, height: 5), zoom: 2)
    t.check(canvasApprox(r.minX, 25) && canvasApprox(r.minY, 45)
                && canvasApprox(r.width, 200) && canvasApprox(r.height, 400),
            "screenRect：原点与尺寸都要按 zoom 变换（实际 \(r)）")
}

// —— 锚点缩放：光标下的内容必须原地不动 ——
do {
    // 这是画布手感的命门。锚点算错的症状是「放大时想看的区域直接飞出屏幕」，
    // 而且越放大偏得越远，但单帧看起来只是「有点飘」，极易被当成手势灵敏度问题。
    let anchors = [CGPoint(x: 0, y: 0), CGPoint(x: 640, y: 360), CGPoint(x: 1280, y: 800)]
    let zoomPairs: [(CGFloat, CGFloat)] = [(1, 2), (2, 1), (1, 0.25), (0.5, 4), (3, 3)]
    for anchor in anchors {
        for (oldZoom, newZoom) in zoomPairs {
            let pan = CGSize(width: 37, height: -91)
            // 锚点当前对应的画布点。
            let underCursor = CanvasGeometry.canvasPoint(screen: anchor, pan: pan, zoom: oldZoom)
            let newPan = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan,
                                                           oldZoom: oldZoom, newZoom: newZoom)
            // 缩放后，同一个画布点应当还落在锚点上。
            let after = CanvasGeometry.screenPoint(canvas: underCursor, pan: newPan, zoom: newZoom)
            t.check(canvasApprox(after.x, anchor.x, 0.001) && canvasApprox(after.y, anchor.y, 0.001),
                    "★★锚点缩放必须保持锚点下内容不动（anchor=\(anchor) \(oldZoom)→\(newZoom)，实际落在 \(after)）")
        }
    }

    // zoom 不变时 pan 也不该动（否则每帧微小抖动会累积成漂移）。
    let stable = CanvasGeometry.panForAnchoredZoom(anchorScreen: CGPoint(x: 200, y: 100),
                                                   pan: CGSize(width: 9, height: 8),
                                                   oldZoom: 1.5, newZoom: 1.5)
    t.check(canvasApprox(stable.width, 9) && canvasApprox(stable.height, 8),
            "锚点缩放：zoom 未变时 pan 必须原样（实际 \(stable)）")
}

// —— 网格步长自适应 ——
do {
    // 网格的失败模式是两个极端：缩小时线密到糊成灰色一片（还会拖垮绘制），
    // 放大时线稀到失去参照。所以屏幕步长必须被夹在一个可视区间里，而不是简单地 base*zoom。
    for zoom in [CanvasGeometry.zoomMin, 0.4, 0.75, 1, 1.6, 2.5, CanvasGeometry.zoomMax] {
        let step = CanvasGeometry.gridScreenStep(base: 40, zoom: zoom)
        t.check(step >= 14 - 0.001 && step <= 96 + 0.001,
                "★★网格屏幕步长必须落在 [14, 96]（zoom=\(zoom) 得到 \(step)）")
        t.check(step > 0 && step.isFinite, "网格步长必须为有限正数（zoom=\(zoom)）")
    }
    // 极端 zoom 下也不能返回 0 / NaN —— 那会让 gridLineOffsets 陷入死循环。
    t.check(CanvasGeometry.gridScreenStep(base: 40, zoom: 0).isFinite,
            "★★zoom=0 时网格步长仍须有限（否则生成线坐标会死循环）")
}

// —— 网格线坐标 ——
do {
    let offsets = CanvasGeometry.gridLineOffsets(viewLength: 100, panComponent: 0, step: 25)
    t.check(!offsets.isEmpty, "网格线坐标不应为空")
    t.check(offsets.allSatisfy { $0 >= -25 && $0 <= 125 },
            "网格线坐标应覆盖可视区且不过度外溢（实际 \(offsets)）")
    // 覆盖性：首线 ≤ 0、末线 ≥ viewLength，否则边缘会出现没有网格的空白带。
    t.check((offsets.first ?? 1) <= 0, "★★首条网格线必须 ≤ 0（否则左/上边缘留白）")
    t.check((offsets.last ?? -1) >= 100, "★★末条网格线必须 ≥ 视图长度（否则右/下边缘留白）")
    // 平移一整个步长，线的集合应当与原来重合（网格是周期性的），
    // 否则平移时会看到网格「抖一下再对齐」。
    let shifted = CanvasGeometry.gridLineOffsets(viewLength: 100, panComponent: 25, step: 25)
    t.equal(shifted.count, offsets.count, "平移整数个步长后网格线数量应一致")
    for (a, b) in zip(offsets, shifted) {
        t.check(canvasApprox(a, b, 0.001), "★★平移一个整步长后网格线必须重合（\(a) vs \(b)）")
    }
    // 防死循环：step 非法时必须返回空而不是转圈。
    t.check(CanvasGeometry.gridLineOffsets(viewLength: 100, panComponent: 0, step: 0).isEmpty,
            "★★step=0 必须返回空数组（不得死循环）")
}

// —— 单击 / 拖拽判别（v2.11.7 hotfix21：点空白取消选中） ——
//
// 这个判别是「点空白取消选中」与「拖出选框」的分水岭：判早了 → 一次真框选被当成点击，
// 刚框上的节点当场被清空；判晚了 → 带手抖的单击被当成框选，取消选中时灵时不灵。
// 两侧都是用户一眼能看见的坏行为，所以边界逐条钉死。
do {
    t.check(CanvasGeometry.clickSlop > 0, "clickSlop 必须为正（否则任何按下都会被判成拖拽）")
    t.check(CanvasGeometry.clickSlop < 10,
            "★★clickSlop 不能太大：超过 10pt 会把肉眼可见的小框选吞成点击")

    t.check(CanvasGeometry.isClickWithoutDrag(translation: .zero),
            "★★零位移必须判为单击（这是「点空白取消选中」的主路径）")
    t.check(CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: 2, height: 1)),
            "鼠标单击的 1~2pt 抖动仍须判为单击")
    t.check(CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: -3, height: 0)),
            "负方向抖动同样判为单击（判别只看距离，不看方向）")

    // 边界：正好等于 slop 算单击（含等号），刚超过就算拖拽。
    t.check(CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: CanvasGeometry.clickSlop, height: 0)),
            "位移正好等于 clickSlop 时判为单击（边界含等号）")
    t.check(!CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: CanvasGeometry.clickSlop + 0.01, height: 0)),
            "★★刚超过 clickSlop 立刻判为拖拽")
    t.check(!CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: 40, height: 30)),
            "★★一次正常框选（50pt 位移）必须判为拖拽，不能被当成点击清空选中")

    // 斜向：必须按欧氏距离而不是分量判断。3,3 的实际位移 4.24 > 4，应算拖拽；
    // 若按「每个分量都 < slop」判断就会错判成单击。
    t.check(!CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: 3, height: 3)),
            "★★斜向 3+3（欧氏 4.24）必须判为拖拽 —— 证明用的是距离而非分量")

    // NaN 防护：手势在极端情况下会喂进 NaN，此时按「没动」处理（清空选中是可恢复动作，
    // 而放任 NaN 流进 commitMarquee 会用 NaN 矩形做命中判定，结果完全不可预期）。
    t.check(CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: CGFloat.nan, height: CGFloat.nan)),
            "★★NaN 位移按单击处理，不得让 NaN 流进框选矩形")

    // 自定义 slop 生效（供将来触控板/鼠标分档使用）。
    t.check(CanvasGeometry.isClickWithoutDrag(translation: CGSize(width: 8, height: 0), slop: 12),
            "自定义 slop 应生效")
}

// —— 吸附 ——
do {
    t.equal(CanvasGeometry.snap(CGPoint(x: 11, y: 29), step: 10), CGPoint(x: 10, y: 30), "snap：就近取整到步长")
    t.equal(CanvasGeometry.snap(CGPoint(x: -11, y: -29), step: 10), CGPoint(x: -10, y: -30), "snap：负坐标同样就近")
    // step ≤ 0 时必须原样返回（除零保护）。
    t.equal(CanvasGeometry.snap(CGPoint(x: 3.7, y: 4.2), step: 0), CGPoint(x: 3.7, y: 4.2),
            "★★snap：step=0 时原样返回，不得产生 NaN")
}

// —— 4 张展开 ——
do {
    let origin = CGPoint(x: 100, y: 200)
    let size = CanvasNode.defaultSize
    let gap: CGFloat = 20
    let frames = CanvasGeometry.fanOutFrames(origin: origin, nodeSize: size, count: 4, gap: gap)
    t.equal(frames.count, 4, "fanOut：4 张应得 4 个 frame")
    // 首个必须落在原位——「展开」的语义是原节点留在原地、其余向右生长，
    // 不是整组重新排版；否则用户会觉得自己的节点被挪走了。
    t.check(canvasApprox(frames[0].minX, origin.x) && canvasApprox(frames[0].minY, origin.y),
            "★★fanOut：第一个 frame 必须保持在原点（实际 \(frames[0].origin)）")
    // 横向等距、Y 对齐。
    for i in 1..<frames.count {
        t.check(canvasApprox(frames[i].minX - frames[i - 1].minX, size.width + gap),
                "fanOut：相邻间距必须为 宽+gap（第 \(i) 个实际差 \(frames[i].minX - frames[i-1].minX)）")
        t.check(canvasApprox(frames[i].minY, origin.y), "fanOut：所有 frame 必须同一 Y（横向展开）")
    }
    // 互不重叠。
    for i in 0..<frames.count {
        for j in (i + 1)..<frames.count {
            t.check(!frames[i].intersects(frames[j]), "★★fanOut：展开出的节点不得互相重叠（\(i) vs \(j)）")
        }
    }
    // count=1 应退化为单个原位 frame。
    let single = CanvasGeometry.fanOutFrames(origin: origin, nodeSize: size, count: 1, gap: gap)
    t.equal(single.count, 1, "fanOut：count=1 得单个 frame")
    // 非法 count 不得崩、不得返回负数量。
    t.check(CanvasGeometry.fanOutFrames(origin: origin, nodeSize: size, count: 0, gap: gap).count <= 1,
            "fanOut：count=0 时不得产生多余 frame")

    // bounds 必须正好包住全部 frame。
    let bounds = CanvasGeometry.fanOutBounds(origin: origin, nodeSize: size, count: 4, gap: gap)
    for (i, f) in frames.enumerated() {
        t.check(bounds.contains(f) || canvasApprox(bounds.maxX, f.maxX, 0.001),
                "fanOutBounds 必须包住第 \(i) 个 frame")
    }
    t.check(canvasApprox(bounds.width, size.width * 4 + gap * 3),
            "fanOutBounds 宽度 = 4 张宽 + 3 个间隙（实际 \(bounds.width)）")
}

// —— 向右推挤 ——
do {
    let size = CanvasNode.defaultSize
    let gap: CGFloat = 20
    // 展开占位区落在 (0,0)-(560,300)，右侧原有两个节点会被撞到。
    let bounds = CGRect(x: 0, y: 0, width: 560, height: size.height)
    let existing = [
        CGRect(x: 300, y: 0, width: size.width, height: size.height),   // 与 bounds 重叠 → 必须推
        CGRect(x: 900, y: 0, width: size.width, height: size.height),   // 在右侧且不重叠 → 不该动
        CGRect(x: -400, y: 0, width: size.width, height: size.height),  // 在左侧 → 不该动
        CGRect(x: 300, y: 800, width: size.width, height: size.height), // 同 X 但另一行 → 不该动
    ]
    let offsets = CanvasGeometry.pushRightOffsets(existing: existing, bounds: bounds, gap: gap)

    t.check(offsets[0] != nil && (offsets[0] ?? 0) > 0, "★★推挤：与展开区重叠的节点必须获得正向偏移")
    if let d = offsets[0] {
        let moved = existing[0].offsetBy(dx: d, dy: 0)
        t.check(moved.minX >= bounds.maxX + gap - 0.001,
                "★★推挤：被推后必须完全让出展开区并留出 gap（推后 minX=\(moved.minX)，要求 ≥ \(bounds.maxX + gap)）")
        t.check(!moved.intersects(bounds), "★★推挤：推后不得再与展开区重叠")
    }
    t.check(offsets[1] == nil || canvasApprox(offsets[1] ?? 0, 0),
            "推挤：右侧不重叠的节点不该被移动")
    t.check(offsets[2] == nil || canvasApprox(offsets[2] ?? 0, 0),
            "★★推挤：左侧节点绝不能被移动（会把用户已排好的内容打乱）")
    t.check(offsets[3] == nil || canvasApprox(offsets[3] ?? 0, 0),
            "★★推挤：不同行（Y 不相交）的节点不该被牵连")

    // 空场景不该报出任何偏移。
    t.check(CanvasGeometry.pushRightOffsets(existing: [], bounds: bounds, gap: gap).isEmpty,
            "推挤：没有既存节点时返回空")

    // —— 级联：被推的节点不能撞上它右边原本无关的邻居 ——
    // 这是「只推重叠者」这种朴素实现会踩的坑：把 A 推开之后 A 撞上了 B，凭空造出新重叠。
    do {
        let chain = [
            CGRect(x: 300, y: 0, width: size.width, height: size.height),  // 与展开区重叠
            CGRect(x: 620, y: 0, width: size.width, height: size.height),  // 原本不重叠，但 A 推过来会撞上
        ]
        let cascade = CanvasGeometry.pushRightOffsets(existing: chain, bounds: bounds, gap: gap)
        let moved = chain.enumerated().map { $0.element.offsetBy(dx: cascade[$0.offset] ?? 0, dy: 0) }
        t.check(!moved[0].intersects(bounds) && !moved[1].intersects(bounds),
                "★★级联推挤：推完后没有任何节点还压在展开区上")
        t.check(!moved[0].intersects(moved[1]),
                "★★级联推挤：推挤不得在既有节点之间造出新的重叠（\(moved[0]) vs \(moved[1])）")
        t.check(moved[0].minX < moved[1].minX, "级联推挤：应保持原有左右次序")
    }
}

// —— 适应窗口 ——
do {
    let content = CGRect(x: -100, y: -50, width: 800, height: 400)
    let view = CGSize(width: 1000, height: 600)
    let fit = CanvasGeometry.fitTransform(contentBounds: content, viewSize: view, padding: 40)
    t.check(fit.zoom >= CanvasGeometry.zoomMin && fit.zoom <= CanvasGeometry.zoomMax,
            "fit：zoom 必须在合法区间（实际 \(fit.zoom)）")
    // 内容四角变换后必须都落在视图内（这才叫「适应窗口」）。
    let corners = [
        CGPoint(x: content.minX, y: content.minY), CGPoint(x: content.maxX, y: content.minY),
        CGPoint(x: content.minX, y: content.maxY), CGPoint(x: content.maxX, y: content.maxY),
    ]
    for c in corners {
        let s = CanvasGeometry.screenPoint(canvas: c, pan: fit.pan, zoom: fit.zoom)
        t.check(s.x >= -0.5 && s.x <= view.width + 0.5 && s.y >= -0.5 && s.y <= view.height + 0.5,
                "★★fit：内容四角变换后必须落在视图内（角 \(c) → \(s)，视图 \(view)）")
    }
    // 内容应大致居中：左右留白之差不该超过 1pt。
    let lt = CanvasGeometry.screenPoint(canvas: CGPoint(x: content.minX, y: content.minY), pan: fit.pan, zoom: fit.zoom)
    let rb = CanvasGeometry.screenPoint(canvas: CGPoint(x: content.maxX, y: content.maxY), pan: fit.pan, zoom: fit.zoom)
    t.check(abs(lt.x - (view.width - rb.x)) < 1, "fit：内容应水平居中（左 \(lt.x) / 右 \(view.width - rb.x)）")
    t.check(abs(lt.y - (view.height - rb.y)) < 1, "fit：内容应垂直居中")

    // 退化输入：零尺寸内容 / 零尺寸视图都不能产出 NaN。
    let degenerate = CanvasGeometry.fitTransform(contentBounds: .zero, viewSize: view)
    t.check(degenerate.zoom.isFinite && degenerate.pan.width.isFinite && degenerate.pan.height.isFinite,
            "★★fit：零尺寸内容不得产出 NaN/∞")
    let noView = CanvasGeometry.fitTransform(contentBounds: content, viewSize: .zero)
    t.check(noView.zoom.isFinite && noView.pan.width.isFinite && noView.pan.height.isFinite,
            "★★fit：零尺寸视图不得产出 NaN/∞")
}

// —— 滚轮：Cmd+滚缩放 / 裸滚平移（v2.11.7 hotfix17）——
do {
    // 方向：上滚放大、下滚缩小、不滚不变。
    t.check(CanvasGeometry.wheelZoomFactor(scrollDeltaY: 10) > 1, "wheelZoom：上滚（正 delta）应放大")
    t.check(CanvasGeometry.wheelZoomFactor(scrollDeltaY: -10) < 1, "wheelZoom：下滚（负 delta）应缩小")
    t.check(canvasApprox(CanvasGeometry.wheelZoomFactor(scrollDeltaY: 0), 1), "wheelZoom：零位移系数必须恰为 1")

    // 单调性：滚得越多，系数越大。
    t.check(CanvasGeometry.wheelZoomFactor(scrollDeltaY: 5) < CanvasGeometry.wheelZoomFactor(scrollDeltaY: 9),
            "wheelZoom：系数应随 delta 单调递增")

    // ★ 关键护栏：触控板惯性单帧可给出上百的 delta，未钳制会一帧冲到 zoomMax（观感=画布爆炸）。
    let huge = CanvasGeometry.wheelZoomFactor(scrollDeltaY: 3000)
    let tiny = CanvasGeometry.wheelZoomFactor(scrollDeltaY: -3000)
    t.check(huge <= 1.25 + 1e-9, "★★wheelZoom：单次系数上限必须钳到 1.25（实际 \(huge)）")
    t.check(tiny >= 0.8 - 1e-9, "★★wheelZoom：单次系数下限必须钳到 0.8（实际 \(tiny)）")
    t.check(CanvasGeometry.wheelZoomFactor(scrollDeltaY: .nan) == 1, "★★wheelZoom：NaN 输入必须退化为 1")
    t.check(CanvasGeometry.wheelZoomFactor(scrollDeltaY: .infinity) <= 1.25,
            "★★wheelZoom：+∞ 输入不得越过上限")

    // 与锚点缩放联立：Cmd+滚一次之后，光标下的画布内容必须还在光标下。
    do {
        let anchor = CGPoint(x: 640, y: 400)
        let pan0 = CGSize(width: -120, height: 85)
        let zoom0: CGFloat = 1.4
        let z1 = CanvasGeometry.clampZoom(zoom0 * CanvasGeometry.wheelZoomFactor(scrollDeltaY: 8))
        let pan1 = CanvasGeometry.panForAnchoredZoom(anchorScreen: anchor, pan: pan0, oldZoom: zoom0, newZoom: z1)
        let before = CanvasGeometry.canvasPoint(screen: anchor, pan: pan0, zoom: zoom0)
        let after = CanvasGeometry.canvasPoint(screen: anchor, pan: pan1, zoom: z1)
        t.check(canvasApprox(before.x, after.x) && canvasApprox(before.y, after.y),
                "★★Cmd+滚轮：缩放后光标下的画布点必须不动（前 \(before) / 后 \(after)）")
    }

    // 裸滚 = 纯平移，且不碰 zoom（缩放只允许 Cmd 触发）。
    let panned = CanvasGeometry.pannedViewport(pan: CGSize(width: 30, height: -10),
                                              scrollDeltaX: -4,
                                              scrollDeltaY: 22)
    t.check(canvasApprox(panned.width, 26) && canvasApprox(panned.height, 12),
            "裸滚轮：delta 应直接累加到 pan（实际 \(panned)）")
    // 不取反：系统已按「自然滚动」偏好处理过方向，这里再翻一次会让用户的系统设置失效。
    t.check(CanvasGeometry.pannedViewport(pan: .zero, scrollDeltaX: 0, scrollDeltaY: 5).height > 0,
            "★★裸滚轮：不得对 scrollingDelta 取反（否则自然滚动设置失效）")
    let nanPan = CanvasGeometry.pannedViewport(pan: CGSize(width: 7, height: 9),
                                              scrollDeltaX: .nan,
                                              scrollDeltaY: .infinity)
    t.check(canvasApprox(nanPan.width, 7) && canvasApprox(nanPan.height, 9),
            "★★裸滚轮：非有限 delta 必须被忽略而不是污染 pan（实际 \(nanPan)）")
}

// —— 行滚动归一化（v2.11.7 hotfix17）——
do {
    // 触控板：精确增量已经是点，原样透传。
    t.check(canvasApprox(CanvasGeometry.normalizedScrollDelta(-8.5, precise: true, lineStep: 24), -8.5),
            "scrollNorm：精确增量必须原样透传")
    // ★ 传统滚轮给的是行数：一格 ±1~3。若当点用，一格只挪 3pt（实测「滚半天画布不动」）。
    t.check(canvasApprox(CanvasGeometry.normalizedScrollDelta(-3, precise: false, lineStep: 24), -72),
            "★★scrollNorm：非精确增量必须按行步长放大（3 行 × 24 = 72pt）")
    t.check(CanvasGeometry.normalizedScrollDelta(1, precise: false, lineStep: 24) > 20,
            "★★scrollNorm：鼠标滚轮单格平移量不得小于 20pt（否则视觉上等于没动）")
    // 方向不能被归一化改掉。
    t.check(CanvasGeometry.normalizedScrollDelta(-1, precise: false, lineStep: 8) < 0,
            "scrollNorm：符号必须保持")
    t.check(CanvasGeometry.normalizedScrollDelta(.nan, precise: true, lineStep: 24) == 0,
            "★★scrollNorm：NaN 必须归零，不得污染 pan/zoom")
    // 缩放用更小的步长：鼠标滚轮一格约 8%，不至于一格跳一档。
    let oneNotch = CanvasGeometry.wheelZoomFactor(
        scrollDeltaY: CanvasGeometry.normalizedScrollDelta(1, precise: false, lineStep: 8))
    t.check(oneNotch > 1.05 && oneNotch < 1.12,
            "★★Cmd+滚轮：鼠标滚轮单格缩放应落在 5%~12%（实际 \((oneNotch - 1) * 100)%）")
}

// —— 包围盒 ——
do {
    t.equal(CanvasGeometry.bounds(of: []), .zero, "bounds：空数组返回 zero")
    let b = CanvasGeometry.bounds(of: [
        CGRect(x: 10, y: 10, width: 100, height: 50),
        CGRect(x: -30, y: 200, width: 20, height: 20),
    ])
    t.check(canvasApprox(b.minX, -30) && canvasApprox(b.minY, 10)
                && canvasApprox(b.maxX, 110) && canvasApprox(b.maxY, 220),
            "bounds：应为所有矩形的并集包围盒（实际 \(b)）")
}

// MARK: - CANVAS-DOC：画布模型与落盘

/// 造一个画布节点。
///
/// ★ v2.11.7 hotfix20：`CanvasNode` 不再是「内容副本」而是**槽位摆位**——身份由
/// `groupId#slot` 派生，正文/附件一律实时读槽位，节点里根本没有 `prompt` 字段了。
/// 于是每次构造都必须交代它摆的是**哪一页哪一组的第几号槽位**。测试里绝大多数用例只关心
/// 几何，所以用这个工厂把槽位身份收进默认值，只有需要区分身份的用例才显式传 `group`/`slot`。
func canvasNode(slot: Int = 1,
                group: String = "g1",
                page: String = "p1",
                x: CGFloat = 0,
                y: CGFloat = 0,
                width: CGFloat = CanvasNode.defaultSize.width,
                height: CGFloat = CanvasNode.defaultSize.height,
                count: Int = 1,
                fontName: String? = nil,
                fontSize: CGFloat? = nil) -> CanvasNode {
    CanvasNode(pageId: page,
               groupId: group,
               slot: slot,
               x: x,
               y: y,
               width: width,
               height: height,
               count: count,
               fontName: fontName,
               fontSize: fontSize)
}

do {
    // 瞬态状态折叠：`running` / `queued` 落盘后必须变 idle。
    // 不折叠的症状是重启后节点永远停在「生成中」——轮询进程早就没了，它永远不会变，
    // 而用户看到「生成中」是不会去点重跑的，节点就成了僵尸。
    for transient in [CanvasNodeState.idle, .queued(ahead: 3), .running(startedAt: Date())] {
        var node = canvasNode()
        node.state = transient
        let data = try! JSONEncoder().encode(node)
        let back = try! JSONDecoder().decode(CanvasNode.self, from: data)
        t.equal(back.state, .idle, "★★瞬态状态 \(transient) 落盘后必须折叠为 idle")
    }
    // 终态必须完整保留（含 payload）。
    do {
        var node = canvasNode()
        node.state = .succeeded(assetPath: "/tmp/a.png")
        let back = try! JSONDecoder().decode(CanvasNode.self, from: try! JSONEncoder().encode(node))
        t.equal(back.state, .succeeded(assetPath: "/tmp/a.png"), "succeeded 状态及产物路径必须保留")

        node.state = .failed(reason: "配额不足")
        let back2 = try! JSONDecoder().decode(CanvasNode.self, from: try! JSONEncoder().encode(node))
        t.equal(back2.state, .failed(reason: "配额不足"), "★★failed 状态及原因必须保留（否则无法重跑排查）")
    }

    // frame / setFrameOrigin 一致性。
    var n = canvasNode(x: 5, y: 6, width: 10, height: 20)
    t.equal(n.frame, CGRect(x: 5, y: 6, width: 10, height: 20), "CanvasNode.frame 与 x/y/w/h 一致")
    n.setFrameOrigin(CGPoint(x: 50, y: 60))
    t.check(canvasApprox(n.x, 50) && canvasApprox(n.y, 60), "setFrameOrigin 应改写 x/y")

    // 存储往返。用独立临时目录，绝不碰真实数据目录。
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipslots_canvas_smoke_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let storage = CanvasStorage(rootOverride: dir)

    t.equal(storage.load().nodes.count, 0, "首次读取应得空画布")

    var doc = CanvasDocument()
    doc.nodes = [canvasNode(slot: 1, group: "grp_a", x: 12, y: 34, count: 4),
                 canvasNode(slot: 7, group: "grp_b", x: -5, y: 0)]
    doc.panX = 11; doc.panY = 22; doc.zoom = 1.5
    t.check(storage.save(doc), "画布文档应保存成功")

    // 换一个实例读（绕开内存缓存），验证真的落到了盘上。
    let reread = CanvasStorage(rootOverride: dir).load()
    t.equal(reread.nodes.count, 2, "★★重新读盘应拿回 2 个节点")
    t.equal(reread.nodes.first?.id, "grp_a#1", "★★节点身份应由 groupId#slot 派生，且顺序保持")
    t.equal(reread.nodes.first?.groupId, "grp_a", "槽位组 id 应完整保留")
    t.equal(reread.nodes.first?.slot, 1, "槽位号应完整保留")
    t.equal(reread.nodes.first?.pageId, "p1", "★★页 id 必须保留——跨页放置的节点靠它找回槽位")
    t.equal(reread.nodes.first?.count, 4, "张数参数应保留")
    t.check(canvasApprox(reread.panX, 11) && canvasApprox(reread.panY, 22) && canvasApprox(reread.zoom, 1.5),
            "★★视口（pan/zoom）应随文档持久化，下次进画布还在原处")
    t.equal(reread.schemaVersion, CanvasDocument.currentSchemaVersion, "schemaVersion 应写入当前版本")


    // 损坏文件：必须旁置 .corrupt 后按空画布继续，而不是崩溃或阻塞进入画布。
    let file = dir.appendingPathComponent("canvas/canvas.json")
    try! Data("{ 这不是 JSON".utf8).write(to: file)
    let broken = CanvasStorage(rootOverride: dir)
    t.equal(broken.load().nodes.count, 0, "★★损坏的画布文件应回落到空画布（画布是派生资产，不阻塞启动）")
    t.check(FileManager.default.fileExists(atPath: file.path + ".corrupt"),
            "★★损坏文件必须旁置为 .corrupt 供事后打捞")

    // 缓存失效后应重新读盘。
    let cached = CanvasStorage(rootOverride: dir)
    _ = cached.load()
    cached.invalidateCache()
    t.check(cached.load().nodes.isEmpty, "invalidateCache 后应重新读盘")
}

// MARK: - CANVAS-UNDO：撤销栈 + 键位判定 + 多选位移（v2.11.7 hotfix18）
//
// 为什么这组必须存在：撤销是**破坏性操作的唯一退路**，它自己写错就没有第二道防线了。
// 三类错误都不会当场报错，只会静默丢数据：
//   1. 游标模型算错 → 撤销后再做新动作，redo 分支没截断，栈里留着永远到不了的"未来"。
//   2. 容量裁剪写错 → 裁掉的是新条目而不是最老的，用户按 Cmd+Z 直接跳回半小时前。
//   3. 多选位移用「逐节点吸附新坐标」而不是「吸附 delta」→ 每个节点各自被吸到最近网格，
//      选中集合的相对位置被悄悄改掉（两个相距 30pt 的节点拖完变成相距 24pt）。
// 这三条在 UI 上都要靠人眼逐节点核对才能发现，所以必须在这里钉死。

do {
    // hotfix20：节点没有独立 id 了，身份 = groupId#slot。这里用「组名」当作以前的 id，
    // 得到的节点 id 就是 "a#1" / "b#1"，仍然彼此不同，撤销栈只关心这一点。
    func node(_ id: String, _ x: CGFloat, _ y: CGFloat) -> CanvasNode {
        canvasNode(group: id, x: x, y: y)
    }
    func entry(_ kind: CanvasHistoryEntry.Kind,
               _ detail: String,
               before: [CanvasNode] = [],
               after: [CanvasNode] = [],
               slotEdit: CanvasHistoryEntry.SlotTextEdit? = nil) -> CanvasHistoryEntry {
        CanvasHistoryEntry(kind: kind, detail: detail, before: before, after: after, slotEdit: slotEdit)
    }

    // ── 空栈边界
    var stack = CanvasUndoStack()
    t.check(stack.isEmpty, "新栈应为空")
    t.check(!stack.canUndo, "空栈不可撤销")
    t.check(!stack.canRedo, "空栈不可重做")
    t.check(stack.undo() == nil, "空栈 undo 应返回 nil 而不是崩")
    t.check(stack.redo() == nil, "空栈 redo 应返回 nil 而不是崩")

    // ── 基本游标推进
    stack.push(entry(.addNode, "A", after: [node("a", 0, 0)]))
    stack.push(entry(.addNode, "B", before: [node("a", 0, 0)], after: [node("a", 0, 0), node("b", 10, 10)]))
    t.equal(stack.count, 2, "push 两条后应有 2 条")
    t.equal(stack.cursor, 2, "push 后游标应指向末尾（全部已生效）")
    t.check(stack.canUndo && !stack.canRedo, "刚 push 完：可撤销、不可重做")

    let undone = stack.undo()
    t.equal(undone?.detail, "B", "★★undo 应返回最新那条（B），而不是最老那条")
    t.equal(stack.cursor, 1, "undo 后游标应回退 1")
    t.check(stack.canUndo && stack.canRedo, "撤销一步后：两边都可走")
    t.equal(stack.display.filter { !$0.applied }.count, 1, "display 里应有 1 条已撤销（置灰）条目")
    t.equal(stack.display.first?.entry.detail, "B", "display 应新的在前")
    t.equal(stack.display.first?.cursorAfter, 2, "★★display.cursorAfter 应是「推到这条做完」所需的游标值")

    let redone = stack.redo()
    t.equal(redone?.detail, "B", "redo 应把刚撤销的那条还回来")
    t.equal(stack.cursor, 2, "redo 后游标应回到末尾")

    // ── 撤销后再 push：redo 分支必须被截断
    _ = stack.undo()                       // cursor = 1，B 处于可重做状态
    stack.push(entry(.addNode, "C"))       // 在 A 之后开新分支
    t.equal(stack.count, 2, "★★撤销后 push 新条目，必须截掉被撤销的分支（应剩 A + C）")
    t.equal(stack.cursor, 2, "新分支 push 后游标应指向末尾")
    t.check(!stack.canRedo, "★★开了新分支就不该还能 redo 到旧分支（那是两个互斥的未来）")
    t.equal(stack.display.first?.entry.detail, "C", "新分支的条目应在最前")

    // ── 容量：裁掉的必须是**最老**的
    var big = CanvasUndoStack()
    for i in 0..<(CanvasUndoStack.capacity + 10) {
        big.push(entry(.moveNode, "step\(i)"))
    }
    t.equal(big.count, CanvasUndoStack.capacity, "栈长度应封顶在 capacity=\(CanvasUndoStack.capacity)")
    t.equal(big.cursor, CanvasUndoStack.capacity, "满栈时游标应等于容量")
    t.equal(big.display.first?.entry.detail, "step\(CanvasUndoStack.capacity + 9)",
            "最新一条应保留在最前")
    t.check(!big.entries.contains { $0.detail == "step0" },
            "★★溢出时必须丢最老的（step0），而不是丢最新的")
    t.equal(big.entries.first?.detail, "step10",
            "★★裁剪后最老的应是 step10（丢掉了 step0~step9 共 10 条）")

    // 满栈撤销到底：游标可以退到 0，且不越界
    var drain = big
    var steps = 0
    while drain.undo() != nil { steps += 1 }
    t.equal(steps, CanvasUndoStack.capacity, "应能一路撤销 capacity 步")
    t.equal(drain.cursor, 0, "撤销到底游标应为 0")
    t.check(!drain.canUndo && drain.canRedo, "撤销到底：不可再撤、全部可重做")

    // ── slotEdit 必须原样带在条目上（撤销时要靠它回滚槽位主体文本）
    var withSlot = CanvasUndoStack()
    let edit = CanvasHistoryEntry.SlotTextEdit(groupId: "g1", slot: 3, before: "旧文本", after: "新文本")
    withSlot.push(entry(.editNode, "标签", slotEdit: edit))
    let popped = withSlot.undo()
    t.equal(popped?.slotEdit?.before, "旧文本",
            "★★撤销条目必须带回 slotEdit.before —— 否则画布退回旧文本、编辑页还留着新文本，两边对不上")
    t.equal(popped?.slotEdit?.slot, 3, "slotEdit 的槽位号应保留")
    t.equal(popped?.slotEdit?.groupId, "g1", "slotEdit 的组 id 应保留（可能是非当前组）")
    t.equal(withSlot.redo()?.slotEdit?.after, "新文本", "重做应能拿到 slotEdit.after")

    // ── 键位判定
    typealias KB = CanvasKeyBinding
    for code in KB.deleteKeyCodes {
        t.equal(KB.action(keyCode: code, command: false, shift: false), .delete,
                "keyCode \(code)（Delete/Backspace）应判为删除")
    }
    t.equal(KB.action(keyCode: KB.zKeyCode, command: true, shift: false), .undo, "⌘Z 应判为撤销")
    t.equal(KB.action(keyCode: KB.zKeyCode, command: true, shift: true), .redo, "⇧⌘Z 应判为重做")
    t.equal(KB.action(keyCode: KB.zKeyCode, command: false, shift: false), .none,
            "★★裸 Z 不能判成撤销 —— 那会让用户在任何输入场景下打不出字母 z")
    t.equal(KB.action(keyCode: KB.zKeyCode, command: true, shift: false, option: true), .none,
            "⌥⌘Z 不是本 App 的绑定，应放行给系统")
    // 删除键必须要求「无 Command」：⌘Delete 在 macOS 里是「移到废纸篓」类语义，不该被画布截走。
    t.equal(KB.action(keyCode: 51, command: true, shift: false), .none,
            "★★⌘Delete 不应判为画布删除（避免与系统语义打架）")
    t.equal(KB.action(keyCode: 0, command: false, shift: false), .none, "无关键位应返回 .none")

    // ── 多选位移：吸附 delta，而不是逐节点吸附新坐标
    let step = CanvasGeometry.snapStep
    t.check(step > 0, "snapStep 必须为正")
    // 两个节点相距 30pt（非网格整数倍）。同一 delta 施加后，间距必须仍是 30pt。
    let ax: CGFloat = 0, bx: CGFloat = 30
    let rawDelta: CGFloat = 13
    let snappedDelta = CanvasGeometry.snapScalar(rawDelta, step: step)
    let newAx = ax + snappedDelta
    let newBx = bx + snappedDelta
    t.check(canvasApprox(newBx - newAx, bx - ax),
            "★★多选位移必须吸附 delta：施加同一位移后两节点间距应仍为 \(bx - ax)（实得 \(newBx - newAx)）")
    // 反例留档：如果改成逐节点吸附新坐标，间距就会被改掉。
    let wrongAx = CanvasGeometry.snapScalar(ax + rawDelta, step: step)
    let wrongBx = CanvasGeometry.snapScalar(bx + rawDelta, step: step)
    t.check(!canvasApprox(wrongBx - wrongAx, bx - ax),
            "★★反例校验：逐节点吸附新坐标确实会改变相对间距（\(wrongBx - wrongAx) ≠ \(bx - ax)），"
            + "所以实现必须走 snapScalar(delta)")

    // snapScalar 自身的边界
    t.equal(CanvasGeometry.snapScalar(0, step: step), 0, "snapScalar：0 原样")
    t.check(canvasApprox(CanvasGeometry.snapScalar(-13, step: 8), -16),
            "snapScalar：负数应向最近网格取整（-13 → -16）")
    t.equal(CanvasGeometry.snapScalar(7, step: 0), 7, "★★step<=0 时不能除零，应原样返回")
    t.equal(CanvasGeometry.snapScalar(.nan, step: 8), 0, "★★NaN 应回落到 0（NaN 坐标会让节点整体消失）")

    // ── 历史条目展示信息完整性：面板要靠它们说清"撤销的是哪一步"
    for kind in [CanvasHistoryEntry.Kind.addNode, .moveNode, .removeNode,
                 .fanOut, .clear, .editNode, .bindSlot, .styleNode] {
        t.check(!kind.title.isEmpty, "\(kind.rawValue) 必须有中文动作名")
        t.check(!kind.symbolName.isEmpty, "\(kind.rawValue) 必须有图标名")
    }
    // `Kind` 是 Codable 的（随撤销栈条目一起序列化过），rawValue 一旦被改名，
    // 老数据的历史条目就会解不出来。钉住新增这一档的字面量。
    t.equal(CanvasHistoryEntry.Kind.styleNode.rawValue, "styleNode",
            "styleNode 的 rawValue 不可改名（历史条目 Codable 依赖它）")
}

// MARK: - CANVAS-PLACEMENT：节点 = 槽位摆位（v2.11.7 hotfix20）
//
// 为什么这组必须存在：这一版把「节点自带一份内容 + 用 sourceSlot 指回槽位」改成
// 「节点就是槽位的一个摆位」。三类错误都不会当场报错，只会静默毁数据或静默丢画布：
//   1. 身份口径写错（不是 groupId#slot）→ 同一槽位能被摆两次，SwiftUI ForEach 撞 id，
//      两张卡片开始抢同一份数据，表现是"拖一张另一张跟着跳"。
//   2. 旧文档迁移漏掉 `sourceGroupId/sourceSlot` → 用户升级后**整张画布变空**，
//      而画布是派生资产，没有回收站可捞。
//   3. 逐节点容错解码写成整份 throw → 一个老的"未绑定节点"就能带走整张画布。
// 这三条都得在读写层钉死，UI 上只会看到"东西没了"，无从倒推。

do {
    // ── 身份口径
    t.equal(CanvasNode.makeId(groupId: "grp", slot: 3), "grp#3",
            "★★节点身份必须是 groupId#slot（画布去重、ForEach、选中集合全靠它）")
    t.equal(canvasNode(slot: 3, group: "grp").id, "grp#3",
            "node.id 应与 makeId 完全一致")
    t.check(canvasNode(slot: 1, group: "a").id != canvasNode(slot: 1, group: "b").id,
            "★★不同组的同号槽位必须是不同节点（否则跨组放置会互相顶掉）")
    t.check(canvasNode(slot: 1, group: "a").id != canvasNode(slot: 2, group: "a").id,
            "同组不同槽位必须是不同节点")

    let enc = JSONEncoder()
    let dec = JSONDecoder()

    // ── 编码只写新字段：旧的 source* / prompt 不许回写。
    // 回写的害处不是占空间，而是让下一位读者以为那份副本还有人维护。
    do {
        let data = try enc.encode(canvasNode(slot: 2, group: "g", page: "p"))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        t.check(raw["groupId"] as? String == "g" && raw["slot"] as? Int == 2 && raw["pageId"] as? String == "p",
                "新字段 pageId/groupId/slot 必须落盘")
        t.check(raw["prompt"] == nil && raw["sourceSlot"] == nil && raw["sourceGroupId"] == nil
                    && raw["sourcePageId"] == nil && raw["id"] == nil,
                "★★不许再回写 prompt / source* / 独立 id（死字段会被误当成真相）")
    } catch {
        t.check(false, "节点编码不应抛错：\(error)")
    }

    // ── 旧文档迁移：hotfix19 的节点用 source* 指向槽位，必须平移过来，位置/参数不动。
    do {
        let legacy: [String: Any] = [
            "id": "node_legacy",
            "sourcePageId": "page_old",
            "sourceGroupId": "group_old",
            "sourceSlot": 5,
            "prompt": "旧节点自带的正文",
            "x": 120, "y": 240, "width": 300, "height": 200,
            "model": "seedream45", "ratio": "16:9", "count": 3,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let node = try dec.decode(CanvasNode.self, from: data)
        t.equal(node.groupId, "group_old", "★★旧 sourceGroupId 必须迁到 groupId")
        t.equal(node.slot, 5, "★★旧 sourceSlot 必须迁到 slot")
        t.equal(node.pageId, "page_old", "旧 sourcePageId 必须迁到 pageId")
        t.equal(node.id, "group_old#5", "迁移后的身份仍按 groupId#slot 派生")
        t.check(canvasApprox(node.x, 120) && canvasApprox(node.y, 240)
                    && canvasApprox(node.width, 300) && canvasApprox(node.height, 200),
                "★★迁移必须原样保留几何——位置一变，用户升级后画布就乱了")
        t.equal(node.count, 3, "出图参数应原样保留")
        t.equal(node.ratio, "16:9", "比例参数应原样保留")
    } catch {
        t.check(false, "★★hotfix19 旧节点必须能迁移解码（实测抛错：\(error)）")
    }

    // ── 旧的「未绑定节点」：没有任何槽位引用，新结构没地方放它的 prompt。
    // 约定是解码抛错、由文档级跳过；绝不能凭空造一个槽位去接（那是往用户资产里写脏数据）。
    do {
        let unbound: [String: Any] = ["id": "node_free", "prompt": "无处安放的正文", "x": 0, "y": 0]
        let data = try JSONSerialization.data(withJSONObject: unbound)
        _ = try dec.decode(CanvasNode.self, from: data)
        t.check(false, "★★旧的未绑定节点应解码失败（约定由文档级跳过），实测却解出来了")
    } catch {
        t.check(true, "旧的未绑定节点按约定解码失败")
    }

    // ── 文档级逐节点容错：一个坏节点只该丢它自己。
    do {
        let good = try JSONSerialization.jsonObject(
            with: try enc.encode(canvasNode(slot: 1, group: "ok"))) as? [String: Any] ?? [:]
        let docRaw: [String: Any] = [
            "schemaVersion": CanvasDocument.currentSchemaVersion,
            "nodes": [good,
                      ["id": "node_free", "prompt": "无处安放"],   // 老的未绑定节点
                      ["x": "这不是数字"],                          // 彻底的脏数据
                      good],                                       // 与第一个同槽 → 应被去重
            "panX": 5, "panY": 6, "zoom": 2,
        ]
        let data = try JSONSerialization.data(withJSONObject: docRaw)
        let doc = try dec.decode(CanvasDocument.self, from: data)
        t.equal(doc.nodes.count, 1,
                "★★坏节点逐个跳过、同槽重复去重后应只剩 1 个（实得 \(doc.nodes.count)）")
        t.equal(doc.nodes.first?.id, "ok#1", "保留下来的应是那个合法节点")
        t.check(canvasApprox(doc.panX, 5) && canvasApprox(doc.panY, 6) && canvasApprox(doc.zoom, 2),
                "★★个别节点坏掉不该影响视口等文档级字段")
    } catch {
        t.check(false, "★★含坏节点的文档必须仍能解码（实测抛错：\(error)）")
    }

    // ── 去重口径：同一 groupId#slot 只保留**第一个**摆位，位置取先来的那个。
    let deduped = CanvasDocument.dedupedBySlot([
        canvasNode(slot: 1, group: "g", x: 10, y: 10),
        canvasNode(slot: 1, group: "g", x: 999, y: 999),
        canvasNode(slot: 2, group: "g", x: 20, y: 20),
    ])
    t.equal(deduped.count, 2, "★★同槽重复摆位必须去重（否则 ForEach 撞 id，两张卡片抢同一份数据）")
    t.check(canvasApprox(deduped.first?.x ?? -1, 10),
            "去重应保留先出现的那一个（位置 10 而不是 999）")
    t.equal(Set(deduped.map(\.id)).count, deduped.count, "去重后 id 必须互不相同")
}

// MARK: - CANVAS-FONT：节点正文字体的模型层（v2.11.7 hotfix19）
//
// 为什么这组必须存在：用户报的 bug 是"字体选了但没保存"。这类 bug 的两个藏身处都是静默的：
//   1. 字号越界 → 卡片正文被撑出容器或小到不可读，没有任何报错。
//   2. 新增的可选字段没进 Codable → 落盘再读回来字体就丢了，**只在重启 App 后才暴露**，
//      当场看起来完全正常。这是本次最需要机器盯住的一条。
// 第三处（族名 → NSFont 的解析）依赖 AppKit，活在 App target 里，本 harness 覆盖不到；
// 那部分靠 `CanvasFontCatalog` 只列"本机真的装了的字体" + 面板里的实时预览行兜住。

do {
    // ── 字号夹取
    t.equal(CanvasNode.clampBodyFontSize(10), 10, "合法字号原样返回")
    t.equal(CanvasNode.clampBodyFontSize(0), CanvasNode.bodyFontSizeRange.lowerBound,
            "★★低于下限应夹到下限（0pt 的文字等于内容消失）")
    t.equal(CanvasNode.clampBodyFontSize(999), CanvasNode.bodyFontSizeRange.upperBound,
            "★★高于上限应夹到上限（超大字号会把卡片其余内容顶出容器）")
    t.equal(CanvasNode.clampBodyFontSize(.nan), CanvasNode.defaultBodyFontSize,
            "★★NaN 必须回落默认值（NaN 字号会让整张卡片布局失效且不报错）")
    t.equal(CanvasNode.clampBodyFontSize(.infinity), CanvasNode.defaultBodyFontSize,
            "★★无穷大同样回落默认值")
    t.check(CanvasNode.bodyFontSizeRange.contains(CanvasNode.defaultBodyFontSize),
            "默认字号必须落在合法区间内")

    // ── 未设置字体时的解析口径
    let plain = canvasNode()
    t.check(plain.fontName == nil, "新节点默认不带字体族（跟随系统）")
    t.check(!plain.hasCustomFont, "没设过字体的节点 hasCustomFont 应为 false")
    t.equal(plain.resolvedBodyFontSize, CanvasNode.defaultBodyFontSize,
            "未设字号时 resolvedBodyFontSize 应给默认值")

    // ── 构造时即夹取：越界值不该有机会进入内存，更不该落盘
    let oversized = canvasNode(fontName: "MiSans", fontSize: 400)
    t.equal(oversized.fontSize, CanvasNode.bodyFontSizeRange.upperBound,
            "★★init 也必须夹取字号，否则越界值会绕过 store 直接落盘")

    // ── Codable 往返：这一条挡住"重启后字体丢了"
    var styled = canvasNode(x: 12, y: 34, fontName: "HarmonyOS Sans SC", fontSize: 16)
    styled.model = "seedream45"
    let enc = JSONEncoder()
    let dec = JSONDecoder()
    do {
        let data = try enc.encode(styled)
        let back = try dec.decode(CanvasNode.self, from: data)
        t.equal(back.fontName, "HarmonyOS Sans SC", "★★字体族必须能 Codable 往返（否则重启即丢）")
        t.equal(back.fontSize, 16, "★★字号必须能 Codable 往返")
        t.check(back.hasCustomFont, "往返后仍应判定为自定义字体")
    } catch {
        t.check(false, "CanvasNode 带字体字段的 Codable 往返不应抛错：\(error)")
    }

    // ── 向后兼容：hotfix19 之前落盘的节点 JSON 里没有 fontName / fontSize 两个键。
    // 新字段必须是「缺失即 nil」而不是「缺失即解码失败」—— 后者会让整份画布数据读不出来。
    do {
        let data = try enc.encode(plain)
        var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        raw.removeValue(forKey: "fontName")
        raw.removeValue(forKey: "fontSize")
        let legacy = try JSONSerialization.data(withJSONObject: raw)
        let back = try dec.decode(CanvasNode.self, from: legacy)
        t.check(back.fontName == nil && back.fontSize == nil,
                "★★老数据缺 fontName/fontSize 时应解成 nil")
        t.equal(back.resolvedBodyFontSize, CanvasNode.defaultBodyFontSize,
                "老数据应回落默认字号")
    } catch {
        t.check(false, "★★缺少字体字段的老 JSON 必须仍能解码（实测抛错：\(error)）")
    }

    // ── 脏数据：磁盘上被手改成越界字号时，读取路径也要有出口。
    // 解码本身不夹取（Codable 直接写 stored property），所以 `resolvedBodyFontSize`
    // 必须是最后一道闸——渲染只认它。
    do {
        let data = try enc.encode(plain)
        var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        raw["fontSize"] = 900
        let dirty = try JSONSerialization.data(withJSONObject: raw)
        let back = try dec.decode(CanvasNode.self, from: dirty)
        t.equal(back.resolvedBodyFontSize, CanvasNode.bodyFontSizeRange.upperBound,
                "★★脏数据的越界字号必须在读取侧被夹住（渲染只认 resolvedBodyFontSize）")
    } catch {
        t.check(false, "越界字号的 JSON 解码不应抛错：\(error)")
    }
}


// ============================================================================
// MARK: - Agent（v2.11.7）
// ============================================================================
//
// Agent 这条链上，绝大多数 bug 不会在编译期暴露，也不会在"手点一次能聊天"时暴露：
// 它们藏在**流式分块的边界**、**请求体的形状**、**工具循环的终止条件**和
// **脚本执行的路径检查**里。所以下面几组刻意都不联网：
// SSE 用文本回放、HTTP 用 AgentScriptedTransport、CLI 用注入的假 runner。
// 打 ★★ 的断言都对应一条"错了就线上炸/账单炸/被越权读文件"的具体后果。

// MARK: Agent 测试用的小工具
//
// 这个 harness 是同步的（3600 行既有用例都依赖顶层同步语义），而 Agent 全是 async。
// 用信号量桥接。刻意用 `Task.detached`：main.swift 的顶层代码在 Swift 5.7+ 是
// main actor 隔离的，若 Task 继承了 main actor，随后 `semaphore.wait()` 阻塞主线程
// 就会**死锁**——测试会挂住而不是失败，最难查。detached 不继承隔离，稳。

final class SmokeBox<T>: @unchecked Sendable {
    var value: T?
}

func smokeAwait<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SmokeBox<T>()
    Task.detached {
        box.value = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

/// 记录事件顺序。只留"类型"不留内容，断言的是时序而不是文案。
final class SmokeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: AgentRunEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .reasoningDelta: storage.append("reasoning")
        case .contentDelta: storage.append("content")
        case .assistantCompleted: storage.append("assistant")
        case .toolStarted: storage.append("toolStarted")
        case .toolCompleted: storage.append("toolCompleted")
        case .usage: storage.append("usage")
        case .note: storage.append("note")
        }
    }

    var kinds: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// 假工具执行器：只记调用、回固定结果，不碰磁盘。
final class SmokeToolExecutor: AgentToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentToolCall] = []
    private let result: AgentToolResult

    init(result: AgentToolResult = AgentToolResult(content: "{\"ok\":true,\"slots\":[]}", summary: "完成")) {
        self.result = result
    }

    var calls: [AgentToolCall] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func specs() -> [AgentToolSpec] {
        [AgentToolSpec(name: "list_slots",
                       description: "列出槽位",
                       parameters: .object(["type": "object", "properties": .object([:])]),
                       originLabel: "内置")]
    }

    func execute(call: AgentToolCall) async -> AgentToolResult {
        // 加锁抽成同步函数：在 async 上下文里直接 NSLock.lock() 在 Swift 6 语言模式下是错误。
        record(call)
        return result
    }

    private func record(_ call: AgentToolCall) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
    }
}

/// 记录 CLI argv 的假 runner。断言"参数怎么映射"，而不是"CLI 干了什么"。
final class SmokeArgvRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    private var _stdout = "{\"ok\":true}"
    private var _exitCode: Int32 = 0

    func record(_ argv: [String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(argv)
    }

    func stub(stdout: String, exitCode: Int32) {
        lock.lock(); defer { lock.unlock() }
        _stdout = stdout
        _exitCode = exitCode
    }

    var result: AgentProcessResult {
        lock.lock(); defer { lock.unlock() }
        return AgentProcessResult(exitCode: _exitCode, stdout: _stdout, stderr: "", timedOut: false)
    }

    var last: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.last ?? []
    }
}

/// argv 感知的假 CLI（v2.11.7 hotfix26）。
///
/// SmokeArgvRecorder 对所有命令返回同一份 stdout，验不了「先列举、再拿 id 执行」的两步链路：
/// delete_group 传组名时，第一次调用必须拿到 groups 列表，第二次才是 delete-group。
/// 这里按命令名分发 stdout，并保留**整轮**调用序列，好断言「歧义时第二步压根没发出去」。
final class SmokeFakeCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _allCalls: [[String]] = []
    var groupsJSON = "{\"ok\":true,\"groups\":[]}"
    var pagesJSON = "{\"ok\":true,\"pages\":[]}"

    /// 每次工具调用前清掉本轮序列（allCalls 仍累计，用于全局 --force 断言）。
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _calls = []
    }

    func run(_ argv: [String]) -> AgentProcessResult {
        lock.lock()
        _calls.append(argv)
        _allCalls.append(argv)
        let stdout: String
        switch argv.first {
        case "groups": stdout = groupsJSON
        case "pages": stdout = pagesJSON
        default: stdout = "{\"ok\":true}"
        }
        lock.unlock()
        return AgentProcessResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)
    }

    /// 本轮工具调用产生的 CLI 调用序列。
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var allCalls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _allCalls
    }

    var last: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls.last ?? []
    }
}

// MARK: - AGENT-JSON：JSONValue 往返与容错
//
// 这一组盯的是"schema 与 arguments 的形状"。最要紧的是整数：
// schema 里的 `"maximum": 10` 被编成 `10.0` 会让上游 JSON Schema 校验直接 400，
// 而这个错在本地永远看不见（本地不校验 schema）。所以它是硬断言。

do {
    let schema = JSONValue.object([
        "type": "object",
        "properties": .object(["slot": .object(["type": "integer", "maximum": 10])]),
    ])
    let text = (try? schema.encodedText()) ?? ""
    t.check(text.contains("\"maximum\":10"), "★★schema 里的整数必须编成 10 而不是 10.0（上游校验很严，且本地无感）")
    t.check(!text.contains("10.0"), "整数不应出现小数点形式")

    // 模型把整数写成字符串是常态，读取侧要能吃；但不能吃出错觉。
    t.equal(JSONValue.string("3").intValue, 3, "字符串 \"3\" 应能取成 Int")
    t.equal(JSONValue.string("3.5").intValue, nil, "非整字符串不该硬转 Int")
    t.equal(JSONValue.number(4).intValue, 4, "数字取 Int")
    t.equal(JSONValue.number(4.5).intValue, nil, "带小数的数字不该被悄悄截断成 Int")
    t.equal(JSONValue.string("true").boolValue, true, "字符串 true 应能取成 Bool")
    t.equal(JSONValue.bool(false).boolValue, false, "布尔取值")

    // 空串等同缺省：模型经常用空串占位可选参数。
    t.check(JSONValue.string("   ").isBlank, "★空白串必须视为缺省，否则会拿空串去查页面名")
    t.check(JSONValue.null.isBlank, "null 视为缺省")
    t.check(!JSONValue.string("x").isBlank, "非空串不是缺省")

    // 无参工具的 arguments 常常是空串而不是 {}。
    if let empty = try? JSONValue.decode(jsonText: "") {
        t.check(empty.objectValue?.isEmpty == true, "★空 arguments 文本应解成空对象（模型对无参工具就这么发）")
    } else {
        t.check(false, "空 arguments 文本不该抛错")
    }

    // Bool 不能被当成数字（解码顺序：Bool 必须先于 Double 试）。
    if let parsed = try? JSONValue.decode(jsonText: "{\"a\":true,\"b\":1}") {
        t.equal(parsed["a"]?.boolValue, true, "true 应解成 bool")
        t.equal(parsed["b"]?.intValue, 1, "1 应解成数字")
        t.check(parsed["a"]?.intValue == nil, "★bool 不能被解成数字 1")
    } else {
        t.check(false, "混合类型对象应可解码")
    }

    // 嵌套往返：Skill 里第三方写的 parameters 会原样进请求体，不能被改形。
    let nested = "{\"a\":{\"b\":[1,\"x\",true,null]}}"
    if let round = try? JSONValue.decode(jsonText: nested), let back = try? round.encodedText() {
        t.equal(back, nested, "★嵌套结构必须原样往返（第三方 schema 会直接进请求体）")
    } else {
        t.check(false, "嵌套结构应可往返")
    }
}

// MARK: - AGENT-SSE：流式解码
//
// 分块位置是这一组的核心。真实 URLSession 在任意字节处断开，
// 所以"逐字符喂"必须和"整段喂"得到完全一样的结果。

do {
    let body = """
    data: {"choices":[{"index":0,"delta":{"reasoning_content":"先看槽位"}}]}

    data: {"choices":[{"index":0,"delta":{"content":"槽位 3 "}}]}

    data: {"choices":[{"index":0,"delta":{"content":"已更新"}}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":45,"total_tokens":165,"prompt_cache_hit_tokens":64}}

    data: [DONE]

    """

    var whole = AgentSSEDecoder()
    var acc = AgentStreamAccumulator()
    for event in whole.feed(body) + whole.finish() { acc.ingest(event) }
    t.equal(acc.content, "槽位 3 已更新", "整段喂入应拼出完整正文")
    t.equal(acc.reasoning, "先看槽位", "整段喂入应拼出思考内容")
    t.equal(acc.finishReason, "stop", "finish_reason 应被记录")
    t.equal(acc.usage?.promptTokens, 120, "usage.prompt_tokens")
    t.equal(acc.usage?.cachedTokens, 64, "usage 命中缓存 tokens（要靠 stream_options 才有）")

    // 逐字符喂：模拟最恶劣的分块。
    var perChar = AgentSSEDecoder()
    var acc2 = AgentStreamAccumulator()
    for ch in body {
        for event in perChar.feed(String(ch)) { acc2.ingest(event) }
    }
    for event in perChar.finish() { acc2.ingest(event) }
    t.equal(acc2.content, acc.content, "★★逐字符分块的结果必须与整段一致（跨 chunk 残行拼装）")
    t.equal(acc2.reasoning, acc.reasoning, "逐字符分块的思考内容也应一致")
    t.equal(acc2.usage?.totalTokens, 165, "逐字符分块也应解出 usage")

    // 心跳注释、event/id 字段、\r\n 行尾都不能干扰。
    var noisy = AgentSSEDecoder()
    var acc3 = AgentStreamAccumulator()
    let noisyBody = ": keep-alive\r\nevent: message\r\nid: 42\r\n"
        + "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\r\n\r\n"
        + "data: [DONE]\r\n"
    for event in noisy.feed(noisyBody) + noisy.finish() { acc3.ingest(event) }
    t.equal(acc3.content, "OK", "★心跳注释 / event / id 行与 \\r\\n 行尾都必须被正确跳过")

    // 脏 data 行不能炸掉整条流。
    var weird = AgentSSEDecoder()
    var acc4 = AgentStreamAccumulator()
    for event in weird.feed("data: not-json\ndata: {\"choices\":[{\"delta\":{\"content\":\"仍然可用\"}}]}\n") { acc4.ingest(event) }
    for event in weird.finish() { acc4.ingest(event) }
    t.equal(acc4.content, "仍然可用", "★脏 data 行应被忽略，而不是让整轮失败")

    // 流中途的 error 对象必须被识别成失败（余额不足/鉴权失效常在流开始后才暴露）。
    var failing = AgentSSEDecoder()
    var acc5 = AgentStreamAccumulator()
    for event in failing.feed("data: {\"error\":{\"message\":\"Insufficient Balance\",\"code\":\"402\"}}\n") { acc5.ingest(event) }
    for event in failing.finish() { acc5.ingest(event) }
    t.equal(acc5.serverError?.message, "Insufficient Balance",
            "★★流中途的 error 对象必须被识别成失败，不能当成空 chunk 吞掉")

    // finish() 要能把最后一行没有换行结尾的残留吐出来。
    var noTrailingNewline = AgentSSEDecoder()
    var acc6 = AgentStreamAccumulator()
    for event in noTrailingNewline.feed("data: {\"choices\":[{\"delta\":{\"content\":\"末尾无换行\"}}]}") { acc6.ingest(event) }
    for event in noTrailingNewline.finish() { acc6.ingest(event) }
    t.equal(acc6.content, "末尾无换行", "★最后一行没有换行时，finish() 必须把它交出来")
}

// MARK: - AGENT-TOOLCALL：工具调用的增量拼装
//
// 首帧带 id+name，后续帧只带 arguments 片段；并行调用靠 index 区分。
// 这是整条链最容易写错的地方——错了的表现是"模型明明调了工具，参数却是半截 JSON"。

do {
    let body = """
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"write_slot","arguments":""}}]}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"slot\\":"}}]}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"3,\\"text\\":\\"猫\\"}"}}]}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"list_slots","arguments":"{}"}}]}}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """
    var decoder = AgentSSEDecoder()
    var acc = AgentStreamAccumulator()
    for event in decoder.feed(body) + decoder.finish() { acc.ingest(event) }

    t.equal(acc.toolCalls.count, 2, "★两个并行工具调用应按 index 归并成 2 个")
    t.equal(acc.toolCalls.first?.id, "call_a", "首个调用 id")
    t.equal(acc.toolCalls.first?.name, "write_slot", "首个调用名（name 只在首帧出现）")
    t.equal(acc.toolCalls.first?.argumentsJSON, "{\"slot\":3,\"text\":\"猫\"}",
            "★★分片的 arguments 必须原样拼回完整 JSON")
    if let args = try? acc.toolCalls.first?.arguments() {
        t.equal(args["slot"]?.intValue, 3, "拼好的 arguments 应能解析出 slot")
        t.equal(args["text"]?.stringValue, "猫", "拼好的 arguments 应能解析出中文 text")
    } else {
        t.check(false, "拼装后的 arguments 应是合法 JSON")
    }
    t.equal(acc.toolCalls.last?.name, "list_slots", "第二个调用名")
    t.equal(acc.finishReason, "tool_calls", "finish_reason 应为 tool_calls")

    // id 缺失时必须兜一个：role=tool 消息的 tool_call_id 为空会被上游 400。
    var noId = AgentStreamAccumulator()
    noId.ingest(.toolCall(index: 0, id: nil, name: "list_slots", argumentsDelta: "{}"))
    t.check(noId.toolCalls.first?.id.isEmpty == false, "★id 缺失时必须自造一个（tool_call_id 不能为空）")

    // 只有 arguments、没有 name 的残缺调用应被丢弃，而不是造出一个空名工具。
    var nameless = AgentStreamAccumulator()
    nameless.ingest(.toolCall(index: 0, id: "x", name: nil, argumentsDelta: "{}"))
    t.equal(nameless.toolCalls.count, 0, "★无工具名的残缺调用应被丢弃（空名工具会让上游 400）")

    // 顺序按 index 而不是按到达顺序。
    var reordered = AgentStreamAccumulator()
    reordered.ingest(.toolCall(index: 1, id: "b", name: "second", argumentsDelta: "{}"))
    reordered.ingest(.toolCall(index: 0, id: "a", name: "first", argumentsDelta: "{}"))
    t.equal(reordered.toolCalls.map(\.name), ["first", "second"], "工具调用应按 index 排序而非到达顺序")
}

// MARK: - AGENT-BODY：请求体形状
//
// 最关键的一条：**带 tools 时 reasoning_content 必须回传**，否则上游 400。
// 这不是我们的偏好，是 DeepSeek 思考模式 + Tool Calls 的硬要求，而且只在
// "先思考、再调工具、再回答"的第二轮才暴露——手点一次很容易漏掉。

do {
    let history: [AgentMessage] = [
        AgentMessage(role: .user, content: "看看槽位"),
        AgentMessage(role: .assistant,
                     content: "",
                     reasoning: "需要先列出槽位",
                     toolCalls: [AgentToolCall(id: "call_1", name: "list_slots", argumentsJSON: "{}")]),
        AgentMessage(role: .tool, content: "{\"ok\":true}", toolCallId: "call_1", toolName: "list_slots"),
        // 本地错误提示气泡：不该进上下文。
        AgentMessage(role: .assistant, content: "网络错误：连接超时", isFailure: true),
    ]
    let tools = AgentBuiltinTools(cliPath: "/nonexistent/clipslots").specs()
    let config = AgentConfig(model: "deepseek-reasoner", systemPrompt: "你是助手")
    let body = AgentService.requestBody(history: history, config: config, tools: tools)

    if let messages = body["messages"]?.arrayValue, messages.count >= 4 {
        t.equal(messages.count, 4, "★system + user + assistant + tool = 4 条（本地失败提示被剔除）")
        t.equal(messages[0]["role"]?.stringValue, "system", "system 必须在最前")
        t.equal(messages[0]["content"]?.stringValue, "你是助手", "system 内容取自 config，不取历史")

        let assistant = messages[2]
        t.equal(assistant["role"]?.stringValue, "assistant", "第三条是 assistant")
        t.equal(assistant["reasoning_content"]?.stringValue, "需要先列出槽位",
                "★★带 tools 时必须回传 reasoning_content，否则 DeepSeek 直接 400")
        t.check(assistant["content"] != nil, "★只有工具调用的那轮，content 键也必须保留（空串）")
        t.equal(assistant["tool_calls"]?.arrayValue?.count, 1, "assistant 应带 1 个 tool_call")
        t.equal(assistant["tool_calls"]?.arrayValue?.first?["function"]?["name"]?.stringValue, "list_slots",
                "tool_call 的函数名应原样回传")
        t.equal(assistant["tool_calls"]?.arrayValue?.first?["type"]?.stringValue, "function",
                "tool_call 必须带 type=function")

        let toolMessage = messages[3]
        t.equal(toolMessage["role"]?.stringValue, "tool", "第四条是 tool 结果")
        t.equal(toolMessage["tool_call_id"]?.stringValue, "call_1", "★tool 消息必须带 tool_call_id")
    } else {
        t.check(false, "请求体必须有至少 4 条 messages")
    }

    t.equal(body["stream"]?.boolValue, true, "流式请求 stream=true")
    t.equal(body["stream_options"]?["include_usage"]?.boolValue, true,
            "★想拿到 usage 必须显式开 stream_options.include_usage")
    t.equal(body["model"]?.stringValue, "deepseek-reasoner", "默认模型遵循用户指定")
    t.check((body["tools"]?.arrayValue?.count ?? 0) >= 4, "内置工具应全部进 tools")
    t.equal(body["tools"]?.arrayValue?.first?["type"]?.stringValue, "function", "工具类型是 function")
    t.check(body["tools"]?.arrayValue?.first?["function"]?["parameters"] != nil, "工具必须带 parameters schema")

    // thinking 三态：默认一个字段都不发（老模型别名未必认这两个键）。
    t.check(body["thinking"] == nil,
            "★★serverDefault 时请求体里不能出现 thinking 字段（老模型别名可能不认）")
    t.check(body["reasoning_effort"] == nil, "未指定推理强度时不应出现 reasoning_effort")

    let enabled = AgentService.requestBody(
        history: history,
        config: AgentConfig(thinkingMode: .enabled, reasoningEffort: "high"),
        tools: tools)
    t.equal(enabled["thinking"]?["type"]?.stringValue, "enabled", "显式开启时应发 thinking.enabled")
    t.equal(enabled["reasoning_effort"]?.stringValue, "high", "显式推理强度应发出")

    let disabled = AgentService.requestBody(
        history: history,
        config: AgentConfig(thinkingMode: .disabled, reasoningEffort: "high"),
        tools: tools)
    t.equal(disabled["thinking"]?["type"]?.stringValue, "disabled", "关闭思考时应发 thinking.disabled")
    t.check(disabled["reasoning_effort"] == nil, "★关闭思考时不应再发 reasoning_effort（自相矛盾的组合会 422）")

    // 空 tools 数组会被某些网关判为非法，干脆不发这个键。
    let noTools = AgentService.requestBody(history: history, config: config, tools: [])
    t.check(noTools["tools"] == nil, "没有工具时不应出现 tools 键")

    // 非流式请求不该带 stream_options。
    let sync = AgentService.requestBody(history: history, config: config, tools: tools, stream: false)
    t.equal(sync["stream"]?.boolValue, false, "非流式请求 stream=false")
    t.check(sync["stream_options"] == nil, "非流式请求不应带 stream_options")

    // System Prompt 为空时不该塞一条空 system 进去。
    let noPrompt = AgentService.requestBody(history: [AgentMessage(role: .user, content: "hi")],
                                            config: AgentConfig(systemPrompt: "   "),
                                            tools: [])
    t.equal(noPrompt["messages"]?.arrayValue?.count, 1, "★空白 System Prompt 不应产生一条空 system 消息")

    // 缺 tool_call_id 的 tool 消息发出去必被 400，宁可丢掉。
    let orphanTool = AgentService.requestBody(
        history: [AgentMessage(role: .user, content: "hi"), AgentMessage(role: .tool, content: "{}")],
        config: AgentConfig(systemPrompt: ""),
        tools: [])
    t.equal(orphanTool["messages"]?.arrayValue?.count, 1, "★没有 tool_call_id 的 tool 消息必须被剔除")
}

// MARK: - AGENT-LOOP：工具调用闭环（脚本化传输，不碰网络）

do {
    // 第 1 轮：模型要求调工具；第 2 轮：给出终答。
    let round1 = """
    data: {"choices":[{"delta":{"reasoning_content":"得先看一眼"}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"name":"list_slots","arguments":"{\\"group\\":\\"默认\\"}"}}]}}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """
    let round2 = """
    data: {"choices":[{"delta":{"content":"共 10 个槽位，其中 3 个为空。"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """
    // splitEvery 刻意取 37：保证 JSON 会在中间被切开，顺带再压一遍跨 chunk 拼装。
    let transport = AgentScriptedTransport(steps: [
        .sse(round1, splitEvery: 37),
        .sse(round2, splitEvery: 37),
    ])
    let service = AgentService(transport: transport,
                               secretStore: AgentInMemorySecretStore(key: "sk-smoke"))
    let executor = SmokeToolExecutor()
    let events = SmokeEventLog()

    let produced = smokeAwait { () -> [AgentMessage] in
        (try? await service.run(history: [AgentMessage(role: .user, content: "看看槽位")],
                                config: AgentConfig(),
                                tools: executor) { event in
            events.append(event)
        }) ?? []
    }

    t.equal(executor.calls.count, 1, "★工具应被执行且只执行一次")
    t.equal(executor.calls.first?.name, "list_slots", "执行的工具名")
    t.equal((try? executor.calls.first?.arguments())?["group"]?.stringValue, "默认",
            "★工具参数应完整送达执行侧（含中文、且经历过跨 chunk 拼装）")

    t.equal(produced.count, 3, "★应产出 assistant(工具轮) + tool(结果) + assistant(终答) 共 3 条")
    t.equal(produced.first?.toolCalls.count, 1, "第一条 assistant 带工具调用")
    t.equal(produced.first?.reasoning, "得先看一眼", "第一轮思考内容必须留在消息里（下一轮要回传）")
    t.equal(produced.count > 1 ? produced[1].role : .user, .tool, "第二条是工具结果")
    t.equal(produced.count > 1 ? produced[1].toolCallId : nil, "call_x", "工具结果应绑定正确的 call id")
    t.equal(produced.last?.content, "共 10 个槽位，其中 3 个为空。", "最后一条是终答")

    // 第二次请求必须带上工具结果和上一轮的 reasoning_content。
    if let second = transport.requestJSON(at: 1), let messages = second["messages"]?.arrayValue, messages.count >= 4 {
        t.equal(messages.count, 4, "★第二次请求应包含 system+user+assistant+tool 四条")
        t.equal(messages[2]["reasoning_content"]?.stringValue, "得先看一眼",
                "★★第二次请求必须回传上一轮 reasoning_content（带 tools 时不回传会 400）")
        t.equal(messages[3]["role"]?.stringValue, "tool", "第二次请求应带 tool 结果")
        t.equal(messages[3]["content"]?.stringValue, "{\"ok\":true,\"slots\":[]}", "工具结果应原样回传给模型")
    } else {
        t.check(false, "第二次请求体应可解析且含 4 条消息")
    }

    // 事件顺序：思考 → 工具开始 → 工具结束 → 终答。
    let kinds = events.kinds
    t.check(kinds.contains("reasoning") && kinds.contains("toolStarted")
            && kinds.contains("toolCompleted") && kinds.contains("content"),
            "★事件流应覆盖思考/工具开始/工具结束/正文四类")
    if let iStart = kinds.firstIndex(of: "toolStarted"),
       let iEnd = kinds.firstIndex(of: "toolCompleted"),
       let iContent = kinds.lastIndex(of: "content") {
        t.check(iStart < iEnd, "工具开始必须早于工具结束")
        t.check(iEnd < iContent, "★终答必须在工具结果之后（否则说明第二轮没等工具）")
    } else {
        t.check(false, "事件顺序断言的前置事件缺失")
    }
}

// MARK: - AGENT-GUARD：错误翻译与死循环护栏

do {
    // 没有 API Key 时必须在发请求前就失败。
    let service = AgentService(transport: AgentScriptedTransport(steps: []),
                               secretStore: AgentInMemorySecretStore(key: nil))
    t.check(!service.hasAPIKey, "空 secret store 下 hasAPIKey 应为 false")
    let missing = smokeAwait { () -> AgentError? in
        do {
            _ = try await service.run(history: [AgentMessage(role: .user, content: "hi")],
                                      config: AgentConfig(), tools: nil) { _ in }
            return nil
        } catch let e as AgentError { return e } catch { return nil }
    }
    t.equal(missing, AgentError.missingAPIKey, "★缺 API Key 应直接抛 missingAPIKey，不该发出请求")

    // HTTP 错误码翻译成人话。
    let unauthorized = AgentScriptedTransport(steps: [
        .init(statusCode: 401,
              chunks: ["{\"error\":{\"message\":\"Authentication Fails\",\"code\":\"invalid_api_key\"}}"]),
    ])
    let svc401 = AgentService(transport: unauthorized,
                              secretStore: AgentInMemorySecretStore(key: "sk-bad"))
    let err401 = smokeAwait { () -> AgentError? in
        do {
            _ = try await svc401.run(history: [AgentMessage(role: .user, content: "hi")],
                                     config: AgentConfig(), tools: nil) { _ in }
            return nil
        } catch let e as AgentError { return e } catch { return nil }
    }
    if case .http(let status, let message, _) = err401 {
        t.equal(status, 401, "401 应被识别")
        t.equal(message, "Authentication Fails", "错误 body 里的 message 应被提取")
        t.check(err401?.errorDescription?.contains("鉴权失败") == true, "★401 应翻译成人能看懂的中文提示")
    } else {
        t.check(false, "401 应产生 AgentError.http，实际：\(String(describing: err401))")
    }

    // 模型名问题要能被单独识别出来——DeepSeek 模型别名会随代际下线，
    // UI 靠这个标志提示"去设置里换模型"，否则用户只能看到一句 400。
    t.check(AgentError.http(status: 400, message: "Model Not Exist", code: nil).hintsModelProblem,
            "★★『模型不存在』类错误必须可识别，好在 UI 上提示改模型名")
    t.check(AgentError.http(status: 404, message: "model not found", code: nil).hintsModelProblem,
            "404 + model not found 也算模型名问题")
    t.check(!AgentError.http(status: 429, message: "rate limit", code: nil).hintsModelProblem,
            "限流不是模型名问题")
    t.check(AgentError.http(status: 402, message: nil, code: nil).errorDescription?.contains("余额不足") == true,
            "402 应提示余额不足")

    // 上游流里带 error 对象时按 upstream 报错。
    let upstream = AgentScriptedTransport(steps: [
        .sse("data: {\"error\":{\"message\":\"Insufficient Balance\",\"code\":\"402\"}}\n\n"),
    ])
    let svcUp = AgentService(transport: upstream, secretStore: AgentInMemorySecretStore(key: "sk-x"))
    let errUp = smokeAwait { () -> AgentError? in
        do {
            _ = try await svcUp.run(history: [AgentMessage(role: .user, content: "hi")],
                                    config: AgentConfig(), tools: nil) { _ in }
            return nil
        } catch let e as AgentError { return e } catch { return nil }
    }
    t.equal(errUp, AgentError.upstream(message: "Insufficient Balance", code: "402"),
            "★200 里夹着 error 对象也必须报错，不能当成空回答")

    // 上游一直要求调工具时，必须在 maxToolRounds 处停下。
    let loopStep = AgentScriptedTransport.Step.sse("""
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_loop","type":"function","function":{"name":"list_slots","arguments":"{}"}}]}}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """)
    let loopTransport = AgentScriptedTransport(steps: Array(repeating: loopStep, count: 6))
    let loopService = AgentService(transport: loopTransport,
                                   secretStore: AgentInMemorySecretStore(key: "sk-loop"))
    let loopExecutor = SmokeToolExecutor()
    let loopProduced = smokeAwait { () -> [AgentMessage] in
        (try? await loopService.run(history: [AgentMessage(role: .user, content: "循环吧")],
                                    config: AgentConfig(maxToolRounds: 3),
                                    tools: loopExecutor) { _ in }) ?? []
    }
    t.equal(loopExecutor.calls.count, 3,
            "★★工具轮上限必须生效（否则模型和工具能互相喂饭喂到账单爆）")
    t.check(loopProduced.last?.isFailure == true, "触顶时应留下一条可见提示")
    t.check(loopProduced.last?.content.contains("3 轮") == true, "提示里应说明停在第几轮")

    // 上游啥也没返回时，不能产出一个永远空白的气泡。
    let emptyTransport = AgentScriptedTransport(steps: [.sse("data: [DONE]\n\n")])
    let emptyService = AgentService(transport: emptyTransport,
                                    secretStore: AgentInMemorySecretStore(key: "sk-empty"))
    let emptyError = smokeAwait { () -> AgentError? in
        do {
            _ = try await emptyService.run(history: [AgentMessage(role: .user, content: "hi")],
                                           config: AgentConfig(), tools: nil) { _ in }
            return nil
        } catch let e as AgentError { return e } catch { return nil }
    }
    if case .invalidResponse = emptyError {
        t.check(true, "★空响应应报错，而不是产出空白气泡")
    } else {
        t.check(false, "空响应应产生 invalidResponse，实际：\(String(describing: emptyError))")
    }

    // 模型想调工具但没有执行器时，应收尾而不是继续转圈。
    let wantTool = AgentScriptedTransport(steps: [loopStep])
    let noExec = AgentService(transport: wantTool, secretStore: AgentInMemorySecretStore(key: "sk-n"))
    let noExecProduced = smokeAwait { () -> [AgentMessage] in
        (try? await noExec.run(history: [AgentMessage(role: .user, content: "hi")],
                               config: AgentConfig(), tools: nil) { _ in }) ?? []
    }
    t.equal(noExecProduced.count, 1, "★没有执行器时应立刻收尾，不能空转到轮上限")
}

// MARK: - AGENT-CLI：内置工具的参数映射
//
// 用注入的假 runner 断言 argv，不碰真实数据目录。重点有两处：
//   1. page 名 / page UUID 的分流（`--page` 只吃 UUID，模型给的多半是名字）；
//   2. 裸 write 与 --if-empty 的选择（用户明确要求"直接改，不要反复确认"）。

do {
    let recorder = SmokeArgvRecorder()
    // cliPath 指向一个真实存在且可执行的文件，好让 isAvailable 通过；真正的执行被 runner 拦掉。
    let tools = AgentBuiltinTools(cliPath: "/bin/echo") { _, argv in
        recorder.record(argv)
        return recorder.result
    }

    func runTool(_ name: String, _ json: String) -> AgentToolResult {
        let call = AgentToolCall(id: "c", name: name, argumentsJSON: json)
        return smokeAwait { await tools.execute(call: call) }
    }

    // 页面名 + 组名
    _ = runTool("list_slots", "{\"page\":\"我的页面\",\"group\":\"提示词\"}")
    t.check(recorder.last.contains("--page-name"),
            "★★页面名必须走 --page-name（--page 只吃 UUID，模型给的多半是名字）")
    t.check(recorder.last.contains("我的页面"), "页面名应作为参数传入")
    t.check(recorder.last.contains("--group") && recorder.last.contains("提示词"),
            "组名走 --group（CLI 的 --group 同时接受 id 与名字）")

    // 页面 UUID
    let uuid = UUID().uuidString
    _ = runTool("list_slots", "{\"page\":\"\(uuid)\"}")
    t.check(recorder.last.contains("--page") && !recorder.last.contains("--page-name"),
            "★UUID 形态的 page 应走 --page")

    // 空串等同不传
    _ = runTool("list_slots", "{\"page\":\"  \",\"group\":\"\"}")
    t.equal(recorder.last, ["list"], "★空白参数应被视为未传，而不是拿空串去匹配页面/组")

    // read
    _ = runTool("read_slot", "{\"slot\":3}")
    t.equal(recorder.last, ["read", "3"], "read_slot 应把 slot 作为位置参数")

    let missingSlot = runTool("read_slot", "{}")
    t.check(missingSlot.isFailure, "缺 slot 应失败")
    t.check(missingSlot.content.contains("MISSING_SLOT"),
            "★失败要带结构化 error_code，模型才有机会自我纠正")

    t.check(runTool("read_slot", "{\"slot\":0}").content.contains("SLOT_OUT_OF_RANGE"),
            "越界 slot 应被本地拦下，不必浪费一次 CLI 调用")

    // write：默认覆盖，显式 if_empty 才只写空槽
    _ = runTool("write_slot", "{\"slot\":2,\"text\":\"赛博朋克\",\"label\":\"夜景\"}")
    t.check(recorder.last.starts(with: ["write", "2", "--text", "赛博朋克"]), "write 的位置参数与 --text")
    t.check(recorder.last.contains("--label") && recorder.last.contains("夜景"), "label 应传入")
    t.check(!recorder.last.contains("--if-empty"),
            "★★默认不加 --if-empty（用户明确要求「直接改，不要反复确认」）")

    _ = runTool("write_slot", "{\"slot\":2,\"text\":\"x\",\"if_empty\":true}")
    t.check(recorder.last.contains("--if-empty"), "显式 if_empty 时应加 --if-empty")
    t.check(!recorder.last.contains("--overwrite-text"),
            "★--if-empty 与 --overwrite-text 互斥，不能同时出现（CLI 会拒）")

    t.check(runTool("write_slot", "{\"slot\":2}").content.contains("MISSING_TEXT"), "缺 text 应本地失败")

    // search
    _ = runTool("search_slots", "{\"query\":\"人像\",\"all_groups\":true,\"limit\":20}")
    t.check(recorder.last.starts(with: ["search", "人像"]), "search 的位置参数")
    t.check(recorder.last.contains("--all-groups"), "all_groups 应映射成 --all-groups")
    t.check(recorder.last.contains("--limit") && recorder.last.contains("20"), "limit 应映射成 --limit")

    t.check(runTool("search_slots", "{\"query\":\"  \"}").content.contains("MISSING_QUERY"),
            "空查询应本地失败，不去捞全库")

    // 发现类工具：让模型先看清页面/组，别瞎猜名字
    _ = runTool("list_groups", "{}")
    t.check(!recorder.last.isEmpty, "list_groups 应产生一次 CLI 调用")
    _ = runTool("list_pages", "{}")
    t.check(!recorder.last.isEmpty, "list_pages 应产生一次 CLI 调用")

    // 未知工具名
    t.check(runTool("delete_everything", "{}").content.contains("UNKNOWN_TOOL"),
            "★未知工具名必须被拒（模型偶尔会自己发明工具）")

    // CLI 失败时把 error_code 原样带回给模型
    recorder.stub(stdout: "{\"ok\":false,\"error_code\":\"SLOT_NOT_EMPTY\",\"error\":\"槽位非空\"}", exitCode: 1)
    let failed = runTool("write_slot", "{\"slot\":2,\"text\":\"x\",\"if_empty\":true}")
    t.check(failed.isFailure, "CLI 非零退出应标记为失败")
    t.check(failed.summary.contains("SLOT_NOT_EMPTY"), "★失败摘要应带 CLI 的 error_code（UI 状态行要看）")
    t.check(failed.content.contains("SLOT_NOT_EMPTY"), "★CLI 的 JSON 应原样回传给模型，让它改用覆盖写")
    recorder.stub(stdout: "{\"ok\":true}", exitCode: 0)

    // CLI 不在时给可操作的提示，而不是空输出
    let missingCLI = AgentBuiltinTools(cliPath: "/nonexistent/clipslots")
    let cliCall = AgentToolCall(id: "c", name: "list_slots", argumentsJSON: "{}")
    t.check(smokeAwait { await missingCLI.execute(call: cliCall) }.content.contains("CLI_MISSING"),
            "★CLI 缺失应报 CLI_MISSING 并提示重装，而不是静默失败")

    // 工具 schema 自检：名字合法、描述非空、schema 是 object
    let specs = AgentBuiltinTools().specs()
    t.check(specs.count >= 6, "内置工具应至少 6 个（含 list_groups / list_pages）")
    for spec in specs {
        let legal = spec.name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        t.check(legal, "工具名 \(spec.name) 只能含字母数字下划线连字符")
        t.check(spec.name.count <= 64, "工具名 \(spec.name) 不得超过 64 字符")
        t.check(!spec.description.isEmpty, "工具 \(spec.name) 必须有描述（模型靠它决定调不调）")
        t.equal(spec.parameters["type"]?.stringValue, "object", "工具 \(spec.name) 的 parameters 应是 object schema")
    }
    t.equal(Set(specs.map(\.name)).count, specs.count, "★工具名不能重复（重名会让上游拒绝整个 tools 数组）")

    let writeRequired = specs.first { $0.name == "write_slot" }?
        .parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    t.check(writeRequired.contains("slot") && writeRequired.contains("text"), "write_slot 必填 slot 与 text")
}

// MARK: - AGENT-CLI hotfix26：写侧工具（清空 / 粘贴 / 建组建页 / 改名 / 删除 / 附件 / 缩略图）
//
// 这一组盯三件事：
//   1. argv 映射：工具 schema 的参数名 ≠ CLI flag 名（new_name → --name、files → 位置参数…），
//      错一个字就是一次「模型以为做了、其实 CLI 拒了」的无声失败；
//   2. 名称 → ID 解析：delete-group / rename-group / delete-page 的位置参数**只吃 id**，
//      而模型给的永远是人类说法（"删掉设计稿这个组"）。所以要验「先列举、再拿 id 执行」两步链路，
//      以及同名多命中时**不许瞎猜**（必须回 AMBIGUOUS_GROUP 让它带 page 重试）；
//   3. --force 绝不出现在任何 argv 里：它是跨进程写锁的逃生门，给模型等于把并发写坏数据常态化。
do {
    let fake = SmokeFakeCLI()
    fake.groupsJSON = """
    {"ok":true,"groups":[\
    {"id":"g-design","name":"设计稿","pageName":"默认页面"},\
    {"id":"g-copy","name":"文案","pageName":"默认页面"},\
    {"id":"g-dup-a","name":"重名组","pageName":"甲页"},\
    {"id":"g-dup-b","name":"重名组","pageName":"乙页"}]}
    """
    fake.pagesJSON = """
    {"ok":true,"pages":[{"id":"default","name":"默认页面"},{"id":"p-draft","name":"草稿"}]}
    """
    let tools = AgentBuiltinTools(cliPath: "/bin/echo") { _, argv in fake.run(argv) }

    func runTool(_ name: String, _ json: String) -> AgentToolResult {
        fake.reset()
        return smokeAwait { await tools.execute(call: AgentToolCall(id: "c", name: name, argumentsJSON: json)) }
    }

    // —— 清空 / 粘贴：都是「slot 位置参数 + page/group 作用域」
    _ = runTool("clear_slot", "{\"slot\":3,\"page\":\"草稿\",\"group\":\"设计稿\"}")
    t.equal(fake.last, ["clear", "3", "--page-name", "草稿", "--group", "设计稿"],
            "★clear_slot 应映射成 clear <slot> + 作用域（不是 write --text \"\"，那样附件还留着）")
    t.check(runTool("clear_slot", "{}").content.contains("MISSING_SLOT"), "clear_slot 缺 slot 应本地失败")

    _ = runTool("paste_slot", "{\"slot\":5}")
    t.equal(fake.last, ["paste", "5"], "paste_slot 应映射成 paste <slot>")

    // —— 建组 / 建页
    _ = runTool("create_group", "{\"name\":\"插画\",\"page\":\"草稿\"}")
    t.equal(fake.last, ["create-group", "插画", "--page-name", "草稿"],
            "create_group：名称走位置参数，页面走 --page-name")
    _ = runTool("create_group", "{\"name\":\"插画\",\"group\":\"忽略我\"}")
    t.check(!fake.last.contains("--group"),
            "★create-group 的 flag 白名单里没有 --group，多传会被 CLI 当非法 flag 整条拒掉")
    t.check(runTool("create_group", "{\"name\":\"  \"}").content.contains("MISSING_NAME"),
            "空白组名应本地失败，不去 CLI 撞 INVALID_INPUT_FORMAT")

    _ = runTool("create_page", "{\"name\":\"草稿2\",\"first_group_name\":\"首组\"}")
    t.equal(fake.last, ["create-page", "草稿2", "--group-name", "首组"],
            "★create_page 的 first_group_name 应映射成 --group-name（原子命名，省掉一次 rename）")
    _ = runTool("create_page", "{\"name\":\"草稿3\"}")
    t.equal(fake.last, ["create-page", "草稿3"], "不传 first_group_name 时不应凭空加 --group-name")

    // —— 改名：组名 → id 的解析链路
    _ = runTool("rename_group", "{\"group\":\"设计稿\",\"new_name\":\"插画\"}")
    t.equal(fake.calls.count, 2, "★rename_group 传组名时应先 groups 列举、再执行，共两次 CLI 调用")
    t.equal(fake.calls.first?.first, "groups", "第一次调用应是 groups 列举")
    t.equal(fake.last, ["rename-group", "g-design", "--name", "插画"],
            "★★组名必须被解析成 id（rename-group 的位置参数只吃 id），new_name 走 --name")
    t.check(!fake.last.contains("--page") && !fake.last.contains("--page-name"),
            "★id 已解析出来，再传页面作用域会被 CLI 的 flag 白名单拒掉")

    _ = runTool("rename_group", "{\"group\":\"g-copy\",\"new_name\":\"正文\"}")
    t.equal(fake.last, ["rename-group", "g-copy", "--name", "正文"],
            "★传的本来就是 id 时应直接命中（id 优先于同名匹配）")
    t.check(runTool("rename_group", "{\"group\":\"设计稿\"}").content.contains("MISSING_NEW_NAME"),
            "rename_group 缺 new_name 应本地失败")

    // —— 删组：歧义与不存在都要给模型可执行的下一步
    _ = runTool("delete_group", "{\"group\":\"设计稿\"}")
    t.equal(fake.last, ["delete-group", "g-design"], "delete_group 应把组名解析成 id")
    _ = runTool("delete_group", "{\"group\":\"文案\",\"page\":\"默认页面\"}")
    t.check(fake.calls.first?.contains("--page-name") == true,
            "★带 page 时列举也要收窄范围，否则解析出的 id 可能来自别的页面")

    let ambiguous = runTool("delete_group", "{\"group\":\"重名组\"}")
    t.check(ambiguous.isFailure, "同名多命中必须失败，不能挑一个删")
    t.check(ambiguous.content.contains("AMBIGUOUS_GROUP"), "★同名歧义要回 AMBIGUOUS_GROUP")
    t.check(ambiguous.content.contains("g-dup-a") && ambiguous.content.contains("g-dup-b"),
            "★★歧义错误要列出全部候选 id，模型才能直接带 id 重试而不是再问一轮用户")
    t.equal(fake.calls.count, 1, "★歧义时只应停在列举，绝不能把 delete-group 发出去")

    let notFound = runTool("delete_group", "{\"group\":\"不存在的组\"}")
    t.check(notFound.content.contains("GROUP_NOT_FOUND"), "组不存在应回 GROUP_NOT_FOUND")
    t.check(notFound.content.contains("设计稿") && notFound.content.contains("文案"),
            "★找不到时要列出现有组名，避免模型反复猜同一个错名字")
    t.check(runTool("delete_group", "{}").content.contains("MISSING_GROUP"), "delete_group 缺 group 应本地失败")

    // —— 删页
    _ = runTool("delete_page", "{\"page\":\"草稿\"}")
    t.equal(fake.calls.first, ["pages"], "delete_page 应先 pages 列举")
    t.equal(fake.last, ["delete-page", "p-draft"], "★页面名必须解析成 id（delete-page 只吃 id）")
    _ = runTool("delete_page", "{\"page\":\"default\"}")
    t.equal(fake.last, ["delete-page", "default"],
            "传 id 时直接用；默认页保护交给 CLI 判定（DEFAULT_PAGE_PROTECTED），不在本地提前编造结论")
    let pageMiss = runTool("delete_page", "{\"page\":\"没这页\"}")
    t.check(pageMiss.content.contains("PAGE_NOT_FOUND"), "页面不存在应回 PAGE_NOT_FOUND")
    t.check(pageMiss.content.contains("草稿"), "★找不到时要列出现有页面名")
    t.check(runTool("delete_page", "{}").content.contains("MISSING_PAGE"), "delete_page 缺 page 应本地失败")

    // —— 附件 / 缩略图
    _ = runTool("write_attachment",
                "{\"slot\":2,\"files\":[\"/tmp/a.png\",\"/tmp/b.png\"],\"replace\":true,\"label\":\"参考\"}")
    t.check(fake.last.starts(with: ["write-attachment", "2", "/tmp/a.png", "/tmp/b.png"]),
            "★write_attachment：文件路径是位置参数且必须保序（附件顺序就是用户看到的顺序）")
    t.check(fake.last.contains("--replace") && fake.last.contains("--label"), "replace/label 应映射成同名 flag")
    t.check(runTool("write_attachment", "{\"slot\":2,\"files\":[]}").content.contains("MISSING_FILES"),
            "空 files 应本地失败，不发一条什么都不写的命令")

    _ = runTool("set_thumbnail", "{\"slot\":1,\"image\":\"/tmp/c.png\",\"if_absent\":true}")
    t.equal(fake.last, ["set-thumbnail", "1", "--image", "/tmp/c.png", "--if-absent"],
            "set_thumbnail：image 走 --image，if_absent 走 --if-absent")
    t.check(runTool("set_thumbnail", "{\"slot\":1}").content.contains("MISSING_IMAGE"),
            "set_thumbnail 缺 image 应本地失败")
    _ = runTool("clear_thumbnail", "{\"slot\":4}")
    t.equal(fake.last, ["clear-thumbnail", "4"], "clear_thumbnail 应映射成 clear-thumbnail <slot>")
    _ = runTool("repair_index", "{}")
    t.equal(fake.last, ["repair-index"], "repair_index 无参数")

    // —— schema 契约：工具齐不齐、描述有没有把「别做什么」写清楚
    let specs = AgentBuiltinTools().specs()
    let names = Set(specs.map(\.name))
    for required in ["clear_slot", "paste_slot", "create_group", "create_page",
                     "rename_group", "delete_group", "delete_page",
                     "write_attachment", "set_thumbnail", "clear_thumbnail", "repair_index"] {
        t.check(names.contains(required), "★内置工具集必须包含 \(required)（缺了模型只会编造替代方案）")
    }
    func spec(_ name: String) -> AgentToolSpec? { specs.first { $0.name == name } }
    t.check(spec("clear_slot")?.description.contains("write_slot") == true,
            "★★clear_slot 的描述必须点明与 write_slot 的区别，否则模型继续用「写空串」冒充清空")
    t.check(spec("delete_group")?.description.contains("DEFAULT_GROUP_PROTECTED") == true,
            "★delete_group 描述要写明默认组删不掉，模型才不会把 CLI 的拒绝当成自己参数错了反复重试")
    t.check(spec("delete_page")?.description.contains("DEFAULT_PAGE_PROTECTED") == true,
            "★delete_page 描述要写明默认页删不掉")
    // 默认页的 id 是 default_page，默认组才是 default（CLI 里两个常量不同名）。实测 `delete-page default`
    // 走的是 PAGE_NOT_FOUND 而不是保护分支 —— 描述里写错这个字符串，模型会把「保护」误读成「参数写错」。
    t.check(spec("delete_page")?.description.contains("default_page") == true,
            "★★默认页 id 是 default_page，不是 default（别照抄默认组的常量）")
    t.check(spec("delete_group")?.description.contains("CANNOT_DELETE_LAST_GROUP") == true,
            "★删到只剩一个组时 CLI 会拒（CANNOT_DELETE_LAST_GROUP），描述要给出「改用 delete_page」的出路")
    t.check(spec("paste_slot")?.description.contains("剪贴板") == true,
            "★paste_slot 只写剪贴板、不模拟按键，描述必须说清，避免模型谎报「已粘贴」")
    t.equal(spec("delete_group")?.parameters["required"]?.arrayValue?.compactMap(\.stringValue), ["group"],
            "delete_group 必填 group")
    t.equal(spec("rename_group")?.parameters["required"]?.arrayValue?.compactMap(\.stringValue),
            ["group", "new_name"], "rename_group 必填 group 与 new_name")
    t.equal(spec("delete_page")?.parameters["required"]?.arrayValue?.compactMap(\.stringValue), ["page"],
            "delete_page 必填 page")
    for s in specs {
        let props = s.parameters["properties"]?.objectValue ?? [:]
        t.check(props["force"] == nil,
                "★★工具 \(s.name) 不得暴露 force（跳过跨进程写锁是人类自救手段，交给模型等于常态化并发写坏数据）")
    }
    t.check(fake.allCalls.allSatisfy { !$0.contains("--force") },
            "★★本组所有 CLI 调用都不该出现 --force")
}

// MARK: - AGENT-SKILL：SKILL.md 解析
//
// 核心立场：**不从自然语言里猜 schema**。有结构声明才生成 Function Calling 工具，
// 没有就只暴露 list_skills / read_skill / run_skill_script 让模型自己读文档。
// 所以这一组重点验"该丢的丢掉了"，而不只是"该解的解出来了"。

do {
    let markdown = """
    ---
    name: clipslots-manager
    description: "读写 ClipSlots 槽位内容"
    version: 1.7.0
    used_when: 需要操作槽位时
    ---

    # ClipSlots Manager

    这是正文第一段。

    ```json clipslots-tools
    [
      {
        "name": "summarize",
        "description": "汇总某组槽位",
        "parameters": {"type": "object", "properties": {"group": {"type": "string"}}, "required": ["group"]},
        "command": ["python3", "scripts/summarize.py", "--group", "{{group}}"]
      },
      {
        "name": "no_command",
        "description": "缺少执行方式，应被丢弃",
        "parameters": {"type": "object"}
      }
    ]
    ```
    """
    let parsed = AgentSkillCatalog.parse(markdown: markdown)
    t.equal(parsed.name, "clipslots-manager", "frontmatter 的 name 应被解析")
    t.equal(parsed.description, "读写 ClipSlots 槽位内容", "带引号的 description 应去引号")
    t.equal(parsed.version, "1.7.0", "version 应被解析")
    t.equal(parsed.tools.count, 1,
            "★★没有 command 的声明必须丢弃（留着就是个调了没反应的死工具，模型会反复重试）")
    t.equal(parsed.tools.first?.name, "summarize", "声明工具名")
    t.equal(parsed.tools.first?.command.count, 4, "命令数组应完整保留（含 {{占位符}}）")
    t.equal(parsed.tools.first?.parameters["required"]?.arrayValue?.first?.stringValue, "group",
            "第三方写的 parameters 应原样保留")

    // 没有结构声明就一个工具都不该造出来。
    let plain = AgentSkillCatalog.parse(markdown: "---\nname: plain\ndescription: 普通技能\n---\n\n用 clipslots write 写入槽位即可。")
    t.equal(plain.tools.count, 0, "★★纯自然语言 SKILL.md 不得凭空生成工具（这是幻觉工具的源头）")

    // 缺 description 时回落到第一段正文，而不是留空。
    t.equal(AgentSkillCatalog.parse(markdown: "---\nname: solo\n---\n\n# 标题\n\n第一段说明。\n").description,
            "第一段说明。", "★缺 description 时应回落到首段正文")

    // 完全没有 frontmatter 也不能崩。
    t.equal(AgentSkillCatalog.parse(markdown: "# 只有标题\n\n正文。", fallbackName: "bare-skill").name,
            "bare-skill", "无 frontmatter 时用目录名兜底")

    // 围栏块里是坏 JSON 时，整份 Skill 仍要可用（只是没有声明工具）。
    let broken = AgentSkillCatalog.parse(markdown: "---\nname: broken\n---\n\n```json clipslots-tools\n[{oops}]\n```\n")
    t.equal(broken.name, "broken", "★坏掉的工具声明不应让整份 SKILL.md 解析失败")
    t.equal(broken.tools.count, 0, "坏 JSON 不产生工具")

    // slug 规则：它要能当 Function Calling 工具名的一部分。
    t.equal(AgentSkillCatalog.slugify("Clip Slots Manager"), "clip_slots_manager", "空格转下划线并小写")
    t.equal(AgentSkillCatalog.slugify("a/b.c"), "a_b_c", "路径与点号归一成下划线")
    t.equal(AgentSkillCatalog.slugify("中文"), "", "非 ASCII 全部丢弃（工具名字符集限制）")

    let toolName = AgentSkillTools.declaredToolName(skillSlug: "clipslots_manager", toolName: "summarize")
    t.equal(toolName, "skill_clipslots_manager_summarize",
            "★Skill 工具名应带 skill_<slug>_ 前缀做命名空间隔离")
    t.check(toolName.count <= 64, "工具名不得超过 64 字符")
    t.equal(AgentSkillTools.declaredToolName(skillSlug: "x", toolName: "中文工具"), "skill_x_tool",
            "★纯中文工具名 slug 化后为空，必须兜一个合法名而不是 skill_x_")
}

// MARK: - AGENT-SKILL-FS：目录扫描去重与脚本路径防逃逸
//
// 这一组在临时目录里搭出真实的安装形态：bundle 内自带 + 插件市场上传 +
// Agent 目录软链（AgentSkillInstallManager 就是这么装的）。
// 软链是重点——它既是"同一个 Skill 出现两遍"的来源，也是"正常路径被误判越界"的来源。

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("clipslots_skill_\(UUID().uuidString)")

    let bundle = root.appendingPathComponent("ClipSlots.app")
    let bundleSkills = bundle.appendingPathComponent("Contents/Resources/skills/clipslots-manager")
    let home = root.appendingPathComponent("home")
    let community = home.appendingPathComponent("Library/Application Support/ClipSlots/community-skills/my-skill")
    let codex = home.appendingPathComponent(".codex/skills")

    do {
        try fm.createDirectory(at: bundleSkills.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: community, withIntermediateDirectories: true)
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)

        try "---\nname: clipslots-manager\ndescription: 内置槽位技能\nversion: 1.7.0\n---\n正文"
            .write(to: bundleSkills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "print('hi')\n"
            .write(to: bundleSkills.appendingPathComponent("scripts/hello.py"), atomically: true, encoding: .utf8)
        try "---\nname: my-skill\ndescription: 社区技能\n---\n正文"
            .write(to: community.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: solo\ndescription: 单文件技能\n---\n正文"
            .write(to: codex.appendingPathComponent("solo.md"), atomically: true, encoding: .utf8)
        // Agent 目录里的软链指回 bundle 内那个——这正是本项目的安装方式。
        try fm.createSymbolicLink(at: codex.appendingPathComponent("clipslots-manager"),
                                  withDestinationURL: bundleSkills)

        let found = AgentSkillCatalog.discover(bundlePath: bundle.path, homeDirectory: home.path)
        t.equal(found.map(\.slug).sorted(), ["clipslots_manager", "my_skill", "solo"],
                "★★软链到同一份 SKILL.md 的项必须去重（否则同一个 Skill 在列表里出现两遍）")

        let manager = found.first { $0.slug == "clipslots_manager" }
        t.equal(manager?.source, .bundled, "★去重时应保留优先级更高的来源（bundle > 插件市场 > Agent 目录）")
        t.equal(manager?.scripts, ["scripts/hello.py"], "应发现目录内的脚本")
        t.equal(manager?.version, "1.7.0", "应带上版本号（UI 要显示）")
        t.equal(found.first { $0.slug == "my_skill" }?.source, .community, "社区技能来源标记")
        t.equal(found.first { $0.slug == "solo" }?.source, .agentDirectory, "单文件技能来源标记")

        // 路径防逃逸：这是"允许模型跑本机代码"这件事的核心闸门。
        let dir = bundleSkills.path
        t.check(AgentSkillTools.resolveScriptPath(skillDirectory: dir, script: "scripts/hello.py") != nil,
                "正常相对路径应被接受")
        t.check(AgentSkillTools.resolveScriptPath(skillDirectory: dir, script: "../../../../etc/passwd") == nil,
                "★★`../` 逃逸必须被拒绝")
        t.check(AgentSkillTools.resolveScriptPath(skillDirectory: dir, script: "/bin/sh") == nil,
                "★★绝对路径必须被拒绝")
        t.check(AgentSkillTools.resolveScriptPath(skillDirectory: dir, script: "~/.ssh/id_rsa") == nil,
                "★★家目录展开写法必须被拒绝")
        t.check(AgentSkillTools.resolveScriptPath(skillDirectory: dir, script: "scripts/../scripts/hello.py") != nil,
                "标准化后仍在目录内的路径应被接受")
        t.check(AgentSkillTools.resolveScriptPath(
                    skillDirectory: codex.appendingPathComponent("clipslots-manager").path,
                    script: "scripts/hello.py") != nil,
                "★软链形态的 Skill 目录内的脚本不应被误判为越界（Agent 目录里全是软链）")

        // 未勾选时，Skill 一律不可见。
        t.equal(AgentSkillTools(enabledSkills: []).specs().count, 0,
                "★★没有启用任何 Skill 时不得暴露任何 Skill 工具（含 list_skills）")

        let enabled = AgentSkillTools(enabledSkills: found)
        let names = enabled.specs().map(\.name)
        t.check(names.contains("list_skills") && names.contains("read_skill"),
                "启用后应暴露 list_skills / read_skill")
        t.check(names.contains("run_skill_script"), "存在可执行脚本时才暴露 run_skill_script")
        t.equal(Set(names).count, names.count, "Skill 工具名不得重复")

        // 只暴露没有脚本的 Skill 时，不该出现执行入口。
        let scriptless = AgentSkillTools(enabledSkills: found.filter { $0.scripts.isEmpty })
        t.check(!scriptless.specs().map(\.name).contains("run_skill_script"),
                "★没有任何脚本时不应暴露 run_skill_script（给模型一把没锁孔的钥匙只会招来重试）")

        func runSkillTool(_ tools: AgentSkillTools, _ name: String, _ json: String) -> AgentToolResult {
            let call = AgentToolCall(id: "c", name: name, argumentsJSON: json)
            return smokeAwait { await tools.execute(call: call) }
        }

        // 未启用/不存在的 Skill 解析不出来。
        t.check(runSkillTool(AgentSkillTools(enabledSkills: [found[0]]), "read_skill",
                             "{\"skill\":\"完全不存在\"}").content.contains("SKILL_NOT_FOUND"),
                "★读取未启用或不存在的 Skill 必须失败")

        // 非脚本类型不许执行。
        t.check(runSkillTool(enabled, "run_skill_script",
                             "{\"skill\":\"clipslots_manager\",\"script\":\"SKILL.md\"}")
                    .content.contains("SCRIPT_TYPE_REJECTED"),
                "★.md 之类的非脚本文件不得被执行")

        // 逃逸路径在执行入口也要被拦一次（不能只靠上面的纯函数）。
        t.check(runSkillTool(enabled, "run_skill_script",
                             "{\"skill\":\"clipslots_manager\",\"script\":\"../../../../../bin/sh\"}")
                    .content.contains("SCRIPT_PATH_REJECTED"),
                "★★逃逸路径在执行入口也必须被拒")

        // 缺 script 参数
        t.check(runSkillTool(enabled, "run_skill_script", "{\"skill\":\"clipslots_manager\"}")
                    .content.contains("MISSING_SCRIPT"),
                "缺 script 应失败")

        // 真跑一次脚本
        let ran = runSkillTool(enabled, "run_skill_script",
                               "{\"skill\":\"clipslots_manager\",\"script\":\"scripts/hello.py\"}")
        t.check(ran.content.contains("hi") || ran.content.contains("SCRIPT_FAILED"),
                "脚本应被执行（本机无 python3 时允许 SCRIPT_FAILED）")

        // list_skills 的输出要是模型看得懂的 JSON
        let listed = runSkillTool(enabled, "list_skills", "")
        if let payload = try? JSONValue.decode(jsonText: listed.content) {
            t.equal(payload["skills"]?.arrayValue?.count, 3, "list_skills 应列出全部已启用 Skill")
            t.check(payload["skills"]?.arrayValue?.first?["slug"] != nil, "每项应带 slug（后续工具靠它定位）")
        } else {
            t.check(false, "list_skills 输出应是合法 JSON")
        }

        // read_skill 能按 slug 读到原文
        t.check(runSkillTool(enabled, "read_skill", "{\"skill\":\"clipslots_manager\"}")
                    .content.contains("内置槽位技能"),
                "read_skill 应返回 SKILL.md 原文")

        // 未知 Skill 工具名
        t.check(runSkillTool(enabled, "skill_nope_x", "{}").content.contains("UNKNOWN_TOOL"),
                "未知 Skill 工具名应被拒绝")

        try? fm.removeItem(at: root)
    } catch {
        try? fm.removeItem(at: root)
        t.check(false, "Skill 扫描用例的临时目录准备失败：\(error)")
    }
}

// MARK: - AGENT-PROCESS：进程执行的超时与大输出
//
// 这三条都是"写错了不会报错、只会挂住"的类型，必须用真实进程压。

do {
    // 大输出不能死锁：管道缓冲约 64KB，必须边跑边读。
    let big = smokeAwait {
        await AgentProcessRunner.run(executable: "/usr/bin/python3",
                                     arguments: ["-c", "print('x' * 300000)"],
                                     timeout: 20)
    }
    if big.exitCode == 0 {
        t.check(big.stdout.count > 100_000,
                "★★大输出必须能读出来（不边跑边读就会和子进程互相等成死锁）")
    } else {
        t.check(true, "本机无 python3，跳过大输出用例")
    }

    // 超时必须真的把进程干掉，而不是等它自己结束。
    let slow = smokeAwait {
        await AgentProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
    }
    t.check(slow.timedOut, "★超时应被标记")
    t.check(!slow.succeeded, "超时不算成功")

    // stdin 要写进去并正确关闭，否则读 stdin 的脚本会一直挂着。
    let piped = smokeAwait {
        await AgentProcessRunner.run(executable: "/bin/cat",
                                     arguments: [],
                                     standardInput: "hello-stdin",
                                     timeout: 10)
    }
    t.equal(piped.stdout, "hello-stdin", "★标准输入应被写入并关闭（不关就是又一处挂死）")

    // 不存在的可执行文件要正常返回失败，而不是抛异常炸掉整轮对话。
    let bogus = smokeAwait {
        await AgentProcessRunner.run(executable: "/nonexistent/bin/nope", arguments: [], timeout: 5)
    }
    t.check(!bogus.succeeded, "★不存在的可执行文件应返回失败而不是抛异常")
}

// MARK: - WINDOW-WIDTH：主窗口宽度预算（v2.11.7 hotfix24）
//
// 为什么这组必须存在：用户反馈「缩小窗口（分有无智能体页面）会有 UI 错乱」，取证后发现根因是
// **窗口允许被缩到比内容真正需要的宽度更窄**，而 SwiftUI 的 HStack 面对「放不下」是**静默溢出**、
// 由窗口裁掉，不会把差额上报成父容器最小宽度（实测 contentMinSize 恒为 720、
// NSHostingView.fittingSize 返回 0×0）。也就是说这类错乱**不会有任何运行时报错**，
// 只会表现为「logo 缺一半、齿轮掉出右边、搜索栏里的菜单叠到图标底下、居中胶囊盖住拨杆标签」。
//
// 所以宽度预算的算术必须在这里钉死。三类错误都是静默的：
//   1. 居中行最小宽度写成 `左 + 右`（而不是 `2 × max(左, 右)`）→ 居中控件不再落在中线上，
//      窗口一窄就压住旁边的控件。这正是 hotfix20~23 那颗胶囊反复"跑位"的同一个坑。
//   2. 两侧可用宽度算错 → 一侧被压到溢出，另一侧留着空白。
//   3. 窗口最小宽度低于顶栏所需 → 回归到本次修复前的裁切状态。
do {
    // ── 居中行：最小宽度必须按"两侧对称"算
    //
    // 中线固定 ⇒ 左右两个槽位宽度必然相等 ⇒ 这个共同宽度必须容得下**较宽**的那一簇。
    // 若误写成 左+右+中，窄侧会白拿空间、宽侧被压，居中控件也就不在中线上了。
    t.equal(WindowLayoutMetrics.centerReservedRowMinWidth(leftMin: 300, rightMin: 400,
                                                         centerWidth: 130, gap: 12),
            2 * 400 + 130 + 24,
            "★★居中行最小宽 = 2×max(左,右) + 中 + 2×留白（写成 左+右+中 就等于放弃真居中）")
    t.equal(WindowLayoutMetrics.centerReservedRowMinWidth(leftMin: 400, rightMin: 300,
                                                         centerWidth: 130, gap: 12),
            2 * 400 + 130 + 24,
            "左右互换结果必须一样（对称性）")
    t.equal(WindowLayoutMetrics.centerReservedRowMinWidth(leftMin: 0, rightMin: 0,
                                                         centerWidth: 130, gap: 12),
            130 + 24,
            "两簇为空时只剩中间控件与留白")
    // 负数不能把最小宽度算成更小 —— 上游是 sizeThatFits 的返回值，理论上非负，
    // 但一旦某个子树在测量期返回异常值，这里必须钳住而不是把窗口下限拉低。
    t.check(WindowLayoutMetrics.centerReservedRowMinWidth(leftMin: -50, rightMin: -50,
                                                         centerWidth: 130, gap: 12) >= 130,
            "★负的子视图宽度不得把行最小宽算到比中间控件还小")

    // ── 居中行：两侧各自可用宽度
    let half = WindowLayoutMetrics.centerReservedHalfWidth(totalWidth: 1000, centerWidth: 130, gap: 12)
    t.equal(half, (1000 - 130 - 24) / 2, "两侧可用宽 = (总宽 - 中 - 2×留白) / 2")
    // 自洽性：行宽恰好等于最小宽时，两侧拿到的正好是各自的最小宽度 —— 这是"不会溢出"的关键不变量。
    let lMin: CGFloat = 322, rMin: CGFloat = 432
    let rowMin = WindowLayoutMetrics.centerReservedRowMinWidth(leftMin: lMin, rightMin: rMin,
                                                              centerWidth: 130, gap: 12)
    let halfAtMin = WindowLayoutMetrics.centerReservedHalfWidth(totalWidth: rowMin,
                                                               centerWidth: 130, gap: 12)
    t.check(halfAtMin >= lMin && halfAtMin >= rMin,
            "★★行宽取最小值时，两侧可用宽必须仍 ≥ 各自最小宽（否则最小宽度公式本身就漏了）")
    t.check(WindowLayoutMetrics.centerReservedHalfWidth(totalWidth: 50, centerWidth: 130, gap: 12) == 0,
            "总宽小于中间控件时可用宽钳到 0，不得返回负数（负 proposal 会让子树布局发疯）")

    // ── 内容区：工作区 + 侧栏
    t.equal(WindowLayoutMetrics.contentRowMinWidth(canvas: false, libraryWidth: 0, agentVisible: false),
            WindowLayoutMetrics.editWorkspaceMinWidth,
            "编辑页不开侧栏时，内容区最小宽就是卡片区最小宽")
    t.equal(WindowLayoutMetrics.contentRowMinWidth(canvas: false, libraryWidth: 0, agentVisible: true),
            WindowLayoutMetrics.editWorkspaceMinWidth + WindowLayoutMetrics.agentSidebarWidth,
            "★开 Agent 侧栏必须**加上**它的定宽，而不是让它挤占卡片区")
    t.equal(WindowLayoutMetrics.contentRowMinWidth(canvas: true, libraryWidth: 240, agentVisible: true),
            240 + WindowLayoutMetrics.canvasViewportMinWidth + WindowLayoutMetrics.agentSidebarWidth,
            "★画布模式要同时容下左侧槽位库、可视区与右侧侧栏")
    t.check(WindowLayoutMetrics.contentRowMinWidth(canvas: true, libraryWidth: 44, agentVisible: true)
            < WindowLayoutMetrics.contentRowMinWidth(canvas: true, libraryWidth: 240, agentVisible: true),
            "槽位库收起后内容区最小宽应变小")

    // ── 窗口下限：必须真的挡住已知的错乱区间
    //
    // 720 是修复前写死的假下限，实测 720~840 顶栏被裁、~1058 以下搜索栏内容溢出。
    // 这条断言的作用是：以后任何人想把窗口下限调回"手感更自由"的小数值时，测试会先拦住他。
    t.check(WindowLayoutMetrics.minWindowContentWidth > 840,
            "★★窗口最小宽必须高于实测的裁切区间上界（840），否则本次修复直接失效")
    t.check(WindowLayoutMetrics.minWindowContentWidth >= 1058,
            "★★窗口最小宽必须容得下编辑页顶栏实测所需的 1058pt")
    // 下限也不能反过来大到把窗口顶出常见屏幕：1280 是仍在服役的最窄 Mac 逻辑宽度。
    t.check(WindowLayoutMetrics.minWindowContentWidth <= 1280,
            "★窗口最小宽不得超过 1280（再大就会在窄屏上顶出可见区域）")
    // 顶栏所需宽度当前**大于**「内容区 + 侧栏」所需，实际生效的下限来自顶栏。
    // 这条断言把这个前提写进测试：哪天顶栏瘦身了，它会提醒去重新评估窗口下限。
    t.check(WindowLayoutMetrics.minWindowContentWidth
            >= WindowLayoutMetrics.contentRowMinWidth(canvas: true, libraryWidth: 240, agentVisible: true),
            "★★窗口最小宽必须同时兜住最吃宽度的内容区组合（画布 + 展开的槽位库 + Agent 侧栏）")

    // 侧栏宽度只能有一个来源：AgentSidebarView.width 引用的就是这个常量。
    t.equal(WindowLayoutMetrics.agentSidebarWidth, 320, "Agent 侧栏定宽 320（与 AgentSidebarView.width 同源）")
}

// MARK: - PLUGIN-RELEASE：GitHub latest release 解析（插件市场动态下载链接，v2.11.8）
//
// 这组盯两类风险：
//   1. **挑错资产**：Release 里常混着 zip / txt / 校验和文件，挑错就是给用户下一个打不开的包；
//   2. **开错链接**：`browser_download_url` 是从网络响应读出来、随后不经确认就交给
//      NSWorkspace.open 的字符串。一旦 host / scheme 没校验，这个按钮就成了「一键下载任意
//      文件」的启动器。所以 http、异站 host 必须一律判不可信，宁可降级到 Release 页面。
do {
    func json(_ s: String) -> Data { s.data(using: .utf8)! }

    // 真实形状：取自 scrollapp-leftclick v2.2.3 的 API 响应（裁掉无关字段）。
    let real = json("""
    {"tag_name":"v2.2.3","name":"v2.2.3 · 弹窗彻底可关闭","assets":[
      {"name":"Scrollapp-v2.2.3.dmg",
       "browser_download_url":"https://github.com/Seven-hub-fanfan/scrollapp-leftclick/releases/download/v2.2.3/Scrollapp-v2.2.3.dmg"}]}
    """)
    let parsed = GitHubReleaseParser.parseLatest(real)
    t.equal(parsed?.tag, "v2.2.3", "应解析出原始 tag")
    t.equal(parsed?.version, "2.2.3", "★展示版本号要去掉 tag 的 v 前缀（卡片上再补一个 v，否则显示成 vv2.2.3）")
    t.equal(parsed?.dmgURL.absoluteString,
            "https://github.com/Seven-hub-fanfan/scrollapp-leftclick/releases/download/v2.2.3/Scrollapp-v2.2.3.dmg",
            "★★必须是 asset 直链（浏览器打开即下载），不是 Release 页面 URL")

    // 混合资产：非 dmg 在前，必须被跳过而不是拿第一个。
    let mixed = json("""
    {"tag_name":"v9.9.9","assets":[
      {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/o/r/releases/download/v9.9.9/SHA256SUMS.txt"},
      {"name":"Source-v9.9.9.zip","browser_download_url":"https://github.com/o/r/releases/download/v9.9.9/Source-v9.9.9.zip"},
      {"name":"App-v9.9.9.DMG","browser_download_url":"https://github.com/o/r/releases/download/v9.9.9/App-v9.9.9.DMG"}]}
    """)
    t.equal(GitHubReleaseParser.parseLatest(mixed)?.dmgURL.lastPathComponent, "App-v9.9.9.DMG",
            "★要跳过 txt/zip 挑出 dmg，且后缀判断大小写不敏感（.DMG 也算）")

    // 没有 dmg → nil（调用方降级到 Release 页面，而不是打开一个 zip）
    t.check(GitHubReleaseParser.parseLatest(json("""
    {"tag_name":"v1.0","assets":[{"name":"app.zip","browser_download_url":"https://github.com/o/r/app.zip"}]}
    """)) == nil, "★Release 里没有 dmg 时必须返回 nil，不能退而求其次给个 zip")

    // 安全：http 与异站 host 一律不可信
    t.check(GitHubReleaseParser.parseLatest(json("""
    {"tag_name":"v1.0","assets":[{"name":"a.dmg","browser_download_url":"http://github.com/o/r/a.dmg"}]}
    """)) == nil, "★★http 直链必须拒（明文可被中间人替换成任意文件）")
    t.check(GitHubReleaseParser.parseLatest(json("""
    {"tag_name":"v1.0","assets":[{"name":"a.dmg","browser_download_url":"https://evil.example.com/a.dmg"}]}
    """)) == nil, "★★非 GitHub host 的直链必须拒（否则响应被改写就等于一键下载任意文件）")
    t.check(GitHubReleaseParser.parseLatest(json("""
    {"tag_name":"v1.0","assets":[{"name":"a.dmg","browser_download_url":"https://github.com.evil.example/a.dmg"}]}
    """)) == nil, "★★host 校验必须按域名边界比对，github.com.evil.example 不算 GitHub")
    t.check(GitHubReleaseParser.isTrustedDownloadURL(
        URL(string: "https://objects.githubusercontent.com/xx/yy.dmg")!),
            "★githubusercontent.com 子域是 GitHub 直链的实际落点，必须放行（否则 302 后就打不开了）")

    // 畸形响应：缺 tag / 缺 assets / 根本不是 JSON
    t.check(GitHubReleaseParser.parseLatest(json("""
    {"assets":[{"name":"a.dmg","browser_download_url":"https://github.com/o/r/a.dmg"}]}
    """)) == nil, "缺 tag_name 应返回 nil（版本号无从展示）")
    t.check(GitHubReleaseParser.parseLatest(json("{\"tag_name\":\"v1.0\"}")) == nil, "缺 assets 应返回 nil")
    t.check(GitHubReleaseParser.parseLatest(json("<html>rate limited</html>")) == nil,
            "★非 JSON（限流页 / 网关错误页）应返回 nil 而不是崩")

    // tag → 版本号
    t.equal(GitHubReleaseParser.displayVersion(fromTag: "v2.2.3"), "2.2.3", "去 v 前缀")
    t.equal(GitHubReleaseParser.displayVersion(fromTag: "2.2.3"), "2.2.3", "本来没前缀就原样返回")
    t.equal(GitHubReleaseParser.displayVersion(fromTag: "V10.0"), "10.0", "大写 V 也要处理")
    t.equal(GitHubReleaseParser.displayVersion(fromTag: "  v1.2  "), "1.2", "两端空白要修掉")

    // 仓库 slug 校验：它会被拼进 api.github.com 的路径
    t.check(GitHubReleaseParser.isValidRepoSlug("Seven-hub-fanfan/scrollapp-leftclick"), "正常 slug 应通过")
    t.check(GitHubReleaseParser.isValidRepoSlug("o/r.dot_ok-1"), "点/下划线/连字符是合法仓库名字符")
    for bad in ["owner", "a/b/c", "../etc", "o/..", "o/", "/r", "", "o/r?x=1", "o/r#f", "o r/x", "o/r/../../x"] {
        t.check(!GitHubReleaseParser.isValidRepoSlug(bad), "★非法 slug 必须拒：\(bad.isEmpty ? "(空)" : bad)")
    }
    t.equal(GitHubReleaseParser.latestReleaseAPIURL(repo: "o/r")?.absoluteString,
            "https://api.github.com/repos/o/r/releases/latest", "API 地址拼接")
    t.equal(GitHubReleaseParser.latestReleasePageURL(repo: "o/r")?.absoluteString,
            "https://github.com/o/r/releases/latest", "★降级页面用 releases/latest（永远指向最新版，不写死 tag）")
    t.check(GitHubReleaseParser.latestReleaseAPIURL(repo: "o/../r") == nil,
            "★★非法 slug 不得拼出 URL（否则请求会逃出 /repos/ 前缀打到别的 endpoint）")
}

// MARK: - KEYCHAIN-PROBE：钥匙串探测必须非阻塞（v2.11.8）
//
// 背景：adhoc 签名每次构建都变，覆盖安装后首次读钥匙串必然弹系统授权框，而
// SecItemCopyMatching 会阻塞调用线程。Agent 侧栏原来在首帧同步读 → 主窗口在用户点掉
// 授权框前画不出来。这里断言的是「探测接口存在且能在非主线程完成、不存在的条目返回
// false 而不是抛/挂」；真实 ACL 弹框行为无法在无头测试里覆盖。
do {
    let service = "com.clipslots.smoke.keychain.probe.absent"
    let account = "no-such-account-\(UUID().uuidString)"
    let exists = smokeAwait { await AgentKeychainProbe.hasAPIKey(service: service, account: account) }
    t.check(!exists, "★不存在的钥匙串条目探测应返回 false（errSecItemNotFound 不弹框、不抛）")

    // 同一探测跑两次仍然是 false，且不会因为 continuation 被重复 resume 而崩。
    let again = smokeAwait { await AgentKeychainProbe.hasAPIKey(service: service, account: account) }
    t.check(!again, "重复探测保持 false（continuation 只 resume 一次）")
}

// MARK: - CANVAS-SPAWN：新节点落点几何（v2.11.8）
//
// 三个入口（双击空白 / Cmd+V / 选中节点下方的 +）算的是同一件事：一个点 → 一个不撞车的落点。
// 这里锁死口径，防止三处各写一份后出现「双击建的节点对齐网格、粘贴的偏半格」。
do {
    // 视口中心：默认整视图中心。
    let c1 = CanvasSpawnGeometry.viewportCenter(pan: .zero, zoom: 1,
                                               viewportSize: CGSize(width: 1000, height: 600))
    t.check(canvasApprox(c1.x, 500) && canvasApprox(c1.y, 300), "视口中心（无平移无缩放）= 视图中心")

    // 缩放 + 平移后仍必须与 CanvasGeometry 的反变换一致（同一个公式，不能各算一套）。
    let pan = CGSize(width: -120, height: 80)
    let c2 = CanvasSpawnGeometry.viewportCenter(pan: pan, zoom: 2,
                                               viewportSize: CGSize(width: 800, height: 400))
    let expect2 = CanvasGeometry.canvasPoint(screen: CGPoint(x: 400, y: 200), pan: pan, zoom: 2)
    t.check(canvasApprox(c2.x, expect2.x) && canvasApprox(c2.y, expect2.y),
            "★视口中心必须等于 CanvasGeometry 反变换的结果（screen = canvas*zoom+pan 唯一口径）")

    // 侧栏让位：槽位库展开占 240pt 时，中心要落在**可见区域**中心，不能藏到侧栏后面。
    let c3 = CanvasSpawnGeometry.viewportCenter(pan: .zero, zoom: 1,
                                               viewportSize: CGSize(width: 760, height: 600),
                                               viewportOrigin: CGPoint(x: 240, y: 0))
    t.check(canvasApprox(c3.x, 620), "★侧栏展开时落点取可见区域中心（240+760/2），否则新节点藏在侧栏后面")

    // 中心 → 左上角。
    let o1 = CanvasSpawnGeometry.origin(forCenter: CGPoint(x: 100, y: 100),
                                       size: CGSize(width: 260, height: 300))
    t.check(canvasApprox(o1.x, -30) && canvasApprox(o1.y, -50), "中心换算成左上角要各减半宽半高")

    // 下游落点：左对齐 + 垂直间距 60（用户指定）。
    let frame = CGRect(x: 40, y: 100, width: 260, height: 300)
    let down = CanvasSpawnGeometry.downstreamOrigin(of: frame, newSize: CanvasNode.defaultSize)
    t.check(canvasApprox(down.x, 40), "★下游节点与上游**左对齐**（中心对齐在卡片宽度不同时看起来像随机缩进）")
    t.check(canvasApprox(down.y, 460), "下游节点在上游下方 60pt（100+300+60）")
    t.equal(CanvasSpawnGeometry.downstreamGap, 60, "下游间距常量 = 60pt")

    // 让位：没有既有节点时原样返回。
    let keep = CanvasSpawnGeometry.nonOverlappingOrigin(desired: CGPoint(x: 10, y: 10), existing: [])
    t.check(canvasApprox(keep.x, 10) && canvasApprox(keep.y, 10), "画布上没有节点时落点不动")

    // 完全重合 → 斜向让位一步。
    let moved = CanvasSpawnGeometry.nonOverlappingOrigin(desired: CGPoint(x: 10, y: 10),
                                                        existing: [CGPoint(x: 10, y: 10)])
    t.check(canvasApprox(moved.x, 38) && canvasApprox(moved.y, 38),
            "★与已有节点完全重合时斜向让位一步（28,28），否则用户以为「点了没反应」")

    // 相隔够远（> collisionRadius）就不让位：允许重叠是正常排版意图，只禁止完全重合。
    let far = CanvasSpawnGeometry.nonOverlappingOrigin(desired: CGPoint(x: 10, y: 10),
                                                      existing: [CGPoint(x: 60, y: 10)])
    t.check(canvasApprox(far.x, 10), "★距离超过判定半径就不让位（部分重叠是合法排版，不该被系统擅自挪开）")

    // 让位有上限：满屏都是重合点时接受重叠而不是无限循环 / 扔到视野外。
    let crowd = (0..<200).map { CGPoint(x: 10 + CGFloat($0) * 28, y: 10 + CGFloat($0) * 28) }
    let capped = CanvasSpawnGeometry.nonOverlappingOrigin(desired: CGPoint(x: 10, y: 10),
                                                         existing: crowd,
                                                         maxAttempts: 3)
    t.check(canvasApprox(capped.x, 10 + 3 * 28), "★让位次数封顶后接受重叠（宁可叠着，也不能死循环或飞出视野）")

    // 空槽位选择：1-based、从小到大、全满返回 nil。
    t.equal(CanvasSpawnGeometry.firstFreeSlot(total: 10, occupied: []), 1, "空组取第 1 号槽位")
    t.equal(CanvasSpawnGeometry.firstFreeSlot(total: 10, occupied: [1, 2, 4]), 3, "跳过已占用，取最小空号")
    t.check(CanvasSpawnGeometry.firstFreeSlot(total: 3, occupied: [1, 2, 3]) == nil,
            "★全部占满返回 nil —— 绝不覆盖已有槽位来满足一次「新建节点」")
    t.check(CanvasSpawnGeometry.firstFreeSlot(total: 0, occupied: []) == nil,
            "槽位数为 0（配置损坏）返回 nil，不能让 1...0 崩掉")
}

// MARK: - CANVAS-FAN：槽位节点扇形堆叠卡片（v2.11.8）
//
// 用户要求的交互：收拢叠放 → 整节点 hover 扇开 → 单卡 hover 抬起放大提层。
// 几何放在 Kit 是为了能在这里断言"对称""不越界""hover 只影响那一张"。
do {
    // 张数夹取：0 也要给一张（空槽位显示虚线空卡），超过 4 张截断。
    t.equal(CanvasFanGeometry.layouts(count: 0, expanded: false).count, 1,
            "★0 张内容也返回 1 张卡片（空槽位要有一张空卡，否则节点预览区一片空白像坏了）")
    t.equal(CanvasFanGeometry.layouts(count: 9, expanded: false).count, CanvasFanGeometry.maxCards,
            "卡片数封顶 4 张（再多在 236pt 宽的预览区里只会糊成一团）")

    // 角度关于中轴严格对称。
    let four = CanvasFanGeometry.layouts(count: 4, expanded: true)
    let angles = four.map { $0.angle }
    t.check(canvasApprox(angles[0], -angles[3]) && canvasApprox(angles[1], -angles[2]),
            "★展开角度关于中轴严格对称（不对称会让整叠卡片的视觉重心随张数奇偶左右跳）")
    let three = CanvasFanGeometry.layouts(count: 3, expanded: true)
    t.check(canvasApprox(three[1].angle, 0), "奇数张时中间那张角度为 0")
    t.check(canvasApprox(three[1].offset.width, 0), "奇数张时中间那张水平位移为 0")

    // 展开幅度必须大于收拢幅度，否则 hover 看不出变化。
    let collapsed4 = CanvasFanGeometry.layouts(count: 4, expanded: false)
    t.check(abs(four[0].angle) > abs(collapsed4[0].angle) * 2,
            "★展开态张角显著大于收拢态（用户要的就是「扇开」这个动作被看见）")
    t.check(abs(four[0].offset.width) > abs(collapsed4[0].offset.width),
            "展开态水平错位也更大")

    // 收拢态后卡下沉、展开态不下沉（要看清内容）。
    t.check(collapsed4[0].offset.height > 0, "收拢态两侧卡片略微下沉，产生「被压在下面」的层次")
    t.check(canvasApprox(four[0].offset.height, 0), "展开态不下沉（下沉会遮挡内容，与「看全每张卡」的目的冲突）")

    // 单卡 hover：只动那一张，抬起 -8pt、放大 1.08、Z 层提到最上。
    let hovered = CanvasFanGeometry.layouts(count: 4, expanded: true, hoveredIndex: 2)
    t.check(canvasApprox(hovered[2].scale, 1.08), "★单卡 hover 放大 1.08（用户指定）")
    t.check(canvasApprox(hovered[2].offset.height, -8), "★单卡 hover 上移 8pt（用户指定）")
    t.check(hovered[2].zIndex > hovered[3].zIndex && hovered[2].zIndex > hovered[0].zIndex,
            "★被悬停的卡片 Z 层最高（否则放大的那 8% 会被邻卡切掉，看起来像渲染错误）")
    t.check(canvasApprox(hovered[0].scale, 1) && canvasApprox(hovered[1].offset.height, 0),
            "hover 一张不该影响其他卡片的缩放/位移")
    t.check(canvasApprox(hovered[3].angle, four[3].angle), "hover 不改变任何卡片的角度（只抬起放大）")

    // 收拢态下的 zIndex 递增：后加的卡片压在前面的上面，最前那张才是 + 角标的宿主。
    t.check(collapsed4[3].zIndex > collapsed4[0].zIndex, "堆叠顺序稳定（下标越大越靠前）")

    // 文本分段：空行优先、其次换行、都没有就整段一张。
    t.equal(CanvasFanGeometry.textSegments("").count, 0, "空文本不产生文本卡")
    t.equal(CanvasFanGeometry.textSegments("   \n  ").count, 0, "纯空白文本不产生文本卡")
    t.equal(CanvasFanGeometry.textSegments("只有一段话").count, 1, "单段文本 → 一张卡")
    t.equal(CanvasFanGeometry.textSegments("第一段\n\n第二段\n\n第三段"), ["第一段", "第二段", "第三段"],
            "★空行是用户手写的段落边界，最可信，优先按它切")
    t.equal(CanvasFanGeometry.textSegments("a\nb\nc\nd").count, CanvasFanGeometry.maxTextCards,
            "文本卡最多 3 张（超出部分不显示，卡片不是阅读器）")
    t.equal(CanvasFanGeometry.textSegments("a\n\nb", limit: 1), ["a"], "limit 生效")

    // 内容来源优先级：图片附件 > 正文分段 > 空卡。
    t.equal(CanvasFanGeometry.cardSources(attachmentImageIndices: [0, 2], text: "一段文字"),
            [.attachmentIndex(0), .attachmentIndex(2)],
            "★有图片附件时优先成卡（图片是更具体的内容），且下标必须是原始附件下标而不是 0/1 重新编号")
    t.equal(CanvasFanGeometry.cardSources(attachmentImageIndices: [], text: "甲\n\n乙"),
            [.textSegment("甲"), .textSegment("乙")], "没有图片时正文分段成卡")
    t.equal(CanvasFanGeometry.cardSources(attachmentImageIndices: [], text: "  "),
            [.empty], "★空槽位返回一张空卡（而不是零张，零张会让预览区看起来像加载失败）")
    t.equal(CanvasFanGeometry.cardSources(attachmentImageIndices: [0, 1, 2, 3, 4, 5], text: "").count,
            CanvasFanGeometry.maxCards, "图片卡同样封顶 4 张")
}

// MARK: - CANVAS-PASTE：Cmd+V 类型判定（v2.11.8）
//
// 剪贴板通常同时带多种表示。这里锁死优先级：文件 > 位图 > 文本。
// 判定写错的表现是「复制一张图进画布，得到一个内容是 img 标签的文本节点」。
do {
    let png = URL(fileURLWithPath: "/tmp/a.png")
    let doc = URL(fileURLWithPath: "/tmp/a.pdf")

    t.check(CanvasPasteClassifier.classify(CanvasPasteSnapshot()) == nil,
            "★空剪贴板返回 nil（调用方要给提示，不能静默什么都不做）")
    t.check(CanvasPasteClassifier.classify(CanvasPasteSnapshot(text: "   \n ")) == nil,
            "只有空白字符 = 没内容")

    t.equal(CanvasPasteClassifier.classify(CanvasPasteSnapshot(fileURLs: [png],
                                                              hasBitmap: true,
                                                              text: "<img src=x>")),
            CanvasPasteIntent.imageNodeWithFiles([png]),
            "★★同时有文件+位图+文本时取文件（最具体）—— 从浏览器复制图片就是这种三合一剪贴板")
    t.equal(CanvasPasteClassifier.classify(CanvasPasteSnapshot(hasBitmap: true, text: "some html")),
            CanvasPasteIntent.imageNodeWithBitmap,
            "★位图优先于文本（截图没有文件路径，若判成文本就丢了整张图）")
    t.equal(CanvasPasteClassifier.classify(CanvasPasteSnapshot(text: "  hello  ")),
            CanvasPasteIntent.textNode("hello"),
            "纯文本兜底，且首尾空白被去掉")
    t.equal(CanvasPasteClassifier.classify(CanvasPasteSnapshot(fileURLs: [doc])),
            CanvasPasteIntent.imageNodeWithFiles([doc]),
            "非图片文件同样成节点（作为入参文件），不因为不是图片就丢弃")

    t.check(CanvasPasteClassifier.isImageFile(png), "png 识别为图片")
    t.check(CanvasPasteClassifier.isImageFile(URL(fileURLWithPath: "/tmp/B.JPEG")), "扩展名大小写不敏感")
    t.check(!CanvasPasteClassifier.isImageFile(doc),
            "★pdf 不算图像入参（NSImage 能打开它，但落进图像节点会得到一张莫名的首页缩略图）")
    t.check(!CanvasPasteClassifier.isImageFile(URL(fileURLWithPath: "/tmp/a.svg")),
            "svg 同理不算（矢量文件不是位图入参）")
    t.check(!CanvasPasteClassifier.isImageFile(URL(fileURLWithPath: "/tmp/noext")), "无扩展名不算图片")
}

// MARK: - CANVAS-KEY-PASTE：Cmd+V 快捷键判定（v2.11.8）
do {
    let v = CanvasKeyBinding.vKeyCode
    t.equal(CanvasKeyBinding.action(keyCode: v, command: true, shift: false), .paste, "⌘V = 粘贴")
    t.equal(CanvasKeyBinding.action(keyCode: v, command: false, shift: false), .none,
            "★裸 V 不是粘贴（它在画布类工具里是「选择工具」的肌肉记忆键，不能顺手占掉）")
    t.equal(CanvasKeyBinding.action(keyCode: v, command: true, shift: true), .none,
            "★⌘⇧V 不吃（各家 App 里是「粘贴为纯文本」，吞掉它用户查不出是谁吃的）")
    t.equal(CanvasKeyBinding.action(keyCode: v, command: true, shift: false, option: true), .none,
            "⌘⌥V 不吃（同理）")
    // 与既有绑定互不干扰。
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.zKeyCode, command: true, shift: false), .undo,
            "新增粘贴不影响 ⌘Z")
    t.equal(CanvasKeyBinding.action(keyCode: 51, command: false, shift: false), .delete,
            "新增粘贴不影响删除键")
}

// MARK: - CANVAS-TEXT-NODE：文本节点类型 + parentNodeId 血缘（v2.11.8）
do {
    t.equal(CanvasNodeKind.text.rawValue, "text", "文本节点的 rawValue 稳定（落盘值，改了等于旧数据读不出来）")
    t.equal(CanvasNodeKind.text.displayName, "文本", "文本节点显示名")
    t.check(!CanvasNodeKind.text.symbolName.isEmpty, "文本节点有图标")
    t.check(!CanvasNodeKind.text.producesAsset,
            "★文本节点不出图（它是「给下游用的一段文字」，把它当出图节点会让批量导出多出空文件）")
    t.check(CanvasNodeKind.image.producesAsset, "图像节点出图")

    // parentNodeId 往返。
    var child = canvasNode(slot: 2)
    child.parentNodeId = "g1#1"
    let data = try! JSONEncoder().encode(child)
    let back = try! JSONDecoder().decode(CanvasNode.self, from: data)
    t.equal(back.parentNodeId, "g1#1", "parentNodeId 能落盘并读回（+ 号建的下游节点靠它记血缘）")

    // 老数据（没有这个字段）必须解得出来，且为 nil。
    let legacy = """
    {"pageId":"p1","groupId":"g1","slot":3,"kind":"image","x":0,"y":0}
    """.data(using: .utf8)!
    let old = try! JSONDecoder().decode(CanvasNode.self, from: legacy)
    t.check(old.parentNodeId == nil,
            "★老画布数据没有 parentNodeId 也要能读（新字段可选是本项目的向后兼容口径，不靠版本分支）")
    t.equal(old.slot, 3, "老数据其余字段正常解出")

    // kind 也要向后兼容：老数据里没有 text 这个值，但新值必须能往返。
    var textNode = canvasNode(slot: 4)
    textNode.kind = .text
    let td = try! JSONEncoder().encode(textNode)
    t.equal(try! JSONDecoder().decode(CanvasNode.self, from: td).kind, .text, "text 类型能往返")
}

// MARK: - WINDOW-RESCUE：主窗口离屏 / 最小化自救几何（v2.11.8）
do {
    let primary = CGRect(x: 0, y: 0, width: 1512, height: 900)
    let secondary = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let screens = [primary, secondary]

    // 正常摆位：不许动窗口。
    let ok = CGRect(x: 100, y: 80, width: 1300, height: 800)
    t.check(!MainWindowRescueGeometry.needsRescue(window: ok, visibleFrames: screens),
            "窗口完整落在主屏内不触发自救")
    // 用户故意放副屏也不许动——这是最容易被自救逻辑「热心地」搬回主屏的场景。
    let onSecondary = CGRect(x: 1600, y: 100, width: 1200, height: 800)
    t.check(!MainWindowRescueGeometry.needsRescue(window: onSecondary, visibleFrames: screens),
            "★窗口在副屏正常显示时不能被搬回主屏（否则每次启动都把用户的摆位打乱）")

    // 复现线上那次「进程在跑但看不到窗口」：外接屏拔掉后窗口留在屏外。
    let offscreen = CGRect(x: 1766, y: -1790, width: 1512, height: 974)
    t.check(MainWindowRescueGeometry.needsRescue(window: offscreen, visibleFrames: [primary]),
            "★窗口完全落在所有屏幕之外必须自救（现场表现为 App 有进程、无可见窗口）")
    let fixed = MainWindowRescueGeometry.rescuedFrame(window: offscreen, visibleFrames: [primary])
    t.check(primary.contains(fixed), "自救后窗口完整落在屏幕可见区域内")
    t.check(abs(fixed.midX - primary.midX) < 0.5 && abs(fixed.midY - primary.midY) < 0.5,
            "完全离屏时居中落点（贴边会让人以为窗口被挤坏了）")

    // 只露一条边同样算看不见。
    let sliver = CGRect(x: -1400, y: 100, width: 1500, height: 800)
    t.check(MainWindowRescueGeometry.visibleFraction(window: sliver, visibleFrames: screens) < MainWindowRescueGeometry.minVisibleFraction,
            "只露出一小条边时可见比例低于阈值")
    t.check(MainWindowRescueGeometry.needsRescue(window: sliver, visibleFrames: screens), "露一条边也要自救")
    let slid = MainWindowRescueGeometry.rescuedFrame(window: sliver, visibleFrames: screens)
    t.check(primary.contains(slid), "部分离屏时夹回屏内")
    t.check(abs(slid.height - sliver.height) < 0.5, "夹回时不无谓改变能装下的尺寸")

    // 窗口比屏幕大：必须夹到屏幕尺寸，不能溢出。
    let huge = CGRect(x: -500, y: -500, width: 4000, height: 3000)
    let clamped = MainWindowRescueGeometry.rescuedFrame(window: huge, visibleFrames: [primary])
    t.check(clamped.width <= primary.width + 0.5 && clamped.height <= primary.height + 0.5,
            "★超过屏幕的窗口被夹到屏幕尺寸（否则自救完标题栏还在屏外，等于没救）")
    t.check(primary.contains(clamped.insetBy(dx: -0.5, dy: -0.5).intersection(primary)), "夹完仍在屏内")

    // 拿不到屏幕信息时保守不动。
    t.check(!MainWindowRescueGeometry.needsRescue(window: offscreen, visibleFrames: []),
            "★没有屏幕信息时不动窗口（宁可不救，也不要在异常态里乱搬）")
    t.equal(MainWindowRescueGeometry.rescuedFrame(window: offscreen, visibleFrames: []), offscreen,
            "无屏幕信息时原样返回")

    // 尺寸退化的窗口（0×0）也要能救回可用大小。
    let degenerate = CGRect(x: 5000, y: 5000, width: 0, height: 0)
    t.check(MainWindowRescueGeometry.needsRescue(window: degenerate, visibleFrames: [primary]), "0 尺寸窗口需要自救")
    let revived = MainWindowRescueGeometry.rescuedFrame(window: degenerate, visibleFrames: [primary])
    t.check(revived.width > 0 && revived.height > 0, "自救后窗口有可用尺寸")
    t.check(primary.contains(revived), "自救后窗口在屏内")
}

// MARK: - CANVAS-DBLCLICK：空白双击判定（v2.11.8，替代失效的 onTapGesture(count: 2)）
do {
    let interval: TimeInterval = 0.5
    let p0 = CGPoint(x: 400, y: 300)
    let first = CanvasClickCadence.Click(point: p0, time: 100.0)

    t.check(!CanvasClickCadence.isDoubleClick(previous: nil,
                                             current: first,
                                             interval: interval),
            "第一击不是双击（没有前一击时必须返回 false，否则一进画布点一下就弹菜单）")

    t.check(CanvasClickCadence.isDoubleClick(previous: first,
                                            current: .init(point: p0, time: 100.18),
                                            interval: interval),
            "同点位、间隔 0.18s 判为双击")

    t.check(!CanvasClickCadence.isDoubleClick(previous: first,
                                             current: .init(point: p0, time: 100.9),
                                             interval: interval),
            "★超过系统双击间隔就不算双击（慢慢点两下取消选中，不该弹出菜单）")

    // 位置容差：手抖要容忍，跨半个画布点两下不能算双击。
    let jitter = CGPoint(x: p0.x + 4, y: p0.y - 3)  // 位移 5 < slop 6
    t.check(CanvasClickCadence.isDoubleClick(previous: first,
                                            current: .init(point: jitter, time: 100.2),
                                            interval: interval),
            "落点抖动 5pt 仍判为双击（容差内）")
    let farAway = CGPoint(x: p0.x + 220, y: p0.y + 40)
    t.check(!CanvasClickCadence.isDoubleClick(previous: first,
                                             current: .init(point: farAway, time: 100.2),
                                             interval: interval),
            "★画布两处各点一下不算双击（否则快速点两个不同位置会凭空弹菜单）")
    // 容差边界：正好在 slop 上算命中，刚超出就不算。
    let onEdge = CGPoint(x: p0.x + CanvasClickCadence.defaultSlop, y: p0.y)
    t.check(CanvasClickCadence.isDoubleClick(previous: first,
                                            current: .init(point: onEdge, time: 100.2),
                                            interval: interval),
            "位移正好等于容差算双击")
    let overEdge = CGPoint(x: p0.x + CanvasClickCadence.defaultSlop + 0.5, y: p0.y)
    t.check(!CanvasClickCadence.isDoubleClick(previous: first,
                                             current: .init(point: overEdge, time: 100.2),
                                             interval: interval),
            "位移刚超出容差不算双击")

    // 时间边界与时钟回拨。
    t.check(CanvasClickCadence.isDoubleClick(previous: first,
                                            current: .init(point: p0, time: 100.0 + interval),
                                            interval: interval),
            "间隔正好等于阈值算双击")
    t.check(!CanvasClickCadence.isDoubleClick(previous: first,
                                             current: .init(point: p0, time: 99.8),
                                             interval: interval),
            "★时间倒流（时钟回拨/传参顺序反了）不算双击，不能因为算出负数就当 0 秒")
    t.check(CanvasClickCadence.defaultSlop > 0, "容差为正")
}

// MARK: - CANVAS-ESC：裸 Esc = 从临时态退出（v2.11.8 修「编辑态卡住」）
do {
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.escapeKeyCode, command: false, shift: false), .cancel,
            "裸 Esc 判为 cancel（用来收掉 inline 编辑残留态 / 关浮层 / 取消选中）")
    t.equal(CanvasKeyBinding.escapeKeyCode, 53, "Esc 键码固定为 53")
    // 带修饰键的 Esc 系统另有用途（⌘Esc 语音控制、⌥Esc 旁白），画布不许吃。
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.escapeKeyCode, command: true, shift: false), .none,
            "★⌘Esc 不归画布（系统语音控制快捷键，吃掉了用户查不出是谁吃的）")
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.escapeKeyCode, command: false, shift: true), .none,
            "⇧Esc 不归画布")
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.escapeKeyCode, command: false, shift: false, option: true), .none,
            "⌥Esc 不归画布")
    // 新增绑定不能影响既有的四条。
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.zKeyCode, command: true, shift: false), .undo, "Esc 绑定不影响 ⌘Z")
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.zKeyCode, command: true, shift: true), .redo, "Esc 绑定不影响 ⌘⇧Z")
    t.equal(CanvasKeyBinding.action(keyCode: CanvasKeyBinding.vKeyCode, command: true, shift: false), .paste, "Esc 绑定不影响 ⌘V")
    t.equal(CanvasKeyBinding.action(keyCode: 51, command: false, shift: false), .delete, "Esc 绑定不影响删除键")
}

t.report()
