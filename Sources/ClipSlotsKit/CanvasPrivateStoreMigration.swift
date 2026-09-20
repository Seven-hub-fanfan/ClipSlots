import Foundation

/// 把画布私有内容从**槽位库**搬到**画布私有库**（v2.14.0）。
///
/// ## 要修的是什么
///
/// v2.11.8~v2.13.x 的画布私有组（`__unfiled__` / `__canvas__<projectId>`）就住在
/// `special_slots/index.json` 里，靠"在发布边界上过滤掉"对用户隐身。用户的反馈把这个设计判死了：
///
/// > 「发现未入库和暂存区都会占用槽位组的创建，其实不应该直接显示在默认页面中，并且更不应该在
/// > 槽位组里新建暂存区……不占用槽位页面的任何页面和槽位组的形式，只在画布模式中进行一个管理。」
///
/// 他没说错。那套过滤在实现上也漏了：`specialSlots` 有两条旁路赋值没走过滤，于是编辑页的组标签栏
/// 就真的冒出「未入库」「画布·项目」两个组，还被算进"这一页有几个组"。
///
/// ## 这次的做法
///
/// 把这些组**物理搬出** `special_slots/`：目录搬到 `canvas/private_slots/<groupId>/`，索引条目从
/// 主索引删掉、写进画布私有库的索引。搬完之后槽位库里不存在这些组 —— 不是看不见，是不存在。
///
/// ## 为什么"搬目录"而不是"重新导出再导入"
///
/// 槽位内容不只有正文：附件是外置文件（`.bin` + `attachments.json`）、Label 是 `label.txt`、
/// 手动缩略图是另一个文件。一次 `moveItem` 把整棵子树原样搬过去，零解析、零转码、不可能丢字段；
/// 而"读出来再写进去"每加一种新字段就多一个漏搬的机会。
///
/// ## 安全边界
///
/// - **幂等**：主索引里没有画布私有组时直接返回，不碰任何文件。
/// - **目标已存在就不搬**（只登记索引）：不合并、不覆盖。宁可留一份孤儿目录在老位置，也不能把
///   两份内容混进同一个目录。
/// - **先搬目录、再改索引**：反过来的话，一旦搬目录那一步失败，索引已经说"这个组不在槽位库了"，
///   而内容还躺在 `special_slots/` 里没人认领。
/// - 游标清理：主索引里指向被搬走组的 `currentSpecialSlotId` / `selected` / `activeHotkey` /
///   自动存储与自动粘贴游标全部要修，否则会留下"指向一个不存在的组"的悬空引用（那是 v2.4.1
///   那批修复反复在处理的老病）。
public enum CanvasPrivateStoreMigration {

    /// 迁移计划（纯数据，可测）。
    public struct Plan: Equatable {
        /// 需要搬去画布私有库的组。
        public let groupsToMove: [SpecialSlot]
        /// 搬完之后的主索引（已剔除这些组并修好悬空游标）。
        public let mainIndexAfter: SpecialSlotIndex
        /// 主索引需不需要落盘。
        public var needsWrite: Bool { !groupsToMove.isEmpty || cursorsChanged }
        /// 只有游标要修（组已经搬过、但索引里还留着指向它的游标）。
        public let cursorsChanged: Bool

        public static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.groupsToMove.map(\.id) == rhs.groupsToMove.map(\.id)
                && lhs.cursorsChanged == rhs.cursorsChanged
                && lhs.mainIndexAfter.specialSlots.map(\.id) == rhs.mainIndexAfter.specialSlots.map(\.id)
                && lhs.mainIndexAfter.currentSpecialSlotId == rhs.mainIndexAfter.currentSpecialSlotId
        }
    }

    /// 纯逻辑：给定主索引，算出要搬哪些组、搬完之后的主索引长什么样。
    public static func plan(mainIndex: SpecialSlotIndex) -> Plan {
        var index = mainIndex
        let reserved = index.specialSlots.filter { SpecialSlotStorage.isReservedGroupId($0.id) }
        index.specialSlots.removeAll { SpecialSlotStorage.isReservedGroupId($0.id) }

        var cursorsChanged = false

        // 当前组指向被搬走的组：退回本页第一个普通组（没有就退回任意组，再没有就退回 "default" ——
        // 与 `repairPageScopedSlotGroupsIfNeeded` 的兜底保持一致，避免两处修复互相打架）。
        if SpecialSlotStorage.isReservedGroupId(index.currentSpecialSlotId) {
            let samePage = index.specialSlots
                .filter { $0.pageId == index.currentPageId }
                .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
            index.currentSpecialSlotId = samePage.first?.id ?? index.specialSlots.first?.id ?? "default"
            cursorsChanged = true
        }
        if let selected = index.selectedSpecialSlotId, SpecialSlotStorage.isReservedGroupId(selected) {
            index.selectedSpecialSlotId = index.currentSpecialSlotId
            cursorsChanged = true
        }
        if let active = index.activeHotkeySpecialSlotId, SpecialSlotStorage.isReservedGroupId(active) {
            index.activeHotkeySpecialSlotId = index.currentSpecialSlotId
            cursorsChanged = true
        }
        if let c = index.autoStoreCursor, SpecialSlotStorage.isReservedGroupId(c.groupId) {
            index.autoStoreCursor = nil
            cursorsChanged = true
        }
        if let c = index.autoStoreCursorPrev, SpecialSlotStorage.isReservedGroupId(c.groupId) {
            index.autoStoreCursorPrev = nil
            cursorsChanged = true
        }
        if let c = index.autoPasteCursor, SpecialSlotStorage.isReservedGroupId(c.groupId) {
            index.autoPasteCursor = nil
            cursorsChanged = true
        }
        if let c = index.autoPasteCursorPrev, SpecialSlotStorage.isReservedGroupId(c.groupId) {
            index.autoPasteCursorPrev = nil
            cursorsChanged = true
        }

        return Plan(groupsToMove: reserved, mainIndexAfter: index, cursorsChanged: cursorsChanged)
    }

    /// 进程内只跑一次的入口（v2.14.0）。
    ///
    /// 调用点必须在**任何人读主索引之前**——GUI 是 `SlotStoreObservable.init`，CLI 是命令分发前。
    /// 晚一步的代价是：UI 已经拿着含保留组的索引渲染完了第一帧，组标签栏闪一下「未入库」。
    ///
    /// `once` 用锁而不是 `lazy static`：这个函数返回值有意义（搬了几组，调用方要写日志），
    /// 而 `lazy static` 的初始化语义会把"第二次调用返回 0"和"第一次真的搬了 0 组"混成一件事。
    @discardableResult
    public static func runOnce() -> Int {
        onceLock.lock()
        if didRun { onceLock.unlock(); return 0 }
        didRun = true
        onceLock.unlock()
        // 先只看主索引：没有保留组（全新用户，或上次启动已经迁移过）就到此为止。
        //
        // 这一步刻意**不碰** `SpecialSlotStorage.canvasPrivate`：那个惰性单例一旦被求值就会建出
        // `canvas/private_slots/` 目录和一份索引，从没打开过画布的用户凭空多一个数据目录。
        // 而 `run()` 的默认参数在调用点就会求值，所以这道门必须挡在 `run()` 之前，不能挡在里面。
        guard plan(mainIndex: SpecialSlotStorage.shared.loadIndex()).needsWrite else { return 0 }
        return run()
    }

    private static let onceLock = NSLock()
    private static var didRun = false

    /// 执行迁移。返回真正搬走的组数。
    ///
    /// 在 App 启动早期调一次即可（CLI 不需要：它压根不认识画布，主索引里没有这些组之后它的行为
    /// 反而更干净）。
    @discardableResult
    public static func run(main: SpecialSlotStorage = .shared,
                           canvasPrivate: SpecialSlotStorage = .canvasPrivate) -> Int {
        let plan = plan(mainIndex: main.loadIndex())
        guard plan.needsWrite else { return 0 }

        let fm = FileManager.default
        var moved = 0
        for group in plan.groupsToMove {
            let source = main.storageRoot.appendingPathComponent(group.id, isDirectory: true)
            let target = canvasPrivate.storageRoot.appendingPathComponent(group.id, isDirectory: true)
            if fm.fileExists(atPath: source.path) {
                if fm.fileExists(atPath: target.path) {
                    // 目标已存在（上一次迁移搬到一半被打断）：不合并、不覆盖。老目录留在原地，
                    // 索引条目仍然登记到私有库 —— 内容一条不丢，最多多一份孤儿目录。
                    NSLog("[ClipSlots] v2.14 迁移：\(group.id) 在画布私有库里已存在，跳过搬移（老目录保留在 special_slots）")
                } else {
                    do {
                        try fm.createDirectory(at: canvasPrivate.storageRoot, withIntermediateDirectories: true)
                        try fm.moveItem(at: source, to: target)
                        // 搬完立刻把主库里那个指着老路径的存储句柄踢掉。不踢的后果很具体：任何一次
                        // 经由旧句柄的写入都会在 `special_slots/<组>/` 下把目录重建出来，等于刚
                        // 搬走的组又在槽位库里复活。
                        main.evictGroupStorageCacheAfterMigration(groupId: group.id)
                        moved += 1
                    } catch {
                        // 搬不动就整体放弃这一组：**不**把它从主索引里删掉，否则内容就成了孤儿。
                        NSLog("[ClipSlots] v2.14 迁移失败（\(group.id)）：\(error.localizedDescription)，本组保留在槽位库")
                        continue
                    }
                }
            }
            // 登记到画布私有库的索引。名字统一成「未入库」——「暂存区」那个叫法是 v2.13.0 的产物，
            // 用户明确说了不要。
            do {
                try canvasPrivate.ensureReservedGroup(id: group.id,
                                                      name: SpecialSlotStorage.unfiledGroupName)
            } catch {
                NSLog("[ClipSlots] v2.14 迁移：登记 \(group.id) 到画布私有库失败：\(error.localizedDescription)")
            }
        }

        // 主索引最后写：前面任何一步失败都只是"多留一份在老位置"，而不是"索引说没有、内容还在"。
        do {
            var after = plan.mainIndexAfter
            // 只把**确认已经登记进私有库**的组从主索引里摘掉。搬移失败的组要留在主索引里，
            // 否则 STG-2（写内容要求组在 index 里）会让那份内容从此不可写。
            let registered = Set(canvasPrivate.loadIndex().specialSlots.map(\.id))
            let stillOwned = plan.groupsToMove.filter { !registered.contains($0.id) }
            if !stillOwned.isEmpty {
                after.specialSlots.append(contentsOf: stillOwned)
                NSLog("[ClipSlots] v2.14 迁移：\(stillOwned.count) 个组未能登记到画布私有库，暂留槽位库")
            }
            try main.saveIndex(after)
            NSLog("[ClipSlots] v2.14 迁移完成：搬移 \(moved) 组，主索引剔除 \(plan.groupsToMove.count - stillOwned.count) 组")
        } catch {
            NSLog("[ClipSlots] v2.14 迁移：主索引落盘失败：\(error.localizedDescription)")
        }
        return moved
    }
}
