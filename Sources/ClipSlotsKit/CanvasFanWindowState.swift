import Foundation

/// 堆叠卡片「翻页窗口」的**跨视图重建存活**（v2.11.8 六轮）。
///
/// ## 用户报的现象
///
/// 「向节点拖入新图片后，图片处于第 1 张。但点击右键、然后切到其他页面再切回来，新图片变成了
/// 第 2 张，旧卡片翻到第 1 张 —— 顺序反了。」
///
/// ## 为什么这不是"排序 bug"而是"窗口 bug"
///
/// 附件的顺序**只有一份真相**：`SlotContent.attachments` 的数组下标，它随槽位内容一起落盘，
/// 读回来不做任何 `sorted` / `reversed`（见 `CanvasSlotOrder` 的注释与 smoke 断言）。
/// 所以"顺序变了"的观感来自另外两处**临时状态**：
///
/// 1. `windowStart`（当前显示到第几张开始的那 5 张）此前是 `CanvasSlotFanStack` 的 `@State`。
///    `@State` 的寿命绑定在**视图身份**上：右键（`.contextMenu` 会把内容重新求值/重建）、
///    画布↔编辑页切换（整棵子树 unmount/remount）都会把它打回 0。用户翻到第 2 页、或刚拖入的
///    新附件正好落在第 2 页，一次右键就把窗口打回第 1 页 —— 眼睛看到的就是"卡片顺序全变了"。
/// 2. 附件增删时旧代码无条件 `windowStart = 0`，于是"拖入一张新图" = "跳回第一页"，新图片
///    （在数组尾部）反而被翻页藏起来了。
///
/// 修法就是把窗口起点变成**可跨重建恢复的数据**：
///   - 纯函数（本文件的 `clamp` / `startAfterCountChange` / `startRevealing`）负责算，可被 smoke 直接断言；
///   - `CanvasFanWindowRegistry` 按节点 key 存活，视图重建后 `onAppear` 把它读回来。
///
/// ## 为什么不塞进 `CanvasStore`（@Published）
///
/// 项目现存的性能债是「任一槽位变化触发全局重绘」，再往 `@Published` 上挂一个"鼠标翻页"级别的
/// 高频状态，等于每翻一页整张画布重排。登记处是**普通引用类型**：写它不发通知（翻页本身已经由
/// 视图自己的 `@State` 驱动动画），它只承担"重建后我还记得你翻到哪了"这一件事。
public enum CanvasFanWindowState {

    /// 把窗口起点钳制到合法区间 `[0, max(0, total - capacity)]`。
    ///
    /// 越界起点的后果不是"显示错"而是"显示空"：`CardWindow` 会切出 0 张卡，节点预览区突然变空白。
    public static func clamp(start: Int, total: Int, capacity: Int) -> Int {
        guard total > 0, capacity > 0 else { return 0 }
        let last = max(0, total - capacity)
        return min(max(0, start), last)
    }

    /// 让某个下标**可见**的最小改动起点：已经在窗口里就原地不动，否则把它挪进来。
    ///
    /// 原地不动这件事是刻意的 —— 用户正看着第 2 页，某个后台刷新若把窗口"对齐"到别的页，
    /// 表现就是卡片自己跳了一下。
    public static func startRevealing(index: Int, start: Int, total: Int, capacity: Int) -> Int {
        guard total > 0, capacity > 0 else { return 0 }
        let idx = min(max(0, index), total - 1)
        let cur = clamp(start: start, total: total, capacity: capacity)
        if idx < cur { return clamp(start: idx, total: total, capacity: capacity) }
        if idx > cur + capacity - 1 {
            return clamp(start: idx - capacity + 1, total: total, capacity: capacity)
        }
        return cur
    }

    /// 附件数量变化后的新起点。
    ///
    /// - 变多（拖入 / 粘贴 / 新建）：把**新增的最后一张**露出来。用户刚拖进来的东西必须看得见，
    ///   这是"拖入后新图片在哪"这个问题唯一说得过去的答案；旧代码在这里写 `0`，等于把新图片藏到
    ///   翻页之后。
    /// - 变少（删除）：只钳制，不跳页。删一张就跳回第一页会让"连删几张"变成"每删一张都要重新翻回来"。
    /// - 不变（改名 / 换路径）：只钳制。
    public static func startAfterCountChange(oldTotal: Int,
                                            newTotal: Int,
                                            start: Int,
                                            capacity: Int) -> Int {
        guard newTotal > 0, capacity > 0 else { return 0 }
        if newTotal > oldTotal {
            return startRevealing(index: newTotal - 1, start: start, total: newTotal, capacity: capacity)
        }
        return clamp(start: start, total: newTotal, capacity: capacity)
    }

    /// 登记处的 key。`nodeId` 已经是 `groupId#slot`，再拼上展开风格 —— 扇形（容量 5）与轮播
    /// （容量 3）的起点不通用，共用一个 key 会让切风格时开在半页上。
    public static func key(nodeId: String, styleTag: String) -> String {
        "\(nodeId)|\(styleTag)"
    }
}

/// 按节点存活的窗口起点登记处。见 `CanvasFanWindowState` 顶部注释里"为什么不用 @Published"。
public final class CanvasFanWindowRegistry {

    public static let shared = CanvasFanWindowRegistry()

    private var starts: [String: Int] = [:]
    private let lock = NSLock()

    public init() {}

    /// 读回起点并**当场钳制**：期间附件可能被别处（CLI / 编辑页 / 另一个面板）删到更少。
    public func start(for key: String, total: Int, capacity: Int) -> Int {
        lock.lock()
        let raw = starts[key] ?? 0
        lock.unlock()
        return CanvasFanWindowState.clamp(start: raw, total: total, capacity: capacity)
    }

    public func set(_ start: Int, for key: String) {
        lock.lock()
        starts[key] = max(0, start)
        lock.unlock()
    }

    public func forget(_ key: String) {
        lock.lock()
        starts.removeValue(forKey: key)
        lock.unlock()
    }

    /// 仅测试用：清空全部记录。
    public func reset() {
        lock.lock()
        starts.removeAll()
        lock.unlock()
    }
}

/// 附件卡片顺序的**唯一真相**（v2.11.8 六轮）。
///
/// 这个类型没有"排序"函数，这正是它要表达的东西：**顺序就是持久化数组的下标**，
/// 渲染层不许再引入第二套排序口径。
///
/// ## 为什么不按 `createdAt` 排
///
/// `SlotAttachment` 确实带 `createdAt`，但入参文件面板支持**手动拖拽排序**（用户在 v2.11.8 二轮
/// 明确要求过"支持调整每个槽位顺序"），而"设为入参"就是把某张挪到首位 —— 一旦渲染层按
/// `createdAt` 重排，这两个功能当场失效（用户拖完松手，卡片自己弹回去）。
/// `createdAt` 因此只是元信息，不是排序键。
///
/// ## 为什么需要 fingerprint
///
/// 用来在 smoke 里做"unmount/remount 模拟"：同一份持久化数据、两次独立构建视图数据源，
/// 指纹必须逐字相同。顺序若在任何一环被 `sorted` / `reversed` / 字典遍历打乱，指纹立刻不等。
public enum CanvasSlotOrder {

    /// 顺序指纹：`下标:名字` 逐项拼接。含下标是为了让"两张同名附件互换位置"也能被抓到。
    public static func fingerprint(_ attachments: [SlotContent.SlotAttachment]) -> String {
        attachments.enumerated()
            .map { "\($0.offset):\($0.element.name)" }
            .joined(separator: "|")
    }

    /// 新附件应落在的下标：**尾部**。
    ///
    /// 首位是有语义的（缩略图 / 圆盘 / 「设为入参」取的那一张），拖入一张新图不该悄悄顶掉它 ——
    /// 这也是为什么修法是"把新附件露出来"而不是"把新附件插到最前面"。
    public static func insertionIndex(currentCount: Int) -> Int { max(0, currentCount) }
}
