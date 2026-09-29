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
    await settle(0.24)
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
    } else { check(false, "draft editor mounts with restored text") }
    window.close()
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
