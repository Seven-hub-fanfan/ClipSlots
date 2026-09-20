import Foundation

/// 画布私有内容的**清扫规则**（v2.13.0）。
///
/// ## 要解决的问题
///
/// 用户原话：「未入库这一部分有问题，我的开始只是希望有一个存放不在槽位的节点，在画布中删除应该
/// 就消失了才可以」。
///
/// v2.12.x 的行为是：画布节点的内容存在保留组的槽位里，而 `CanvasStore.removeNodes` 只删节点、
/// **不碰槽位**。于是槽位库里堆了一地删过的节点残留（用户截图里 9 条）。
///
/// ## 为什么不是"删节点时顺手把槽位清掉"
///
/// 试过这个思路，它和撤销打架：画布的撤销栈能把刚删的节点恢复回来，但内容已经被清掉了 ——
/// 用户按 Cmd+Z 看到节点回来了、里面是空的，这比残留严重得多（残留只是脏，这是丢数据）。
///
/// 所以这里换成**声明式的不变量**，而不是在删除路径上做一次命令式清理：
///
/// > 私有组里只允许存在两种内容：① 当前画布上有节点引用的；② 撤销/重做栈还能恢复出来的。
///
/// 其余的就是垃圾，清掉。这条不变量对"删节点"、"改绑槽位"、"历史残留"、"上一个版本留下的脏数据"
/// 一视同仁，不需要为每条路径各写一遍清理逻辑。
///
/// ## 安全边界（这一段是整个文件最重要的部分）
///
/// 这个算法会**删用户内容**，所以它必须在任何可疑情况下选择什么都不做：
///
/// - `documentLoadFailed` 为真时直接返回空集合。画布文档解码失败时 `CanvasStorage` 会返回
///   `.empty`（画布是派生资产，损坏即重来）—— 那时"当前画布引用的槽位"是空集，清扫会把整个
///   项目的内容一次性抹掉。这是本设计唯一的灾难性失败模式，必须在入口就堵死。
/// - 只清**保留组**（`SpecialSlotStorage.isReservedGroupId`）。从槽位库拖上画布的节点，内容属于
///   用户的正式槽位，画布无权处置。
/// - 只清**当前项目自己的**私有组。别的项目的节点不在本次 `referenced` 里，跨组清扫等于删别人的画布。
/// - 实际删除走 `SpecialSlotStorage.clear`，它会把旧内容克隆进 `.trash`（30 天可恢复）。即使上面
///   三条全部失效，用户仍有一条捞回来的路。
public enum CanvasPrivateSlotSweep {

    /// 一次清扫的输入。
    public struct Input {
        /// 本项目的私有组 id。
        public var privateGroupId: String
        /// 该组磁盘上当前**有内容**的槽位号。
        public var occupiedSlots: Set<Int>
        /// 当前画布上的节点引用到的槽位号（只算落在 `privateGroupId` 里的）。
        public var referencedByNodes: Set<Int>
        /// 撤销/重做栈里的历史快照引用到的槽位号（同上，只算本组的）。
        ///
        /// 单独列出来而不是和上面合并，是为了让"为什么这条没被清掉"在日志里能分辨：
        /// 被节点引用 = 正在用；被历史引用 = 等着可能的 Cmd+Z。
        public var referencedByHistory: Set<Int>
        /// 画布文档这次加载是否失败过（损坏 / 读不出来）。
        public var documentLoadFailed: Bool

        public init(privateGroupId: String,
                    occupiedSlots: Set<Int>,
                    referencedByNodes: Set<Int>,
                    referencedByHistory: Set<Int>,
                    documentLoadFailed: Bool) {
            self.privateGroupId = privateGroupId
            self.occupiedSlots = occupiedSlots
            self.referencedByNodes = referencedByNodes
            self.referencedByHistory = referencedByHistory
            self.documentLoadFailed = documentLoadFailed
        }
    }

    /// 该清掉哪些槽位。返回升序数组（顺序确定，便于日志与断言）。
    public static func slotsToClear(_ input: Input) -> [Int] {
        // 安全闸 1：文档加载失败 → 一个都不动。理由见类型注释。
        guard !input.documentLoadFailed else { return [] }
        // 安全闸 2：不是保留组 → 一个都不动。正式槽位的内容不属于画布。
        guard SpecialSlotStorage.isReservedGroupId(input.privateGroupId) else { return [] }

        let protected = input.referencedByNodes.union(input.referencedByHistory)
        return input.occupiedSlots.subtracting(protected).sorted()
    }

    /// 从节点列表里取出落在 `groupId` 的槽位号。
    ///
    /// 节点的 `groupId` 可能指向正式槽位（从槽位库拖上来的），那些不在本组，天然被排除。
    public static func slots(of nodes: [CanvasNode], in groupId: String) -> Set<Int> {
        var out = Set<Int>()
        for n in nodes where n.groupId == groupId { out.insert(n.slot) }
        return out
    }

    /// 从撤销/重做栈的历史条目里取出落在 `groupId` 的槽位号。
    ///
    /// 两个方向都要看：`before` 是撤销能恢复出来的，`after` 是重做能恢复出来的。
    /// 少看一边就会出现"重做之后节点回来了但内容空了"。
    ///
    /// 还要看 `slotEdit`：绑定槽位的节点被编辑时，撤销要把**槽位文本**写回去（见
    /// `CanvasHistoryEntry.SlotTextEdit`）。那个槽位此刻可能已经不在任何快照的节点列表里了
    /// （比如"编辑 → 删节点"两步之后），但撤销两次仍然需要它活着。
    public static func slots(ofHistory entries: [CanvasHistoryEntry], in groupId: String) -> Set<Int> {
        var out = Set<Int>()
        for e in entries {
            for n in e.before where n.groupId == groupId { out.insert(n.slot) }
            for n in e.after where n.groupId == groupId { out.insert(n.slot) }
            if let edit = e.slotEdit, edit.groupId == groupId { out.insert(edit.slot) }
        }
        return out
    }
}
