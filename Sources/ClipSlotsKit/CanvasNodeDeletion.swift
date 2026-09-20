import Foundation

/// 删除画布节点前的**影响面**计算（v2.11.8 三轮 hotfix2）。
///
/// ## 为什么需要它
///
/// 用户第三段录屏（20260916103044）里删卡片时撞了一次"删不掉/提示看不懂"，明确要求改成一次
/// 可继续的确认：「弹出 Alert：该内容已作为入参被其他节点引用，删除将断开连接，是否继续？允许用户
/// 选择强制删除或取消」。
///
/// 关键点是**只在真的有引用时才拦**。无脑对每次删除弹确认是最省事的写法，也是最招人烦的写法 ——
/// 画布上删一个刚建错的空节点是高频动作，每次都要点一下"继续"会让删除变成两步操作。
///
/// ## 引用是什么
///
/// `CanvasNode.parentNodeId` 是单向血缘（见那边的注释）：子节点记着"我是从谁身上长出来的"。
/// 所以"被别人当入参用"等价于"存在别的节点的 `parentNodeId` 指向我"。这里刻意**不把"同一批一起
/// 被删掉的子节点"算作引用** —— 父子一起选中一起删时，删完不会留下任何断链，弹确认纯属噪声。
///
/// ## 为什么放 Kit
///
/// 这是典型的"错了也不报错"的逻辑：漏判 → 静默断链（用户事后才发现连接没了）；误判 → 天天多点一次
/// 确认。两种翻车都不会 crash、都很难在手测里稳定复现，只有断言能盯住。
public enum CanvasNodeDeletion {

    /// 删除 `ids` 这批节点会**断掉哪些引用**。
    ///
    /// - Returns: `(引用者 id 集合, 被引用的节点 id 集合)`。前者用来决定弹不弹、后者用来写文案。
    ///   两个都为空 = 可以直接删。
    public static func brokenLinks(deleting ids: Set<String>,
                                   nodes: [CanvasNode]) -> (referrers: Set<String>, referenced: Set<String>) {
        brokenLinks(deleting: ids, nodes: nodes, edges: [])
    }

    /// 同上，但把 v2.12.0 的**连线**一起算进来。
    ///
    /// 两个来源取并集而不是二选一：连线是新的真相，但 `parentNodeId` 仍然可能存在没有对应边的情况
    /// （用户手动删掉了那条线，血缘字段还留着 —— 那时它已经不是"入参引用"了）。所以判定标准统一成
    /// **"删掉它会让别的节点少一个输入"**：
    ///   - 存在 `edge.from ∈ ids` 且 `edge.to ∉ ids` → `to` 会少一个输入；
    ///   - 存在 `node.parentNodeId ∈ ids` 且该节点不在删除批次里 → 同上（老数据兜底）。
    ///
    /// 反方向（`edge.to ∈ ids`）**不算**：下游被删只是上游少了个消费者，上游自己的内容一点没变，
    /// 为此弹确认纯属噪声（这条规矩从初版就立着：无脑确认是最招人烦的写法）。
    public static func brokenLinks(deleting ids: Set<String>,
                                   nodes: [CanvasNode],
                                   edges: [CanvasEdge]) -> (referrers: Set<String>, referenced: Set<String>) {
        guard !ids.isEmpty else { return ([], []) }
        var referrers: Set<String> = []
        var referenced: Set<String> = []
        for node in nodes {
            // 引用者自己也在这批里 → 一起消失，不算断链。
            guard !ids.contains(node.id) else { continue }
            guard let parent = node.parentNodeId, ids.contains(parent) else { continue }
            referrers.insert(node.id)
            referenced.insert(parent)
        }
        for edge in edges {
            guard ids.contains(edge.fromNodeId), !ids.contains(edge.toNodeId) else { continue }
            referrers.insert(edge.toNodeId)
            referenced.insert(edge.fromNodeId)
        }
        return (referrers, referenced)
    }

    /// 删除前是否需要弹确认。
    public static func needsConfirm(deleting ids: Set<String>,
                                   nodes: [CanvasNode],
                                   edges: [CanvasEdge] = []) -> Bool {
        !brokenLinks(deleting: ids, nodes: nodes, edges: edges).referrers.isEmpty
    }

    /// Alert 正文。文案主体按用户给的原话，只在末尾补上"几个"这种量化信息 ——
    /// 「有 2 个节点正把它当入参」和「有 47 个」是完全不同的决定，不给数字等于让用户盲选。
    public static func confirmMessage(referrerCount: Int) -> String {
        let base = "该内容已作为入参被其他节点引用，删除将断开连接，是否继续？"
        guard referrerCount > 1 else { return base }
        return base + "（共 \(referrerCount) 个下游节点会失去这条连接）"
    }

    public static let confirmTitle = "删除后会断开连接"
    public static let confirmPrimary = "仍然删除"
    public static let confirmCancel = "取消"
}
