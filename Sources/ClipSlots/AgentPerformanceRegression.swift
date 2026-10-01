#if DEBUG
import AppKit
import SwiftUI
import Combine
import ClipSlotsKit

private final class AgentHistoryFixture: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        for i in 0..<24 {
            let calls = (0..<3).map { AgentToolCall(id: "tool-\(i)-\($0)", name: "write_slot",
                argumentsJSON: #"{"page":"fixture","group":"test","slot":1,"text":"sample"}"#) }
            await onEvent(.assistantCompleted(.init(role: .assistant,
                content: "## 步骤 \(i)\n- 整理槽位中的**提示词**，保留附件。\n- 检查执行结果。\n", toolCalls: calls)))
            for call in calls {
                await onEvent(.toolStarted(call))
                await onEvent(.toolCompleted(callId: call.id, name: call.name,
                    result: .init(content: #"{"ok":true,"preview":"sample"}"#, summary: "完成")))
            }
        }
        return []
    }
}

private struct AgentPerformanceTransport: AgentTransport {
    let deltas: [String]
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let deltas = deltas
        return AgentHTTPStream(statusCode: 200, chunks: AsyncThrowingStream { continuation in
            let task = Task.detached {
                for delta in deltas {
                    guard !Task.isCancelled else { break }
                    let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": delta]]]])
                    continuation.yield(Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8))
                    try? await Task.sleep(for: .milliseconds(8))
                }
                continuation.yield(Data("data: [DONE]\n\n".utf8))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}

@MainActor
func runAgentPerformanceRegression(directory: URL) async {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let fragment = "- 画面保持**主体清晰**，柔和侧光与自然层次，参考图保持原始比例。\n"
    let response = String(repeating: fragment, count: 90)
    var deltas: [String] = []
    var cursor = response.startIndex
    while cursor < response.endIndex {
        let next = response.index(cursor, offsetBy: 6, limitedBy: response.endIndex) ?? response.endIndex
        deltas.append(String(response[cursor..<next]))
        cursor = next
    }
    let fixture = directory.appendingPathComponent("tikacli")
    let payload = try! JSONSerialization.data(withJSONObject: deltas)
    try? payload.write(to: directory.appendingPathComponent("deltas.json"))
    let script = """
    #!/usr/bin/python3
    import pathlib,json,time,sys
    root=pathlib.Path(__file__).parent
    for delta in json.loads((root/'deltas.json').read_text()):
        print(json.dumps({'type':'text-delta','delta':delta},ensure_ascii=False,indent=2),flush=True)
        time.sleep(0.008)
    print(json.dumps({'type':'finish'}),flush=True)
    """
    try? script.write(to: fixture, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    var reports: [[String: Any]] = []
    var checks: [String: Bool] = [:]
    for kind in ["deepseek", "tika"] {
        let model = AgentChatModel(displayName: "性能测试", backend: AgentHistoryFixture(),
                                   persistenceURL: directory.appendingPathComponent("\(kind)-session.json"))
        model.send(text: "准备历史", config: AgentConfig(), enabledSkills: [])
        while model.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        let host = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true)))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 480, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        if kind == "deepseek" {
            model.setBackend(AgentService(transport: AgentPerformanceTransport(deltas: deltas),
                                         secretStore: AgentInMemorySecretStore(key: "fixture")))
        } else {
            model.setBackend(TikaCLIService(config: .init(cliPath: fixture.path, perTurnTimeout: 60)))
        }
        var publishes = 0
        let subscription = model.objectWillChange.sink { publishes += 1 }
        var gaps: [Double] = []
        var last = CFAbsoluteTimeGetCurrent()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = CFAbsoluteTimeGetCurrent()
                gaps.append((now - last) * 1000)
                last = now
            }
        }
        AgentSidebarView.debugBodies = 0
        AgentSidebarView.debugScrolls = 0
        AgentMarkdownText.debugParses = 0
        AgentMarkdownText.debugParseBytes = 0
        model.debugReceivedEvents = 0
        model.debugTranscriptReads = 0
        model.debugPersistenceMS = []
        let start = CFAbsoluteTimeGetCurrent()
        model.send(text: "继续生成长回答", config: AgentConfig(), enabledSkills: [])
        while model.isRunning && CFAbsoluteTimeGetCurrent() - start < 75 {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if model.isRunning { model.stop() }
        ticker.cancel()
        subscription.cancel()
        let sorted = gaps.sorted()
        checks["\(kind) exact full response"] = model.messages.last?.content == response
        reports.append(["backend": kind, "seconds": elapsed, "events": model.debugReceivedEvents,
            "publishes": publishes, "sidebarBodies": AgentSidebarView.debugBodies,
            "scrollRequests": AgentSidebarView.debugScrolls, "markdownParses": AgentMarkdownText.debugParses,
            "parsedBytes": AgentMarkdownText.debugParseBytes, "transcriptReads": model.debugTranscriptReads,
            "maxMainGapMS": sorted.last ?? 0, "p95MainGapMS": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
            "gapsOver100MS": gaps.filter { $0 > 100 }.count, "saveMS": model.debugPersistenceMS])
        // Let the final history replacement and deferred scroll settle before visual validation.
        try? await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        if let scroll = scrollViews(host).max(by: { $0.frame.height < $1.frame.height }) {
            reports[reports.count - 1]["scrollBounds"] = NSStringFromRect(scroll.documentVisibleRect)
            reports[reports.count - 1]["documentBounds"] = NSStringFromRect(scroll.documentView?.bounds ?? .zero)
            reports[reports.count - 1]["bottomMarkerY"] = AgentSidebarView.debugBottom
            checks["\(kind) final answer bottom is visible"] = AgentSidebarView.debugBottom.map {
                $0 >= 0 && $0 <= scroll.contentView.bounds.height + 2
            } ?? false
        }
        let restored = AgentChatModel(displayName: "恢复", backend: AgentHistoryFixture(),
                                      persistenceURL: directory.appendingPathComponent("\(kind)-session.json"))
        checks["\(kind) restored transcript"] = restored.transcript.count == model.transcript.count
            && restored.messages.last?.content == response && !restored.transcript.isEmpty
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(kind).png"))
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_AGENT_INTERACTION"] == "1" {
            model.send(text: "滚动历史时继续生成", config: AgentConfig(), enabledSkills: [])
            try? await Task.sleep(for: .milliseconds(900))
            if let scroll = scrollViews(host).max(by: { $0.frame.height < $1.frame.height }) {
                // AppKit scroll surface + the same live-scroll notification used by the observer.
                // This is in-process input validation, not a physical desktop mouse test.
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                try? await Task.sleep(for: .milliseconds(300))
                checks["\(kind) reading history does not snap to latest"] = scroll.documentVisibleRect.minY < 100
                func editors(_ view: NSView) -> [NSTextView] {
                    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
                }
                if let editor = editors(host).first(where: { $0.isEditable }) {
                    let inputStart = CFAbsoluteTimeGetCurrent()
                    window.makeFirstResponder(editor)
                    editor.insertText("生成时输入🙂", replacementRange: NSRange(location: 0, length: 0))
                    reports[reports.count - 1]["nativeInputHandlingMS"] = (CFAbsoluteTimeGetCurrent() - inputStart) * 1000
                    checks["\(kind) native input during stream"] = model.isRunning && model.draft.contains("生成时输入🙂")
                } else { checks["\(kind) native input during stream"] = false }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(kind)-history.png"))
                }
            } else { checks["\(kind) history scroll mounts"] = false }
            let stopStart = CFAbsoluteTimeGetCurrent()
            model.stop()
            reports[reports.count - 1]["stopHandlingMS"] = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            checks["\(kind) stop preserves partial response"] = !model.isRunning &&
                model.messages.dropLast().last?.content.hasPrefix(fragment) == true &&
                model.messages.last?.content == "已停止本次回答。"
        }
        window.close()
    }
    await runAgentModelProbe(directory: directory) { condition, label in checks[label] = condition }
    let report: [String: Any] = ["scenarios": reports, "checks": checks,
        "failures": checks.filter { !$0.value }.map(\.key), "passed": checks.values.filter { $0 }.count]
    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("report.json"))
    // #region debug-point A-D:performance-report
    var request = URLRequest(url: URL(string: "http://127.0.0.1:7787/event")!); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "agent-stream-lag", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A-D", "msg": "[DEBUG] agent performance benchmark", "data": report]); _ = try? await URLSession.shared.data(for: request)
    // #endregion
    NSApp.terminate(nil)
}
#endif
