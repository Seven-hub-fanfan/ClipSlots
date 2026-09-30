import Foundation

// MARK: - Agent 后端选择
//
// v2.17.7 起，ClipSlots 的 AI 助手支持两个后端：
//   - **DeepSeek**（默认）：走 HTTPS + OpenAI 兼容 SSE + OpenAI tool_calls；由 `AgentService` 实现。
//   - **Tika**：走本机 `tikacli chat --json` 子进程 + XML `<clipslots-call>` 契约；
//     App 层的 `TikaCLIService` 实现。
//
// 两条路的最终交付都是「一段 assistant 消息 + 若干工具执行结果」，UI 层只订阅 `AgentRunEvent`
// 完全无感——这也是本文件存在的意义：让上层（`AgentChatModel`）与后端解耦。
//
// 为什么不硬替换 DeepSeek：
//   1. Tika 首帧延迟明显更高（几秒 vs 几百毫秒），有的场景 DeepSeek 手感更好；
//   2. Tika Agent 的模型选择是"预配置好几个 Agent 挑一个"，不如 DeepSeek 那样即时改模型；
//   3. 出问题时保留一条独立可回退的通路，比"全押 Tika"稳。
//
// 所以这里做的是**开关+并存**，不是替换。

// MARK: - 后端类型标识

public enum AgentBackendKind: String, Codable, CaseIterable, Sendable {
    case deepseek
    case tika

    /// UI 展示名——@AppStorage 是纯字符串，UI 上要展示更友好的名字用这个。
    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .tika: return "Tika Agent"
        }
    }
}

// MARK: - 后端抽象

/// 上层（AgentChatModel）看到的"一次运行"接口。DeepSeek / Tika 都要实现这个协议。
///
/// - `history` 完整消息数组（含历史轮次 assistant 与 tool 消息）。
/// - `config` DeepSeek 用 `AgentConfig`；Tika 用同一个类型但只吃 `.systemPrompt`（后端切换时 UI 会隐藏无关字段）。
/// - `tools` DeepSeek 用来在请求体里带 tool schema；Tika **忽略**这个参数（工具契约不走 schema）。
/// - `onEvent` 事件回调；Tika 后端会把 XML 工具调用的执行结果也翻译成 `.toolStarted` / `.toolCompleted`
///   事件让 UI 感知一致。
public protocol AgentBackend: AnyObject, Sendable {
    /// 与 `AgentService.run` 完全同签名，方便 DeepSeek 直接 extension conformance。
    /// 返回值是"这一轮新加入 history 的消息"（assistant + role=tool 消息）；Tika 后端也遵守同样语义。
    @discardableResult
    func run(history: [AgentMessage],
             config: AgentConfig,
             tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage]
}

// MARK: - AgentService 顺带符合

/// 让现有的 DeepSeek 实现符合 `AgentBackend`，不改任何一行 AgentService 内部实现。
extension AgentService: AgentBackend {}

// MARK: - Tika 后端偏好键 / 会话配置

/// Tika 后端要存的偏好。**放 @AppStorage**（tikacli 已经自己管好 JWT，
/// 我们这里不存任何凭据）。
public enum TikaBackendPreferences {
    public static let backendKindKey = "agent.backend.kind"
    public static let tikaEnabledKey = "agent.tika.enabled"
    public static let tikaAgentIdKey = "agent.tika.agentId"
    /// 一组 Agent 选项（JSON 编码：`[{"id":"...","name":"...","model":"..."}]`），
    /// 让用户在 UI 上像"选模型"一样选。
    public static let tikaAgentCatalogKey = "agent.tika.agentCatalog"
    public static let tikaCLIPathKey = "agent.tika.cliPath"
    public static let tikaSystemPromptKey = "agent.tika.systemPrompt"
}

/// Tika Agent 目录里的一项（persist 到 @AppStorage 用）。
public struct TikaAgentOption: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// 上一次跑这个 Agent 时从 start 事件抓到的模型标签，仅供 UI 展示。
    public var model: String?

    public init(id: String, name: String, model: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
    }
}

/// Tika 后端本次会话的运行配置。tikacli 支持的参数很少，能塞的都塞这里。
public struct TikaBackendConfig: Equatable, Sendable {
    /// tikacli 可执行文件绝对路径。默认从 PATH 里找；未来 App 内置版可以指向自带 bin。
    public var cliPath: String
    /// 目标 Agent。为 nil 时 tikacli 用当前 Space 的默认 Agent。
    public var agentId: String?
    /// 目标 Space。为 nil 时 tikacli 用当前 default space。
    public var spaceId: String?
    /// 每轮子进程超时。tikacli 内部还会串到云端排队，别设太紧；60s 是安全值。
    public var perTurnTimeout: TimeInterval
    /// 一次对话里允许的 XML 工具调用最大轮数——护栏，避免 Agent 死循环耗光额度。
    public var maxToolTurns: Int
    /// 是否自动审批 Tika 云端工具（`--auto-approve`）。默认 true，方便对话不被 approval 卡住；
    /// 但因为提示词禁止云端工具，实际上很少触发。
    public var autoApprove: Bool
    /// 追加到 Tika Web Agent instructions 之后的本地补充要求；与 DeepSeek system prompt 分开保存。
    public var supplementalSystemPrompt: String

    public init(cliPath: String = "tikacli",
                agentId: String? = nil,
                spaceId: String? = nil,
                perTurnTimeout: TimeInterval = 60,
                maxToolTurns: Int = 8,
                autoApprove: Bool = true,
                supplementalSystemPrompt: String = "") {
        self.cliPath = cliPath
        self.agentId = agentId
        self.spaceId = spaceId
        self.perTurnTimeout = perTurnTimeout
        self.maxToolTurns = maxToolTurns
        self.autoApprove = autoApprove
        self.supplementalSystemPrompt = supplementalSystemPrompt
    }
}
