import Foundation
import CoreGraphics

/// 无限画布的数据模型（v2.11.7）。
///
/// 与 `SlotConnectionModels` 同构：全部 `Codable` + 带 `schemaVersion`，向后兼容靠「新字段可选
/// 或带默认值」而不是靠版本分支。画布数据是**派生资产**（可重新生成），因此损坏时的兜底是丢弃
/// 重建而非阻塞启动 —— 这一点与槽位数据（用户唯一资产，必须死保）截然不同。

// MARK: - 节点类型

public enum CanvasNodeKind: String, Codable, Equatable {
    /// 图像生成节点。
    case image
    /// 视频生成节点。
    case video
    /// 批量模版节点（自身不出图，是批量任务的母体）。
    case batchTemplate

    public var displayName: String {
        switch self {
        case .image: return "图像生成"
        case .video: return "视频生成"
        case .batchTemplate: return "批量模版"
        }
    }

    /// 顶部类型标签用的 SF Symbol。
    public var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .batchTemplate: return "square.stack.3d.up"
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

public struct CanvasNode: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: CanvasNodeKind

    /// 画布空间坐标（左上角）。与缩放/平移无关，这是持久化的唯一位置真值。
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    /// 提示词。批量场景下来自槽位主体文本。
    public var prompt: String

    // MARK: 参数（MVP 只落地参数栏要显示的三项；完整 schema 驱动见架构文档 9.6）

    /// 模型稳定 ID，例如 `seedream45`。
    public var model: String
    /// 比例，例如 `1:1`。
    public var ratio: String
    /// 张数（1 / 2 / 4）。对应 CLI 的 `--count`。
    public var count: Int

    // MARK: 正文排版（v2.11.7 hotfix19）

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

    // MARK: 来源与状态

    /// 节点来源槽位（若由槽位库拖入 / 批量展开产生）。仅作溯源，不产生写回。
    public var sourcePageId: String?
    public var sourceGroupId: String?
    public var sourceSlot: Int?
    public var sourceLabel: String?

    public var state: CanvasNodeState
    /// Crate 任务 ID，失败排查与「复制 taskId」用。
    public var taskId: String?
    /// 随机种子。实测 `--count n` 的每个任务 seed 各不相同，固定 seed 重跑依赖它。
    public var seed: Int?

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

    /// 是否显式设过字体（供 UI 显示「跟随系统」与否）。
    public var hasCustomFont: Bool {
        if let fontName, !fontName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return fontSize != nil
    }

    public init(id: String = "node_" + UUID().uuidString,
                kind: CanvasNodeKind = .image,
                x: CGFloat,
                y: CGFloat,
                width: CGFloat = CanvasNode.defaultSize.width,
                height: CGFloat = CanvasNode.defaultSize.height,
                prompt: String = "",
                model: String = "seedream45",
                ratio: String = "1:1",
                count: Int = 1,
                fontName: String? = nil,
                fontSize: CGFloat? = nil,
                sourcePageId: String? = nil,
                sourceGroupId: String? = nil,
                sourceSlot: Int? = nil,
                sourceLabel: String? = nil,
                state: CanvasNodeState = .idle,
                taskId: String? = nil,
                seed: Int? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.prompt = prompt
        self.model = model
        self.ratio = ratio
        self.count = count
        self.fontName = fontName
        self.fontSize = fontSize.map(CanvasNode.clampBodyFontSize)
        self.sourcePageId = sourcePageId
        self.sourceGroupId = sourceGroupId
        self.sourceSlot = sourceSlot
        self.sourceLabel = sourceLabel
        self.state = state
        self.taskId = taskId
        self.seed = seed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

    public var pan: CGSize { CGSize(width: panX, height: panY) }
}
