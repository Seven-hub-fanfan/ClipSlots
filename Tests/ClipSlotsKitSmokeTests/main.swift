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

t.report()
