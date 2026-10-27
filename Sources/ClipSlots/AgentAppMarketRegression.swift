#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit
import Vision

private final class MarketFixtureBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] { [] }
}

@MainActor
func runAgentAppMarketRegression(store: SlotStoreObservable, root: URL) async {
    var passed: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        (value ? passed.append(name) : failures.append(name))
        NSLog("[AgentMarket] %@ %@", value ? "PASS" : "FAIL", name)
    }
    let oldSkin = AppSkinCenter.current
    let oldAppearance = NSApp.appearance
    let oldEnabled = UserDefaults.standard.object(forKey: AgentPreferences.enabledSkillsKey)
    defer {
        AppSkinCenter.apply(oldSkin); NSApp.appearance = oldAppearance
        if let oldEnabled { UserDefaults.standard.set(oldEnabled, forKey: AgentPreferences.enabledSkillsKey) }
        else { UserDefaults.standard.removeObject(forKey: AgentPreferences.enabledSkillsKey) }
    }
    func find(_ root: NSView, _ id: String) -> AnyObject? {
        NativeAccessibilityProbe.elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
    }
    func press(_ root: NSView, _ id: String) -> Bool { find(root, id)?.accessibilityPerformPress?() == true }
    func settle() async { try? await Task.sleep(for: .milliseconds(220)) }
    func fill(_ view: NSView, _ id: String, _ text: String) -> Bool {
        guard let element = find(view, id),
              let field = (element as? NSTextField) ?? ((element as? NSCell)?.controlView as? NSTextField),
              let window = field.window else { return false }
        window.makeFirstResponder(field)
        guard let editor = window.fieldEditor(true, for: field) as? NSTextView else { return false }
        editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        return field.stringValue == text
    }
    func capture(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
        } else { check(false, name + " native bitmap") }
        let elements = NativeAccessibilityProbe.elements(view).map { element -> [String: String] in
            ["id": element.accessibilityIdentifier?() ?? "", "label": element.accessibilityLabel?() ?? "",
             "value": ((element as? NSAccessibilityProtocol)?.accessibilityValue() as? String) ?? ""]
        }
        try? JSONSerialization.data(withJSONObject: elements, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name + ".ax.json"))
    }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NativeAccessibilityProbe.enable()
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root.appendingPathComponent("canvas")),
                                 projectStorage: CanvasProjectStorage(rootOverride: root.appendingPathComponent("canvas")))
        let model = AgentSessionStore().canvasSession(canvas: canvas, store: store)
        model.setBackend(MarketFixtureBackend())
        let skillFile = root.appendingPathComponent("SKILL.md")
        let markdown = "# 本地市场测试\n\n保持角色、比例和素材一致。"
        try markdown.write(to: skillFile, atomically: true, encoding: .utf8)
        let skill = AgentSkill(slug: "market-fixture", name: "角色一致性",
            description: "根据真实本地技能保持创作一致性", version: "1.0", directory: root.path,
            markdownPath: skillFile.path, source: .bundled, declaredTools: [], scripts: [])
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 440, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); model.stop() }
        for skin in [AppSkin.minimal, .colorful] {
            AppSkinCenter.apply(skin)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for width in [360, 440, 960] {
                    let suffix = "\(skin.rawValue)-\(dark ? "dark" : "light")-\(width)"
                    UserDefaults.standard.set("", forKey: AgentPreferences.enabledSkillsKey)
                    model.draft = "保留原草稿🙂"
                    model.draftSkillReferences = []
                    let session = model.selectedConversationID
                    let graph = canvas.nodes
                    var closed = 0, used = 0
                    let host = NSHostingView(rootView: AgentAppMarketView(model: model, fixtureSkills: [skill],
                        onClose: { closed += 1 }, onUse: { used += 1 }))
                    window.contentView = host; window.setContentSize(CGSize(width: width, height: 760))
                    window.makeKeyAndOrderFront(nil)
                    await settle()
                    capture(host, "market-home-" + suffix)
                    check(find(host, "agent-app-market") != nil && find(host, "agent-market-featured-brand") != nil,
                          suffix + " actual native market and featured applications")
                    check(press(host, "agent-market-featured-brand"), suffix + " featured card opens detail")
                    await settle()
                    _ = press(host, "agent-market-primary")
                    check(used == 0 && model.draft == "保留原草稿🙂",
                          suffix + " required topic prevents empty trial")
                    check(fill(host, "agent-market-topic", "柠檬汽水"), suffix + " native topic input")
                    check(fill(host, "agent-market-requirements", "清爽，保持产品原比例"), suffix + " native requirement input")
                    await settle(); capture(host, "market-detail-" + suffix)
                    check(press(host, "agent-market-primary"), suffix + " trial fills actual conversation")
                    check(used == 1 && model.draft.hasPrefix("保留原草稿🙂\n\n")
                            && model.draft.contains("柠檬汽水") && model.draft.contains("保持产品原比例")
                            && model.selectedConversationID == session && canvas.nodes == graph,
                          suffix + " trial preserves draft session and canvas without generation")
                    check(press(host, "agent-market-back"), suffix + " detail returns to market")
                    await settle()
                    check(press(host, "agent-market-category-品牌设计"), suffix + " category filter responds")
                    await settle()
                    check(find(host, "agent-market-item-brand") != nil && find(host, "agent-market-item-film") == nil,
                          suffix + " category filter renders only matching creative applications")
                    check(press(host, "agent-market-tab-skills"), suffix + " skills tab responds")
                    await settle()
                    check(press(host, "agent-market-item-skill-market-fixture"), suffix + " real local skill opens")
                    await settle()
                    check(press(host, "agent-market-enable-skill"), suffix + " actual skill enable action")
                    await settle()
                    let enabled = AgentPreferences.decodeEnabledSlugs(UserDefaults.standard.string(forKey: AgentPreferences.enabledSkillsKey) ?? "")
                    check(enabled == [skill.slug] && AgentSkillTools(enabledSkills: [skill]).specs().contains { $0.name == "read_skill" },
                          suffix + " enabled preferences map to real skill tools")
                    capture(host, "market-skill-" + suffix)
                    let before = model.draft
                    check(press(host, "agent-market-primary"), suffix + " actual skill reference action")
                    for _ in 0..<40 {
                        if !model.isAddingSkill { break }
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    check(model.draftSkillReferences.count == 1 && model.draftSkillReferences.first?.markdown == markdown
                            && model.draft == before, suffix + " reference reads exact local markdown and preserves body")
                    check(press(host, "agent-market-enable-skill"), suffix + " actual skill disable action")
                    await settle()
                    check(AgentPreferences.decodeEnabledSlugs(UserDefaults.standard.string(forKey: AgentPreferences.enabledSkillsKey) ?? "").isEmpty,
                          suffix + " disable removes actual authorization")
                    _ = press(host, "agent-market-back"); await settle()
                    check(fill(host, "agent-market-search", "no-match-4ba965"), suffix + " native market search")
                    await settle(); capture(host, "market-empty-" + suffix)
                    check(find(host, "agent-market-empty") != nil && find(host, "agent-market-item-skill-market-fixture") == nil,
                          suffix + " search renders actual empty result")
                    _ = press(host, "agent-market-clear-search"); await settle()
                    _ = press(host, "agent-market-tab-all"); await settle()
                    check(press(host, "agent-market-item-canvas-mcp"), suffix + " canvas MCP detail opens")
                    await settle(); capture(host, "market-mcp-" + suffix)
                    if let button = find(host, "agent-market-primary"),
                       let rect = button.accessibilityFrame?() {
                        check(rect.width > 100 && window.frame.insetBy(dx: -2, dy: -2).contains(rect),
                              suffix + " detail action fully fits native window")
                    } else { check(false, suffix + " detail action has native bounds") }
                    _ = press(host, "agent-market-back"); await settle()
                    check(press(host, "agent-market-close") && closed == 1 && model.draft == before,
                          suffix + " return-to-conversation preserves complete draft")
                }
            }
        }
        let readOnlyHost = NSHostingView(rootView: AgentAppMarketView(model: model, isReadOnly: true,
            fixtureSkills: [skill], onClose: {}, onUse: {}))
        window.contentView = readOnlyHost; await settle()
        _ = press(readOnlyHost, "agent-market-item-skill-market-fixture"); await settle()
        let beforeRaw = UserDefaults.standard.string(forKey: AgentPreferences.enabledSkillsKey)
        let beforeReferences = model.draftSkillReferences
        _ = press(readOnlyHost, "agent-market-enable-skill")
        _ = press(readOnlyHost, "agent-market-primary")
        await settle()
        check(UserDefaults.standard.string(forKey: AgentPreferences.enabledSkillsKey) == beforeRaw
                && model.draftSkillReferences == beforeReferences,
              "read-only market cannot enable skill or add draft reference")
        model.draftSkillReferences = (0..<4).map { .init(name: "skill\($0)", path: "path\($0)", markdown: "test") }
        let limitHost = NSHostingView(rootView: AgentAppMarketView(model: model, fixtureSkills: [skill], onClose: {}, onUse: {}))
        window.contentView = limitHost; await settle()
        _ = press(limitHost, "agent-market-item-skill-market-fixture"); await settle()
        _ = press(limitHost, "agent-market-primary"); await settle()
        check(model.draftSkillReferences.count == 4 && !model.draftSkillReferences.contains { $0.path == skill.markdownPath },
              "four-reference limit is enforced in actual market action")
        model.draftSkillReferences = []
        let scoped = try model.externalHandoffContext(readOnly: true)
        check(scoped.liveLease?.accessMode == .allDirectoriesReadOnly,
              "read-only market connection creates a truly read-only live lease")
        _ = press(limitHost, "agent-market-back"); await settle()
        _ = press(limitHost, "agent-market-item-canvas-mcp"); await settle()
        check(press(limitHost, "agent-market-primary"), "market action opens actual project MCP handoff")
        await settle()
        if let sheet = window.sheets.first?.contentView {
            check(find(sheet, "agent-external-title") != nil && find(sheet, "agent-external-mcp-help") != nil,
                  "actual MCP handoff has scoped project title and configuration action")
            capture(sheet, "market-actual-mcp-handoff")
            _ = press(sheet, "agent-external-mcp-help"); await settle()
            check(find(sheet, "agent-external-copy-mcp") != nil,
                  "MCP help opens actual scoped installation configuration")
            _ = press(sheet, "agent-external-close")
        } else { check(false, "actual MCP handoff sheet exists") }
        await settle()
        _ = press(limitHost, "agent-market-back"); await settle()
        check(fill(limitHost, "agent-market-search", "ScrollApp"), "market searches actual independent plugin")
        await settle()
        check(press(limitHost, "agent-market-item-plugin-scrollapp-leftclick"), "market opens actual plugin details")
        await settle()
        check(press(limitHost, "agent-market-primary"), "market opens real plugin installation flow")
        await settle()
        if let sheet = window.sheets.first?.contentView {
            var titleRendered = false
            if let bitmap = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
                sheet.cacheDisplay(in: sheet.bounds, to: bitmap)
                if let image = bitmap.cgImage {
                    let text = VNRecognizeTextRequest()
                    text.recognitionLevel = .accurate; text.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([text])
                    titleRendered = (text.results?.compactMap { $0.topCandidates(1).first?.string }.joined() ?? "")
                        .localizedCaseInsensitiveContains("ScrollApp")
                }
            }
            check(titleRendered && find(sheet, "plugins-detail-title-scrollapp-leftclick") != nil
                    && find(sheet, "plugins-close") != nil,
                  "real plugin management shows selected installation item")
            capture(sheet, "market-actual-plugin-installation")
            _ = press(sheet, "plugins-close")
        } else { check(false, "actual plugin installation sheet exists") }
        window.orderOut(nil)
        await runAgentSidebarPagesProbe(model: model, directory: root, check: check)
        await runAgentNativeMCPProbe(store: store, directory: root, check: check)
        check(AgentMarketRecipe.all.allSatisfy { $0.prompt(topic: "", requirements: "", ratio: "16:9") == nil },
              "all five recipes enforce required subject")
        check(Set(AgentMarketRecipe.all.map(\.id)).count == 5
                && !AgentMarketRecipe.all.contains { $0.name.lowercased().contains("tapnow") },
              "five distinct neutral creative applications")
    } catch { check(false, "market fixture: \(error.localizedDescription)") }
    let report: [String: Any] = ["passed": passed, "failures": failures,
        "paid_generation_requests": 0, "themes": 4, "widths": [360, 440, 960],
        "scope": "Native market actions, required inputs, local skill authorization/reference, draft preservation, sidebar menus and live stdio canvas MCP"]
    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("report.json"))
    NSApp.terminate(nil)
}
#endif
