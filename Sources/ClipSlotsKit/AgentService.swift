import Foundation

// MARK: - Agent 核心
//
// 这一层负责"和 DeepSeek 说话"这件事的全部，且**不含任何 UI 依赖**：
//   请求体组装 → SSE 流式读取 → 工具调用循环 → 错误翻译。
//
// 之所以放在 Kit 而不是 App：App target 是 GUI 可执行文件，测不了；
// Kit 能被 `swift run ClipSlotsKitSmokeTests` 直接吃进去。本文件里最容易出错的三处
// （请求体形状、SSE 拼装、工具循环终止条件）因此全部可测。
//
// ## 与 DeepSeek 当前 API 的三条硬约定（都是踩过/查证过的，改动前先读）
//
// 1. **带 tools 时，reasoning_content 必须原样回传**。
//    官方文档（Thinking Mode → Tool Calls）明确写着：请求携带 `tools` 参数时，
//    之前所有轮次的 `reasoning_content` 都要回传，**包括没有发生工具调用的轮次**，
//    否则 API 返回 400。因为 ClipSlots 的 Agent 永远带着内置 CLI 工具，
//    所以本实现是"assistant 消息只要有 reasoning 就一定回传"。
//    （对照：不带 tools 时回传也无害，会被服务端忽略。所以不需要按情况分叉。）
// 2. **thinking 开关默认不发**。文档说思考模式默认开启，`thinking` / `reasoning_effort`
//    属于新一代参数；老模型别名（deepseek-chat 等）是否接受这两个字段没有保证。
//    因此 `AgentThinkingMode.serverDefault` 时请求体里根本不出现这些键——
//    "少发一个可选参数"永远比"发了被 400"安全。
// 3. **模型名会随代际变化**。用户指定默认 `deepseek-reasoner`（可选 `deepseek-chat`），
//    而官方当前在售名是 `deepseek-flash` / `deepseek-v4-pro`。所以模型是**可自由填写**的
//    字符串 + 预设下拉，并且把"模型不存在"类错误单独翻译成带建议的提示，
//    而不是让用户对着一句 400 发呆。

// MARK: - 消息模型

public struct AgentToolCall: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    /// 原始 arguments 文本。刻意保留字符串而不是解析后的结构：
    /// 回传给上游时必须逐字节一致，解析只发生在执行侧。
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public func arguments() throws -> JSONValue {
        try JSONValue.decode(jsonText: argumentsJSON)
    }
}

public struct AgentMessage: Identifiable, Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var id: UUID
    public var role: Role
    public var content: String
    /// 思维链。仅 assistant 有；UI 折叠展示，同时必须回传上游（见文件头约定 1）。
    public var reasoning: String?
    public var toolCalls: [AgentToolCall]
    /// role == .tool 时必填，对应它回应的那个 tool_call。
    public var toolCallId: String?
    /// role == .tool 时的工具名，仅用于 UI 展示，不进请求体。
    public var toolName: String?
    /// 本地标记：工具执行失败 / 本地错误提示。不进请求体的额外语义，仅驱动 UI 配色。
    public var isFailure: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(),
                role: Role,
                content: String,
                reasoning: String? = nil,
                toolCalls: [AgentToolCall] = [],
                toolCallId: String? = nil,
                toolName: String? = nil,
                isFailure: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isFailure = isFailure
        self.createdAt = createdAt
    }

    /// 这条消息是否需要出现在发给上游的 messages 里。
    /// 本地提示（比如"未配置 API Key"这种 UI 级 assistant 气泡）不该污染上下文。
    public var isWireVisible: Bool {
        switch role {
        case .system: return true
        case .user: return true
        case .assistant:
            // 纯本地错误提示不回传；有工具调用或有内容的正常回复才回传。
            if isFailure && toolCalls.isEmpty { return false }
            return true
        case .tool: return toolCallId != nil
        }
    }
}

// MARK: - 工具

public struct AgentToolSpec: Equatable, Sendable {
    public let name: String
    public let description: String
    /// JSON Schema（object）。无参工具传 `["type": "object", "properties": [:]]`。
    public let parameters: JSONValue
    /// UI 展示用的来源标签："内置" / Skill 名。不进请求体。
    public let originLabel: String

    public init(name: String, description: String, parameters: JSONValue, originLabel: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.originLabel = originLabel
    }

    public var wireValue: JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": parameters,
            ]),
        ])
    }
}

public struct AgentToolResult: Equatable, Sendable {
    /// 回给模型的内容（一般是 JSON 文本）。
    public let content: String
    /// 是否失败。失败也照样回给模型——让它有机会自我纠正，而不是把整轮对话打断。
    public let isFailure: Bool
    /// UI 状态行用的一句话摘要。
    public let summary: String

    public init(content: String, isFailure: Bool = false, summary: String) {
        self.content = content
        self.isFailure = isFailure
        self.summary = summary
    }

    public static func failure(_ message: String, code: String = "TOOL_ERROR") -> AgentToolResult {
        let payload = JSONValue.object([
            "ok": .bool(false),
            "error_code": .string(code),
            "error": .string(message),
        ])
        let text = (try? payload.encodedText()) ?? "{\"ok\":false,\"error\":\"\(message)\"}"
        return AgentToolResult(content: text, isFailure: true, summary: message)
    }
}

public protocol AgentToolExecuting: AnyObject {
    /// 本轮开放给模型的工具清单（内置 + 用户勾选的 Skill）。
    func specs() -> [AgentToolSpec]
    func execute(call: AgentToolCall) async -> AgentToolResult
}

// MARK: - 配置

public enum AgentThinkingMode: String, Codable, CaseIterable, Sendable {
    /// 不发 thinking 字段，完全跟随服务端默认（最兼容，默认值）。
    case serverDefault
    case enabled
    case disabled

    public var displayName: String {
        switch self {
        case .serverDefault: return "跟随服务端"
        case .enabled: return "开启"
        case .disabled: return "关闭"
        }
    }
}

public struct AgentModelPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let note: String
    public init(id: String, note: String) { self.id = id; self.note = note }
}

public struct AgentConfig: Equatable, Sendable {
    public static let defaultEndpoint = URL(string: "https://api.deepseek.com/v1/chat/completions")!
    public static let defaultModel = "deepseek-reasoner"

    /// 用户指定的默认 System Prompt。版本号内嵌，方便模型自报家门时说对。
    public static let defaultSystemPrompt = """
    你是 ClipSlots 的 AI 助手，帮助用户管理提示词槽位和图像生成任务。
    你可以通过工具直接读写槽位内容，用户说「把槽位3改成...」时直接调用工具执行，不要反复确认。
    但 delete_page / delete_group / clear_slot 是破坏性操作：目标已经被点名（"删掉草稿这一页"）就直接做并说清删了什么；
    目标含糊（"清一下"、"把没用的删掉"）时先问清对象再动手，不要自己挑一个删。
    回答简洁，操作完成后给一句确认。当前应用版本：v2.11.7。
    """

    /// 预设模型：前两个是用户明确要求的默认/备选，后两个是官方文档当前在售名，
    /// 留着是因为老别名随时可能被下线，用户需要一个不改代码就能自救的出口。
    public static let modelPresets: [AgentModelPreset] = [
        AgentModelPreset(id: "deepseek-reasoner", note: "默认 · 思考型"),
        AgentModelPreset(id: "deepseek-chat", note: "对话型"),
        AgentModelPreset(id: "deepseek-flash", note: "官方当前 Flash"),
        AgentModelPreset(id: "deepseek-v4-pro", note: "官方当前 Pro"),
    ]

    public var endpoint: URL
    public var model: String
    public var systemPrompt: String
    public var thinkingMode: AgentThinkingMode
    /// nil = 不发 reasoning_effort。取值 low/high/max。
    public var reasoningEffort: String?
    /// 工具调用轮上限。防"模型和工具互相喂饭"死循环，也防账单失控。
    public var maxToolRounds: Int

    public init(endpoint: URL = AgentConfig.defaultEndpoint,
                model: String = AgentConfig.defaultModel,
                systemPrompt: String = AgentConfig.defaultSystemPrompt,
                thinkingMode: AgentThinkingMode = .serverDefault,
                reasoningEffort: String? = nil,
                maxToolRounds: Int = 8) {
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
        self.maxToolRounds = max(1, min(maxToolRounds, 20))
    }
}

// MARK: - 运行事件

public enum AgentRunEvent: Sendable {
    case reasoningDelta(String)
    case contentDelta(String)
    /// 一轮 assistant 输出结束（可能带 tool_calls）。
    case assistantCompleted(AgentMessage)
    case toolStarted(AgentToolCall)
    case toolCompleted(callId: String, name: String, result: AgentToolResult)
    case usage(AgentUsage)
    /// 达到轮上限之类的运行提示，直接进 UI 作为系统气泡。
    case note(String)
}

// MARK: - 传输层
//
// 抽出协议只为一件事：smoke 测试能塞假 SSE 进来，跑通"流式 → 工具 → 再流式"整条链，
// 而不需要网络、不需要 API Key。

public struct AgentHTTPStream: Sendable {
    public let statusCode: Int
    public let chunks: AsyncThrowingStream<Data, Error>
    public init(statusCode: Int, chunks: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.chunks = chunks
    }
}

public protocol AgentTransport: Sendable {
    func stream(request: URLRequest) async throws -> AgentHTTPStream
}

public struct URLSessionAgentTransport: AgentTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 300) {
        let cfg = URLSessionConfiguration.ephemeral
        // 流式响应不能被缓存，也不该等"整体完成"才给数据。
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        // 思考型模型首个 token 可能几十秒才来，资源超时必须放宽，
        // 否则会在"模型正在想"的时候被自己掐断。
        cfg.timeoutIntervalForResource = timeout * 4
        session = URLSession(configuration: cfg)
    }

    public func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    // 按行读：SSE 本身是行协议，逐字节 yield 只是白烧 CPU。
                    // 下游 decoder 仍然按"任意切分"处理，所以这里的行边界只是优化。
                    for try await line in bytes.lines {
                        continuation.yield(Data((line + "\n").utf8))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AgentHTTPStream(statusCode: status, chunks: stream)
    }
}

// MARK: - 错误

public enum AgentError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyPrompt
    case http(status: Int, message: String?, code: String?)
    case upstream(message: String, code: String?)
    case network(String)
    case invalidResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没有配置 DeepSeek API Key，点右上角齿轮填入后即可开始对话。"
        case .emptyPrompt:
            return "请先输入内容。"
        case .http(let status, let message, _):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch status {
            case 400:
                return "请求被拒绝（400）：\(detail ?? "请求体格式不合法")。若刚改过模型名，请确认该模型仍在售。"
            case 401:
                return "鉴权失败（401）：API Key 无效或已撤销，请在设置里重新填写。"
            case 402:
                return "余额不足（402）：请到 DeepSeek 平台充值后重试。"
            case 404:
                return "接口或模型不存在（404）：\(detail ?? "请检查模型名与 Endpoint")。"
            case 422:
                return "参数不合法（422）：\(detail ?? "请检查模型名、thinking 与 reasoning_effort 设置")。"
            case 429:
                return "触发限流（429）：请稍等一会儿再发。"
            case 500, 502, 503:
                return "上游服务异常（\(status)）：稍后重试即可。"
            default:
                return "请求失败（\(status)）\(detail.map { "：\($0)" } ?? "")"
            }
        case .upstream(let message, _):
            return "上游返回错误：\(message)"
        case .network(let message):
            return "网络错误：\(message)"
        case .invalidResponse(let message):
            return "响应无法解析：\(message)"
        case .cancelled:
            return "已停止本次回答。"
        }
    }

    /// 是否是"换个模型名可能就好了"的错误——UI 据此显示模型建议。
    public var hintsModelProblem: Bool {
        switch self {
        case .http(let status, let message, _):
            guard status == 400 || status == 404 || status == 422 else { return false }
            let m = (message ?? "").lowercased()
            return m.contains("model") || m.contains("not exist") || m.contains("not found")
        default:
            return false
        }
    }
}

// MARK: - 服务

public final class AgentService: @unchecked Sendable {
    private let transport: AgentTransport
    private let secretStore: AgentSecretStore

    public init(transport: AgentTransport = URLSessionAgentTransport(),
                secretStore: AgentSecretStore = AgentKeychain.shared) {
        self.transport = transport
        self.secretStore = secretStore
    }

    public var hasAPIKey: Bool { secretStore.readAPIKey() != nil }

    // MARK: 请求体（public 以便 smoke 直接断言形状）

    public static func requestBody(history: [AgentMessage],
                                  config: AgentConfig,
                                  tools: [AgentToolSpec],
                                  stream: Bool = true) -> JSONValue {
        var messages: [JSONValue] = []

        let prompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            messages.append(.object(["role": .string("system"), "content": .string(prompt)]))
        }

        for message in history where message.isWireVisible {
            switch message.role {
            case .system:
                // 历史里的 system 由 config.systemPrompt 统一承担，避免重复注入。
                continue
            case .user:
                messages.append(.object(["role": .string("user"), "content": .string(message.content)]))
            case .assistant:
                var obj: [String: JSONValue] = [
                    "role": .string("assistant"),
                    // content 可以是空串（模型只发工具调用的那一轮），必须保留键。
                    "content": .string(message.content),
                ]
                // 见文件头约定 1：带 tools 时不回传 reasoning_content 会被 400。
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    obj["reasoning_content"] = .string(reasoning)
                }
                if !message.toolCalls.isEmpty {
                    obj["tool_calls"] = .array(message.toolCalls.map { call in
                        .object([
                            "id": .string(call.id),
                            "type": .string("function"),
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.argumentsJSON),
                            ]),
                        ])
                    })
                }
                messages.append(.object(obj))
            case .tool:
                guard let callId = message.toolCallId else { continue }
                messages.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(callId),
                    "content": .string(message.content),
                ]))
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array(messages),
            "stream": .bool(stream),
        ]
        if stream {
            // 要 usage 就必须显式开；否则流式响应不带用量。
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map(\.wireValue))
        }
        switch config.thinkingMode {
        case .serverDefault: break // 见文件头约定 2：一个字段都不发
        case .enabled: body["thinking"] = .object(["type": .string("enabled")])
        case .disabled: body["thinking"] = .object(["type": .string("disabled")])
        }
        if let effort = config.reasoningEffort, !effort.isEmpty, config.thinkingMode != .disabled {
            body["reasoning_effort"] = .string(effort)
        }
        return .object(body)
    }

    // MARK: 主循环

    /// 跑完一次"用户发言 → 若有工具则执行 → 直到模型给出终答"。
    /// 返回新增的消息（assistant / tool），调用方负责追加进自己的历史。
    @discardableResult
    public func run(history: [AgentMessage],
                    config: AgentConfig,
                    tools: AgentToolExecuting?,
                    onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        guard let apiKey = secretStore.readAPIKey() else { throw AgentError.missingAPIKey }

        var working = history
        var produced: [AgentMessage] = []
        let specs = tools?.specs() ?? []

        for round in 0..<config.maxToolRounds {
            try Task.checkCancellation()

            let accumulator = try await streamOnce(history: working,
                                                   config: config,
                                                   specs: specs,
                                                   apiKey: apiKey,
                                                   onEvent: onEvent)

            if let err = accumulator.serverError {
                throw AgentError.upstream(message: err.message, code: err.code)
            }

            let assistant = accumulator.assistantMessage()
            // 兜底：既没内容也没工具调用（网络中断/上游异常收尾）时给个可见提示，
            // 否则 UI 上会出现一个永远空白的气泡，用户不知道发生了什么。
            if assistant.content.isEmpty, assistant.toolCalls.isEmpty, assistant.reasoning?.isEmpty != false {
                throw AgentError.invalidResponse("上游未返回任何内容")
            }
            working.append(assistant)
            produced.append(assistant)
            await onEvent(.assistantCompleted(assistant))

            guard !assistant.toolCalls.isEmpty else { return produced }

            guard let tools else {
                // 模型想调工具但本轮没有执行器（理论上不会发生，因为 specs 为空时模型无从调用）。
                let note = "模型请求了工具但当前没有可用工具，已跳过。"
                await onEvent(.note(note))
                return produced
            }

            for call in assistant.toolCalls {
                try Task.checkCancellation()
                await onEvent(.toolStarted(call))
                let result = await tools.execute(call: call)
                await onEvent(.toolCompleted(callId: call.id, name: call.name, result: result))
                let toolMessage = AgentMessage(role: .tool,
                                               content: result.content,
                                               toolCallId: call.id,
                                               toolName: call.name,
                                               isFailure: result.isFailure)
                working.append(toolMessage)
                produced.append(toolMessage)
            }

            if round == config.maxToolRounds - 1 {
                let note = "已连续执行 \(config.maxToolRounds) 轮工具调用，为避免死循环这里停下了。可以补充说明后再试。"
                await onEvent(.note(note))
                produced.append(AgentMessage(role: .assistant, content: note, isFailure: true))
            }
        }
        return produced
    }

    // MARK: 单次流式请求

    private func streamOnce(history: [AgentMessage],
                            config: AgentConfig,
                            specs: [AgentToolSpec],
                            apiKey: String,
                            onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> AgentStreamAccumulator {
        let body = Self.requestBody(history: history, config: config, tools: specs, stream: true)
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = Data(try body.encodedText().utf8)
        } catch {
            throw AgentError.invalidResponse("请求体序列化失败：\(error.localizedDescription)")
        }

        let response: AgentHTTPStream
        do {
            response = try await transport.stream(request: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw AgentError.cancelled }
            throw AgentError.network(urlError.localizedDescription)
        } catch {
            throw AgentError.network(error.localizedDescription)
        }

        guard (200...299).contains(response.statusCode) else {
            // 错误响应是普通 JSON（不是 SSE），把 body 收全再翻译。
            var raw = Data()
            for try await chunk in response.chunks { raw.append(chunk) }
            let (message, code) = Self.parseErrorBody(raw)
            throw AgentError.http(status: response.statusCode, message: message, code: code)
        }

        var decoder = AgentSSEDecoder()
        var accumulator = AgentStreamAccumulator()

        func dispatch(_ events: [AgentStreamEvent]) async {
            for event in events {
                accumulator.ingest(event)
                switch event {
                case .reasoning(let text): await onEvent(.reasoningDelta(text))
                case .content(let text): await onEvent(.contentDelta(text))
                case .usage(let usage): await onEvent(.usage(usage))
                default: break
                }
            }
        }

        do {
            for try await chunk in response.chunks {
                try Task.checkCancellation()
                await dispatch(decoder.feed(chunk))
            }
            await dispatch(decoder.finish())
        } catch is CancellationError {
            throw AgentError.cancelled
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw AgentError.cancelled }
            // 已经流出一部分内容时不算彻底失败：保留已收到的部分，让上层展示。
            if accumulator.content.isEmpty && accumulator.toolCalls.isEmpty {
                throw AgentError.network(urlError.localizedDescription)
            }
            await onEvent(.note("连接中断，以下内容可能不完整：\(urlError.localizedDescription)"))
        } catch {
            if accumulator.content.isEmpty && accumulator.toolCalls.isEmpty {
                throw AgentError.network(error.localizedDescription)
            }
            await onEvent(.note("流读取中断：\(error.localizedDescription)"))
        }

        return accumulator
    }

    static func parseErrorBody(_ data: Data) -> (String?, String?) {
        if let env = try? AgentSSEDecoder.decoder.decode(WireErrorEnvelope.self, from: data),
           let err = env.error {
            return (err.message, err.code ?? err.type)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? nil : String(text.prefix(400)), nil)
    }
}

// MARK: - Mock 传输（smoke 用）

/// 把预设好的 SSE 文本按脚本回放，支持多轮（第 N 次请求返回第 N 段脚本），
/// 用于测"流式 → 工具调用 → 再流式 → 终答"整条链。
public final class AgentScriptedTransport: AgentTransport, @unchecked Sendable {
    public struct Step: Sendable {
        public let statusCode: Int
        /// 已经按任意位置切好的分片——刻意允许在 JSON 中间断开，用来验证跨 chunk 拼装。
        public let chunks: [String]
        public init(statusCode: Int = 200, chunks: [String]) {
            self.statusCode = statusCode
            self.chunks = chunks
        }
        public static func sse(_ body: String, splitEvery: Int = 0, statusCode: Int = 200) -> Step {
            guard splitEvery > 0 else { return Step(statusCode: statusCode, chunks: [body]) }
            var parts: [String] = []
            var current = ""
            for ch in body {
                current.append(ch)
                if current.count >= splitEvery { parts.append(current); current = "" }
            }
            if !current.isEmpty { parts.append(current) }
            return Step(statusCode: statusCode, chunks: parts)
        }
    }

    private var steps: [Step]
    private let lock = NSLock()
    public private(set) var capturedRequests: [Data] = []

    public init(steps: [Step]) { self.steps = steps }

    public func stream(request: URLRequest) async throws -> AgentHTTPStream {
        // 取脚本这一步是同步的，刻意抽成非 async 函数：在 async 上下文里直接
        // NSLock.lock() 在 Swift 6 语言模式下是错误（可能阻塞协作线程池）。
        let step = nextStep(capturing: request.httpBody ?? Data())

        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in step.chunks { continuation.yield(Data(chunk.utf8)) }
            continuation.finish()
        }
        return AgentHTTPStream(statusCode: step.statusCode, chunks: chunks)
    }

    private func nextStep(capturing body: Data) -> Step {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(body)
        guard !steps.isEmpty else {
            return Step(statusCode: 500, chunks: ["{\"error\":{\"message\":\"脚本已耗尽\"}}"])
        }
        return steps.removeFirst()
    }

    /// 最后一次请求体（测试断言请求形状用）。
    public func lastRequestJSON() -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        guard let data = capturedRequests.last else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func requestJSON(at index: Int) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        guard index < capturedRequests.count else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: capturedRequests[index])
    }
}
