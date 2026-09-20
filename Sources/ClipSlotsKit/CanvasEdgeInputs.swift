import Foundation

/// 把连线解析成**生成入参**（v2.12.0）。
///
/// 这是"节点之间真的有数据流动"这件事的落点：v2.11.x 的生成只读本节点槽位，上游产物不参与，
/// 所以画布上的关系是装饰性的。这里负责回答一个问题 —— **要跑这个节点，从上游拿到了什么**。
///
/// ## 为什么在 Kit 而不是在编排层
///
/// 角色消歧（显式角色优先、自动角色补位、多余的降级成参考图）是一组纯规则，错了不会崩：
/// 首帧被悄悄当成参考图，用户只会觉得"这个模型不听话"。这种错误必须靠断言盯，不能靠手测。
public enum CanvasEdgeInputs {

    // MARK: - 上游快照

    /// 一个上游节点在解析时刻的样子。
    ///
    /// 刻意做成扁平的值类型而不是直接传 `CanvasNode`：解析需要的"正文"与"产物路径"一个来自槽位、
    /// 一个来自节点状态，凑齐这两样本来就是编排层的活。Kit 只认这份快照，就不必认识槽位存储。
    public struct Upstream: Equatable {
        public var nodeId: String
        public var kind: CanvasNodeKind
        /// 该节点绑定槽位的正文（文本节点的内容 / 出图节点自己的提示词）。
        public var text: String
        /// 已成功产出的资产本地路径。nil = 还没出图。
        public var assetPath: String?

        public init(nodeId: String, kind: CanvasNodeKind, text: String, assetPath: String?) {
            self.nodeId = nodeId
            self.kind = kind
            self.text = text
            self.assetPath = assetPath
        }
    }

    // MARK: - 解析结果

    public struct Resolved: Equatable {
        /// 空结果（没有入边时用）。`Resolved` 的成员全有默认值，但结构体的隐式 memberwise init
        /// 是 internal，跨模块（App target）拿不到 —— 必须显式给一个。
        public init() {}

        /// 要拼进提示词的上游文本，按连线顺序。
        public var promptFragments: [String] = []
        public var firstFramePath: String?
        public var lastFramePath: String?
        public var referencePaths: [String] = []
        /// 有几条上游"本该给图但还没出图"。
        ///
        /// 单独记一个数是为了让编排层能把失败原因写准：用户连了三条线却报"提示词为空"，
        /// 他会以为是提示词的问题，而真正的原因是上游还没跑。
        public var pendingUpstreamCount: Int = 0

        public var assetPaths: [String] {
            var out: [String] = []
            if let f = firstFramePath { out.append(f) }
            if let l = lastFramePath { out.append(l) }
            out.append(contentsOf: referencePaths)
            return out
        }

        public var isEmpty: Bool {
            promptFragments.isEmpty && firstFramePath == nil
                && lastFramePath == nil && referencePaths.isEmpty
        }
    }

    // MARK: - 解析

    /// 把入边解析成入参。
    ///
    /// ## 两轮扫描，显式角色先落座
    ///
    /// 只扫一轮的话，一条 `.auto` 的图边会先抢到首帧位，后面那条用户**明确设成首帧**的边只能
    /// 降级成参考图 —— 即"我明明设了首帧，它却没当首帧用"。所以先让显式角色全部落座，
    /// 再让自动角色去补空位。
    ///
    /// ## 角色与上游类型不匹配时不报错，而是按语义归位
    ///
    /// 文本上游拿不出图，图上游拿不出文字。用户完全可能把一条线的角色改成"尾帧"之后又把上游
    /// 换成了文本节点。这时报错（或静默丢弃）都不好：前者把一次创作打断，后者让人找不着东西。
    /// 规则是「**按上游真正拿得出的东西归位**」：文本上游一律进提示词，图上游一律进图位。
    public static func resolve(incoming: [CanvasEdge],
                              upstreams: [String: Upstream],
                              downstreamKind: CanvasNodeKind) -> Resolved {
        var out = Resolved()
        // 带上序号，最后按序号还原"连线顺序"——两轮扫描会打乱 append 的先后。
        var fragments: [(Int, String)] = []
        var references: [(Int, String)] = []
        var first: (Int, String)?
        var last: (Int, String)?
        var pending = 0

        let isVideo = downstreamKind == .video

        func placeAsset(_ index: Int, _ path: String, role: CanvasEdgeRole) {
            switch role {
            case .firstFrame where isVideo:
                if first == nil { first = (index, path) } else { references.append((index, path)) }
            case .lastFrame where isVideo:
                if last == nil { last = (index, path) } else { references.append((index, path)) }
            default:
                references.append((index, path))
            }
        }

        // 第一轮：显式角色。
        for (index, edge) in incoming.enumerated() {
            guard edge.role != .auto, let up = upstreams[edge.fromNodeId] else { continue }
            if edge.role == .prompt {
                let text = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { fragments.append((index, text)) }
                continue
            }
            guard let path = up.assetPath, !path.isEmpty else {
                // 明确要图但上游没图：文本上游退回提示词（至少把内容传下去），出图上游记一笔待产。
                if up.kind == .text {
                    let text = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { fragments.append((index, text)) }
                } else {
                    pending += 1
                }
                continue
            }
            placeAsset(index, path, role: edge.role)
        }

        // 第二轮：自动角色补位。
        for (index, edge) in incoming.enumerated() {
            guard edge.role == .auto, let up = upstreams[edge.fromNodeId] else { continue }
            if up.kind == .text {
                let text = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { fragments.append((index, text)) }
                continue
            }
            guard let path = up.assetPath, !path.isEmpty else {
                pending += 1
                continue
            }
            // 视频下游的第一张自动图当首帧（"把这张图动起来"是最常见的意图）；
            // 图像下游没有首帧概念，一律参考图。
            let resolvedRole: CanvasEdgeRole = (isVideo && first == nil) ? .firstFrame : .reference
            placeAsset(index, path, role: resolvedRole)
        }

        out.promptFragments = fragments.sorted { $0.0 < $1.0 }.map(\.1)
        out.firstFramePath = first?.1
        out.lastFramePath = last?.1
        out.referencePaths = references.sorted { $0.0 < $1.0 }.map(\.1)
        out.pendingUpstreamCount = pending
        return out
    }

    // MARK: - 提示词合并

    /// 上游文本 + 本节点正文 → 最终提示词。
    ///
    /// **上游在前、本节点在后**：上游文本节点通常承载"风格 / 世界设定"这类共享前缀（一个文本节点
    /// 连给五个出图节点是典型用法），本节点正文才是这一张的具体要求。人写提示词也是先铺设定再提要求。
    ///
    /// 空段一律剔除，段间空一行 —— 用换行而不是逗号连接是因为多模型实测对段落结构比对标点敏感。
    public static func mergedPrompt(own: String, upstream: [String]) -> String {
        var parts: [String] = []
        for fragment in upstream {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        let mine = own.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { parts.append(mine) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 图位分配（视频）

    /// 视频节点的首帧 / 尾帧 / 参考图最终取哪几张。
    ///
    /// 与 `CrateModelCatalog.assignVideoFrames`（纯按槽位附件顺序分配）的关系是**连线优先、
    /// 槽位补位**：连线是用户明确表达的意图，槽位附件是"这个槽位里正好有的图"。
    ///
    /// 不复用 `assignVideoFrames` 是因为它按**位置**分配（第 1 张=首帧、第 2 张=尾帧）。如果把
    /// 连线给的图拼成数组喂进去，一条只设了"尾帧"的连线会被当成首帧 —— 而这正是用户唯一明确
    /// 指定过的那个位置。
    public static func videoFrames(edgeInputs: Resolved,
                                   slotImages: [String],
                                   model: CrateModelCatalog.ModelInfo?) -> (first: String?, last: String?, references: [String]) {
        // 目录没加载出来时按"接受图输入"处理：拒掉用户挂的图比多传一张更糟（多传最坏是服务端报错，
        // 少传是静默不生效）。
        if let model, !model.acceptsVideoImageInput { return (nil, nil, []) }

        var used = Set<String>()
        func take(_ path: String?) -> String? {
            guard let path, !path.isEmpty, used.insert(path).inserted else { return nil }
            return path
        }

        let first = take(edgeInputs.firstFramePath)
        let explicitLast = take(edgeInputs.lastFramePath)
        var pool = slotImages.filter { !used.contains($0) }

        var resolvedFirst = first
        if resolvedFirst == nil, !pool.isEmpty {
            resolvedFirst = take(pool.removeFirst())
        }
        var resolvedLast = explicitLast
        let supportsLast = model?.supportsLastFrame ?? true
        if resolvedLast == nil, supportsLast, !pool.isEmpty {
            resolvedLast = take(pool.removeFirst())
        }
        if !supportsLast { resolvedLast = nil }

        // 互斥模型：有首/尾帧就不能再带参考图（见 `framesExcludeReferences`）。
        if model?.framesExcludeReferences == true {
            return (resolvedFirst, resolvedLast, [])
        }
        var refs: [String] = []
        for path in edgeInputs.referencePaths where used.insert(path).inserted { refs.append(path) }
        for path in pool where used.insert(path).inserted { refs.append(path) }
        if let cap = model?.referenceImageMaxCount {
            refs = cap > 0 ? Array(refs.prefix(cap)) : []
        }
        return (resolvedFirst, resolvedLast, refs)
    }

    /// 图像节点的参考图最终取哪几张：连线在前、槽位附件在后，去重。
    ///
    /// 顺序有语义（多参考图模型按顺序理解权重），连线在前是因为它是显式意图。
    public static func imageReferences(edgeInputs: Resolved, slotImages: [String]) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for path in edgeInputs.assetPaths where !path.isEmpty && used.insert(path).inserted {
            out.append(path)
        }
        for path in slotImages where !path.isEmpty && used.insert(path).inserted {
            out.append(path)
        }
        return out
    }
}
