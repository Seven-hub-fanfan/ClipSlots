import Foundation

// MARK: - Tika CLI 后端
//
// v2.17.7 新加。用户可以在设置里把 AI 后端从 DeepSeek 切到 Tika：这个文件负责实现整条链。
//
// 与 AgentService（DeepSeek）的三条本质差异：
//
//   1. **传输不是 HTTPS**，是本机 `tikacli chat --agent-id <id> --json --auto-approve` 子进程。
//      认证由 tikacli 自己 (`tikacli auth login`) 管，App 端不持有任何凭据。
//   2. **工具调用不是 OpenAI tool_calls**。tikacli 云端 sandbox 与用户 Mac 隔离，
//      Agent 没法直接跑 clipslots。所以走"提示词软契约"：
//        Agent 输出 `<clipslots-call cmd="clipslots list --json"/>`
//        → App 拦截、白名单校验、本地跑 clipslots
//        → 把 stdout 塞回 `<clipslots-result>` XML 作为下一 user turn 发给 tikacli。
//      这个循环在这里完成，对外呈现的 `AgentRunEvent` 与 DeepSeek 完全一致。
//   3. **多轮历史用"每轮拼一次"策略**。tikacli 内部有 session cache，但为了让 `run()`
//      调用可重入（用户随时开新会话）、不依赖 tikacli 侧的 session 生命周期，
//      每次 App 层 `run()`：首轮加 `--new`，把整段 AgentChatModel history 拼成
//      "背景 + 当前问题"发给 tikacli；后续工具循环用同一 tikacli cached session
//      连续发 `<clipslots-result>` XML。
//
// **护栏**（顺序对应上面各点）：
//   - tikacli 子进程超时按 `TikaBackendConfig.perTurnTimeout` 走；触发就 SIGTERM 并当失败上报。
//   - Agent 输出里的 XML 强制过白名单（ClipSlotsCommandGuard），未白名单命令不执行，
//     直接回喂 `code="COMMAND_NOT_ALLOWED"`，让 Agent 自愈。
//   - 工具循环最多 `maxToolTurns` 轮，避免 Agent 死循环耗光调用额度。
//
// 这个文件里 **不写认证 / login / 密钥缓存**。tikacli 已经把 JWT 管好了，
// 让它自己处理是最稳的边界。

// MARK: - 错误

public enum TikaBackendError: LocalizedError {
    case cliNotFound(String)
    case notAuthenticated
    case processFailed(exit: Int32, stderr: String)
    case timedOut
    case emptyResponse
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let path):
            return "tikacli 未安装或不可执行（尝试路径：\(path)）。请先 `npm install -g @tt-tika/tika-cli`，或在设置里改路径。"
        case .notAuthenticated:
            return "tikacli 未登录。请在终端执行 `tikacli auth login`，浏览器授权后重试。"
        case .processFailed(let exit, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "tikacli 进程失败（exit=\(exit)）\(trimmed.isEmpty ? "" : "：\(trimmed)")"
        case .timedOut:
            return "tikacli 响应超时。可能是云端排队或网络问题，稍后重试；持续出现请检查企业网络。"
        case .emptyResponse:
            return "tikacli 无响应文本。可能是 Agent 只输出了工具调用没有正文（不常见），请再问一次。"
        case .protocolViolation(let m):
            return "Tika 协议异常：\(m)"
        }
    }
}

// MARK: - TikaCLIService

/// 与 `AgentService` 对等的 Tika 后端实现。**线程安全约束**：与 AgentService 一样按每次 `run()` 独立态处理，
/// 不共享跨 turn 状态；stop 通过 `Task.cancel()` 到达，本方法内部 spawn 的 Process 会在 cancel 时 terminate。
public final class TikaCLIService: NSObject, AgentBackend, @unchecked Sendable {

    public let config: TikaBackendConfig
    /// 用来执行 clipslots CLI 的本地进程 runner。默认走标准 `/usr/local/bin/clipslots`；smoke 可注入假 runner。
    private let localRunner: (String, [String]) async -> AgentProcessResult
    private let clipslotsCLIPath: String

    public init(config: TikaBackendConfig,
                clipslotsCLIPath: String = AgentBuiltinTools.defaultCLIPath,
                localRunner: ((String, [String]) async -> AgentProcessResult)? = nil) {
        self.config = config
        self.clipslotsCLIPath = clipslotsCLIPath
        self.localRunner = localRunner ?? { path, args in
            await AgentProcessRunner.run(executable: path, arguments: args, timeout: 30)
        }
        super.init()
    }

    // MARK: AgentBackend 协议

    @discardableResult
    public func run(history: [AgentMessage],
                    config sessionConfig: AgentConfig,
                    tools: AgentToolExecuting?,
                    onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        // 1. 先校验 tikacli 可执行
        guard FileManager.default.isExecutableFile(atPath: resolvedCLIPath) else {
            throw TikaBackendError.cliNotFound(resolvedCLIPath)
        }

        var produced: [AgentMessage] = []

        // 2. 首轮：把 history 拼成完整 primer 发过去，`--new` 起独立 session。
        //    只有最后一条 user 消息是当前问题，前面都是"背景"。
        let primer = renderPrimer(from: history, systemPrompt: config.supplementalSystemPrompt)
        // 每个工具轮都以 --new 启动，并把到目前为止的完整 transcript 重发。
        // tikacli 0.6.x 没有 --session-id；依赖它的全局 cached session 会让编辑页/画布页并发串话。
        // 自包含 transcript 稍多耗一点 token，但换来确定的会话隔离。
        var transcript = primer
        var totalTurns = 0

        // 3. 工具循环
        while totalTurns < config.maxToolTurns {
            try Task.checkCancellation()

            let outcome = try await runOneTurn(userMessage: transcript,
                                               onEvent: onEvent)
            totalTurns += 1

            // 3a. 收集 assistant 消息（附加 XML 警告尾巴）
            let assistantText = outcome.accumulator.renderContent()
            let assistantMsg = AgentMessage(role: .assistant,
                                            content: assistantText,
                                            reasoning: outcome.accumulator.reasoning.isEmpty ? nil : outcome.accumulator.reasoning)
            await onEvent(.assistantCompleted(assistantMsg))
            produced.append(assistantMsg)

            // 3b. 扫 XML，看是否需要继续
            let extraction = ClipSlotsToolScanner.scan(outcome.accumulator.text)
            if extraction.isEmpty {
                // 没工具调用，本次 run 结束
                return produced
            }

            // 3c. 逐个执行（提示词要求一次一个，但宽容支持多个）
            var resultFragments: [String] = []
            for item in extraction.items {
                switch item.payload {
                case .ok(let call):
                    let toolCall = AgentToolCall(
                        id: UUID().uuidString,
                        name: "clipslots_" + call.subcommand.replacingOccurrences(of: "-", with: "_"),
                        argumentsJSON: "{\"argv\":\(argvToJSON(call.argv))}")
                    await onEvent(.toolStarted(toolCall))

                    let exec = await localRunner(clipslotsCLIPath, call.argv)
                    let ok = exec.succeeded
                    let cliResult = ClipSlotsToolExecutionResult(
                        ok: ok,
                        code: parseErrorCode(from: exec.stdout, exitCode: exec.exitCode, timedOut: exec.timedOut),
                        exitCode: exec.exitCode,
                        stdout: exec.stdout,
                        stderr: exec.stderr,
                        timedOut: exec.timedOut)

                    let envelope = ClipSlotsResultEnvelope.render(cliResult, command: call.rawCommand)
                    resultFragments.append(envelope)

                    let uiResult = AgentToolResult(
                        content: exec.stdout.isEmpty ? exec.stderr : exec.stdout,
                        isFailure: !ok,
                        summary: ok ? "OK" : "FAIL(\(cliResult.code))")
                    await onEvent(.toolCompleted(callId: toolCall.id, name: toolCall.name, result: uiResult))

                    // 把 tool 消息也放进 produced（AgentChatModel 会把它显示成"工具行"）
                    produced.append(AgentMessage(role: .tool,
                                                 content: exec.stdout,
                                                 toolCallId: toolCall.id,
                                                 toolName: toolCall.name,
                                                 isFailure: !ok))

                case .error(let err):
                    let rejection = ClipSlotsToolExecutionResult.rejection(err)
                    let envelope = ClipSlotsResultEnvelope.render(rejection, command: err.rawCommand)
                    resultFragments.append(envelope)

                    // 也上报为一次失败的 tool call，方便用户看到"Agent 编了个 rm，被拒了"
                    let toolCall = AgentToolCall(id: UUID().uuidString,
                                                 name: "clipslots_rejected",
                                                 argumentsJSON: "{}")
                    await onEvent(.toolStarted(toolCall))
                    let failedResult = AgentToolResult.failure(err.message, code: err.code)
                    await onEvent(.toolCompleted(callId: toolCall.id, name: toolCall.name, result: failedResult))
                    produced.append(AgentMessage(role: .tool,
                                                 content: err.message,
                                                 toolCallId: toolCall.id,
                                                 toolName: toolCall.name,
                                                 isFailure: true))
                }
            }

            // 3d. tikacli 没有显式 session-id 参数；把完整过程拼进下一个独立 turn，避免
            // 编辑页/画布页同时对话时争抢 CLI 的“最近会话”缓存。
            transcript += "\n\n【Agent 上一步输出】\n" + outcome.accumulator.text
            transcript += "\n\n【本地工具执行结果】\n" + resultFragments.joined(separator: "\n\n")
        }

        await onEvent(.note("已达到工具调用轮上限（\(config.maxToolTurns) 轮），本次 Tika 对话结束。"))
        return produced
    }

    // MARK: 私有

    private var resolvedCLIPath: String {
        // 用户可能只填了 "tikacli"，PATH 里也许没有——尝试 `/usr/local/bin/tikacli`、~/bin 常见位置。
        let raw = config.cliPath
        if raw.hasPrefix("/") { return raw }
        let candidates = [
            "/usr/local/bin/\(raw)",
            NSString(string: "~/bin/node-v22/bin/\(raw)").expandingTildeInPath,
            NSString(string: "~/bin/\(raw)").expandingTildeInPath,
            "/opt/homebrew/bin/\(raw)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return raw
    }

    /// 把 AgentChatModel 的完整 history 序列化成一段自然语言 primer。
    /// - 最后一条 user 消息 = 当前问题（重点标出）
    /// - 之前的都作为"对话历史，仅作背景"
    /// - System prompt 单独放最前（Tika Agent 有自己的 instructions；这里 systemPrompt 是"追加要求"）
    private func renderPrimer(from history: [AgentMessage], systemPrompt: String) -> String {
        // 找最后一条 user 消息作为"当前问题"
        var currentQuestion: String = ""
        var priorTurns: [AgentMessage] = []

        // system 由专用 supplementalSystemPrompt 承载；user / assistant / tool 都保留，
        // 否则用户下一轮问“刚才查到了什么”时会丢失上一轮本地 CLI 结果。
        let filtered = history.filter { $0.role != .system }
        for (idx, msg) in filtered.enumerated() {
            if idx == filtered.count - 1 && msg.role == .user {
                currentQuestion = msg.content
            } else {
                priorTurns.append(msg)
            }
        }
        if currentQuestion.isEmpty, let last = filtered.last {
            currentQuestion = last.content
            priorTurns = Array(filtered.dropLast())
        }

        var parts: [String] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("【补充系统指示（来自 App 端配置，与 Tika Agent 的 instructions 一起遵守）】\n" + systemPrompt)
        }
        if !priorTurns.isEmpty {
            var lines: [String] = []
            for m in priorTurns {
                switch m.role {
                case .user:     lines.append("用户：" + m.content)
                case .assistant: lines.append("Agent：" + m.content)
                case .tool: lines.append("工具 \(m.toolName ?? "clipslots")：" + m.content)
                default: break
                }
            }
            parts.append("【对话历史，仅作背景】\n" + lines.joined(separator: "\n"))
        }
        parts.append("【用户当前问题】\n" + currentQuestion)
        return parts.joined(separator: "\n\n")
    }

    /// 单轮 tikacli chat 运行结果。
    private struct TurnOutcome {
        let accumulator: TikaAssistantAccumulator
    }

    /// 起一个 tikacli chat 进程，逐块读 stdout，累积到 accumulator。
    ///
    /// 这里不用 `readabilityHandler + readDataToEndOfFile`：两者混用时，进程退出边界可能同时
    /// 消费同一段尾帧；也不用“先等退出再读”，否则输出超过 pipe buffer 会死锁。两个 detached
    /// reader 从进程启动前就开始 drain，EOF 后才返回，因此既保留流式事件，也不会漏最后一帧。
    private func runOneTurn(userMessage: String,
                            onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> TurnOutcome {
        var args: [String] = ["chat", "--json"]
        if config.autoApprove { args.append("--auto-approve") }
        // 每轮独立会话，连续性由自包含 transcript 保证；不读写 tikacli 全局 cached session。
        args.append("--new")
        if let agentId = config.agentId, !agentId.isEmpty { args += ["--agent-id", agentId] }
        if let spaceId = config.spaceId, !spaceId.isEmpty { args += ["--space-id", spaceId] }
        args.append(userMessage)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedCLIPath)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let box = TurnBox()
        let stdoutReader = Task.detached(priority: .userInitiated) {
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                await box.ingest(String(decoding: data, as: UTF8.self), onEvent: onEvent)
            }
        }
        let stderrReader = Task.detached(priority: .utility) {
            while true {
                let data = stderr.fileHandleForReading.availableData
                if data.isEmpty { break }
                await box.appendStderr(String(decoding: data, as: UTF8.self))
            }
        }

        let waiter = TikaProcessWaiter(process: process, timeout: config.perTurnTimeout)
        do {
            try await withTaskCancellationHandler {
                try await waiter.runAndWait {
                    // Process fork 后父进程不再写 pipe；关闭父写端，reader 才能在子进程结束时看到 EOF。
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                }
            } onCancel: {
                waiter.cancel()
            }
        } catch {
            // 启动失败时没有子进程替我们关闭写端；主动关掉，才能让两个 reader 收到 EOF。
            // 超时/取消时 terminate/SIGKILL 会关闭子进程持有的写端。
            if !process.isRunning {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
            }
            _ = await stdoutReader.result
            _ = await stderrReader.result
            throw error
        }

        _ = await stdoutReader.result
        _ = await stderrReader.result

        let exitCode = process.terminationStatus
        let acc = await box.snapshot()
        let stderrText = await box.snapshotStderr()

        if exitCode != 0 && stderrText.lowercased().contains("not authenticated") {
            throw TikaBackendError.notAuthenticated
        }
        if exitCode != 0 && acc.text.isEmpty {
            throw TikaBackendError.processFailed(exit: exitCode, stderr: stderrText)
        }
        return TurnOutcome(accumulator: acc)
    }

    private func argvToJSON(_ argv: [String]) -> String {
        // 简单的 JSON 数组序列化——只有字符串，用 JSONSerialization。
        let data = (try? JSONSerialization.data(withJSONObject: argv)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func parseErrorCode(from stdout: String, exitCode: Int32, timedOut: Bool) -> String {
        if timedOut { return "TIMEOUT" }
        if exitCode == 0 { return "" }
        // clipslots CLI 的失败 stdout 是 `{"ok":false,"error_code":"..."}`
        if let data = stdout.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let code = obj["error_code"] as? String {
            return code
        }
        return "PROCESS_FAILED"
    }
}

// MARK: - Process 等待 / 超时 / 取消

/// `Process.terminationHandler` 必须在 `run()` 之前安装，否则极短命令会出现“先退出、后挂 handler”
/// 的竞态。这个 gate 还把超时与 Task cancellation 收敛成一次性 completion。
private final class TikaProcessWaiter: @unchecked Sendable {
    private let process: Process
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(process: Process, timeout: TimeInterval) {
        self.process = process
        self.timeout = max(0.1, timeout)
    }

    func runAndWait(onStarted: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            process.terminationHandler = { [weak self] _ in self?.finish(.success(())) }
            do {
                try process.run()
                onStarted()
            } catch {
                finish(.failure(TikaBackendError.cliNotFound(process.executableURL?.path ?? "tikacli")))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                if self.finish(.failure(TikaBackendError.timedOut)) { self.stopProcess() }
            }
        }
    }

    func cancel() {
        if finish(.failure(CancellationError())) { stopProcess() }
    }

    @discardableResult
    private func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    private func stopProcess() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

// MARK: - 每轮子进程读写的并发盒

/// 用来把 stdout 的多线程回调收敛到 actor 里，累积 JSON 帧、发事件。
private actor TurnBox {
    private var decoder = TikaJSONFramingDecoder()
    private var accumulator = TikaAssistantAccumulator()
    private var stderrBuffer = ""

    func ingest(_ chunk: String,
                onEvent: @Sendable (AgentRunEvent) async -> Void) async {
        let frames = decoder.feed(chunk)
        for frame in frames {
            guard let event = TikaEventDecoder.decode(frame: frame) else { continue }
            switch event {
            case .textDelta(let s):
                accumulator.apply(event)
                await onEvent(.contentDelta(s))
            case .reasoningDelta(let s):
                accumulator.apply(event)
                await onEvent(.reasoningDelta(s))
            default:
                accumulator.apply(event)
            }
        }
    }

    func appendStderr(_ s: String) {
        stderrBuffer.append(s)
    }

    func snapshot() -> TikaAssistantAccumulator { accumulator }
    func snapshotStderr() -> String { stderrBuffer }
}
