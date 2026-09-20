import Foundation

/// 画布连线（v2.12.0）。
///
/// ## 为什么要有这个类型（而不是继续用 `CanvasNode.parentNodeId`）
///
/// v2.11.x 的"血缘"是节点身上的一个 `parentNodeId?`：由「选中节点下方的 +」写入，只用来在删除时
/// 弹一次断链确认。它有三个结构性上限，恰好就是用户说画布"很蹩脚"的那三件事：
///
///   1. **单值**：一个节点只能有一个上游。而真实创作里"文本 prompt + 参考图 + 尾帧"是三条上游。
///   2. **不渲染**：屏幕上根本看不见关系，用户摆完就忘了谁喂谁。
///   3. **不参与生成**：上游产物不会成为下游入参 —— 节点之间没有数据流动，画布只是"一堆孤立
///      生成器的摆放工具"。
///
/// 所以 v2.12.0 把它升级成**独立的边集合**：多入多出、看得见、并且真的决定生成入参。
///
/// ## 兼容
///
/// 老文档只有 `parentNodeId`。解码时由 `CanvasEdgeGraph.migratedFromParentLinks` 把它补成一条
/// `.auto` 边（见那边的注释），`parentNodeId` 字段**保留不动**：一是降级回 v2.11.x 时血缘还在，
/// 二是它同时还是「下游 + 号是从谁身上长出来的」这一 UI 事实，与"用户手连的边"不完全同义。
///
/// ## 身份
///
/// `id` 是独立 UUID，不像节点那样从内容派生。理由：同一对 (from, to) 在语义上唯一（`canConnect`
/// 会拒重复），但**角色可以改**，而派生 id 会让"改角色"变成"换身份"，撤销栈与选中态都会当场失配
/// （节点身份派生已经吃过这个教训，见 `CanvasStore.rebindNode`）。

// MARK: - 连线角色

/// 上游产物在下游节点里**充当什么**。
///
/// 刻意做成"少而钝"的一组：每多一个角色，就多一条用户必须记住的规则，而模型侧真正区分待遇的
/// 只有首帧 / 尾帧 / 参考图这三类（见 `CrateModelCatalog` 对首尾帧与参考图互斥的处理）。
public enum CanvasEdgeRole: String, Codable, Equatable, CaseIterable {

    /// 自动。按「上游产出什么 + 下游是什么类型」当场决定，见 `CanvasEdgeInputs.resolve`。
    ///
    /// 这是新建连线的默认值，也是绝大多数连线该留的值：用户连线时想的是"把这个给它"，
    /// 而不是"把这个作为第 2 参考图给它"。强迫每条线都先选角色会把一次拖拽变成一次表单填写。
    case auto
    /// 上游文本拼进提示词。
    case prompt
    /// 视频首帧。
    case firstFrame
    /// 视频尾帧。
    case lastFrame
    /// 参考图（图像模型的 `--image`、视频模型的多模态参考）。
    case reference

    public var displayName: String {
        switch self {
        case .auto: return "自动"
        case .prompt: return "提示词"
        case .firstFrame: return "首帧"
        case .lastFrame: return "尾帧"
        case .reference: return "参考图"
        }
    }

    /// 连线上那枚小角标的文字。`.auto` 返回 nil = 不画角标。
    ///
    /// 自动态不画是刻意的：画布上多数线都是自动态，每条都挂一枚"自动"角标等于给每条线加一块
    /// 噪声，而这正是 v2.11.8 二轮从卡片上删掉「未生成」标签时立下的同一条规矩 ——
    /// **所有对象都一样的标签不携带信息**。
    public var badgeText: String? {
        self == .auto ? nil : displayName
    }

    public var symbolName: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .prompt: return "text.alignleft"
        case .firstFrame: return "square.stack.3d.down.forward"
        case .lastFrame: return "square.stack.3d.up.forward"
        case .reference: return "photo.on.rectangle"
        }
    }
}

// MARK: - 连线

public struct CanvasEdge: Codable, Identifiable, Equatable {

    public var id: String
    /// 上游节点 id（`groupId#slot`）。
    public var fromNodeId: String
    /// 下游节点 id。
    public var toNodeId: String
    public var role: CanvasEdgeRole
    /// 建立时间。**参与生成语义**：同一节点的多条入边按它排序，决定"第几张参考图"。
    ///
    /// 不靠数组下标是因为数组顺序会被撤销/重做、删除节点后的 prune、以及未来任何一次
    /// `edges.sort` 悄悄改掉 —— 那会表现为"我没动过，重跑一次首帧变了"。
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                fromNodeId: String,
                toNodeId: String,
                role: CanvasEdgeRole = .auto,
                createdAt: Date = Date()) {
        self.id = id
        self.fromNodeId = fromNodeId
        self.toNodeId = toNodeId
        self.role = role
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromNodeId, toNodeId, role, createdAt
    }

    /// 容错解码：缺 id / 缺角色 / 缺时间都不算坏数据（画布是派生资产，宁可补默认值也不要
    /// 让一条边把整份文档拖下水 —— `CanvasDocument.LenientNode` 同一条思路）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        fromNodeId = try c.decode(String.self, forKey: .fromNodeId)
        toNodeId = try c.decode(String.self, forKey: .toNodeId)
        role = (try? c.decode(CanvasEdgeRole.self, forKey: .role)) ?? .auto
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fromNodeId, forKey: .fromNodeId)
        try c.encode(toNodeId, forKey: .toNodeId)
        try c.encode(role, forKey: .role)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - 连线图算法

/// 连线集合上的纯函数（v2.12.0）。
///
/// 全部下沉到 Kit 是这个项目的既定惯例（见 `CanvasGeometry` / `RadialSegmentLayout` 的注释）：
/// 这里每一条都是"错了也不崩、但静默错"的逻辑 —— 环检测漏判 = 生成时无限递归取入参；
/// prune 漏判 = 画布上留一条指向已删节点的野线；去重漏判 = 同一张参考图被喂两遍。
/// 这类错误在手测里很难稳定复现，只有断言盯得住。
public enum CanvasEdgeGraph {

    // MARK: 连线合法性

    /// 为什么连不上。
    public enum Rejection: Equatable {
        /// 自己连自己。
        case selfLoop
        /// 这两个节点之间已经有一条同向的线了。
        case duplicate
        /// 会形成环。
        case cycle
        /// 端点不存在（节点刚被删 / id 过期）。
        case missingNode

        public var message: String {
            switch self {
            case .selfLoop: return "不能连到自己"
            case .duplicate: return "这两个节点已经连上了"
            case .cycle: return "不能连成环（那样取入参会绕回自己）"
            case .missingNode: return "节点不存在"
            }
        }
    }

    /// 能不能从 `from` 连到 `to`。返回 nil = 可以连。
    ///
    /// `nodeIds` 传空集合表示"不校验端点存在性"（纯算法测试用）。
    public static func canConnect(from: String,
                                 to: String,
                                 edges: [CanvasEdge],
                                 nodeIds: Set<String> = []) -> Rejection? {
        if from == to { return .selfLoop }
        if !nodeIds.isEmpty, !nodeIds.contains(from) || !nodeIds.contains(to) { return .missingNode }
        if edges.contains(where: { $0.fromNodeId == from && $0.toNodeId == to }) { return .duplicate }
        if wouldCreateCycle(from: from, to: to, edges: edges) { return .cycle }
        return nil
    }

    /// 加上 `from → to` 之后会不会有环。
    ///
    /// 等价问题：当前图里 `to` 能不能走到 `from`。用显式栈做 DFS 而不是递归 —— 递归在环已经
    /// 存在（历史脏数据）时会栈溢出崩掉 App，而 `visited` 集合让迭代版在任何输入下都能收敛。
    public static func wouldCreateCycle(from: String, to: String, edges: [CanvasEdge]) -> Bool {
        if from == to { return true }
        var adjacency: [String: [String]] = [:]
        for e in edges { adjacency[e.fromNodeId, default: []].append(e.toNodeId) }
        var stack = [to]
        var visited: Set<String> = [to]
        while let current = stack.popLast() {
            for next in adjacency[current] ?? [] {
                if next == from { return true }
                if visited.insert(next).inserted { stack.append(next) }
            }
        }
        return false
    }

    // MARK: 规整

    /// 丢掉自环、野线（端点不存在）与同向重复线。
    ///
    /// `nodeIds` 传空集合时跳过野线检查（用于只想去重的场合）。顺序保持输入顺序 —— 重复项
    /// **留第一条**，因为它才是用户先连的那条（角色也可能已经改过）。
    public static func normalized(_ edges: [CanvasEdge], nodeIds: Set<String>) -> [CanvasEdge] {
        var seen = Set<String>()
        var out: [CanvasEdge] = []
        out.reserveCapacity(edges.count)
        for e in edges {
            guard e.fromNodeId != e.toNodeId else { continue }
            if !nodeIds.isEmpty {
                guard nodeIds.contains(e.fromNodeId), nodeIds.contains(e.toNodeId) else { continue }
            }
            guard seen.insert("\(e.fromNodeId)->\(e.toNodeId)").inserted else { continue }
            out.append(e)
        }
        return breakingCycles(out)
    }

    /// 把历史脏数据里的环打断（保留先建立的边）。
    ///
    /// 正常路径上 `canConnect` 已经挡住了环，但**节点改绑**会把 id 整体重映射
    /// （`CanvasStore.rebindNode`），理论上能撞出环；而带环的图会让取入参的递归下不来。
    /// 这里按 `createdAt` 从旧到新逐条重放，遇到成环就丢 —— 丢的一定是较新的那条，
    /// 符合"先连的先算"的直觉。
    private static func breakingCycles(_ edges: [CanvasEdge]) -> [CanvasEdge] {
        let ordered = edges.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
        var kept: [CanvasEdge] = []
        var dropped = Set<String>()
        for e in ordered {
            if wouldCreateCycle(from: e.fromNodeId, to: e.toNodeId, edges: kept) {
                dropped.insert(e.id)
            } else {
                kept.append(e)
            }
        }
        guard !dropped.isEmpty else { return edges }
        // 回到输入顺序返回：调用方（撤销栈 / 落盘）对顺序稳定性有依赖。
        return edges.filter { !dropped.contains($0.id) }
    }

    /// 从老文档的 `parentNodeId` 补齐连线。
    ///
    /// 只在"这条血缘还没有对应的边"时补，所以对已经迁移过的文档是幂等的 —— 新版本会**同时**
    /// 写 `parentNodeId` 与边（见 `CanvasStore.placeSlot`），若不判重，每次打开画布都会多一条。
    ///
    /// 补出来的边给 `.auto`：老数据里没有任何角色信息，替用户猜一个具体角色会让"我从没设过尾帧"
    /// 变成事实上的尾帧。`createdAt` 取节点自己的创建时间，这样多条迁移边之间的先后关系
    /// 与用户当初建节点的顺序一致。
    public static func migratedFromParentLinks(nodes: [CanvasNode], edges: [CanvasEdge]) -> [CanvasEdge] {
        let ids = Set(nodes.map(\.id))
        var existing = Set(edges.map { "\($0.fromNodeId)->\($0.toNodeId)" })
        var out = edges
        for node in nodes {
            guard let parent = node.parentNodeId, parent != node.id, ids.contains(parent) else { continue }
            let key = "\(parent)->\(node.id)"
            guard existing.insert(key).inserted else { continue }
            out.append(CanvasEdge(fromNodeId: parent,
                                  toNodeId: node.id,
                                  role: .auto,
                                  createdAt: node.createdAt))
        }
        return normalized(out, nodeIds: ids)
    }

    // MARK: 查询

    /// 指向 `nodeId` 的入边，**按生成语义排序**（`createdAt` 升序，同刻按 id 定序）。
    public static func incoming(of nodeId: String, edges: [CanvasEdge]) -> [CanvasEdge] {
        edges.filter { $0.toNodeId == nodeId }.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
    }

    /// 从 `nodeId` 出发的出边，同样定序。
    public static func outgoing(of nodeId: String, edges: [CanvasEdge]) -> [CanvasEdge] {
        edges.filter { $0.fromNodeId == nodeId }.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
    }

    // MARK: 增删

    /// 删掉一批节点后剩下的边。
    public static func removing(nodeIds ids: Set<String>, from edges: [CanvasEdge]) -> [CanvasEdge] {
        guard !ids.isEmpty else { return edges }
        return edges.filter { !ids.contains($0.fromNodeId) && !ids.contains($0.toNodeId) }
    }

    /// 节点改绑（id 变了）后把边上的端点一起改掉。
    ///
    /// 不做这一步的症状是"把节点拖进槽位库归档后，它的连线全断了"，而断链事后无法还原
    /// （`CanvasStore.rebindNode` 的注释里列的正是这个坑，那时只需要管一个 `parentNodeId`）。
    /// 改完可能撞出重复边（`A→B` 与 `A→B'`，而 B' 改绑成了 B），交给 `normalized` 收。
    public static func remapping(nodeId old: String, to new: String, edges: [CanvasEdge]) -> [CanvasEdge] {
        guard old != new else { return edges }
        let mapped = edges.map { e -> CanvasEdge in
            var copy = e
            if copy.fromNodeId == old { copy.fromNodeId = new }
            if copy.toNodeId == old { copy.toNodeId = new }
            return copy
        }
        return normalized(mapped, nodeIds: [])
    }
}
