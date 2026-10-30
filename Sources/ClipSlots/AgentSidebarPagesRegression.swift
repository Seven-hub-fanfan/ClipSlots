#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentSidebarPagesFixtureProbe(canvas: CanvasStore, store: SlotStoreObservable, directory: URL,
                                     check: (Bool, String) -> Void) async {
    let model = AgentSessionStore().canvasSession(canvas: canvas, store: store)
    model.setBackend(SidebarPagesFixtureBackend())
    await runAgentSidebarPagesProbe(model: model, directory: directory, check: check)
    model.stop()
}

private final class SidebarPagesFixtureBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        []
    }
}

@MainActor
func runAgentSidebarPagesProbe(model: AgentChatModel, directory: URL,
                              references: [AgentCanvasReference] = [],
                              check: (Bool, String) -> Void) async {
    NativeAccessibilityProbe.enable()
    let oldSkin = AppSkinCenter.current
    let oldAppearance = NSApp.appearance
    let oldWidth = UserDefaults.standard.object(forKey: "agent.panel.requestedWidth")
    defer {
        AppSkinCenter.apply(oldSkin); NSApp.appearance = oldAppearance
        if let oldWidth { UserDefaults.standard.set(oldWidth, forKey: "agent.panel.requestedWidth") }
        else { UserDefaults.standard.removeObject(forKey: "agent.panel.requestedWidth") }
    }
    func find(_ root: NSView, _ id: String) -> AnyObject? {
        NativeAccessibilityProbe.elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
    }
    func press(_ root: NSView, _ id: String) -> Bool { find(root, id)?.accessibilityPerformPress?() == true }
    func panel(_ id: String) -> NSView? {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first { find($0, id) != nil }
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(120)) }
    func capture(_ root: NSView, _ name: String, rect: CGRect? = nil) {
        root.layoutSubtreeIfNeeded()
        let nodes: [[String: String]] = NativeAccessibilityProbe.elements(root).map {
            ["id": $0.accessibilityIdentifier?() ?? "", "label": $0.accessibilityLabel?() ?? "",
             "value": (($0 as? NSAccessibilityProtocol)?.accessibilityValue() as? String) ?? ""]
        }
        try? JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".ax.json"))
        let bounds = rect ?? root.bounds
        if let rep = root.bitmapImageRepForCachingDisplay(in: bounds) {
            root.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
    func sidebarRect(_ root: NSView) -> CGRect? {
        guard let frame = find(root, "agent-pages-sidebar")?.accessibilityFrame?(),
              let window = root.window else { return nil }
        return root.convert(window.convertFromScreen(frame), from: nil)
    }
    func visible(_ root: NSView, _ id: String) -> Bool {
        guard let frame = find(root, id)?.accessibilityFrame?(), frame.width > 0, frame.height > 0,
              let window = root.window else { return false }
        return window.frame.insetBy(dx: -2, dy: -2).contains(frame)
    }
    let window = NSWindow(contentRect: CGRect(x: 120, y: 90, width: 1100, height: 740),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    model.clearHistory()
    for skin in AppSkin.allCases {
        AppSkinCenter.apply(skin)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = skin.rawValue + (dark ? "-dark" : "-light")
            for width in [CGFloat(360), 440] {
                UserDefaults.standard.set(Double(width), forKey: "agent.panel.requestedWidth")
                let host = NSHostingView(rootView: HStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity)
                    AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: .canvas,
                                     onToggleExpanded: {})
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("agent-pages-sidebar")
                })
                window.contentView = host
                window.setContentSize(CGSize(width: 1100, height: 740))
                window.makeKeyAndOrderFront(nil)
                // Include WindowServer presentation time after the 750 + 300 ms reveal.
                try? await Task.sleep(for: .milliseconds(1400))
                let name = suffix + "-\(Int(width))"
                if let rect = sidebarRect(host) {
                    check(abs(rect.width - width) <= 1 && abs(rect.maxX - host.bounds.maxX) <= 1,
                          name + " actual sidebar width and right edge match requested main-window layout")
                    capture(host, "agent-page-welcome-" + name, rect: rect)
                    try? JSONSerialization.data(withJSONObject: [
                        "hostWidth": host.bounds.width, "sidebarWidth": rect.width,
                        "sidebarX": rect.minX, "sidebarRight": rect.maxX,
                        "requestedWidth": width, "animationWaitMilliseconds": 1400
                    ], options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("agent-page-layout-" + name + ".json"))
                } else { check(false, name + " native sidebar bounds exist") }
                check(visible(host, "agent-welcome-greeting") && visible(host, "agent-welcome-question"),
                      name + " welcome greeting and question are visible after production reveal")
                check(visible(host, "agent-conversation-chevron"),
                      name + " conversation header exposes a visible dropdown indicator")
                if let menu = find(host, "agent-conversation-menu")?.accessibilityFrame?(),
                   let arrow = find(host, "agent-conversation-chevron")?.accessibilityFrame?() {
                    check(menu.width > 0 && menu.width <= 130 && arrow.minX >= menu.minX + 24
                            && arrow.maxX <= menu.maxX + 2 && arrow.minX >= menu.maxX - 18,
                          name + " short-title chevron stays beside title inside its native menu hit area")
                } else { check(false, name + " native title menu and chevron bounds exist") }
                check(visible(host, "agent-extension-entry") && visible(host, "agent-extension-dismiss"),
                      name + " extension entry and dismiss control fit inside sidebar")
                let priorDraft = model.draft
                check(press(host, "agent-extension-entry"), name + " extension entry opens centered application manager")
                await settle()
                if let picker = panel("agent-application-manager") {
                    capture(picker, "agent-page-extensions-" + name)
                    check(model.draft == priorDraft, name + " extension navigation preserves draft")
                    _ = press(picker, "market-manager-close")
                } else { check(false, name + " centered application manager exists") }
                await settle()
                capture(host, "agent-market-return-" + name, rect: sidebarRect(host))
                check(panel("agent-application-manager") == nil, name + " market returns to conversation")
                check(press(host, "agent-extension-dismiss"), name + " extension entry can be dismissed")
                await settle()
                capture(host, "agent-market-dismiss-" + name, rect: sidebarRect(host))
                check(find(host, "agent-extension-entry") == nil && model.draft == priorDraft
                        && visible(host, "agent-welcome-question") && visible(host, "agent-composer-add"),
                      name + " dismissing promotion preserves welcome composer and draft")
                check(["agent-composer-add", "agent-working-directory", "agent-approval-policy",
                       "agent-screen-capture", "agent-context-usage", "agent-model-picker"].allSatisfy { visible(host, $0) },
                      name + " all six bottom toolbar controls are fully inside native window")
                check(press(host, "agent-working-directory"), name + " opens access menu")
                await settle()
                if let access = panel("agent-access-menu") {
                    check(AgentAccessMode.allCases.allSatisfy { find(access, "agent-access-\($0.rawValue)") != nil },
                          name + " access menu exposes all three actual scopes")
                    capture(access, "agent-page-access-" + name)
                    check(press(access, "agent-access-\(AgentAccessMode.allDirectoriesReadOnly.rawValue)"),
                          name + " selects read-only scope through native menu")
                    await settle()
                    check(model.accessMode == .allDirectoriesReadOnly && panel("agent-access-menu") == nil,
                          name + " selecting scope closes menu and updates actual model")
                } else { check(false, name + " access popup exists") }
                check(press(host, "agent-approval-policy"), name + " opens approval menu")
                await settle()
                if let approval = panel("agent-approval-menu") {
                    capture(approval, "agent-page-approval-" + name)
                    check(press(approval, "agent-approval-automatic"), name + " selects automatic approval")
                    await settle()
                    check(model.automaticApproval && model.accessMode == .allDirectoriesReadOnly,
                          name + " approval choice never changes access scope")
                } else { check(false, name + " approval popup exists") }
                _ = press(host, "agent-approval-policy")
                await settle()
                if let about = panel("agent-approval-menu") {
                    check(press(about, "agent-approval-about"), name + " opens approval explanation")
                    await settle()
                    capture(about, "agent-page-approval-about-" + name)
                } else { check(false, name + " approval about popup exists") }
                _ = press(host, "agent-approval-policy")
                await settle()
                check(press(host, "agent-context-usage"), name + " opens context ring popup")
                await settle()
                if let usage = panel("agent-context-popover") {
                    capture(usage, "agent-page-context-" + name)
                    let labels = NativeAccessibilityProbe.elements(usage).map {
                        ($0.accessibilityLabel?() ?? "") + " " +
                            ((($0 as? NSAccessibilityProtocol)?.accessibilityValue() as? String) ?? "")
                    }.joined(separator: "\n")
                    check(labels.contains("已用 token") && labels.contains("占比") && labels.contains("0%"),
                          name + " empty context shows actual zero usage and zero percentage")
                } else { check(false, name + " context popup exists") }
                _ = press(host, "agent-context-usage")
                await settle()
                _ = press(host, "agent-working-directory")
                await settle()
                model.draft = "跨会话菜单关闭验收"
                model.clearHistory()
                await settle()
                check(panel("agent-access-menu") == nil && panel("agent-approval-menu") == nil
                      && panel("agent-context-popover") == nil,
                      name + " new conversation closes context approval and directory popups")
            }
        }
    }
    if let context = model.canvasContext, let canvas = context.canvas, references.count == 4 {
        model.draft = "逐项引用点击保留正文"
        model.draftReferences = references
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: .canvas)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent-pages-sidebar")
        })
        window.contentView = host
        window.setContentSize(CGSize(width: 1100, height: 740))
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        await settle()
        let graph = canvas.nodes
        for (index, reference) in references.enumerated() {
            let id = "agent-canvas-reference-\(reference.id)"
            if let frame = find(host, id)?.accessibilityFrame?() {
                // AppKit generates tracking-area enter/exit from WindowServer
                // cursor movement, not from an injected mouseMoved queue item.
                let file = directory.appendingPathComponent("agent-sidebar-mouse-events.jsonl")
                var lines = (try? String(contentsOf: file)) ?? ""
                let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
                for point in [window.convertPoint(toScreen: CGPoint(x: 100, y: 400)),
                              CGPoint(x: frame.midX, y: frame.midY)] {
                    let payload: [String: Any] = [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "window": window.windowNumber, "type": CGEventType.mouseMoved.rawValue,
                        "x": point.x, "y": displayHeight - point.y
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload) {
                        lines += String(decoding: data, as: UTF8.self) + "\n"
                    }
                }
                try? lines.write(to: file, atomically: true, encoding: .utf8)
                for _ in 0..<40 {
                    if panel("agent-reference-preview") != nil { break }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                if let preview = panel("agent-reference-preview") {
                    let labels = NativeAccessibilityProbe.elements(preview).map { $0.accessibilityLabel?() ?? "" }.joined(separator: "\n")
                    check(labels.contains(reference.mediaKind?.title ?? "") && labels.contains(reference.title),
                          "reference \(index) native hover shows exact type and title")
                    capture(preview, "agent-page-reference-preview-\(index)")
                } else {
                    capture(host, "agent-page-reference-hover-failed-\(index)")
                    check(false, "reference \(index) native hover opens preview")
                }
                check(press(host, "agent-remove-reference-\(reference.id)"),
                      "reference \(index) native remove control responds")
                await settle()
                check(model.draftReferences.count == 3 - index
                      && !model.draftReferences.contains(where: { $0.id == reference.id })
                      && model.draft == "逐项引用点击保留正文" && canvas.nodes == graph,
                      "reference \(index) removal preserves body graph and remaining references")
            } else { check(false, "reference \(index) native reference frame exists") }
        }
        model.draftReferences = references
        await settle()
        check(press(host, "agent-clear-canvas-references"), "native clear-all reference button responds")
        await settle()
        check(model.draftReferences.isEmpty && model.draft == "逐项引用点击保留正文"
              && canvas.nodes == graph, "native clear-all preserves body and actual canvas")
        model.clearHistory()
    }
    // Model metadata comes through the production service parser. IDs are fixture
    // IDs, so this verifies layout and routing without claiming vendor ratings.
    let options: [AgentDiscoveredModel]
    do {
        options = try AgentModelCatalog.parse(Data(#"""
        {"data":[
          {"id":"auto","automatic":true,"display_name":"Auto"},
          {"id":"fixture-fast","display_name":"Fixture Fast","description":"快速文字与图像模型。","recommended":true,"context_window":128000,"capabilities":{"image_input":true},"ratings":{"intelligence":4,"speed":5,"cost":2,"thinking":3}},
          {"id":"fixture-reason","display_name":"Fixture Reason","description":"逐步推理与分析。","recommended":true,"context_window":256000,"capabilities":{"image_input":false},"ratings":{"intelligence":5,"speed":2,"cost":4,"thinking":5}},
          {"id":"fixture-locked","display_name":"Fixture Locked","subscription_required":true},
          {"id":"fixture-extra","display_name":"Fixture Extra","context_window":64000}
        ]}
        """#.utf8))
    } catch { check(false, "model page fixture parses through real service metadata parser"); return }
    for skin in AppSkin.allCases {
        AppSkinCenter.apply(skin)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for compact in [false, true] {
                var chosen = ""
                var effortConfig: AgentConfig?
                let width: CGFloat = compact ? 260 : 510
                let host = NSHostingView(rootView: AgentSidebarModelPicker(options: options,
                    selected: "fixture-fast", loading: false, notice: nil, compactDetails: compact,
                    refresh: {}, settings: {}, effortModelIDs: ["fixture-reason"],
                    changeEffort: { id, effort in
                        effortConfig = AgentPreferences.config(model: id, systemPrompt: "",
                            thinkingRaw: AgentThinkingMode.enabled.rawValue, reasoningEffort: effort,
                            endpoint: AgentConfig.defaultEndpoint.absoluteString)
                    }, choose: { chosen = $0 }))
                window.contentView = host
                window.setContentSize(CGSize(width: width, height: 740))
                window.makeKeyAndOrderFront(nil)
                await settle()
                let name = skin.rawValue + (dark ? "-dark" : "-light") + (compact ? "-narrow" : "-wide")
                check(press(host, "agent-model-auto") && chosen == "auto", name + " Auto routes actual service ID")
                check(press(host, "agent-model-info-fixture-fast"), name + " opens fast model details")
                await settle()
                check(visible(host, "agent-model-detail"), name + " model details fit inside native window")
                capture(host, "agent-page-model-detail-" + name)
                check(press(host, "agent-model-info-fixture-reason"), name + " changes model details")
                await settle()
                check(visible(host, "agent-model-detail"), name + " changed model details remain inside window")
                for effort in ["low", "high", "max"] {
                    check(press(host, "agent-model-effort-fixture-reason-\(effort)"),
                          name + " native thinking effort \(effort) control responds")
                    await settle()
                    if let config = effortConfig {
                        let body = AgentService.requestBody(history: [], config: config, tools: [])
                        check(body["model"]?.stringValue == "fixture-reason"
                              && body["reasoning_effort"]?.stringValue == effort
                              && body["thinking"]?["type"]?.stringValue == "enabled",
                              name + " thinking \(effort) reaches exact production request body")
                    } else { check(false, name + " thinking choice produces actual configuration") }
                    check(visible(host, "agent-model-detail"), name + " changing effort keeps detail open")
                    capture(host, "agent-page-model-thinking-\(effort)-" + name)
                }
                check(find(host, "agent-model-effort-fixture-reason")?.accessibilityPerformDecrement?() == true,
                      name + " native thinking slider decrements")
                await settle()
                check(effortConfig?.reasoningEffort == "high", name + " slider decrements max to high")
                check(find(host, "agent-model-effort-fixture-reason")?.accessibilityPerformIncrement?() == true,
                      name + " native thinking slider increments")
                await settle()
                check(effortConfig?.reasoningEffort == "max", name + " slider increments high to max")
                check(press(host, "agent-model-more"), name + " expands more models")
                await settle()
                let beforeLocked = chosen
                _ = press(host, "agent-model-choice-fixture-locked")
                check(chosen == beforeLocked, name + " subscription locked model cannot be selected")
                if find(host, "agent-model-search") != nil,
                   let field = NativeAccessibilityProbe.elements(host).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.placeholderString == "搜索模型" }) {
                    field.selectText(nil)
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.insertText("fixture-extra", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    } else { check(false, name + " native search obtains first responder text editor") }
                    await settle()
                    check(find(host, "agent-model-choice-fixture-extra") != nil
                          && find(host, "agent-model-choice-fixture-locked") == nil,
                          name + " native search filters extra models")
                    capture(host, "agent-page-model-search-" + name)
                    check(press(host, "agent-model-choice-fixture-extra") && chosen == "fixture-extra",
                          name + " filtered selection routes exact backend ID")
                } else { check(false, name + " native model search exists") }
            }
        }
    }
}
#endif
