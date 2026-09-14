import Foundation

/// 画布的撤销/重做栈 + 操作历史（v2.11.7 hotfix18）。
///
/// ## 为什么是「全量快照」而不是「反向补丁」
///
/// 画布节点是**几十个量级**的小数组（一个节点约 300B），整份 `[CanvasNode]` 快照的成本可以忽略；
/// 而反向补丁（记录"把 A 从 x1 移到 x2"再反着做一遍）需要为每一种操作单独写一份逆运算，
/// 多选批量移动、扇出、批量删除各有各的逆运算，任何一个写错都是**静默的数据错乱**
/// （撤销后画布悄悄少一个节点，用户根本不会去核对）。50 步 × 几十个节点 = 几百 KB，
/// 拿这点内存换"逆运算不可能写错"，是这个规模下唯一理性的选择。
///
/// ## 为什么条目里还挂了 `slotEdit`
///
/// 绑定了槽位的节点，它显示的文本**就是槽位数据本身**（画布与编辑页双向同步）。所以"在画布里
/// 改了节点文本"这一步，撤销时不能只还原节点数组 —— 还得把槽位主体文本写回去，否则编辑页那边
/// 的改动就撤不掉了，两边会当场对不上。`slotEdit` 就是这一步要回滚/重放的槽位文本。
///
/// ## 光标模型
///
/// 用「一个数组 + 一个游标」而不是「undo 栈 + redo 栈」：面板要**同时**列出已生效和已撤销的条目
/// （已撤销的置灰），双栈结构还得把两个栈拼起来再排序，游标模型直接一次遍历就够。
///   - `entries` 从旧到新。
///   - `cursor` = 已生效的条目数。`entries[0..<cursor]` 已生效，`entries[cursor...]` 已被撤销。
///   - 新操作入栈时**截断** `entries[cursor...]`（撤销后又做新操作，被撤销的分支不再可重做，
///     这是所有编辑器的通行语义）。
public struct CanvasHistoryEntry: Identifiable, Equatable {

    public enum Kind: String, Codable, Equatable {
        case addNode
        case moveNode
        case removeNode
        case fanOut
        case clear
        /// 在画布里改了节点文本（绑定槽位的节点 = 同时改了槽位数据）。
        case editNode
        /// Cmd+数字 / 圆盘把某个槽位的内容送进了节点。
        case bindSlot

        /// 面板里显示的动作名。
        public var title: String {
            switch self {
            case .addNode: return "新建节点"
            case .moveNode: return "移动节点"
            case .removeNode: return "删除节点"
            case .fanOut: return "展开节点"
            case .clear: return "清空画布"
            case .editNode: return "编辑内容"
            case .bindSlot: return "填入槽位"
            }
        }

        public var symbolName: String {
            switch self {
            case .addNode: return "plus.square.on.square"
            case .moveNode: return "arrow.up.and.down.and.arrow.left.and.right"
            case .removeNode: return "trash"
            case .fanOut: return "square.grid.2x2"
            case .clear: return "xmark.bin"
            case .editNode: return "pencil"
            case .bindSlot: return "tray.and.arrow.down"
            }
        }
    }

    /// 需要一并回滚的槽位主体文本改动（仅"绑定槽位的节点被编辑"这一种操作会带）。
    public struct SlotTextEdit: Equatable {
        public let groupId: String
        public let slot: Int
        public let before: String
        public let after: String

        public init(groupId: String, slot: Int, before: String, after: String) {
            self.groupId = groupId
            self.slot = slot
            self.before = before
            self.after = after
        }
    }

    public let id: String
    public let kind: Kind
    /// 副标题：节点标题 / 数量等上下文。允许为空串（表示无补充信息）。
    public let detail: String
    public let at: Date
    /// 操作前后的完整节点快照。
    public let before: [CanvasNode]
    public let after: [CanvasNode]
    public let slotEdit: SlotTextEdit?

    public init(id: String = UUID().uuidString,
                kind: Kind,
                detail: String = "",
                at: Date = Date(),
                before: [CanvasNode] = [],
                after: [CanvasNode] = [],
                slotEdit: SlotTextEdit? = nil) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.at = at
        self.before = before
        self.after = after
        self.slotEdit = slotEdit
    }

    /// 相对时间戳文案。
    ///
    /// 60s 内说「刚刚」，1 小时内给分钟，再往前直接给钟点 —— 画布历史是**同一次工作会话**里的
    /// 流水，写「2 小时前」不如写「14:05」好定位。
    public func stamp(now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(at)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let comps = calendar.dateComponents([.hour, .minute], from: at)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }
}

/// 定长撤销栈（见 `CanvasHistoryEntry` 的类型注释）。
public struct CanvasUndoStack: Equatable {

    /// 上限 50 步。再往上加的边际收益很低（没人会连撤 50 次），而每一步都攥着两份全量节点快照。
    public static let capacity = 50

    /// 从旧到新。
    public private(set) var entries: [CanvasHistoryEntry] = []
    /// 已生效条目数。`entries[0..<cursor]` 已生效。
    public private(set) var cursor: Int = 0

    public init() {}

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// 面板用的展示顺序：**新的在前**。
    ///
    /// - `applied == false` 的是已被撤销、可重做的条目。
    /// - `cursorAfter` 是「把状态推到这一条刚做完」所需的 cursor 值，面板点条目跳转时直接用它。
    ///   刻意在这里算好而不是让面板自己 `index + 1`：cursor 的语义（已生效条目数，而非下标）
    ///   只在这个类型里成立，泄漏到 UI 层就等于把这条不变量交给每个调用方各自记一遍。
    public var display: [(entry: CanvasHistoryEntry, applied: Bool, cursorAfter: Int)] {
        entries.enumerated().reversed().map { (index, entry) in
            (entry, index < cursor, index + 1)
        }
    }

    /// 下一次 undo 会撤掉的条目（面板上给 Cmd+Z 的提示用）。
    public var undoTarget: CanvasHistoryEntry? {
        guard canUndo else { return nil }
        return entries[cursor - 1]
    }

    /// 下一次 redo 会重做的条目。
    public var redoTarget: CanvasHistoryEntry? {
        guard canRedo else { return nil }
        return entries[cursor]
    }

    /// 记一步。会截断「已撤销分支」，并在超限时丢最旧的一步。
    public mutating func push(_ entry: CanvasHistoryEntry) {
        if cursor < entries.count {
            entries.removeSubrange(cursor...)
        }
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        cursor = entries.count
    }

    /// 撤销一步，返回被撤销的条目（调用方据此把 `before` 应用回画布）。
    public mutating func undo() -> CanvasHistoryEntry? {
        guard canUndo else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// 重做一步，返回被重做的条目（调用方据此把 `after` 应用回画布）。
    public mutating func redo() -> CanvasHistoryEntry? {
        guard canRedo else { return nil }
        let entry = entries[cursor]
        cursor += 1
        return entry
    }

    public mutating func removeAll() {
        entries.removeAll()
        cursor = 0
    }
}

/// 画布的键盘绑定（纯数据，便于 smoke 断言）。
public enum CanvasKeyBinding {

    /// macOS 虚拟键码：51 = Delete(Backspace)，117 = Fn+Delete(Forward Delete)。
    ///
    /// 两个都收：外接键盘上「Delete」是 117，Mac 内置键盘上「delete」是 51，用户嘴里的
    /// 「删除键」在两种硬件上是不同键码，只认一个必然有一半人按了没反应。
    public static let deleteKeyCodes: Set<UInt16> = [51, 117]

    /// `z` 的虚拟键码（Cmd+Z 撤销 / Cmd+Shift+Z 重做）。
    ///
    /// 用键码而不是 `event.charactersIgnoringModifiers`：后者在中文输入法激活时可能拿不到 "z"。
    public static let zKeyCode: UInt16 = 6

    public static func isDeleteKey(_ keyCode: UInt16) -> Bool {
        deleteKeyCodes.contains(keyCode)
    }

    /// 判定一次按键是撤销、重做，还是与画布无关。
    public enum Action: Equatable {
        case delete
        case undo
        case redo
        case none
    }

    /// 纯函数形式的快捷键判定（smoke 直接喂键码 + 修饰键组合断言）。
    ///
    /// - Parameters:
    ///   - keyCode: 虚拟键码。
    ///   - command: 是否按下 ⌘。
    ///   - shift: 是否按下 ⇧。
    ///   - option: 是否按下 ⌥（画布不用它，但传进来才能断言「⌥Z 不是撤销」）。
    public static func action(keyCode: UInt16,
                             command: Bool,
                             shift: Bool,
                             option: Bool = false) -> Action {
        if isDeleteKey(keyCode) {
            // 删除键刻意**不允许带 ⌘/⌥**：⌘⌫ 在 macOS 里是「移到废纸篓」的语义，
            // 用户按它时想的不是"删画布节点"。
            return (command || option) ? .none : .delete
        }
        if keyCode == zKeyCode, command, !option {
            return shift ? .redo : .undo
        }
        return .none
    }
}
