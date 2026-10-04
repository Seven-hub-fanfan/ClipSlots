#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

/// In-process model and rendering checks; no keychain or external API.
@MainActor
func runAgentModelProbe(directory: URL, check: (Bool, String) -> Void) async {
    func settle(_ seconds: Double = 0.2) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    let pendingKey = AgentCredentialGateStore()
    let pending = AgentChatModel(displayName: "授权等待",
        service: AgentService(transport: AgentScriptedTransport(steps: []), secretStore: pendingKey))
    let sendStarted = CFAbsoluteTimeGetCurrent()
    pending.send(text: "等待授权", config: AgentConfig(), enabledSkills: [])
    check(CFAbsoluteTimeGetCurrent() - sendStarted < 0.1, "send returns without waiting for credential authorization")
    await settle(0.1)
    check(pendingKey.started.wait(timeout: .now()) == .success, "credential read starts in backend")
    check(!pendingKey.readOnMain, "credential read stays off the main thread")
    check(pending.isRunning, "UI can update while credential authorization is pending")
    pending.stop()
    pendingKey.release.signal()
    await settle()
    check(!pending.isRunning && !pending.needsConfiguration, "stop ignores late credential failure")

    let missingKey = AgentInMemorySecretStore()
    let missing = AgentChatModel(displayName: "缺少凭据",
        service: AgentService(transport: AgentPanelProbeTransport(), secretStore: missingKey))
    missing.send(text: "配置后继续", config: AgentConfig(), enabledSkills: [])
    await settle()
    check(missing.needsConfiguration && !missing.isRunning, "missing credential opens configuration asynchronously")
    check(missing.messages.count == 1 && missing.messages.first?.role == .user,
          "missing credential preserves the submitted message")
    try? missingKey.writeAPIKey("local-fixture")
    missing.needsConfiguration = false
    missing.retryLast(config: AgentConfig(), enabledSkills: [])
    await settle(0.85)
    check(missing.errorText == nil && missing.messages.count == 2, "configuration then retry keeps one user message")

    let service = AgentService(transport: AgentPanelProbeTransport(),
                               secretStore: AgentInMemorySecretStore(key: "local-fixture"))
    let model = AgentChatModel(displayName: "测试", service: service)
    model.send(text: "旧会话", config: AgentConfig(), enabledSkills: [])
    await settle(0.08)
    model.clearHistory()
    model.send(text: "新会话", config: AgentConfig(), enabledSkills: [])
    await settle(0.85)
    check(!model.isRunning && model.messages.count == 2, "new conversation finishes exactly one answer")
    check(!model.messages.contains { $0.content.contains("旧会话") || $0.isFailure },
          "cancelled previous conversation cannot append to new history")
    check(model.messages.last?.reasoning?.isEmpty == false, "reasoning survives completed answer")
    check(model.transcript.count == 2, "transcript keeps user and assistant roles")

    model.send(text: "继续创作", config: AgentConfig(), enabledSkills: [])
    // First content arrives at 220ms, then the UI can batch it for another 50ms.
    let visibleDeadline = Date().addingTimeInterval(0.4)
    while model.isRunning && model.streamingContent.isEmpty && Date() < visibleDeadline {
        await settle(0.01)
    }
    check(model.isRunning && !model.streamingContent.isEmpty, "streaming answer is visible before completion")
    model.stop()
    await settle(0.3)
    check(!model.isRunning && model.messages.last?.content == "已停止本次回答。", "stop settles and preserves partial answer")
    model.clearHistory()
    await settle()
    check(model.isEmpty && model.streamingContent.isEmpty && model.errorText == nil, "new conversation resets all visible state")

    let retryTransport = AgentScriptedTransport(steps: [
        .init(statusCode: 500, chunks: ["{\"error\":{\"message\":\"fixture failure\"}}"]),
        .sse("data: {\"choices\":[{\"delta\":{\"content\":\"重试成功，继续创作。\"}}]}\n\ndata: [DONE]\n\n")
    ])
    let retry = AgentChatModel(displayName: "重试",
        service: AgentService(transport: retryTransport, secretStore: AgentInMemorySecretStore(key: "local-fixture")))
    retry.send(text: "测试错误重试", config: AgentConfig(), enabledSkills: [])
    await settle()
    check(retry.errorText != nil && !retry.isRunning, "failed request exposes retry state")
    retry.retryLast(config: AgentConfig(), enabledSkills: [])
    await settle()
    check(retry.errorText == nil && retry.messages.last?.content == "重试成功，继续创作。",
          "retry completes without duplicating user message")

    let buffered = AgentChatModel(displayName: "尾片段", backend: AgentBufferedProbeBackend())
    check(!buffered.requiresAPIKey, "non-DeepSeek backend does not request an API key")
    buffered.send(text: "停止前的最后片段", config: AgentConfig(), enabledSkills: [])
    await settle(0.015)
    buffered.stop()
    check(buffered.messages.contains { $0.content == "尚未刷新🙂" && $0.reasoning == "思考尾片段" },
          "stop flushes content and reasoning still waiting in the UI batch")
    buffered.clearHistory()
    await settle(0.12)
    check(buffered.messages.isEmpty && buffered.streamingContent.isEmpty && buffered.streamingReasoning.isEmpty,
          "cancelled stream publication cannot leak into a new conversation")

    model.send(text: "新会话", config: AgentConfig(), enabledSkills: [])
    await settle(0.85)
    let host = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 780),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    for name in ["light", "dark"] {
        window.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        await settle()
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("canvas-agent-answer-\(name).png"))
        }
    }
    model.draft = "尚未发送的多行草稿\n第二行继续补充构图与光线。"
    host.rootView = AgentSidebarView(model: model, isVisible: .constant(true))
    await settle()
    check(model.draft.contains("尚未发送"), "sidebar reconstruction retains draft")
    func editors(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    if let editor = editors(host).first(where: { $0.isEditable && $0.string == model.draft }) {
        check(editor.enclosingScrollView?.hasVerticalScroller == false, "draft editor has no persistent scrollbar gutter")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("追加", replacementRange: editor.selectedRange())
        check(model.draft.hasSuffix("追加"), "native draft editor writes through to conversation")
        model.draft = "外部建议填入"
        await settle()
        check(editor.string == "外部建议填入", "suggestion replaces draft in focused editor")
        if let editor = editor as? AgentDraftEditor.Editor {
            func snapshot(_ name: String) {
                host.layoutSubtreeIfNeeded()
                editor.needsDisplay = true
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("agent-placeholder-\(name).png"))
                }
            }
            for appearance in ["light", "dark"] {
                window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                model.draft = ""
                await settle()
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                check(editor.isPlaceholderVisible, "\(appearance) empty input shows placeholder")
                snapshot("\(appearance)-empty")

                editor.setMarkedText("sa", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                check(editor.hasMarkedText() && editor.string == "sa",
                      "\(appearance) native IME composition is active")
                check(!editor.isPlaceholderVisible, "\(appearance) composing pinyin hides placeholder immediately")
                host.rootView = AgentSidebarView(model: model, isVisible: .constant(true))
                await settle()
                check(editor.hasMarkedText() && editor.string == "sa" && !editor.isPlaceholderVisible,
                      "\(appearance) sidebar refresh preserves composing text without placeholder")
                snapshot("\(appearance)-composing")

                editor.insertText("撒", replacementRange: editor.markedRange())
                check(model.draft == "撒" && !editor.hasMarkedText() && !editor.isPlaceholderVisible,
                      "\(appearance) candidate commit keeps text and hides placeholder")
                snapshot("\(appearance)-committed")
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
                editor.deleteBackward(nil)
                check(model.draft.isEmpty && editor.isPlaceholderVisible,
                      "\(appearance) deleting final character restores placeholder")

                editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                     replacementRange: editor.markedRange())
                editor.unmarkText()
                check(editor.string.isEmpty && editor.isPlaceholderVisible,
                      "\(appearance) cancelling composition restores placeholder")
            }
            editor.insertText("Hello🙂", replacementRange: NSRange(location: 0, length: 0))
            check(model.draft == "Hello🙂" && !editor.isPlaceholderVisible, "plain text and emoji hide placeholder")
            editor.insertText("第一行\n第二行🙂", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            check(model.draft == "第一行\n第二行🙂" && !editor.isPlaceholderVisible,
                  "multiline insertion keeps placeholder hidden")
            model.draft = ""
            await settle()
            check(editor.string.isEmpty && editor.isPlaceholderVisible, "external draft clear restores placeholder")
        } else { check(false, "native draft editor supports composition placeholder") }
    } else { check(false, "draft editor mounts with restored text") }
    window.close()
}

private final class AgentCredentialGateStore: AgentSecretStore {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private(set) var readOnMain = false
    func readAPIKey() -> String? {
        readOnMain = Thread.isMainThread
        started.signal()
        _ = release.wait(timeout: .now() + 3)
        return nil
    }
    func writeAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

private final class AgentBufferedProbeBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        await onEvent(.contentDelta("尚未刷新🙂"))
        await onEvent(.reasoningDelta("思考尾片段"))
        try await Task.sleep(for: .seconds(1))
        return []
    }
}

private struct AgentPanelProbeTransport: AgentTransport {
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        let last = messages?.last?["content"] as? String ?? ""
        let answer = "\(last)：\n## 画面方向\n- 主体清晰，构图简洁。\n- 柔和侧光，保留自然层次。\n\n可以继续补充你想表达的情绪。"
        func chunk(_ delta: [String: String]) -> Data {
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": delta]]])
            return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
        }
        let chunks = [chunk(["reasoning_content": "正在整理画面要素与构图。"]),
                      chunk(["content": String(answer.prefix(18))]),
                      chunk(["content": String(answer.dropFirst(18))]),
                      Data("data: [DONE]\n\n".utf8)]
        return AgentHTTPStream(statusCode: 200, chunks: AsyncThrowingStream { continuation in
            let task = Task {
                for data in chunks {
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    if Task.isCancelled { break }
                    continuation.yield(data)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}
#endif
