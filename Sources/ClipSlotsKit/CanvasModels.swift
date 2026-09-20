import Foundation
import CoreGraphics

/// 无限画布的数据模型（v2.11.7）。
///
/// 与 `SlotConnectionModels` 同构：全部 `Codable` + 带 `schemaVersion`，向后兼容靠「新字段可选
/// 或带默认值」而不是靠版本分支。画布数据是**派生资产**（可重新生成），因此损坏时的兜底是丢弃
/// 重建而非阻塞启动 —— 这一点与槽位数据（用户唯一资产，必须死保）截然不同。

// MARK: - 节点类型

/// 节点卡片的**形态**（v2.15.0）。
///
/// v2.14.x 之前 `CanvasNodeKind` 同时扛了两件事：「这个节点产出什么」和「这张卡片长什么样」。
/// 两者在那时是一对一的，所以没人觉得别扭 —— 直到用户要求「图片 / 视频节点要像 TapNow 那样
/// 媒体占满整张卡」，而**通用槽位卡片**（路径行 → 堆叠卡片 → 提示词 → 入参文件）必须原样保留。
/// 这时 `.image` 一个 case 要同时表达两种完全不同的排版，只能靠视图里写 `if` ——
/// 而卡片形态是有 smoke 断言盯着纵向预算的，靠 `if` 分叉等于把预算表复制一份。
///
/// 所以形态被抽成独立维度：`kind` 继续管语义（跑什么模型、要不要出图），`cardForm` 管排版。
public enum CanvasNodeCardForm: Equatable {
    /// 通用槽位卡：路径行 → 扇形堆叠卡片 → 提示词正文 → 入参文件行。
    /// 这是 v2.11.8 至 v2.14.x 所有节点共用的那张卡（用户截图里的形态）。
    case slotStack
    /// 纯文本卡：路径行 → 深色文本框（占满）→ 入参文件行。
    case text
    /// 媒体卡（v2.15.0）：媒体铺满卡片 + 悬浮信息角标 + 底部单行提示词条。
    case media
}

public enum CanvasNodeKind: String, Codable, Equatable {
    /// 纯文本 / Prompt 节点（v2.11.8）。自身不出图，是"给下游用的一段文字"。
    case text
    /// 图像生成节点。
    case image
    /// 视频生成节点。
    case video
    /// 批量模版节点（自身不出图，是批量任务的母体）。
    case batchTemplate
    /// 槽位节点（v2.15.0）。
    ///
    /// ## 它为什么是一个独立的 kind，而不是"就是 `.image`"
    ///
    /// 用户的原话是把现有这张卡「作为槽位节点」，然后让文本 / 图片 / 视频三种节点按 TapNow 的形态
    /// 重做。也就是说，**现有形态从"所有节点的样子"降格成"其中一种节点的样子"**。如果不给它一个
    /// 名字，就只能靠"绑在正式槽位组上的才算槽位节点"这类启发式去猜 —— 而节点一旦入库就会从
    /// 私有组换到正式组，靠组名猜身份意味着**入库会改变卡片长相**，这是用户最不该遇到的惊喜。
    ///
    /// 语义上它是"通用格子"：既能装提示词跑出图，也能只当一份内容的展台。因此 `producesAsset`
    /// 为 true、模型清单走图像档 —— 它继承的正是 v2.14.x 时 `.image` 的全部能力，
    /// 老文档迁到这里不会少任何一个功能（见 `CanvasDocument.migrateKinds`）。
    case slot

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .image: return "图像生成"
        case .video: return "视频生成"
        case .batchTemplate: return "批量模版"
        case .slot: return "槽位"
        }
    }

    /// 顶部类型标签用的 SF Symbol。
    public var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .video: return "film"
        case .batchTemplate: return "square.stack.3d.up"
        case .slot: return "square.grid.2x2"
        }
    }

    /// 该类型的节点是否会产出资产（决定卡片上"预览区"的语义：产物位 vs 内容位）。
    public var producesAsset: Bool {
        switch self {
        case .text: return false
        case .image, .video, .batchTemplate, .slot: return true
        }
    }

    /// 这个类型用哪种卡片形态渲染（v2.15.0）。
    ///
    /// `batchTemplate` 跟着 `.slot` 走通用卡：它本身不出图，卡上要看的是"这批任务的母本提示词 +
    /// 入参"，正是通用卡擅长的；给它一张媒体卡会留下一大块永远空着的媒体区。
    public var cardForm: CanvasNodeCardForm {
        switch self {
        case .text: return .text
        case .image, .video: return .media
        case .slot, .batchTemplate: return .slotStack
        }
    }

    /// 是否是 v2.15.0 的媒体节点（图片 / 视频）。
    ///
    /// 媒体节点独有的三件事都挂在这个判定上：全屏预览、媒体信息角标、媒体区点击语义。
    public var isMediaNode: Bool { cardForm == .media }
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

    // MARK: 出视频参数（v2.11.19）
    //
    // 为什么不塞进上面那三项里复用：`ratio` 两条链路语义相同（都是构图比例），可以共用；
    // 而分辨率在图像链路里是**混在 ratio 选项里给的**（`2K` / `16:9 4K` 都是 ratio 的取值），
    // 视频链路才有独立的 `--resolution`。共用一个字段的后果是图像节点存着一个永远不传的值，
    // 换链路时还要猜它该怎么迁移。

    /// 分辨率档，例如 `720p` / `4k` / `768P`。空串 = 不传，用模型默认。
    ///
    /// **原样存 CLI 给的大小写**：各模型写法不统一（seedance 的 `4k` vs minimax 的 `2K`），
    /// 而 CLI 校验是精确匹配。存的时候归一化，提交时就得反查回去，等于凭空造一层映射表。
    public var resolution: String
    /// 时长（秒）。`nil` = 不传，用模型默认值（各模型 5/8/10 不等）。
    public var duration: Int?
    /// 要不要生成配音。`nil` = 不传。
    ///
    /// 三态而不是 Bool：`generate_audio` 只有 Seedance 2.x 声明，对其他模型传它 CLI 当场拒收。
    /// 「没设过」必须与「显式关掉」区分开——后者要传 `false`（模型默认是开），前者不能传。
    public var generateAudio: Bool?

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

    /// 本节点**生成产物**在槽位附件列表里的 id（v2.11.17）。
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

    /// 按节点类型取默认尺寸（v2.15.0）。
    ///
    /// 媒体节点（图片 / 视频）比槽位卡宽一点：它的主视觉是一张 aspect-fit 的图，而槽位卡的主视觉
    /// 是一叠槽位缩略图 + 提示词。同样 260pt 宽下，媒体区扣掉 header 与 prompt 条后只剩很扁的一条，
    /// 竖图会被压成一根签子 —— 这正是 `CanvasMediaCardLayout` 让位顺序要处理的那个窘境，
    /// 与其生下来就触发让位，不如一开始给足。
    public static func defaultSize(for kind: CanvasNodeKind) -> CGSize {
        kind.isMediaNode ? CanvasMediaCardLayout.defaultSize : defaultSize
    }

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
                // ★ v2.15.0：默认从 `.image` 改成 `.slot`。默认值服务的是"没指定类型就摆一个格子上去"
                // 这条路径（从左侧槽位库拖 / 「摆到画布」按钮），那本来就是槽位节点；
                // 真要图片 / 视频节点的调用方一律显式传 kind。
                kind: CanvasNodeKind = .slot,
                x: CGFloat,
                y: CGFloat,
                width: CGFloat = CanvasNode.defaultSize.width,
                height: CGFloat = CanvasNode.defaultSize.height,
                model: String = "seedream45",
                ratio: String = "1:1",
                count: Int = 1,
                resolution: String = "",
                duration: Int? = nil,
                generateAudio: Bool? = nil,
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
        self.resolution = resolution
        self.duration = duration
        self.generateAudio = generateAudio
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

    /// 某个节点类型的默认模型（v2.11.19）。
    ///
    /// 视频节点不能沿用 `seedream45`：那是个出图模型，提交时 CLI 会报
    /// `Model seedream45 does not support video generation`，而用户什么都没改过——
    /// 「新建节点、点生成、报错」是最劝退的一种首体验。
    public static func defaultModel(for kind: CanvasNodeKind) -> String {
        switch kind {
        case .video: return CrateGeneration.defaultVideoModel
        default: return CrateGeneration.defaultModel
        }
    }

    /// 某个节点类型的默认比例。
    ///
    /// 视频给 `16:9` 而不是图像那个 `1:1`：方形视频在任何播放场景里都是异类，而 `16:9` 是
    /// 全部 7 个视频模型都声明了的档位（方图 `1:1` 反而不是每个都有）。
    public static func defaultRatio(for kind: CanvasNodeKind) -> String {
        switch kind {
        case .video: return "16:9"
        default: return "1:1"
        }
    }

    // MARK: - Codable（含 hotfix19 及更早的旧文档迁移）

    private enum CodingKeys: String, CodingKey {
        case pageId, groupId, slot
        case kind, x, y, width, height
        case model, ratio, count
        case resolution, duration, generateAudio
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
        // 缺省值跟着 kind 走（v2.11.19）：v2.11.18 及更早的文档里视频节点存的是出图默认值
        // `seedream45` / `1:1`（那时视频链路还没有提交路径，这两个字段对它是死值）。按 kind 取默认
        // 只影响"字段压根不存在"的情况，不会覆盖用户显式选过的值。
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? CanvasNode.defaultModel(for: kind)
        ratio = try c.decodeIfPresent(String.self, forKey: .ratio) ?? CanvasNode.defaultRatio(for: kind)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        // v2.11.19 新增：老文档没有，缺省"不传"（空串 / nil），等价于沿用模型自己的默认值。
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? ""
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        generateAudio = try c.decodeIfPresent(Bool.self, forKey: .generateAudio)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        state = try c.decodeIfPresent(CanvasNodeState.self, forKey: .state) ?? .idle
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
        // v2.11.8 新增字段：老文档没有它，缺省 nil（= 没有上游），不需要版本分支。
        parentNodeId = try c.decodeIfPresent(String.self, forKey: .parentNodeId)
        // v2.11.17 新增：老文档没有产物标记，缺省空集合（= 全部附件都算入参，与老行为一致）。
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
        // 空 / nil 不写：与 `outputAttachmentIds` 同一条规矩。更重要的是这让"没设过"在文件里
        // 就是"字段不存在"，而不是一个需要靠约定解释的空串——图像节点的文档因此完全不变。
        if !resolution.isEmpty {
            try c.encode(resolution, forKey: .resolution)
        }
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(generateAudio, forKey: .generateAudio)
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
    ///
    /// - `1`：v2.11.7 ~ v2.14.x。
    /// - `2`：v2.15.0。`.image` 的**含义变了** —— 它从"所有节点的默认类型"变成"TapNow 式媒体卡"，
    ///   所以老文档里的 `.image` 必须迁成 `.slot`（见 `migrateKinds`）。这正是"语义不兼容"
    ///   的教科书案例：字段没动、值没动，但同一个值现在渲染出完全不同的卡片。
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var nodes: [CanvasNode]

    /// 节点之间的连线（v2.12.0 新增）。
    ///
    /// 老文档没有这个字段，解码时由 `parentNodeId` 迁移补齐（见 `init(from:)`）。新字段用默认值
    /// 承接兼容、不递增 `schemaVersion`，遵循本文件开头立的规矩。
    public var edges: [CanvasEdge]

    /// 视口。存下来是为了下次进画布还在原处 —— 每次都回到原点会让「我刚才在看哪」丢失。
    public var panX: CGFloat
    public var panY: CGFloat
    public var zoom: CGFloat

    public var updatedAt: Date

    public static let empty = CanvasDocument(schemaVersion: CanvasDocument.currentSchemaVersion,
                                            nodes: [],
                                            edges: [],
                                            panX: 0, panY: 0, zoom: 1,
                                            updatedAt: Date())

    public init(schemaVersion: Int = CanvasDocument.currentSchemaVersion,
                nodes: [CanvasNode] = [],
                edges: [CanvasEdge] = [],
                panX: CGFloat = 0,
                panY: CGFloat = 0,
                zoom: CGFloat = 1,
                updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.edges = edges
        self.panX = panX
        self.panY = panY
        self.zoom = zoom
        self.updatedAt = updatedAt
    }

    // MARK: - Codable（逐节点容错 + 同槽去重）

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, nodes, edges, panX, panY, zoom, updatedAt
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

    /// 单条连线的容错解码包装。理由同 `LenientNode`。
    private struct LenientEdge: Decodable {
        let edge: CanvasEdge?
        init(from decoder: Decoder) throws {
            edge = try? CanvasEdge(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 缺字段按 **1** 兜底，不是按 current。写入路径永远写 `schemaVersion`，所以"字段不存在"
        // 只可能来自最早那批文档 —— 把它们当成最新版等于跳过全部迁移，而迁移的代价是
        // 用户画布上每张卡片都换了形态（见 `migrateKinds`）。
        let declaredVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let decoded = (try c.decodeIfPresent([LenientNode].self, forKey: .nodes) ?? [])
            .compactMap(\.node)
        nodes = CanvasDocument.migrateKinds(CanvasDocument.dedupedBySlot(decoded),
                                            fromSchemaVersion: declaredVersion)
        // 迁移完就报最新版：否则每次打开都要再跑一遍（幂等，但会让"这份文档是什么年代的"永远说不清）。
        schemaVersion = max(declaredVersion, CanvasDocument.currentSchemaVersion)
        // 连线必须在节点定稿**之后**再规整：野线（端点指向被去重/被跳过的节点）要在这里被丢掉，
        // 否则画布上会留一条连到虚空的线，而它在屏幕上看起来跟正常线一模一样。
        let decodedEdges = (try c.decodeIfPresent([LenientEdge].self, forKey: .edges) ?? [])
            .compactMap(\.edge)
        edges = CanvasEdgeGraph.migratedFromParentLinks(
            nodes: nodes,
            edges: CanvasEdgeGraph.normalized(decodedEdges, nodeIds: Set(nodes.map(\.id))))
        panX = try c.decodeIfPresent(CGFloat.self, forKey: .panX) ?? 0
        panY = try c.decodeIfPresent(CGFloat.self, forKey: .panY) ?? 0
        zoom = try c.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// 编码。空连线集合不写 —— 与 `CanvasNode.outputAttachmentIds` 同一条规矩：让"从没连过线"
    /// 在文件里长得和 v2.11.x 一样，降级回老版本时不会多出一个它不认识的空数组。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(nodes, forKey: .nodes)
        if !edges.isEmpty { try c.encode(edges, forKey: .edges) }
        try c.encode(panX, forKey: .panX)
        try c.encode(panY, forKey: .panY)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// schema 1 → 2：把 `.image` 迁成 `.slot`（v2.15.0）。
    ///
    /// ## 为什么要迁，以及为什么**只**迁 `.image`
    ///
    /// v2.14.x 里 `.image` 是 `CanvasNode.init` 的**默认 kind**，也是解码缺字段时的兜底值 ——
    /// 换句话说它是个catch-all 桶：从左侧槽位库拖上画布的节点、ADD NODE 建的图像节点、
    /// 最早那批没写 kind 的节点，全在里面。而这些节点在屏幕上长的是**同一张**通用卡
    /// （路径行 → 堆叠卡片 → 提示词 → 入参文件），也就是用户截图里点名要保留的「槽位节点」形态。
    ///
    /// v2.15.0 起 `.image` 改渲染 TapNow 式媒体卡。若不迁移，用户升级后打开画布会发现**每一张**
    /// 卡片都换了形态 —— 包括那些只装了一段文字、根本没有图的节点（媒体区一片空）。迁到 `.slot`
    /// 的效果恰好相反：**视觉零变化**，能力也零损失（`.slot` 继承了 `.image` 的出图链路）。
    ///
    /// `.video` 刻意**不迁**：它从来只能由 ADD NODE →「视频节点」显式产生，不是兜底值，
    /// 所以桶里装的确实都是"用户当初就想要一个视频节点"的那些。它们换成媒体卡是升级而不是意外。
    /// `.text` / `.batchTemplate` 同理，各自形态本来就是专属的。
    ///
    /// 幂等：schema ≥ 2 直接原样返回。
    public static func migrateKinds(_ input: [CanvasNode], fromSchemaVersion version: Int) -> [CanvasNode] {
        guard version < 2 else { return input }
        return input.map { node in
            guard node.kind == .image else { return node }
            var migrated = node
            migrated.kind = .slot
            return migrated
        }
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
