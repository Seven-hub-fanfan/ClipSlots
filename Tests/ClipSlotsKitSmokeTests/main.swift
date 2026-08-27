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

t.report()
