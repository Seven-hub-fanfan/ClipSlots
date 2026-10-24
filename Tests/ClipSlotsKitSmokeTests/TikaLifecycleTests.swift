import Foundation
import ClipSlotsKit

/// Real subprocesses exercise the lifecycle; local tool effects use mocks or an isolated store.
func runTikaLifecycleTests(_ t: TestRunner) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tika-lifecycle-\(UUID())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func cli(_ name: String, _ body: String) -> String {
        let file = dir.appendingPathComponent(name)
        try! Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
    // Allow native subprocess startup on a busy desktop. The active fixture
    // still streams for longer than this idle limit; timeout bounds stay <3s.
    func run(_ path: String, timeout: Double = 1, maxDuration: Double = 600,
             runner: ((String, [String]) async -> AgentProcessResult)? = nil) -> Result<[AgentMessage], Error> {
        let backend = TikaCLIService(config: .init(cliPath: path, perTurnTimeout: timeout,
                                                  maxTurnDuration: maxDuration), localRunner: runner)
        return smokeAwait {
            do {
                return .success(try await backend.run(history: [.init(role: .user, content: "新建88页面加入1-31的序号")],
                    config: AgentConfig(), tools: nil, onEvent: { _ in }))
            } catch { return .failure(error) }
        }
    }
    func succeeded(_ result: Result<[AgentMessage], Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
    let skillFile = dir.appendingPathComponent("SKILL.md")
    try! "TIKA_SKILL_SNAPSHOT：按三个镜头输出🙂。".write(to: skillFile, atomically: true, encoding: .utf8)
    let skill = try! AgentSkillReference.load(name: "fixture", path: skillFile.path)
    let skillCLI = cli("skill-reference", #"""
case "$*" in
  *TIKA_SKILL_SNAPSHOT*) printf '%s\n' '{"type":"text-delta","text":"skill received"}' '{"type":"finish"}' ;;
  *) exit 9 ;;
esac
"""#)
    let skillResult: [AgentMessage] = smokeAwait {
        var config = AgentConfig()
        config.canvasPreviewOnly = true
        return (try? await TikaCLIService(config: .init(cliPath: skillCLI)).run(
            history: [.init(role: .user, content: "写分镜", skillReferences: [skill])],
            config: config, tools: nil, onEvent: { _ in })) ?? []
    }
    t.equal(skillResult.last?.content, "skill received", "Tika actual subprocess receives selected skill snapshot")
    for (name, payload) in [
        ("pure", #"{"type":"text-delta","text":"完整自然语言润色正文"}"#),
        ("local-tool", #"{"type":"text-delta","text":"<clipslots-call cmd=\u0027clipslots pages\u0027/>"}"#),
        ("cloud-tool", #"{"type":"tool-input-available","toolName":"shell","toolCallId":"bad"}"#)
    ] {
        let path = cli("polish-\(name)", #"""
case "$*" in *--auto-approve*) exit 9;; esac
case "$*" in *POLISH_SYSTEM_MARK*) ;; *) exit 8;; esac
printf '%s\n' '
"""# + payload + #"""
' '{"type":"finish"}'
"""#)
        let success = smokeAwait {
            var config = AgentConfig(systemPrompt: "POLISH_SYSTEM_MARK")
            config.taskPolicy = .textPolish
            let backend = TikaCLIService(config: .init(cliPath: path), localRunner: { _, _ in
                t.check(false, "Polish must never run a local tool")
                return .init(exitCode: 0, stdout: "", stderr: "", timedOut: false)
            })
            do {
                let messages = try await backend.run(history: [.init(role: .user, content: "橘猫")],
                    config: config, tools: nil, onEvent: { _ in })
                return messages.last?.content == "完整自然语言润色正文"
            } catch { return false }
        }
        t.equal(success, name == "pure", "Tika polish \(name) honors pure-text contract and forwards task prompt")
    }
    let active = cli("active", #"""
i=0
while [ "$i" -lt 24 ]; do
  printf '%s\n' '{"type":"reasoning-delta","text":"继续分析中文🙂"}'
  /bin/sleep 0.1
  i=$((i+1))
done
printf '%s\n' '{"type":"text-delta","text":"完成🙂"}' '{"type":"finish"}'
"""#)
    let activeResult = run(active)
    t.check(succeeded(activeResult), "Tika 活跃输出超过单次空闲阈值仍能完成：\(activeResult)")
    if case .success(let messages) = activeResult {
        t.equal(messages.last?.content, "完成🙂", "Tika 长请求完整保留中文正文")
        t.equal(messages.last?.reasoning, String(repeating: "继续分析中文🙂", count: 24),
                "Tika 长请求完整保留中文推理")
    }
    let hardLimitStart = Date()
    let hardLimitResult = run(active, maxDuration: 0.7)
    if case .failure(TikaBackendError.turnDurationExceeded) = hardLimitResult {
        t.check(Date().timeIntervalSince(hardLimitStart) < 3, "Tika 活跃输出仍受硬上限保护")
    } else { t.check(false, "Tika 活跃流达到硬上限应停止：\(hardLimitResult)") }

    let silent = cli("silent", "exec /bin/sleep 5")
    let silenceStart = Date()
    let silenceResult = run(silent)
    if case .failure(TikaBackendError.timedOut) = silenceResult {
        t.check(Date().timeIntervalSince(silenceStart) < 3, "Tika 静默请求仍及时超时")
    } else { t.check(false, "Tika 静默应报超时：\(silenceResult)") }

    let finished = cli("finished-hang", #"""
printf '%s\n' '{"type":"text-delta","text":"已完成"}' '{"type":"finish"}'
exec /bin/sleep 5
"""#)
    let finishStart = Date()
    let finishedResult = run(finished)
    t.check(succeeded(finishedResult) && Date().timeIntervalSince(finishStart) < 3,
            "Tika finish 后子进程挂起不能误报响应超时：\(finishedResult)")

    let delayedCallbacks = cli("finished-slow-callback", #"""
printf '%s\n' '{"type":"text-delta","text":"第一段"}' '{"type":"text-delta","text":"第二段"}' '{"type":"finish"}'
exec /bin/sleep 5
"""#)
    let delivered = smokeAwait {
        var events: [String] = []
        let collector = TikaCallbackCollector()
        // Leave time for native process/pipe startup; the UI callback still
        // exceeds the idle limit, so this exercises the same lifecycle failure.
        let backend = TikaCLIService(config: .init(cliPath: delayedCallbacks, perTurnTimeout: 1))
        do {
            let messages = try await backend.run(history: [.init(role: .user, content: "本地回调测试")],
                config: AgentConfig(), tools: nil, onEvent: { event in
                    if case .contentDelta(let text) = event {
                        await collector.append(text)
                        if text == "第一段" { try? await Task.sleep(for: .milliseconds(1500)) }
                    }
                })
            events = await collector.snapshot()
            return (messages.last?.content, events, true, "")
        } catch { return (nil as String?, await collector.snapshot(), false, String(describing: error)) }
    }
    t.check(delivered.2, "Tika 已收到 finish 时慢速界面回调不触发空闲超时：\(delivered.3)")
    t.equal(delivered.0, "第一段第二段", "Tika 慢速回调仍完整保留已完成正文")
    t.equal(delivered.1, ["第一段", "第二段"], "Tika 慢速回调按原事件顺序完成")

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String]] = []
        func append(_ args: [String]) { lock.lock(); values.append(args); lock.unlock() }
        func snapshot() -> [[String]] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let errors = Calls()
    let errorCLI = cli("server-error", #"""
printf '%s\n' '{"type":"text-delta","text":"<clipslots-call cmd=\u0027clipslots pages\u0027/>"}' '{"type":"error","message":"probe service failed"}'
"""#)
    let errorResult = run(errorCLI, runner: { _, args in
        errors.append(args)
        return .init(exitCode: 0, stdout: "{}", stderr: "", timedOut: false)
    })
    t.check(!succeeded(errorResult) && errors.snapshot().isEmpty,
            "Tika 服务端错误不得被当成功并执行残留 XML")

    for (name, tail) in [("partial-idle", "exec /bin/sleep 5"),
                         ("partial-eof", "exit 0"), ("partial-error-exit", "exit 1"),
                         ("error-hang", #"printf '%s\n' '{"type":"error","message":"服务错误"}'; exec /bin/sleep 5"#)] {
        let calls = Calls()
        let partial = cli(name, #"""
printf '%s\n' '{"type":"text-delta","text":"<clipslots-call cmd=\u0027clipslots pages\u0027/>"}'
"""# + "\n" + tail)
        let start = Date()
        let result = run(partial, runner: { _, args in
            calls.append(args)
            return .init(exitCode: 0, stdout: "{}", stderr: "", timedOut: false)
        })
        t.check(!succeeded(result) && calls.snapshot().isEmpty && Date().timeIntervalSince(start) < 3,
                "Tika \(name) 不执行不完整或失败响应里的XML，并及时收尾")
    }

    let cancelling = TikaCLIService(config: .init(cliPath: active, perTurnTimeout: 10))
    let cancellationStart = Date()
    let cancellationOK = smokeAwait {
        let task = Task {
            try await cancelling.run(history: [.init(role: .user, content: "取消")],
                config: AgentConfig(), tools: nil, onEvent: { _ in })
        }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; return false }
        catch is CancellationError { return true }
        catch { return false }
    }
    t.check(cancellationOK && Date().timeIntervalSince(cancellationStart) < 3,
            "Tika 活跃流停止后及时终止进程")

    // A deterministic cloud model emits one command per round, like the original system prompt.
    // Its state is derived from result envelopes, so --new cannot reset the sequence.
    let sequence = cli("sequence", #"""
for prompt do :; done
n=$(printf '%s' "$prompt" | /usr/bin/grep -c '</clipslots-result>' || true)
if [ "$n" -eq 0 ]; then
  cmd="clipslots create-page 88 --group-name 1-10"
elif [ "$n" -lt 4 ]; then
  start=$((n*10+1))
  end=$((n*10+10))
  cmd="clipslots create-group $start-$end --page-name 88"
elif [ "$n" -lt 35 ]; then
  value=$((n-3))
  slot=$(((value-1)%10+1))
  start=$(((value-1)/10*10+1))
  end=$((start+9))
  cmd="clipslots write $slot --text $value --page-name 88 --group $start-$end --if-empty"
else
  printf '%s\n' '{"type":"text-delta","text":"31项已完成"}' '{"type":"finish"}'
  exit 0
fi
printf '{"type":"text-delta","text":"<clipslots-call cmd=\u0027%s\u0027/>"}\n' "$cmd"
printf '%s\n' '{"type":"finish"}'
"""#)
    let sequentialCalls = Calls()
    let sequenceResult = run(sequence, timeout: 3, runner: { _, args in
        sequentialCalls.append(args)
        return .init(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "", timedOut: false)
    })
    let writes = sequentialCalls.snapshot().filter { $0.first == "write" }
    t.equal(writes.count, 31, "Tika 默认轮数允许创建页/4组并逐条填满31项")
    if case .success(let messages) = sequenceResult {
        t.equal(messages.last?.content, "31项已完成", "Tika 31项写完后仍能读取结果并总结")
        let calls = messages.flatMap(\.toolCalls)
        let results = messages.filter { $0.role == .tool }
        t.equal(calls.map(\.id), results.compactMap(\.toolCallId), "Tika 全部工具结果与历史一一关联")
    } else { t.check(false, "Tika 31项工作流不应抛错：\(sequenceResult)") }

    // The batch model requires all prior results before moving on: create page → groups → writes → summary.
    let batch = cli("batch", #"""
for prompt do :; done
n=$(printf '%s' "$prompt" | /usr/bin/grep -c '</clipslots-result>' || true)
if printf '%s' "$prompt" | /usr/bin/grep -q '<clipslots-result ok="false"'; then
  printf '%s\n' '{"type":"error","message":"local command failed"}'
  exit 0
fi
emit() { printf '{"type":"text-delta","text":"<clipslots-call cmd=\u0027%s\u0027/>"}\n' "$1"; }
if [ "$n" -eq 0 ]; then
  emit "clipslots create-page 88 --group-name 1-10"
elif [ "$n" -eq 1 ]; then
  for group in 11-20 21-30 31-40; do
    emit "clipslots create-group $group --page-name 88"
  done
elif [ "$n" -eq 4 ]; then
  value=1
  while [ "$value" -le 31 ]; do
    slot=$(((value-1)%10+1))
    start=$(((value-1)/10*10+1))
    end=$((start+9))
    emit "clipslots write $slot --text $value --page-name 88 --group $start-$end --if-empty"
    value=$((value+1))
  done
elif [ "$n" -eq 35 ]; then
  printf '%s\n' '{"type":"text-delta","text":"31项已完成"}'
else
  printf '%s\n' '{"type":"error","message":"missing tool results"}'
fi
printf '%s\n' '{"type":"finish"}'
"""#)
    let realCLI = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("ClipSlotsCLI").path
    guard FileManager.default.isExecutableFile(atPath: realCLI) else {
        t.check(false, "Tika 真实CLI回归需要先执行 swift build --product ClipSlotsCLI")
        return
    }
    let dataRoot = dir.appendingPathComponent("data", isDirectory: true)
    let actualCalls = Calls()
    let batchResult = run(batch, timeout: 3, runner: { _, args in
        actualCalls.append(args)
        return await AgentProcessRunner.run(executable: "/usr/bin/env",
            arguments: ["CLIPSLOTS_DATA_DIR=" + dataRoot.path, realCLI] + args, timeout: 5)
    })
    t.check(succeeded(batchResult), "Tika 合批通过真实CLI完成全部操作：\(batchResult)")
    t.equal(actualCalls.snapshot().count, 35, "Tika 合批恰好创建1页/3个后续组及31次写入，无重放")
    if case .success(let messages) = batchResult {
        t.equal(messages.filter { $0.role == .assistant }.count, 4, "Tika 合批31项只需4次模型往返")
        t.equal(messages.last?.content, "31项已完成", "Tika 合批完整接收35条结果后总结")
        t.equal(messages.flatMap(\.toolCalls).map(\.id),
                messages.filter { $0.role == .tool }.compactMap(\.toolCallId), "Tika 合批工具历史完整")
    }
    let store = SpecialSlotStorage(baseDirectory: dataRoot.appendingPathComponent("special_slots"), role: .main)
    let index = store.loadIndex()
    let pages = index.pages.filter { $0.name == "88" }
    t.equal(pages.count, 1, "Tika 真实CLI只创建一个88页面")
    guard let page = pages.first else { return }
    let groups = index.specialSlots.filter { $0.pageId == page.id }
    t.equal(groups.count, 4, "Tika 真实CLI创建4个组")
    for value in 1...40 {
        let start = ((value - 1) / 10) * 10 + 1
        let name = "\(start)-\(start + 9)"
        guard let group = groups.first(where: { $0.name == name }) else {
            t.check(false, "Tika 实际组缺失：\(name)")
            continue
        }
        let content = store.get((value - 1) % 10 + 1, in: group.id)
        if value <= 31 {
            let text = content.items.first?.first.map { String(decoding: $0.data, as: UTF8.self) }
            t.equal(text, String(value), "Tika 序号\(value)落盘值与分组正确")
        } else { t.check(content.isEmpty, "Tika 末组剩余槽位\(value)保持空白") }
    }
}

private actor TikaCallbackCollector {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}
