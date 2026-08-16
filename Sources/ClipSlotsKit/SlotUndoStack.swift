import Foundation

/// UNDO-1 (v2.10.95): 多步撤销（Cmd+Z）的纯数据结构。
///
/// 背景：v2.7.26~v2.10.94 只有「一步」撤销（`lastClearSnapshot` 单个快照，Ctrl+Z），且只覆盖
/// 清空/删除。本类型把撤销栈抽成 ClipSlotsKit 里的纯逻辑（无 AppKit / 无 @Published 依赖），
/// 便于 smoke 测试钉死不变量，GUI 侧（SlotStoreObservable）只负责「何时抓快照 / 如何回写」。
///
/// 语义约定（与用户预期一致，不得回归）：
///   • 每个槽位组各自维护一条撤销链，最多 `limitPerGroup`（默认 10，v2.10.97 起可在设置里
///     配置 1~100）步，超出丢弃最旧的一步。
///   • 「清空整组」与「清空单槽」都各算一步（快照是整组 10 个槽位的全量状态，所以撤销后
///     内容全部返回，而不是只回来一个槽位）。
///   • 撤销总是弹出「当前组最新的一步」；其它组的历史保持原样（切回去仍可撤销），避免
///     v2.8.7 (D) 修过的「跨组撤销污染错组」问题。
///   • 全局再加一道 `globalLimit`（每组上限×3，至少 30）上限，防止用户在很多组之间来回操作时无界堆积。
public struct SlotUndoSnapshot: Codable {
    /// 抓快照时该组全部槽位的内容（key 为 1...slotCount）。
    public var slots: [Int: SlotContent]
    /// 抓快照时该组全部槽位标签。
    public var labels: [Int: String]
    /// 人类可读的操作描述，用于撤销后的浮层提示（如「清空槽位 3」）。
    public var title: String
    /// 快照所属槽位组 id。撤销只能回写到同一个组。
    public var groupId: String
    /// 抓取时间（Unix 秒），仅用于日志/排序观测。
    public var capturedAt: TimeInterval

    public init(slots: [Int: SlotContent],
                labels: [Int: String],
                title: String,
                groupId: String,
                capturedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.slots = slots
        self.labels = labels
        self.title = title
        self.groupId = groupId
        self.capturedAt = capturedAt
    }

    /// 内容身份签名（按 contentId + updatedAt，与 slotsSnapshotEqual 同源判据）。
    /// 用于 push 时去重：连续两次抓到完全相同的状态没有撤销价值，只会白占一步额度。
    public var identitySignature: String {
        let slotPart = slots.keys.sorted().map { key -> String in
            guard let c = slots[key] else { return "\(key):-" }
            return "\(key):\(c.contentId):\(c.updatedAt)"
        }.joined(separator: "|")
        let labelPart = labels.keys.sorted().map { "\($0)=\(labels[$0] ?? "")" }.joined(separator: ",")
        return "\(groupId)#\(slotPart)#\(labelPart)"
    }
}

public struct SlotUndoStack: Codable {
    /// 单个槽位组默认保留的撤销步数。
    public static let defaultLimitPerGroup = 10
    /// 设置面板允许的步数范围（UNDO-3 v2.10.97：可配置 1~100 步）。
    public static let minLimitPerGroup = 1
    public static let maxLimitPerGroup = 100

    /// 把任意输入夹到合法步数区间。
    public static func clampLimit(_ value: Int) -> Int {
        max(minLimitPerGroup, min(maxLimitPerGroup, value))
    }

    /// UNDO-3 (v2.10.97): 每组保留步数改为**实例可配置**（设置面板「高级 → 操作历史 → 撤销步数」）。
    /// 语义：改小之后不仅新操作按新上限截断，已有超出部分也立即截断（用户明确要求）。
    public private(set) var limitPerGroup: Int = SlotUndoStack.defaultLimitPerGroup

    /// 所有组合计的硬上限，防止跨组来回操作时无界堆积。随每组上限等比放大（至少 30）。
    public var globalLimit: Int { max(30, limitPerGroup * 3) }

    /// 由旧到新（末尾为最近一次操作前的状态）。
    public private(set) var entries: [SlotUndoSnapshot] = []

    public init(entries: [SlotUndoSnapshot] = [],
                limitPerGroup: Int = SlotUndoStack.defaultLimitPerGroup) {
        self.entries = entries
        self.limitPerGroup = Self.clampLimit(limitPerGroup)
        trim()
    }

    private enum CodingKeys: String, CodingKey {
        case entries, limitPerGroup
    }

    /// 自定义解码：≤v2.10.96 落盘的 JSON 没有 `limitPerGroup` 字段，缺失时回落默认 10，
    /// 避免老用户升级后撤销栈整份解码失败（等于历史被静默清空）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try c.decodeIfPresent([SlotUndoSnapshot].self, forKey: .entries) ?? []
        let decodedLimit = try c.decodeIfPresent(Int.self, forKey: .limitPerGroup)
            ?? SlotUndoStack.defaultLimitPerGroup
        self.init(entries: decodedEntries, limitPerGroup: decodedLimit)
    }

    /// 应用新的每组步数上限。改小会**立即截断**已有历史（返回被丢弃的条目数）。
    @discardableResult
    public mutating func applyLimit(_ newLimit: Int) -> Int {
        let clamped = Self.clampLimit(newLimit)
        guard clamped != limitPerGroup else { return 0 }
        let before = entries.count
        limitPerGroup = clamped
        trim()
        return before - entries.count
    }

    /// 压入一步。返回 false 表示被去重丢弃（与该组最新快照状态完全一致）。
    @discardableResult
    public mutating func push(_ snapshot: SlotUndoSnapshot) -> Bool {
        if let latest = entries.last(where: { $0.groupId == snapshot.groupId }),
           latest.identitySignature == snapshot.identitySignature {
            return false
        }
        entries.append(snapshot)
        trim()
        return true
    }

    /// 弹出指定组的最新一步。其它组的历史不受影响。
    public mutating func popLatest(forGroup groupId: String) -> SlotUndoSnapshot? {
        guard let idx = entries.lastIndex(where: { $0.groupId == groupId }) else { return nil }
        return entries.remove(at: idx)
    }

    public func canUndo(forGroup groupId: String) -> Bool {
        entries.contains { $0.groupId == groupId }
    }

    /// 清空某个组的全部历史。
    /// UNDO-2 (v2.10.96): 用于「新操作让重做链失效」——撤销后又做了新改动，原先的重做分支
    /// 已不再是同一条时间线，必须丢弃（与所有编辑器的 undo/redo 语义一致）。
    public mutating func removeAll(forGroup groupId: String) {
        entries.removeAll { $0.groupId == groupId }
    }

    public func count(forGroup groupId: String) -> Int {
        entries.reduce(0) { $0 + ($1.groupId == groupId ? 1 : 0) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 保留每组最近 `limitPerGroup` 步，并把总量收敛到 `globalLimit`（丢最旧）。
    private mutating func trim() {
        // 1) 逐组裁剪：从新到旧计数，超过每组上限的旧条目丢弃。
        var seen: [String: Int] = [:]
        var keep = Array(repeating: false, count: entries.count)
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            let gid = entries[i].groupId
            let n = (seen[gid] ?? 0) + 1
            seen[gid] = n
            keep[i] = n <= limitPerGroup
        }
        var trimmed: [SlotUndoSnapshot] = []
        trimmed.reserveCapacity(entries.count)
        for (i, e) in entries.enumerated() where keep[i] { trimmed.append(e) }
        // 2) 全局裁剪：只留最新的 globalLimit 条。
        if trimmed.count > globalLimit {
            trimmed.removeFirst(trimmed.count - globalLimit)
        }
        entries = trimmed
    }
}
