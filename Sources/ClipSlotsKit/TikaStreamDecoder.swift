import Foundation

// MARK: - Tika CLI JSON 流解码
//
// v2.17.7 起 ClipSlots 支持把 AI 后端切到 Tika Agent。走的是本机
// `tikacli chat --json --auto-approve --agent-id <id>` 子进程；tikacli 会把
// Agent Runtime 的事件以 pretty-print JSON 对象串（不是单行 NDJSON）打到 stdout。
//
// 一份实测样本长这样（`⎯` 表示换行）：
//
//    {⎯
//      "type": "start",⎯
//      "chat_id": "...",⎯
//      "agent_detail": {⎯
//        "agent_id": "1509440157188",⎯
//        "agent_name": "default"⎯
//      }⎯
//    }⎯
//    {⎯
//      "type": "text-delta",⎯
//      "text": "你好"⎯
//    }⎯
//    ...
//
// **关键：不能按行解析**——每个对象都跨很多行，且字符串字段里可能出现原生 `\n`。
// 只有一种可靠的分帧方式：**逐字符、追踪字符串状态、按大括号深度切分**。
// 这个文件负责把子进程 stdout 的 String 增量喂进来，吐出一个个完整 JSON 帧；
// 再把帧解成 `TikaStreamEvent` 供上层驱动 UI。
//
// 本文件**不碰 Process、不碰 UI**，纯字符串状态机 + JSONSerialization。App 侧的
// TikaCLIService 负责起子进程、灌 stdout、收 stderr、超时——那些不能在 Kit 里测。
// Kit 里能测的（分帧、事件识别、累积器）在 smoke 里逐条断言。

// MARK: - 分帧器

/// 逐字符状态机：把 tikacli --json 的多对象 pretty-print 流按顶层 `{...}` 切成一份一份。
///
/// 关键不变量：
/// - 字符串状态里（引号之间）的 `{`/`}` **不计入**大括号计数；
/// - 反斜杠转义只在字符串里生效，一次吃掉下一个字符（防 `\"` 被误判为字符串结束）；
/// - 对象外的空白（换行/空格/tab）跳过；
/// - 一旦大括号从深度 1 回落到 0，把从开头到当前位置这段截出来作为一帧；
/// - 大括号从未打开就遇到非空白（例如 tikacli 未来打了行注释）→ 忽略那一段，等下一个 `{`。
///
/// 这个策略对 NDJSON、单行紧凑 JSON 也天然兼容——都是 `{...}` 的顶层序列而已。
public struct TikaJSONFramingDecoder {

    private var buffer: [UInt8] = []
    private var index = 0

    // 状态
    private var depth: Int = 0
    private var inString: Bool = false
    private var escapeNext: Bool = false
    /// 当前对象的起点（在 buffer 里的偏移）。depth 从 0 → 1 时记下来。
    private var currentStart: Int?

    public init() {}

    /// 灌入新的 stdout 分片，返回本次可以吐出的完整 JSON 帧（可能 0 到 N 帧）。
    public mutating func feed(_ chunk: String) -> [String] {
        feed(Data(chunk.utf8))
    }

    /// JSON 结构标记均为 ASCII。先按字节分帧，完整帧才解 UTF-8，避免多字节字符跨管道读取时损坏。
    /// 每个字节只检查一次，不能在循环里调用 String.count / index(startIndex, offsetBy:)。
    public mutating func feed(_ chunk: Data) -> [String] {
        // #region debug-point D:tika-framing-cost
        #if DEBUG
        let debugStart = CFAbsoluteTimeGetCurrent()
        defer { if ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_PERF"] == "1", CFAbsoluteTimeGetCurrent() - debugStart > 0.005 { var r = URLRequest(url: URL(string: "http://127.0.0.1:7787/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-stream-lag", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "D", "msg": "[DEBUG] tika framing cost", "data": ["chunkBytes": chunk.count, "pendingBytes": buffer.count, "milliseconds": (CFAbsoluteTimeGetCurrent() - debugStart) * 1000, "mainThread": Thread.isMainThread]]); URLSession.shared.dataTask(with: r).resume() } }
        #endif
        // #endregion
        buffer.append(contentsOf: chunk)
        var frames: [String] = []
        while index < buffer.count {
            let ch = buffer[index]
            if depth == 0 {
                if ch == 0x7B { currentStart = index; depth = 1 }
                index += 1
                continue
            }
            if inString {
                if escapeNext {
                    escapeNext = false
                } else if ch == 0x5C {
                    escapeNext = true
                } else if ch == 0x22 {
                    inString = false
                }
            } else {
                switch ch {
                case 0x22:
                    inString = true
                case 0x7B:
                    depth += 1
                case 0x7D:
                    depth -= 1
                    if depth == 0, let start = currentStart {
                        frames.append(String(decoding: buffer[start...index], as: UTF8.self))
                        currentStart = nil
                    }
                default:
                    break
                }
            }
            index += 1
        }
        // 一批只压缩一次；保留未闭合帧的字节与游标，不保留帧外垃圾。
        if let start = currentStart {
            if start > 0 { buffer.removeFirst(start); index -= start; currentStart = 0 }
        } else {
            buffer.removeAll(keepingCapacity: true)
            index = 0
        }
        return frames
    }

    /// 是否还有未闭合的对象在 buffer 里（用于超时判定）。
    public var hasPending: Bool { depth > 0 || !buffer.isEmpty }
}

// MARK: - 事件类型

/// tikacli chat --json 的事件流。**只保留我们真正需要的字段**——tikacli 未来加事件不算 breaking，
/// 未知 type 会走 `.unknown` 一律忽略。
public enum TikaStreamEvent: Equatable, Sendable {
    /// 会话开始。带出 agent 详情，让 UI 显示当前跑的是哪个 Agent / 什么模型。
    case start(chatId: String?, model: String?, agentId: String?, agentName: String?)
    /// 主文本增量（text-delta）。
    case textDelta(String)
    /// 主文本结束（text-end）——一段文本讲完了。tikacli 可能在同一轮里再来一段。
    case textEnd
    /// 思考链增量（reasoning-delta）。tikacli 目前不一定发；发了我们就透传。
    case reasoningDelta(String)
    /// 工具输入可用（Agent 想调 Tika 云端工具）——ClipSlots XML 契约里理论上不会出现，
    /// 出现了说明系统提示词没管住 Agent，App 层要提示"当前 Agent 尝试调用云端工具，已忽略"。
    case toolInputAvailable(toolName: String?, callId: String?)
    /// 工具输出可用（云端工具跑完了）——同样忽略，只做 UI 提示。
    case toolOutputAvailable(toolName: String?, callId: String?)
    /// 服务端错误（一般是配额/权限/超时）。
    case serverError(message: String)
    /// finish 事件：一次 chat 请求端到端结束。
    case finish(reason: String?)
    /// 心跳/未识别事件——上层可以选择显示为"Agent 思考中…"，或直接忽略。
    case ping
    case unknown(type: String)
}

/// 单帧 JSON → 事件。构造出错（不是合法 JSON）就返回 nil，让上层丢弃这一帧。
public enum TikaEventDecoder {

    public static func decode(frame: String) -> TikaStreamEvent? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(json: obj)
    }

    public static func decode(json: [String: Any]) -> TikaStreamEvent? {
        // tikacli 事件用两种 key 命名过：`type`（新）与 `event`（旧，某些版本）——都容忍。
        let type = (json["type"] as? String) ?? (json["event"] as? String) ?? ""

        switch type {
        case "start":
            let chatId = json["chat_id"] as? String
            let model = json["model"] as? String
            var agentId: String? = nil
            var agentName: String? = nil
            if let detail = json["agent_detail"] as? [String: Any] {
                agentId = detail["agent_id"] as? String ?? detail["agentId"] as? String
                agentName = detail["agent_name"] as? String ?? detail["agentName"] as? String
            }
            return .start(chatId: chatId, model: model, agentId: agentId, agentName: agentName)

        case "text-delta":
            // 有的版本字段叫 text，有的叫 delta——两个都试。
            let text = (json["text"] as? String) ?? (json["delta"] as? String) ?? ""
            // 空 delta 也发一次事件是无害的（累积器会拼空串），但没有字段就没必要发。
            if text.isEmpty && json["text"] == nil && json["delta"] == nil {
                return .unknown(type: type)
            }
            return .textDelta(text)

        case "text-end":
            return .textEnd

        case "reasoning-delta":
            let text = (json["text"] as? String) ?? (json["delta"] as? String) ?? ""
            return .reasoningDelta(text)

        case "tool-input-available":
            let name = json["tool_name"] as? String ?? json["toolName"] as? String
            let callId = json["tool_call_id"] as? String ?? json["callId"] as? String
            return .toolInputAvailable(toolName: name, callId: callId)

        case "tool-output-available":
            let name = json["tool_name"] as? String ?? json["toolName"] as? String
            let callId = json["tool_call_id"] as? String ?? json["callId"] as? String
            return .toolOutputAvailable(toolName: name, callId: callId)

        case "error", "server-error":
            let msg = (json["message"] as? String)
                ?? (json["error"] as? String)
                ?? "Tika 服务端未提供错误详情"
            return .serverError(message: msg)

        case "finish", "finish-reason", "done":
            let reason = json["reason"] as? String ?? json["finish_reason"] as? String
            return .finish(reason: reason)

        case "ping", "data-conversation-title", "sandbox-meta":
            return .ping

        case "":
            return nil

        default:
            return .unknown(type: type)
        }
    }
}

// MARK: - 助理消息累积器
//
// tikacli 事件流是「小片段」；上层 UI（AgentChatModel）想要的是「完整的一轮 assistant」：
//   - 主文本（可能由多段 text-delta ... text-end 拼成）
//   - 思考链（reasoning-delta，可能没有）
//   - 结束时机（finish 事件）
//
// 顺带承担一个「云端工具越权提示」职责：Tika Agent 云端 sandbox 里的 execute/shell/skill
// 我们**不希望**它调，但也没法禁——所以一旦看到 `tool-input-available` / `tool-output-available`，
// 附一段说明合并进 assistant 文本，方便用户在 UI 上看到"Agent 又想去云端跑东西，被我忽略了"。

public struct TikaAssistantAccumulator {
    public private(set) var text: String = ""
    public private(set) var reasoning: String = ""
    public private(set) var pendingCloudToolWarnings: [String] = []
    public private(set) var finished: Bool = false
    public private(set) var errorMessage: String?

    /// 本轮头部记录到的 start 事件信息（agent id / model）；给 UI 展示用。
    public private(set) var agentId: String?
    public private(set) var agentName: String?
    public private(set) var model: String?

    public init() {}

    public mutating func apply(_ event: TikaStreamEvent) {
        switch event {
        case .start(_, let model, let agentId, let agentName):
            self.model = model
            self.agentId = agentId
            self.agentName = agentName
        case .textDelta(let s):
            text.append(s)
        case .textEnd:
            // 语义边界，暂不用做啥；日后想在两段之间插入空行可以在这里做。
            break
        case .reasoningDelta(let s):
            reasoning.append(s)
        case .toolInputAvailable(let name, _):
            let label = name ?? "unknown"
            pendingCloudToolWarnings.append("Agent 尝试调用云端工具 `\(label)`（已忽略；ClipSlots 只识别 <clipslots-call> XML）。")
        case .toolOutputAvailable:
            // 已在 input 事件时提示过；output 不再重复提示。
            break
        case .serverError(let msg):
            errorMessage = msg
        case .finish:
            finished = true
        case .ping, .unknown:
            break
        }
    }

    /// 输出可读的 assistant 文本（合并原文 + 云端工具警告尾巴）。
    public func renderContent() -> String {
        guard !pendingCloudToolWarnings.isEmpty else { return text }
        let tail = pendingCloudToolWarnings.map { "⚠️ " + $0 }.joined(separator: "\n")
        return text.isEmpty ? tail : (text + "\n\n" + tail)
    }
}
