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
}

t.report()
