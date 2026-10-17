#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentComposerProbe(directory: URL, check: (Bool, String) -> Void) async {
    func settle(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .seconds(seconds)) }
    func editors(_ view: NSView) -> [AgentDraftEditor.Editor] {
        (view as? AgentDraftEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        let fallback = (node as? NSView)?.subviews ?? []
        return [node] + (children.isEmpty ? fallback : children).flatMap {
            elements($0 as AnyObject, depth: depth + 1)
        }
    }
    func key(_ editor: AgentDraftEditor.Editor, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [],
             repeatKey: Bool = false) {
        let characters = code == 48 ? "\t" : code == 36 || code == 76 ? "\r" : ""
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeatKey, keyCode: code)!
        editor.window?.makeFirstResponder(editor)
        editor.window?.sendEvent(event)
    }
    let fixturePath = directory.appendingPathComponent("composer-skill.md")
    let original = "---\nname: composer-fixture\n---\n先列出三个镜头，保留中文与🙂。"
    try? original.write(to: fixturePath, atomically: true, encoding: .utf8)
    for mode in [WorkspaceMode.canvas, .agent] {
        let label = mode.rawValue
        let transport = AgentScriptedTransport(steps: (0..<8).map { _ in
            .sse("data: {\"choices\":[{\"delta\":{\"content\":\"本地回复\"}}]}\n\ndata: [DONE]\n\n")
        })
        let model = AgentChatModel(displayName: "键盘测试",
            service: AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture")),
            persistenceURL: directory.appendingPathComponent("composer-\(label).json"))
        // This checks the canvas-styled editor without a live project. Project
        // tool boundaries are covered by runCanvasAgentProbe with a real context.
        func finishReply() async {
            for _ in 0..<100 {
                if !model.isRunning { break }
                await settle(0.05)
            }
            await settle(0.05)
        }
        let host = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: mode))
        let window = NSWindow(contentRect: NSRect(x: 140, y: 100, width: mode == .agent ? 900 : 430, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle(0.4)
        for _ in 0..<50 {
            if editors(host).first?.completion != nil { break }
            await settle(0.05)
        }
        guard let editor = editors(host).first, let completion = editor.completion else {
            check(false, "\(label) composer menu mounted"); window.close(); continue
        }
        func replace(_ text: String) {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        replace("第一行🙂")
        key(editor, 36, .shift)
        editor.insertText("第二行", replacementRange: editor.selectedRange())
        check(model.draft == "第一行🙂\n第二行" && model.messages.isEmpty, "\(label) Shift Enter inserts newline without send")
        key(editor, 36)
        key(editor, 36) // Same event-loop: running guard must prevent a second request.
        check(model.messages.filter { $0.role == .user }.count == 1, "\(label) Return submits exactly once while busy")
        await finishReply()
        check(model.draft.isEmpty && editor.string.isEmpty, "\(label) successful Return clears native draft")
        check(transport.lastRequestJSON()?["messages"]?.arrayValue?.last?["content"]?.stringValue == "第一行🙂\n第二行",
              "\(label) native multiline text reaches request")
        key(editor, 36)
        replace("   \n")
        key(editor, 36)
        check(model.messages.filter { $0.role == .user }.count == 1, "\(label) empty and whitespace Return do not send")
        replace("长按不能发送")
        key(editor, 36, repeatKey: true)
        check(model.messages.filter { $0.role == .user }.count == 1, "\(label) repeated key does not submit")
        key(editor, 76)
        await finishReply()
        check(model.messages.filter { $0.role == .user }.count == 2, "\(label) keypad Enter sends")
        replace("兼容快捷键")
        key(editor, 36, .command)
        await finishReply()
        check(model.messages.filter { $0.role == .user }.count == 3, "\(label) Command Enter still sends once")

        replace("")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        key(editor, 36)
        check(model.messages.filter { $0.role == .user }.count == 3, "\(label) IME Return never sends")
        if editor.hasMarkedText() { editor.unmarkText() }
        replace("")
        editor.setMarkedText("/ji", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        check(!completion.isOpen, "\(label) composing IME suppresses slash menu")
        key(editor, 36, .command)
        check(model.messages.filter { $0.role == .user }.count == 3, "\(label) IME Command Enter never sends")
        if editor.hasMarkedText() { editor.unmarkText() }

        replace("/")
        await settle()
        check(completion.isOpen && completion.rows.first?.title == "/skills", "\(label) slash opens real command menu")
        key(editor, 125)
        check(completion.rows[completion.selected].title == "/model", "\(label) down selects next command")
        key(editor, 126)
        key(editor, 48)
        check(model.draft == "$" && completion.isOpen, "\(label) Tab opens skill search without sending")
        key(editor, 53)
        check(!completion.isOpen && model.draft == "$", "\(label) Escape closes menu and keeps draft")
        let skillButton = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-reference-skill" }
        check(skillButton?.accessibilityPerformPress?() == true, "\(label) visible skill button responds to native press")
        await settle()
        let skillSearch = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
            .first { ($0.accessibilityIdentifier?() ?? "") == "agent-skill-search" }
        check(skillSearch != nil && !completion.isOpen && model.draft == "$",
              "\(label) skill button opens independent search and preserves draft")
        _ = skillButton?.accessibilityPerformPress?()
        await settle()
        replace("$no-such-fixture-123")
        key(editor, 36)
        check(model.messages.filter { $0.role == .user }.count == 3 && !model.draft.isEmpty,
              "\(label) unmatched menu does not accidentally send")
        replace("https://example.test/path")
        check(!completion.isOpen, "\(label) URL slash does not trigger commands")

        replace("🙂 中文 $composer-fixture 保留后文")
        let caret = ("🙂 中文 $composer-fixture" as NSString).length
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.updateCompletion()
        check(completion.rows.count == 1 && completion.rows.first?.isSkill == true, "\(label) searches installed fixture skill")
        key(editor, 36)
        for _ in 0..<30 {
            if !model.isAddingSkill { break }
            await settle(0.02)
        }
        await settle()
        check(model.draftSkillReferences.count == 1 && model.draft == "🙂 中文  保留后文",
              "\(label) skill selection preserves Unicode and surrounding draft")
        check(model.messages.filter { $0.role == .user }.count == 3, "\(label) selecting skill does not submit")
        check(window.firstResponder === editor, "\(label) menu selection keeps editor focus")
        let savedID = model.selectedConversationID
        model.clearHistory()
        check(model.draftSkillReferences.isEmpty, "\(label) new chat has no inherited skills")
        model.openConversation(id: savedID)
        await settle()
        check(model.draftSkillReferences.count == 1, "\(label) conversation switch restores skill draft")
        _ = model.flushSession()
        let restored = AgentChatModel(displayName: "restore", backend: AgentService(transport: transport,
            secretStore: AgentInMemorySecretStore(key: "fixture")),
            persistenceURL: directory.appendingPathComponent("composer-\(label).json"))
        check(restored.draftSkillReferences == model.draftSkillReferences, "\(label) skill draft survives restart")
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("canvas-agent-composer-\(label).png"))
        }
        key(editor, 36)
        await finishReply()
        let sent = model.messages.last { $0.role == .user }
        let body = transport.lastRequestJSON()?["messages"]?.arrayValue?.last?["content"]?.stringValue ?? ""
        check(sent?.skillReferences?.count == 1 && body.contains("COMPOSER_SNAPSHOT_SENTINEL"),
              "\(label) selected skill snapshot reaches actual backend request")
        check(model.draftSkillReferences.isEmpty && model.transcript.count > 0,
              "\(label) sent skill moves from composer into history")
        replace("/")
        await settle()
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("canvas-agent-menu-\(label).png"))
        }
        window.close()
    }
    let isolated = AgentChatModel(displayName: "skill isolation", backend: AgentService(
        transport: AgentScriptedTransport(steps: []), secretStore: AgentInMemorySecretStore(key: "fixture")))
    isolated.addSkillReference(name: "fixture", path: fixturePath.path)
    check(!isolated.send(text: "wait", config: AgentConfig(), enabledSkills: []), "send waits for skill snapshot read")
    isolated.clearHistory()
    await settle()
    check(isolated.draftSkillReferences.isEmpty, "late skill read cannot enter a different conversation")
    isolated.addSkillReference(name: "fixture", path: fixturePath.path)
    await settle()
    try? "changed after selection".write(to: fixturePath, atomically: true, encoding: .utf8)
    check(isolated.draftSkillReferences.first?.markdown == original, "selected skill freezes complete original markdown")
    isolated.addSkillReference(name: "duplicate", path: fixturePath.path)
    await settle()
    check(isolated.draftSkillReferences.count == 1, "duplicate skill selection is idempotent")
    let frozen = AgentMessage(role: .user, content: "应用", skillReferences: isolated.draftSkillReferences)
    check(AgentService.requestBody(history: [frozen], config: AgentConfig(systemPrompt: ""), tools: [])["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains("三个镜头") == true,
          "DeepSeek input includes frozen skill instructions")
    check((try? JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(frozen))) == frozen,
          "skill message persists all snapshot fields")
    isolated.draftSkillReferences = []
    isolated.addSkillReference(name: "missing", path: directory.appendingPathComponent("missing-skill.md").path)
    await settle()
    check(isolated.draftSkillReferences.isEmpty && isolated.errorText != nil, "missing skill reports error without adding reference")
    let oversized = directory.appendingPathComponent("oversized-skill.md")
    try? Data(repeating: 65, count: AgentSkillReference.maximumBytes + 1).write(to: oversized)
    check((try? AgentSkillReference.load(name: "large", path: oversized.path)) == nil,
          "oversized skill is rejected rather than silently truncated")
}
#endif
