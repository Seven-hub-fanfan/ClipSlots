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
//   3. **多轮历史用"每轮拼一次"策略**。每轮都用 `--new` 加自包含 transcript，
//      避免编辑页/画布页争抢 tikacli 的全局 cached session。
//
// **护栏**（顺序对应上面各点）：
//   - stdout 空闲超时按 `perTurnTimeout` 走，活跃请求另受 `maxTurnDuration` 硬上限保护。
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
    case turnDurationExceeded
    case serverError(String)
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
            return "tikacli 长时间没有新的输出，已停止等待。请稍后重试；若已有工具执行结果，请先核对进度再继续。"
        case .turnDurationExceeded:
            return "tikacli 本轮持续时间已达上限，已停止等待。请缩小本次任务范围后继续。"
        case .serverError(let message):
            return "Tika 服务返回错误：\(message)"
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
        let primer = renderPrimer(from: history, systemPrompt: config.supplementalSystemPrompt
            + (sessionConfig.canvasPreviewOnly ? "\n" + sessionConfig.systemPrompt : ""))
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

            try Task.checkCancellation()
            // 先分配稳定的工具 ID，完成后历史与中断恢复才能按 assistant/tool 配对。
            let extraction = ClipSlotsToolScanner.scan(outcome.accumulator.text)
            let toolCalls = extraction.items.map { item -> AgentToolCall in
                switch item.payload {
                case .ok(let call):
                    return AgentToolCall(id: UUID().uuidString,
                        name: "clipslots_" + call.subcommand.replacingOccurrences(of: "-", with: "_"),
                        argumentsJSON: "{\"argv\":\(argvToJSON(call.argv))}")
                case .error:
                    return AgentToolCall(id: UUID().uuidString, name: "clipslots_rejected", argumentsJSON: "{}")
                }
            }
            // 3a. 收集 assistant 消息（附加 XML 警告尾巴）
            let assistantText = outcome.accumulator.renderContent()
            let assistantMsg = AgentMessage(role: .assistant,
                                            content: assistantText,
                                            reasoning: outcome.accumulator.reasoning.isEmpty ? nil : outcome.accumulator.reasoning,
                                            toolCalls: toolCalls)
            await onEvent(.assistantCompleted(assistantMsg))
            produced.append(assistantMsg)

            // 3b. 扫 XML，看是否需要继续
            if extraction.isEmpty {
                // 没工具调用，本次 run 结束
                return produced
            }

            // 3c. 同一轮可包含多条独立命令；顺序执行、逐条回报并检查取消。
            var resultFragments: [String] = []
            for (item, toolCall) in zip(extraction.items, toolCalls) {
                try Task.checkCancellation()
                switch item.payload {
                case .ok(let call):
                    await onEvent(.toolStarted(toolCall))
                    try Task.checkCancellation()
                    if sessionConfig.canvasPreviewOnly {
                        let rejection = AgentToolResult.failure("请只返回待预览的正文，用户确认后才会应用到画布。", code: "PREVIEW_REQUIRED")
                        await onEvent(.toolCompleted(callId: toolCall.id, name: toolCall.name, result: rejection))
                        produced.append(AgentMessage(role: .tool, content: rejection.content,
                            toolCallId: toolCall.id, toolName: toolCall.name, isFailure: true))
                        resultFragments.append(rejection.content)
                        continue
                    }
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
                currentQuestion = msg.wireContent
            } else {
                priorTurns.append(msg)
            }
        }
        if currentQuestion.isEmpty, let last = filtered.last {
            currentQuestion = last.wireContent
            priorTurns = Array(filtered.dropLast())
        }

        var parts: [String] = ["""
        【ClipSlots 本地工具协议】
        本机工具只能在正文中输出 <clipslots-call cmd="clipslots 子命令 参数"/>，等待本地结果后再确认完成。
        不要用云端 shell/skill 读取本机文件或查操作规范。命令默认输出JSON，不添加 --json，不使用管道或脚本。
        一组最多10个槽位，每页最多10组；31个独立序号应分到4组，槽位号始终1..10。
        create-page "页名" --group-name "首组名" 同时创建首组；create-group "组名" --page-name "页名" 建后续组。
        write <槽位> --text "正文" --page-name "页名" --group "组名" --if-empty 写入空槽。
        list --page-name "页名" --group "组名" 查看槽位；groups --page-name "页名" 查看组；pages 查看页面。
        cmd属性内部的双引号用 &quot; 转义。同页不同槽位的独立写入可在同一回复输出多条XML（建议每批≤32条）。
        创建页/组等依赖操作先等成功结果，再输出依赖它的写入；每条命令都有独立结果，失败必须如实说明。
        新任务先查必要状态；同一任务收到成功结果后不重复建页、建组或逐槽回读，独立操作尽量合批。
        """]
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("【补充系统指示（来自 App 端配置，与 Tika Agent 的 instructions 一起遵守）】\n" + systemPrompt)
        }
        if !priorTurns.isEmpty {
            var lines: [String] = []
            for m in priorTurns {
                switch m.role {
                case .user:     lines.append("用户：" + m.wireContent)
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
        let waiter = TikaProcessWaiter(process: process, timeout: config.perTurnTimeout,
                                      maxDuration: config.maxTurnDuration)
        // #region debug-point A:turn-start
        #if DEBUG
        await box.debugReport("turn-start", extra: ["promptBytes": userMessage.utf8.count, "timeout": config.perTurnTimeout])
        #endif
        // #endregion
        let stdoutReader = Task.detached(priority: .userInitiated) {
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                waiter.receivedOutput()
                if await box.ingest(data, onEvent: onEvent) { waiter.streamCompleted() }
            }
        }
        let stderrReader = Task.detached(priority: .utility) {
            while true {
                let data = stderr.fileHandleForReading.availableData
                if data.isEmpty { break }
                await box.appendStderr(String(decoding: data, as: UTF8.self))
            }
        }

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
            // #region debug-point A:turn-failure
            #if DEBUG
            await box.debugReport("turn-failure", extra: ["errorType": String(describing: type(of: error)), "timedOut": (error as? TikaBackendError).map { if case .timedOut = $0 { return true }; return false } ?? false])
            #endif
            // #endregion
            throw error
        }

        _ = await stdoutReader.result
        _ = await stderrReader.result

        let exitCode = process.terminationStatus
        let acc = await box.snapshot()
        let stderrText = await box.snapshotStderr()
        // #region debug-point C:turn-exit
        #if DEBUG
        await box.debugReport("turn-exit", extra: ["exitCode": exitCode])
        #endif
        // #endregion

        if let message = acc.errorMessage { throw TikaBackendError.serverError(message) }
        if exitCode != 0 && stderrText.lowercased().contains("not authenticated") {
            throw TikaBackendError.notAuthenticated
        }
        if exitCode != 0 && !acc.finished {
            throw TikaBackendError.processFailed(exit: exitCode, stderr: stderrText)
        }
        guard acc.finished else {
            throw TikaBackendError.protocolViolation("输出流在完成信号前结束，本轮工具未执行。")
        }
        guard !acc.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TikaBackendError.emptyResponse
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
    private let maxDuration: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completion: Result<Void, Error>?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var lastOutputAt = ProcessInfo.processInfo.systemUptime
    private var streamEnded = false

    init(process: Process, timeout: TimeInterval, maxDuration: TimeInterval) {
        self.process = process
        self.timeout = max(0.1, timeout)
        self.maxDuration = max(0.1, maxDuration)
    }

    func runAndWait(onStarted: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // cancel 可能发生在 continuation 安装前。保留完成结果，既不丢唤醒也不再启动进程。
            if let completion {
                lock.unlock()
                continuation.resume(with: completion)
                return
            }
            self.continuation = continuation
            process.terminationHandler = { [weak self] _ in self?.finish(.success(())) }
            do {
                // 启动与取消串行化，避免 cancel 检查到尚未运行、随后却启动了进程。
                try process.run()
                startedAt = ProcessInfo.processInfo.systemUptime
                lastOutputAt = startedAt
                lock.unlock()
                onStarted()
            } catch {
                lock.unlock()
                finish(.failure(TikaBackendError.cliNotFound(process.executableURL?.path ?? "tikacli")))
                return
            }

            scheduleDeadlineCheck(after: min(timeout, maxDuration))
        }
    }

    func receivedOutput() {
        lock.lock()
        lastOutputAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// finish/error 已表示本轮结束。给 CLI 短暂退出时间，再回收挂起的进程；
    /// 仍通过 terminationHandler 完成等待，并 drain 两个 pipe 保留尾帧。
    func streamCompleted() {
        lock.lock()
        guard completion == nil, !streamEnded else { lock.unlock(); return }
        streamEnded = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.stopProcess()
        }
    }

    private func scheduleDeadlineCheck(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.checkDeadline()
        }
    }

    private func checkDeadline() {
        lock.lock()
        guard completion == nil, !streamEnded else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let idleRemaining = timeout - (now - lastOutputAt)
        let totalRemaining = maxDuration - (now - startedAt)
        lock.unlock()
        if totalRemaining <= 0 {
            if finish(.failure(TikaBackendError.turnDurationExceeded)) { stopProcess() }
        } else if idleRemaining <= 0 {
            if finish(.failure(TikaBackendError.timedOut)) { stopProcess() }
        } else {
            // 输出只更新时间戳，不为每个token创建新timer。
            scheduleDeadlineCheck(after: min(idleRemaining, totalRemaining))
        }
    }

    func cancel() {
        if finish(.failure(CancellationError())) { stopProcess() }
    }

    @discardableResult
    private func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard completion == nil else { lock.unlock(); return false }
        completion = result
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

    // #region debug-point A:stream-observation
    #if DEBUG
    private let debugStart = ProcessInfo.processInfo.systemUptime
    private let debugTrace = UUID().uuidString
    private var debugLastChunk: Double = 0
    private var debugBytes = 0
    private var debugEvents = 0
    func debugReport(_ phase: String, extra: [String: Any] = [:]) {
        if ProcessInfo.processInfo.environment["CLIPSLOTS_TIKA_DEBUG"] == "1" { var r = URLRequest(url: URL(string: ProcessInfo.processInfo.environment["DEBUG_SERVER_URL"] ?? "http://127.0.0.1:7788/event")!); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "tika-batch-timeout", "runId": ProcessInfo.processInfo.environment["TIKA_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A/B/C", "traceId": debugTrace, "msg": "[DEBUG] " + phase, "data": ["elapsed": ProcessInfo.processInfo.systemUptime - debugStart, "lastChunkAt": debugLastChunk, "bytes": debugBytes, "events": debugEvents, "textBytes": accumulator.text.utf8.count, "reasoningBytes": accumulator.reasoning.utf8.count, "finished": accumulator.finished, "serverError": accumulator.errorMessage != nil].merging(extra) { _, new in new }]); URLSession.shared.dataTask(with: r).resume() }
    }
    #endif
    // #endregion

    func ingest(_ chunk: Data,
                onEvent: @Sendable (AgentRunEvent) async -> Void) async -> Bool {
        // #region debug-point A:stream-observation
        #if DEBUG
        debugLastChunk = ProcessInfo.processInfo.systemUptime - debugStart
        debugBytes += chunk.count
        #endif
        // #endregion
        let frames = decoder.feed(chunk)
        for frame in frames {
            guard let event = TikaEventDecoder.decode(frame: frame) else { continue }
            // #region debug-point C:stream-terminal
            #if DEBUG
            debugEvents += 1
            switch event {
            case .finish: debugReport("finish-event")
            case .serverError: debugReport("server-error-event")
            case .toolInputAvailable: debugReport("cloud-tool-event")
            default: break
            }
            #endif
            // #endregion
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
        return accumulator.finished || accumulator.errorMessage != nil
    }

    func appendStderr(_ s: String) {
        stderrBuffer.append(s)
    }

    func snapshot() -> TikaAssistantAccumulator { accumulator }
    func snapshotStderr() -> String { stderrBuffer }
}
