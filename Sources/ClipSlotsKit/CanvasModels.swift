import Foundation
import CoreGraphics

/// 无限画布的数据模型（v2.11.7）。
///
/// 与 `SlotConnectionModels` 同构：全部 `Codable` + 带 `schemaVersion`，向后兼容靠「新字段可选
/// 或带默认值」而不是靠版本分支。画布数据是**派生资产**（可重新生成），因此损坏时的兜底是丢弃
/// 重建而非阻塞启动 —— 这一点与槽位数据（用户唯一资产，必须死保）截然不同。

// MARK: - 节点类型

public enum CanvasNodeKind: String, Codable, Equatable {
    /// 纯文本 / Prompt 节点（v2.11.8）。自身不出图，是"给下游用的一段文字"。
    case text
    /// 图像生成节点。
    case image
    /// 视频生成节点。
    case video
    /// 批量模版节点（自身不出图，是批量任务的母体）。
    case batchTemplate

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .image: return "图像生成"
        case .video: return "视频生成"
        case .batchTemplate: return "批量模版"
        }
    }

    /// 顶部类型标签用的 SF Symbol。
    public var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .video: return "film"
        case .batchTemplate: return "square.stack.3d.up"
        }
    }

    /// 该类型的节点是否会产出资产（决定卡片上"预览区"的语义：产物位 vs 内容位）。
    public var producesAsset: Bool {
        switch self {
        case .text: return false
        case .image, .video, .batchTemplate: return true
        }
    }
}

// MARK: - 节点状态

/// 节点生命周期。与 Crate CLI 的任务状态对应关系见架构文档 9.3。
///
/// 刻意不含「进度百分比」：CLI 不提供任何百分比，编一个假进度在 10~20s 量级会明显失真
/// （走到 90% 卡住）。生成中只表达「已开始 + 已用时长」。
public enum CanvasNodeState: Equatable {
    case idle
    /// 排队中。`ahead` 来自 `crate task get` 的 `queue_ahead_count`，是真字段。
    case queued(ahead: Int)
    /// 生成中。`startedAt` 用于展示已用秒数。
    case running(startedAt: Date)
    case succeeded(assetPath: String)
    case failed(reason: String)

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .idle, .queued, .running: return false
        }
    }
}

/// 状态的持久化表示。
///
/// 分开一层是刻意的：`running(startedAt:)` 这类**瞬态**状态重启后毫无意义（进程都换了，
/// 轮询早已中断），落盘时应折叠成 idle 或 failed，而不是让 App 重启后显示一个永远停在
/// 「生成中 3 小时」的僵尸节点。
extension CanvasNodeState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, assetPath, reason }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .succeeded(let path):
            try c.encode("succeeded", forKey: .kind)
            try c.encode(path, forKey: .assetPath)
        case .failed(let reason):
            try c.encode("failed", forKey: .kind)
            try c.encode(reason, forKey: .reason)
        case .idle, .queued, .running:
            // 瞬态状态不落盘，一律折叠为 idle。
            try c.encode("idle", forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? "idle"
        switch kind {
        case "succeeded":
            self = .succeeded(assetPath: (try? c.decode(String.self, forKey: .assetPath)) ?? "")
        case "failed":
            self = .failed(reason: (try? c.decode(String.self, forKey: .reason)) ?? "未知错误")
        default:
            self = .idle
        }
    }
}

// MARK: - 节点

/// 画布上的一个节点 = **一个槽位在画布上的摆位**（v2.11.7 hotfix20 架构调整）。
///
/// ## 为什么不再自带内容
///
/// hotfix19 之前节点自己存着 `prompt`，同时用 `sourceSlot` 指向溯源槽位，于是同一段文本有两份：
/// 节点里一份、槽位里一份。这种结构注定要靠"同步代码"活着 —— 编辑页改了要推给画布、画布改了要
/// 写回槽位、撤销时两边都要退、导入导出要考虑对不齐的情况。**每一条同步路径都是一个能静默产生
/// 分歧的地方**，而分歧一旦发生，用户看到的是"画布上的字和编辑页不一样"，无法判断哪个是真的。
///
/// 所以这里把结构改成：
///
/// ```text
///   内容（正文 / 入参文件 / Label）   →  只住在槽位里（ClipSlotsKit 的 SlotContent）
///   摆位与出图参数（坐标 / 模型 / 状态）→  只住在这里
/// ```
///
/// 节点**不缓存任何槽位内容**。卡片要显示正文就当场去问槽位，要改正文就直接写槽位。
/// 没有副本，就没有同步，也就没有分歧 —— 双向同步不再是一个需要实现的功能，而是结构的自然结果。
///
/// ## 身份
///
/// `id` 由「槽位引用」派生（`groupId#slot`），不是独立的 UUID。直接后果是
/// **同一个槽位在画布上最多只能有一个节点**。这是刻意的：两个节点指向同一份内容，改一个另一个
/// 跟着变，用户没法解释谁是谁；真要"同一段提示词跑两次"，那是出图张数（`count`）的事。
/// 入口层（`CanvasStore.placeSlot`）遇到重复会选中已有节点而不是再放一个。
///
/// 身份里刻意**不含 `pageId`**：组本身带 `pageId` 字段，组在页面间移动时槽位内容并没有变，
/// 若把页面编进 id，一次移动就会让画布上的节点全部"消失"（id 对不上）。
public struct CanvasNode: Codable, Identifiable, Equatable {

    // MARK: 槽位引用（= 身份 + 内容来源）

    /// 所属页面。**不参与身份**，只是给 UI 做「跳到那一页」用的导航提示。
    public var pageId: String
    /// 槽位组 id（全局唯一）。
    public var groupId: String
    /// 组内槽位号（1 起）。
    public var slot: Int

    /// 由槽位引用派生的稳定 id。
    public var id: String { CanvasNode.makeId(groupId: groupId, slot: slot) }

    public static func makeId(groupId: String, slot: Int) -> String {
        "\(groupId)#\(slot)"
    }

    public var kind: CanvasNodeKind

    /// 画布空间坐标（左上角）。与缩放/平移无关，这是持久化的唯一位置真值。
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    // MARK: 出图参数（MVP 只落地参数栏要显示的三项；完整 schema 驱动见架构文档 9.6）
    //
    // 这些**不是**槽位的概念（槽位只管内容），所以它们留在摆位里。

    /// 模型稳定 ID，例如 `seedream45`。
    public var model: String
    /// 比例，例如 `1:1`。
    public var ratio: String
    /// 张数（1 / 2 / 4）。对应 CLI 的 `--count`。
    public var count: Int

    // MARK: 正文排版（v2.11.7 hotfix19）
    //
    // 字体也是"怎么显示"而不是"是什么内容"，同样属于摆位。同一个槽位在编辑页用系统字体、
    // 在画布上用楷体，是合理的；把字体写进槽位反而会污染用户的内容资产。

    /// 正文字体族名（如 `HarmonyOS Sans SC`）。`nil` = 跟随系统字体。
    ///
    /// 存**族名**而不是 PostScript 名：族名是用户在 picker 里看到的那个字符串，字号/字重变化时
    /// 不需要重新解析；PostScript 名（`HarmonyOSSansSC-Regular`）反过来还得剥掉字重后缀才能显示。
    /// 族名 → 可用字体的解析放在 App 层（需要 AppKit），Kit 只负责存取。
    ///
    /// **字体缺失时的约定**：不做「解析不到就清空字段」的自动纠正。用户换机后字体可能只是暂时没装，
    /// 清空字段等于把设置悄悄丢了；保留族名 + 渲染时回落系统字体，装回字体就自动恢复。
    public var fontName: String?
    /// 正文字号。`nil` = `CanvasNode.defaultBodyFontSize`。
    public var fontSize: CGFloat?

    // MARK: 生成状态

    public var state: CanvasNodeState
    /// Crate 任务 ID，失败排查与「复制 taskId」用。
    public var taskId: String?
    /// 随机种子。实测 `--count n` 的每个任务 seed 各不相同，固定 seed 重跑依赖它。
    public var seed: Int?

    /// 上游节点 id（v2.11.8）。
    ///
    /// 由「节点下方 + 号快速添加下游节点」写入：新节点记下它是从谁身上长出来的。
    /// 连线的**渲染**尚未落地，但血缘关系必须在创建那一刻就记下来 —— 事后无法还原
    /// （用户点完 + 就会拖动节点，位置关系立刻失去意义）。
    ///
    /// 刻意存 id 而不是双向的 children 数组：单向引用不会出现「父说有子、子说没父」的
    /// 不一致，删节点时也只需要清理指向它的引用，不必维护两侧。
    public var parentNodeId: String?

    /// 本节点**生成产物**在槽位附件列表里的 id（v2.11.10）。
    ///
    /// 产物必须写回槽位（画布文档是派生资产，损坏即丢弃重建，不能当用户资产的唯一载体），
    /// 但槽位附件在画布语境下就是「入参文件」—— 不做区分的话，**重跑会把上一轮的出图当成
    /// 这一轮的入参**，文生图会在用户毫不知情的情况下变成图生图（第三轮起还会叠上两张）。
    ///
    /// 因此这里只记 id，不记路径：路径会被存储层改写（`attachments/{id}.bin` 的摄取），
    /// id 是附件唯一不变的身份。生成链路据此把产物从入参集合里剔掉。
    ///
    /// 刻意**不**顺手把产物从卡片的「入参文件」行里藏掉：那一行是「这个槽位里有哪些文件」的
    /// 如实呈现，藏起来用户就无法删除自己不想要的出图了。区分只发生在**提交任务**这一刻。
    public var outputAttachmentIds: [String]

    public var createdAt: Date
    public var updatedAt: Date

    public static let defaultSize = CGSize(width: 260, height: 300)

    /// 正文默认字号。卡片是 260pt 宽的定尺容器，10pt 是「两行能塞进 ~60 字」的经验值。
    public static let defaultBodyFontSize: CGFloat = 10
    /// 字号可选区间。
    ///
    /// 上限 24 不是随手写的：卡片正文区高度固定（约 26~40pt），字号再大就只剩一行且会被截断，
    /// 用户以为「字变大了但内容没了」。下限 8 是 macOS 上还能辨认汉字的实际底线。
    public static let bodyFontSizeRange: ClosedRange<CGFloat> = 8...24

    /// 把任意输入夹到合法区间。**所有写入路径都必须过这一道** —— 字号是能被 stepper 连点、
    /// 也能被历史数据带进来的量，越界值不会报错，只会渲染成一张不可读的卡片。
    public static func clampBodyFontSize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultBodyFontSize }
        return min(max(value, bodyFontSizeRange.lowerBound), bodyFontSizeRange.upperBound)
    }

    /// 实际生效的正文字号（含缺省与限幅）。
    public var resolvedBodyFontSize: CGFloat {
        CanvasNode.clampBodyFontSize(fontSize ?? CanvasNode.defaultBodyFontSize)
    }

    /// 槽位卡片的展开风格（v2.11.8 二轮）。
    ///
    /// ★ 九轮：风格只剩「扇形」一种，用户侧的切换入口（右上角按钮 + 右键子菜单）已删除，
    /// 所以这个字段现在恒为 `.fanOut`。字段本身**保留**，理由见 `ExpandStyle` 的注释 ——
    /// 老文档里存着 `carousel` / `stackedScatter`，得有个类型接住并迁移，删字段会让解码报
    /// "unknown key"（`CanvasNode` 用的是自定义解码，多余键其实无害，但迁移语义会丢）。
    public var animationStyle: CanvasFanGeometry.ExpandStyle

    /// 是否显式设过字体（供 UI 显示「跟随系统」与否）。
    public var hasCustomFont: Bool {
        if let fontName, !fontName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return fontSize != nil
    }

    public init(pageId: String,
                groupId: String,
                slot: Int,
                kind: CanvasNodeKind = .image,
                x: CGFloat,
                y: CGFloat,
                width: CGFloat = CanvasNode.defaultSize.width,
                height: CGFloat = CanvasNode.defaultSize.height,
                model: String = "seedream45",
                ratio: String = "1:1",
                count: Int = 1,
                fontName: String? = nil,
                fontSize: CGFloat? = nil,
                state: CanvasNodeState = .idle,
                taskId: String? = nil,
                seed: Int? = nil,
                parentNodeId: String? = nil,
                outputAttachmentIds: [String] = [],
                animationStyle: CanvasFanGeometry.ExpandStyle = .fanOut,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.pageId = pageId
        self.groupId = groupId
        self.slot = slot
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.model = model
        self.ratio = ratio
        self.count = count
        self.fontName = fontName
        self.fontSize = fontSize.map(CanvasNode.clampBodyFontSize)
        self.state = state
        self.taskId = taskId
        self.seed = seed
        self.parentNodeId = parentNodeId
        self.outputAttachmentIds = outputAttachmentIds
        self.animationStyle = animationStyle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable（含 hotfix19 及更早的旧文档迁移）

    private enum CodingKeys: String, CodingKey {
        case pageId, groupId, slot
        case kind, x, y, width, height
        case model, ratio, count
        case fontName, fontSize
        case state, taskId, seed
        case parentNodeId
        case outputAttachmentIds
        case animationStyle
        case createdAt, updatedAt
        // 旧字段：hotfix19 及更早的节点自带内容与溯源信息。只在解码时读，从不写回。
        case sourcePageId, sourceGroupId, sourceSlot
    }

    /// 手写解码是为了**迁移旧画布文档**。
    ///
    /// 旧结构里槽位引用叫 `sourceGroupId` / `sourceSlot`，而且允许为 nil（"未绑定节点"，内容存在
    /// 节点自己的 `prompt` 里）。新结构下节点必须指向一个槽位，所以：
    ///   - 有 `sourceGroupId` + `sourceSlot` → 平移成新字段，位置与出图参数原样保留。
    ///   - 两者都没有（老的未绑定节点）→ **抛错**。它的内容住在 `prompt` 里，新结构没有地方放；
    ///     与其凭空造一个槽位去承接（会污染用户的槽位资产），不如让它在文档级被跳过。
    ///     `CanvasDocument` 的解码是逐节点容错的，跳过一个不会带走整张画布。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let gid = try c.decodeIfPresent(String.self, forKey: .groupId),
           let s = try c.decodeIfPresent(Int.self, forKey: .slot) {
            groupId = gid
            slot = s
            pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        } else if let gid = try c.decodeIfPresent(String.self, forKey: .sourceGroupId),
                  let s = try c.decodeIfPresent(Int.self, forKey: .sourceSlot) {
            groupId = gid
            slot = s
            pageId = try c.decodeIfPresent(String.self, forKey: .sourcePageId) ?? ""
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .groupId, in: c,
                debugDescription: "节点没有槽位引用（旧的未绑定节点），按约定跳过")
        }

        kind = try c.decodeIfPresent(CanvasNodeKind.self, forKey: .kind) ?? .image
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? CanvasNode.defaultSize.width
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? CanvasNode.defaultSize.height
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "seedream45"
        ratio = try c.decodeIfPresent(String.self, forKey: .ratio) ?? "1:1"
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        state = try c.decodeIfPresent(CanvasNodeState.self, forKey: .state) ?? .idle
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
        // v2.11.8 新增字段：老文档没有它，缺省 nil（= 没有上游），不需要版本分支。
        parentNodeId = try c.decodeIfPresent(String.self, forKey: .parentNodeId)
        // v2.11.10 新增：老文档没有产物标记，缺省空集合（= 全部附件都算入参，与老行为一致）。
        outputAttachmentIds = try c.decodeIfPresent([String].self, forKey: .outputAttachmentIds) ?? []
        // ★ 九轮：只剩扇形一种风格；老文档里的 `carousel` / `stackedScatter` 由
        // `ExpandStyle.init(from:)` 迁移成 `.fanOut`（不抛错，见那边注释）。
        animationStyle = try c.decodeIfPresent(CanvasFanGeometry.ExpandStyle.self,
                                               forKey: .animationStyle) ?? .fanOut
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// 编码只写新字段。旧的 `source*` / `prompt` 刻意不回写 —— 保留它们会让下一位读者以为
    /// 那份副本还有人用，而"看起来还在用的死字段"是最容易被误当成真相的东西。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(slot, forKey: .slot)
        try c.encode(kind, forKey: .kind)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(model, forKey: .model)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(fontName, forKey: .fontName)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(taskId, forKey: .taskId)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(parentNodeId, forKey: .parentNodeId)
        // 空集合不写：绝大多数节点没出过图，写一个空数组只会让每个节点都胖一行。
        if !outputAttachmentIds.isEmpty {
            try c.encode(outputAttachmentIds, forKey: .outputAttachmentIds)
        }
        try c.encode(animationStyle, forKey: .animationStyle)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// 画布空间的矩形。
    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public mutating func setFrameOrigin(_ p: CGPoint) {
        x = p.x
        y = p.y
        updatedAt = Date()
    }
}

// MARK: - 文档

/// 一张画布的完整持久化内容。
public struct CanvasDocument: Codable, Equatable {
    /// 当前 schema 版本。新增字段不需要动它；只有**语义不兼容**的变更才递增。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var nodes: [CanvasNode]

    /// 视口。存下来是为了下次进画布还在原处 —— 每次都回到原点会让「我刚才在看哪」丢失。
    public var panX: CGFloat
    public var panY: CGFloat
    public var zoom: CGFloat

    public var updatedAt: Date

    public static let empty = CanvasDocument(schemaVersion: CanvasDocument.currentSchemaVersion,
                                            nodes: [],
                                            panX: 0, panY: 0, zoom: 1,
                                            updatedAt: Date())

    public init(schemaVersion: Int = CanvasDocument.currentSchemaVersion,
                nodes: [CanvasNode] = [],
                panX: CGFloat = 0,
                panY: CGFloat = 0,
                zoom: CGFloat = 1,
                updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.panX = panX
        self.panY = panY
        self.zoom = zoom
        self.updatedAt = updatedAt
    }

    // MARK: - Codable（逐节点容错 + 同槽去重）

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, nodes, panX, panY, zoom, updatedAt
    }

    /// 单个节点的**容错解码包装**。
    ///
    /// hotfix20 起 `CanvasNode.init(from:)` 会对「没有槽位引用的旧节点」抛错（见那边的注释）。
    /// 若 `nodes` 走默认的 `[CanvasNode]` 合成解码，**一个**坏节点会让整份文档解码失败 —— 而画布
    /// 文档的兜底策略是「解不开就丢弃重建」，用户看到的就是升级后整张画布被清空。逐个解、坏的跳过，
    /// 才能让迁移只损失真正没法承接的那几个节点。
    private struct LenientNode: Decodable {
        let node: CanvasNode?
        init(from decoder: Decoder) throws {
            node = try? CanvasNode(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CanvasDocument.currentSchemaVersion
        let decoded = (try c.decodeIfPresent([LenientNode].self, forKey: .nodes) ?? [])
            .compactMap(\.node)
        nodes = CanvasDocument.dedupedBySlot(decoded)
        panX = try c.decodeIfPresent(CGFloat.self, forKey: .panX) ?? 0
        panY = try c.decodeIfPresent(CGFloat.self, forKey: .panY) ?? 0
        zoom = try c.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// 同一槽位只保留**第一个**摆位。
    ///
    /// 新结构下 `id == groupId#slot`，旧文档里完全可能有两个节点指向同一个槽位（老结构允许，
    /// 因为那时 id 是 UUID）。留着重复项的后果不是"多一张卡片"，而是 SwiftUI `ForEach` 的
    /// id 冲突：选中、拖动、删除都会作用到不确定的那一个，表现为"点 A 动 B"。
    public static func dedupedBySlot(_ input: [CanvasNode]) -> [CanvasNode] {
        var seen = Set<String>()
        var out: [CanvasNode] = []
        out.reserveCapacity(input.count)
        for node in input where seen.insert(node.id).inserted { out.append(node) }
        return out
    }

    public var pan: CGSize { CGSize(width: panX, height: panY) }
}
