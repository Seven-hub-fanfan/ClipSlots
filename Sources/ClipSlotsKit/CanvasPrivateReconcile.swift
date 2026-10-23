import Foundation

/// 画布私有内容与画布节点之间的**对账规则**（v2.14.0，取代 v2.13.0 的 `CanvasPrivateSlotSweep`）。
///
/// ## 要维持的不变量
///
/// > 画布私有库里**可见**的内容，恰好等于当前画布上节点引用到的那些。
///
/// 多出来的（删了节点留下的）立刻搬进撤销暂存区，少了的（撤销把节点带回来了）从暂存区搬回来。
///
/// ## 为什么不是 v2.13.0 那套"清扫 + 撤销栈豁免"
///
/// v2.13.0 的规则是「当前节点引用的 ∪ 撤销栈能恢复的都留着，其余清掉」。逻辑自洽，但用户看到的是：
/// 删了 24 个节点，侧栏里 24 条内容一条都没少 —— 因为它们全都还被撤销栈引用着。用户的原话是
/// 「暂存区还是不会同步删除」。**撤销安全**和**删了就该消失**在那套设计里是对立的。
///
/// 这一版把对立解开：内容不是"留在原地等撤销"，而是**搬进一个不可见的暂存区**
/// （`SpecialSlotStorage.stashSlotForCanvasUndo`）。
///
///   - 对用户：槽位目录当场不在了，列表立刻少一条，符合"删除就消失"。
///   - 对撤销：目录原样躺在暂存区，Cmd+Z 整块搬回来，字节级无损（附件外置文件、Label、
///     手动缩略图都在那棵子树里）。
///
/// ## 安全边界
///
/// - `documentLoadFailed` 为真时**什么都不做**。画布文档解码失败时 `CanvasStorage` 返回 `.empty`
///   （画布是派生资产，损坏即重来），那时"节点引用到的槽位"是空集，照规则会把整个项目的内容一次
///   全搬走。这是本设计唯一的灾难性失败模式，必须在入口堵死。
/// - 只处理**画布私有组**（`SpecialSlotStorage.isReservedGroupId`）。从槽位库拖上画布的节点，
///   内容属于用户的正式槽位，画布无权处置。
/// - 只处理**当前项目自己的**私有组。别的项目的节点不在本次 `referencedByNodes` 里，跨组对账
///   等于把别人的画布清了。
/// - 搬移而非删除：暂存区在磁盘上，进程崩了也不丢；下次启动整体进 `.trash`（30 天可恢复）。
public enum CanvasPrivateReconcile {

    /// 一次对账的输入。
    public struct Input {
        /// 本项目的私有组 id。
        public var privateGroupId: String
        /// 该组磁盘上当前**有内容**的槽位号。
        public var occupiedSlots: Set<Int>
        /// 该组当前躺在撤销暂存区里的槽位号。
        public var stashedSlots: Set<Int>
        /// 当前画布上的节点引用到的槽位号（只算落在 `privateGroupId` 里的）。
        public var referencedByNodes: Set<Int>
        /// 画布文档这次加载是否失败过（损坏 / 读不出来）。
        public var documentLoadFailed: Bool

        public init(privateGroupId: String,
                    occupiedSlots: Set<Int>,
                    stashedSlots: Set<Int>,
                    referencedByNodes: Set<Int>,
                    documentLoadFailed: Bool) {
            self.privateGroupId = privateGroupId
            self.occupiedSlots = occupiedSlots
            self.stashedSlots = stashedSlots
            self.referencedByNodes = referencedByNodes
            self.documentLoadFailed = documentLoadFailed
        }
    }

    /// 对账结果。两个数组都是升序（顺序确定，便于日志与断言）。
    public struct Plan: Equatable {
        /// 有内容但没有节点引用 → 搬进撤销暂存区。
        public let toStash: [Int]
        /// 有节点引用、内容却在暂存区里 → 搬回槽位。
        public let toRestore: [Int]

        public var isEmpty: Bool { toStash.isEmpty && toRestore.isEmpty }

        public init(toStash: [Int], toRestore: [Int]) {
            self.toStash = toStash
            self.toRestore = toRestore
        }
    }

    public static func plan(_ input: Input) -> Plan {
        // 安全闸 1：文档加载失败 → 一个都不动。理由见类型注释。
        guard !input.documentLoadFailed else { return Plan(toStash: [], toRestore: []) }
        // 安全闸 2：不是画布私有组 → 一个都不动。正式槽位的内容不属于画布。
        guard SpecialSlotStorage.isReservedGroupId(input.privateGroupId) else {
            return Plan(toStash: [], toRestore: [])
        }

        let toStash = input.occupiedSlots.subtracting(input.referencedByNodes).sorted()
        // 已经有内容的槽位不恢复：那说明这个槽位号在删除之后被新内容用上了，搬回去会覆盖。
        let toRestore = input.referencedByNodes
            .intersection(input.stashedSlots)
            .subtracting(input.occupiedSlots)
            .sorted()
        return Plan(toStash: toStash, toRestore: toRestore)
    }

    /// 从节点列表里取出落在 `groupId` 的槽位号。
    ///
    /// 节点的 `groupId` 可能指向正式槽位（从槽位库拖上来的），那些不在本组，天然被排除。
    public static func slots(of nodes: [CanvasNode], in groupId: String) -> Set<Int> {
        var out = Set<Int>()
        for n in nodes where n.groupId == groupId { out.insert(n.slot) }
        return out
    }
}
