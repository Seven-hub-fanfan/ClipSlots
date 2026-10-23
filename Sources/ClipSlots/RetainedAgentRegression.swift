#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runRetainedAgentProbe(directory: URL, check: (Bool, String) -> Void) async {
    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    func sse(_ text: String) -> String {
        let value: JSONValue = ["choices": [["delta": ["content": .string(text)], "finish_reason": "stop"]]]
        return "data: \(try! value.encodedText())\n\ndata: [DONE]\n\n"
    }
    func cli(_ name: String, text: String, delay: Bool = false) -> URL {
        let url = directory.appendingPathComponent("tika-\(name)")
        let json: JSONValue = ["type": "text-delta", "text": .string(text)]
        let body = "#!/bin/sh\nprintf '%s\\n' '" + (try! json.encodedText()) + "'\n"
            + (delay ? "/bin/sleep 1\n" : "") + "printf '%s\\n' '{\"type\":\"finish\"}'\n"
        try! body.write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    check(AgentBackendKind.allCases == [.deepseek, .tika, .gateway], "local clients and continuation gateway remain selectable")
    let defaults = UserDefaults.standard
    let oldSidebarBackend = defaults.string(forKey: TikaBackendPreferences.backendKindKey)
    let oldWorkspaceBackend = defaults.string(forKey: AgentPreferences.workspaceBackendKey)
    for mode in WorkspaceMode.allCases {
        // Gateway restart, resume and typed proposals use the separate real
        // gateway transport fixture in AgentGatewayContinuationRegression.
        for kind in [AgentBackendKind.deepseek, .tika] {
            let label = "\(mode.rawValue)/\(kind.rawValue)"
            let scope = AgentBackendScope(workspaceMode: mode)
            AgentBackendCoordinator.setKind(kind, for: scope)
            check(AgentBackendCoordinator.selection(for: scope).kind == kind,
                  "\(label) selection uses shared scope")
            let text = label + " 中文回答🙂"
            let transport = AgentScriptedTransport(steps: [.sse(sse(text), splitEvery: 5)])
            let backend: any AgentBackend = kind == .deepseek
                ? AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture"))
                : TikaCLIService(config: .init(cliPath: cli(label.replacingOccurrences(of: "/", with: "-"), text: text).path))
            let path = directory.appendingPathComponent("retained-\(mode.rawValue)-\(kind.rawValue).json")
            let model = AgentChatModel(displayName: label, backend: backend, persistenceURL: path,
                                       backendScope: scope)
            check(model.backendKind == kind, "\(label) UI and runtime share backend selection")
            model.draft = "草稿🙂"
            check(model.send(text: model.draft, config: AgentConfig(), enabledSkills: []), "\(label) accepts send")
            await waitFor { !model.isRunning }
            check(!model.isRunning && model.errorText == nil && model.messages.last?.content == text,
                  "\(label) receives full Unicode response")
            check(model.requiresAPIKey == (kind == .deepseek), "\(label) authentication routing")
            check(model.flushSession(), "\(label) saves history")
            let raw = try? Data(contentsOf: path)
            let restored = AgentChatModel(displayName: label, backend: backend, persistenceURL: path)
            check(restored.messages == model.messages && restored.draft == model.draft,
                  "\(label) restores history and draft")
            check(restored.flushSession() && (try? Data(contentsOf: path)) == raw,
                  "\(label) read-only reopen preserves bytes")
            let view = AgentSidebarView(model: restored, isVisible: .constant(true), workspaceMode: mode)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 50, y: 50,
                width: mode == .agent ? 1000 : AgentSidebarView.width, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            func editors(_ v: NSView) -> [AgentDraftEditor.Editor] {
                (v as? AgentDraftEditor.Editor).map { [$0] } ?? v.subviews.flatMap(editors)
            }
            check(editors(host).count == 1, "\(label) mounts native input")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("retained-\(mode.rawValue)-\(kind.rawValue).png"))
            }
            window.close()
        }
    }
    let delayed = cli("cancel", text: "正在回答", delay: true)
    let tika = AgentChatModel(displayName: "Tika停止",
        backend: TikaCLIService(config: .init(cliPath: delayed.path)))
    tika.send(text: "开始", config: AgentConfig(), enabledSkills: [])
    try? await Task.sleep(for: .milliseconds(150))
    tika.stop()
    let stopped = tika.messages
    try? await Task.sleep(for: .milliseconds(1100))
    check(!tika.isRunning && tika.messages == stopped, "Tika stop rejects late subprocess output")
    tika.setBackend(TikaCLIService(config: .init(cliPath: cli("retry", text: "重试完成").path)))
    tika.retryLast(config: AgentConfig(), enabledSkills: [])
    await waitFor { !tika.isRunning }
    check(tika.messages.last?.content == "重试完成" && tika.errorText == nil, "Tika retry completes without losing history")
    let failure = AgentScriptedTransport(steps: [
        .init(statusCode: 503, chunks: ["service unavailable"]), .sse(sse("DeepSeek重试完成"))
    ])
    let deepseek = AgentChatModel(displayName: "DeepSeek重试",
        backend: AgentService(transport: failure, secretStore: AgentInMemorySecretStore(key: "fixture")))
    deepseek.send(text: "失败后重试", config: AgentConfig(), enabledSkills: [])
    await waitFor { !deepseek.isRunning }
    check(deepseek.errorText != nil, "DeepSeek network failure appears in chat")
    deepseek.retryLast(config: AgentConfig(), enabledSkills: [])
    await waitFor { !deepseek.isRunning }
    check(deepseek.errorText == nil && deepseek.messages.last?.content == "DeepSeek重试完成",
          "DeepSeek retry preserves user request and completes")
    for kind in [AgentBackendKind.deepseek, .tika] {
        let polished = "金色夕阳照亮海边，海风轻拂人物衣角。"
        let backend: any AgentBackend = kind == .deepseek
            ? AgentService(transport: AgentScriptedTransport(steps: [.sse(sse(polished))]),
                           secretStore: AgentInMemorySecretStore(key: "fixture"))
            : TikaCLIService(config: .init(cliPath: cli("polish", text: polished).path))
        let model = AgentChatModel(displayName: "润色", backend: backend)
        model.draft = "夕阳海边"
        model.polishDraft(config: AgentConfig())
        await waitFor { !model.isPolishing }
        check(model.draft == polished && model.messages.isEmpty && model.polishError == nil,
              "\(kind.rawValue) polish only replaces draft")
    }
    let legacy = directory.appendingPathComponent("legacy-metadata.json")
    let oldMessages = [AgentMessage(role: .user, content: "旧历史"),
                       AgentMessage(role: .assistant, content: "保留的回答")]
    try? writeAgentHistoryFixture(oldMessages, to: legacy, title: "旧会话标题",
        attachments: [.init(path: "/old/attachment.png", name: "attachment.png")])
    let raw = try? Data(contentsOf: legacy)
    let model = AgentChatModel(displayName: "旧记录",
        backend: AgentService(transport: AgentScriptedTransport(steps: []),
                              secretStore: AgentInMemorySecretStore(key: "fixture")), persistenceURL: legacy)
    check(model.messages == oldMessages && model.currentConversationTitle == "旧会话标题",
          "legacy title and transcript decode without removed runtime")
    check(model.flushSession() && (try? Data(contentsOf: legacy)) == raw,
          "legacy metadata remains byte-identical on reopen")
    check(!model.send(text: "继续", config: AgentConfig(), enabledSkills: []) && model.draftAttachments.count == 1,
          "legacy unsupported attachment is retained with explicit send error")
    model.draft = "可编辑草稿"
    check(model.flushSession(), "legacy session permits edits")
    let reloaded = AgentChatModel(displayName: "旧记录", backend: AgentService(), persistenceURL: legacy)
    check(reloaded.codexThreadID == "legacy-fixture" && reloaded.codexContext?.cwd == "/legacy"
          && reloaded.draft == "可编辑草稿", "legacy metadata survives subsequent saves")
    if let oldSidebarBackend {
        defaults.set(oldSidebarBackend, forKey: TikaBackendPreferences.backendKindKey)
    } else {
        defaults.removeObject(forKey: TikaBackendPreferences.backendKindKey)
    }
    if let oldWorkspaceBackend {
        defaults.set(oldWorkspaceBackend, forKey: AgentPreferences.workspaceBackendKey)
    } else {
        defaults.removeObject(forKey: AgentPreferences.workspaceBackendKey)
    }
    AgentBackendCoordinator.broadcastChange()
}
#endif
