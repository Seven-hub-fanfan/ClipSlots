#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentInteractionProbe(directory: URL, check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        let fallback = (node as? NSView)?.subviews ?? []
        return [node] + (children.isEmpty ? fallback : children).flatMap { elements($0 as AnyObject, depth: depth + 1) }
    }
    let path = directory.appendingPathComponent("interaction-session.json")
    let model = AgentChatModel(displayName: "应答测试", backend: InteractionFixtureBackend(), persistenceURL: path)
    model.send(text: "等待授权", config: AgentConfig(), enabledSkills: [])
    await settle()
    guard let first = model.pendingInteractions.first else { check(false, "interactive approval displayed"); return }
    func card(_ request: AgentInteraction) -> AnyView {
        AnyView(AgentInteractionView(request: request, model: model)
            .foregroundColor(TapSkin.ink).padding(18)
            .background(TapSkin.tone(0xfafafa, 0x111111)))
    }
    let host = NSHostingView(rootView: card(first))
    let window = NSWindow(contentRect: NSRect(x: 150, y: 100, width: 360, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close(); model.stop() }
    await settle()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("canvas-agent-approval.png"))
    }
    let button = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-approve-once" }
    check(button != nil, "native approval button accessible")
    _ = button?.accessibilityPerformPress?()
    await settle()
    check(model.pendingInteractions.isEmpty && !model.isRunning, "native approval resumes waiting run")
    check(model.messages.contains { $0.content == "已处理本次应答" }, "approval result reaches transcript")

    model.send(text: "旧会话等待", config: AgentConfig(), enabledSkills: [])
    await settle()
    let stale = model.pendingInteractions.first
    model.clearHistory()
    model.send(text: "新会话等待", config: AgentConfig(), enabledSkills: [])
    await settle()
    if let stale {
        await model.respond(to: stale, result: ["decision": "accept"])
        check(!stale.isPending && model.pendingInteractions.count == 1 && model.isRunning,
              "previous conversation card cannot answer new run")
    } else { check(false, "stale request fixture available") }
    model.stop()
    check(model.pendingInteractions.isEmpty, "stop immediately removes pending request")

    model.setBackend(InteractionFixtureBackend(questions: true))
    model.send(text: "多个问题", config: AgentConfig(), enabledSkills: [])
    await settle()
    guard let question = model.pendingInteractions.first else { check(false, "question card available"); return }
    host.rootView = card(question)
    await settle()
    let nodes = elements(host)
    check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "agent-question-note" },
          "native freeform question editor accessible")
    check(nodes.contains { ($0.accessibilityIdentifier?() ?? "") == "agent-submit-answers" },
          "native question submit accessible")
    await model.respond(to: question, result: ["answers": [:]])
    check(question.isPending && model.isRunning, "incomplete UI response leaves run waiting")
    await model.respond(to: question, result: ["answers": ["style": ["answers": ["自然"]], "note": ["answers": ["PRIVATE_FIXTURE"]]]])
    await settle()
    check(!model.isRunning && model.pendingInteractions.isEmpty, "all questions resume run")
    model.flushSession()
    let saved = (try? String(contentsOf: path)) ?? ""
    check(!saved.contains("PRIVATE_FIXTURE") && !saved.contains("pendingInteractions"),
          "secret answers and pending capabilities never persisted")
}

private final class InteractionFixtureBackend: AgentBackend, @unchecked Sendable {
    let questions: Bool
    init(questions: Bool = false) { self.questions = questions }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        let params: JSONValue = questions
            ? ["questions": [
                ["id": "style", "question": "选择风格", "isOther": false, "options": [["label": "自然"]]],
                ["id": "note", "question": "补充说明", "isOther": true, "isSecret": true]
            ]]
            : ["command": "echo local-fixture", "cwd": "/tmp", "reason": "仅测试应答，不执行命令"]
        let request = AgentInteraction(kind: questions ? .questions : .commandApproval, params: params) { _ in }
        defer { request.invalidate() }
        await onEvent(.interactionRequested(request))
        while request.isPending { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        let message = AgentMessage(role: .assistant, content: "已处理本次应答")
        await onEvent(.assistantCompleted(message))
        return [message]
    }
}
#endif
