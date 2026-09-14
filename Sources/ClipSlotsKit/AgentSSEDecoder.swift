import Foundation

// MARK: - SSE 解码
//
// DeepSeek 的流式响应是 OpenAI 兼容的 text/event-stream：
//
//   data: {"choices":[{"delta":{"reasoning_content":"嗯"},"index":0}]}
//   data: {"choices":[{"delta":{"content":"你"},"index":0}]}
//   data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}
//   data: [DONE]
//
// 看着简单，但真正会咬人的地方有四个，全都在这一个类型里处理掉：
//
//   1. **分块不按行对齐**。URLSession 给的是 TCP 字节块，一个 chunk 可能在
//      `"cont` 中间断开。所以必须自己维护未完成行的缓冲区，绝不能对单个 chunk
//      直接 `split(separator: "\n")` 后全部解析。
//   2. **心跳与注释行**。SSE 允许以 `:` 开头的注释行做 keep-alive，还可能出现
//      空行分隔和 `event:` / `id:` 字段。非 `data:` 的行必须静默跳过。
//   3. **tool_calls 是增量拼装的**。首个 delta 带 id + name + 空 arguments，
//      后续 delta 只带 index 和 arguments 片段。谁都不能假设一个 delta 就是完整调用。
//   4. **流中途可能来错误对象**。鉴权过期/余额不足在流已经开始后才暴露时，
//      服务端会直接在 data 里推 `{"error": {...}}`，不能当普通 chunk 忽略。
//
// 这个 decoder 是纯值语义、无网络依赖的，因此可以被 smoke 测试直接喂字符串。

public struct AgentSSEDecoder {
    /// 跨 chunk 的残行缓冲。
    private var pending = ""

    public init() {}

    /// 喂入一段原始字节（可以是任意切分位置），返回本次能确定解析出的事件。
    public mutating func feed(_ data: Data) -> [AgentStreamEvent] {
        feed(String(decoding: data, as: UTF8.self))
    }

    public mutating func feed(_ text: String) -> [AgentStreamEvent] {
        // CRLF 必须先归一成 LF，这不是"顺手做的整洁事"，是必须做的事：
        // Swift 的 Character 是字素簇，`"\r\n"` 是**一个** Character 且不等于 `"\n"`，
        // 所以 `firstIndex(of: "\n")` 在 CRLF 流上永远找不到换行——所有内容会一直
        // 堆在 pending 里，直到 finish() 才被当成一整行解析（然后解析失败）。
        // 表现是"Agent 一个字都不吐"，而且日志里毫无异常。DeepSeek 目前发 LF，
        // 但中间任何代理/网关改写成 CRLF 就会踩到，所以在入口就抹平。
        // 归一化作用在 pending 整体而非本次 text 上：chunk 边界可能正好切在 \r 和 \n 之间。
        pending += text
        pending = pending.replacingOccurrences(of: "\r\n", with: "\n")
        var events: [AgentStreamEvent] = []

        // 只处理已经出现换行的完整行，剩下的留在 pending 等下一个 chunk。
        while let newlineIndex = pending.firstIndex(of: "\n") {
            let rawLine = String(pending[pending.startIndex..<newlineIndex])
            pending = String(pending[pending.index(after: newlineIndex)...])
            if let parsed = Self.parseLine(rawLine) {
                events.append(contentsOf: parsed)
            }
        }
        return events
    }

    /// 流结束时调用：把最后一行没有换行结尾的残留也解出来。
    public mutating func finish() -> [AgentStreamEvent] {
        let rest = pending
        pending = ""
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Self.parseLine(rest) ?? []
    }

    // MARK: 单行解析

    static func parseLine(_ rawLine: String) -> [AgentStreamEvent]? {
        // \r\n 结尾（HTTP 常见）要先剥掉，否则 `[DONE]\r` 匹配不上。
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }          // 事件分隔空行
        if trimmed.hasPrefix(":") { return nil }   // keep-alive 注释
        guard trimmed.hasPrefix("data:") else { return nil } // event:/id:/retry: 一律忽略

        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return nil }
        if payload == "[DONE]" { return [.done] }

        guard let data = payload.data(using: .utf8) else { return nil }

        // 先看是不是错误对象——错误必须优先于 chunk 解析，
        // 因为 error 载荷里没有 choices，按 chunk 解会变成"空事件"被吞掉。
        if let err = try? Self.decoder.decode(WireErrorEnvelope.self, from: data), let e = err.error {
            return [.serverError(message: e.message ?? "上游返回未描述的错误", code: e.code)]
        }

        guard let chunk = try? Self.decoder.decode(WireChunk.self, from: data) else {
            // 无法识别的 data 行不炸流：宁可少一个 token，也不要让整轮对话失败。
            return nil
        }
        return chunk.events()
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - 流事件

public enum AgentStreamEvent: Equatable, Sendable {
    /// 思维链增量（DeepSeek 的 `reasoning_content`）。
    case reasoning(String)
    /// 正文增量。
    case content(String)
    /// 工具调用增量：同一个 index 的多次事件需要拼接 argumentsDelta。
    case toolCall(index: Int, id: String?, name: String?, argumentsDelta: String?)
    case finish(reason: String?)
    case usage(AgentUsage)
    case serverError(message: String, code: String?)
    case done
}

public struct AgentUsage: Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let cachedTokens: Int?

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int, cachedTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
    }
}

// MARK: - 线格式（仅解码用，不对外暴露）

struct WireChunk: Decodable {
    struct Fn: Decodable {
        let name: String?
        let arguments: String?
    }
    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let type: String?
        let function: Fn?
    }
    struct Delta: Decodable {
        let role: String?
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCallDelta]?
    }
    struct Choice: Decodable {
        let index: Int?
        let delta: Delta?
        let finishReason: String?
    }
    struct Usage: Decodable {
        struct Details: Decodable { let cachedTokens: Int? }
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let promptCacheHitTokens: Int?
        let promptTokensDetails: Details?
    }

    let choices: [Choice]?
    let usage: Usage?

    func events() -> [AgentStreamEvent] {
        var out: [AgentStreamEvent] = []
        for choice in choices ?? [] {
            if let delta = choice.delta {
                // 顺序很关键：先思考再正文。DeepSeek 保证 reasoning 先于 content 结束，
                // 但同一个 chunk 里两者都非空时（切换的那一帧）也必须保持这个顺序，
                // 否则 UI 上会出现"正文里混进最后一句思考"。
                if let r = delta.reasoningContent, !r.isEmpty { out.append(.reasoning(r)) }
                if let c = delta.content, !c.isEmpty { out.append(.content(c)) }
                for tc in delta.toolCalls ?? [] {
                    out.append(.toolCall(index: tc.index ?? 0,
                                         id: tc.id,
                                         name: tc.function?.name,
                                         argumentsDelta: tc.function?.arguments))
                }
            }
            if let reason = choice.finishReason, !reason.isEmpty {
                out.append(.finish(reason: reason))
            }
        }
        if let u = usage {
            out.append(.usage(AgentUsage(promptTokens: u.promptTokens ?? 0,
                                         completionTokens: u.completionTokens ?? 0,
                                         totalTokens: u.totalTokens ?? 0,
                                         cachedTokens: u.promptCacheHitTokens ?? u.promptTokensDetails?.cachedTokens)))
        }
        return out
    }
}

struct WireErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
        let type: String?
        let code: String?

        // code 在 DeepSeek/OpenAI 之间既可能是字符串也可能是数字，两种都吃。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            if let s = try? c.decodeIfPresent(String.self, forKey: .code) { code = s }
            else if let i = try? c.decodeIfPresent(Int.self, forKey: .code) { code = String(i) }
            else { code = nil }
        }
        enum CodingKeys: String, CodingKey { case message, type, code }
    }
    let error: Payload?
}

// MARK: - 流累积器
//
// 事件流 → 一条完整 assistant 消息。单独抽出来的理由：工具调用的拼装逻辑
// （按 index 归并、name 只在首帧出现、arguments 分片）是最容易写错也最值得测的部分，
// 让它脱离网络单独可测。

public struct AgentStreamAccumulator {
    public private(set) var content = ""
    public private(set) var reasoning = ""
    public private(set) var finishReason: String?
    public private(set) var usage: AgentUsage?
    public private(set) var serverError: (message: String, code: String?)?

    /// 按 index 存放拼装中的工具调用。用字典而不是数组：服务端不保证 index 从 0 连续。
    private var partialToolCalls: [Int: (id: String, name: String, args: String)] = [:]

    public init() {}

    public mutating func ingest(_ event: AgentStreamEvent) {
        switch event {
        case .reasoning(let r): reasoning += r
        case .content(let c): content += c
        case .toolCall(let index, let id, let name, let argsDelta):
            if partialToolCalls[index] == nil {
                partialToolCalls[index] = (id: "", name: "", args: "")
            }
            if let id, !id.isEmpty { partialToolCalls[index]?.id = id }
            if let name, !name.isEmpty { partialToolCalls[index]?.name += name }
            if let argsDelta, !argsDelta.isEmpty { partialToolCalls[index]?.args += argsDelta }
        case .finish(let reason): finishReason = reason
        case .usage(let u): usage = u
        case .serverError(let m, let c): serverError = (m, c)
        case .done: break
        }
    }

    public var toolCalls: [AgentToolCall] {
        // 按 index 排序，不按到达顺序：index 是服务端给的权威次序，
        // 而到达顺序在并行工具调用下不保证（先收到 index 1 的首帧完全合法）。
        // 顺序错了不会报错，只会让"先建组再写槽"这类有依赖的调用被反着执行。
        partialToolCalls.keys.sorted().compactMap { index in
            guard let p = partialToolCalls[index], !p.name.isEmpty else { return nil }
            // id 缺失时兜一个：后续 role=tool 消息必须带 tool_call_id，
            // 否则上游 400。宁可自造也不能空。
            let id = p.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : p.id
            return AgentToolCall(id: id, name: p.name, argumentsJSON: p.args)
        }
    }

    /// 组装成可以直接追加进历史、也可以直接回传给上游的 assistant 消息。
    public func assistantMessage() -> AgentMessage {
        AgentMessage(role: .assistant,
                     content: content,
                     reasoning: reasoning.isEmpty ? nil : reasoning,
                     toolCalls: toolCalls)
    }
}
