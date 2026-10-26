#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentComposerLayoutProbe(directory: URL, check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        let fallback = (node as? NSView)?.subviews ?? []
        return [node] + (children.isEmpty ? fallback : children).flatMap {
            elements($0 as AnyObject, depth: depth + 1)
        }
    }
    func editors(_ view: NSView) -> [AgentDraftEditor.Editor] {
        (view as? AgentDraftEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    let originalSkin = AppSkinCenter.current
    defer { AppSkinCenter.apply(originalSkin) }
    let model = AgentChatModel(displayName: "Skill 布局",
        backend: AgentService(transport: AgentScriptedTransport(steps: []),
                              secretStore: AgentInMemorySecretStore(key: "fixture")))
    model.draft = "布局验证草稿🙂"
    let references = (0..<4).map { index in
        AgentSkillReference(name: index == 0 ? "byteartist-core"
                           : "超长技能名称用于检查窄窗口排版和横向滚动-\(index)",
                           path: "/fixture/skill-\(index)/SKILL.md", markdown: "fixture \(index)")
    }
    let host = NSHostingView(rootView: AgentSidebarView(
        model: model, isVisible: .constant(true), workspaceMode: .canvas))
    let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 480, height: 720),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    var geometry: [[String: Any]] = []
    var allAligned = true
    var allInside = true
    var allEditorStable = true
    var allLabelsAligned = true
    var polishAndModelSeparated = true
    for mode in WorkspaceMode.allCases {
        let widths: [CGFloat] = mode == .agent ? [360, 480, 800, 1200] : [AgentSidebarView.width]
        for skin in [AppSkin.minimal, .colorful] {
            AppSkinCenter.apply(skin)
            for appearance in ["light", "dark"] {
                window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                for width in widths {
                    window.setContentSize(NSSize(width: width, height: 720))
                    var originalEditorFrame: CGRect?
                    for count in [0, 1, 4] {
                        model.draftSkillReferences = Array(references.prefix(count))
                        host.rootView = AgentSidebarView(
                            model: model, isVisible: .constant(true), workspaceMode: mode)
                        await settle()
                        host.layoutSubtreeIfNeeded()
                        let nodes = elements(host)
                        func frame(_ id: String) -> CGRect? {
                            nodes.first { ($0.accessibilityIdentifier?() ?? "") == id }?
                                .accessibilityFrame?()
                        }
                        let label = "\(mode.rawValue)-\(skin.rawValue)-\(appearance)-\(Int(width))-\(count)"
                        let skill = frame("agent-reference-skill"), context = frame("agent-context-usage")
                        let add = frame("agent-composer-add"), voice = frame("agent-voice-input")
                        let picker = frame("agent-model-picker")
                        let polish = frame("agent-ai-polish")
                        polishAndModelSeparated = polishAndModelSeparated && (polish.map { p in
                            picker.map { abs(p.midY - $0.midY) < 2 && p.maxX <= $0.minX + 1 } ?? false
                        } ?? false)
                        let row = frame("agent-composer-toolbar")
                        let editorFrame = editors(host).first.map { editor in
                            window.convertToScreen(editor.convert(editor.bounds, to: nil))
                        }
                        if originalEditorFrame == nil { originalEditorFrame = editorFrame }
                        let aligned = add.map { s in
                            context.map { p in abs(s.midY - p.midY) < 2 && s.maxX < p.minX } ?? false
                        } ?? false
                        let contentFrame = window.convertToScreen(host.frame)
                        let inside = [add, context, voice, picker, polish, editorFrame].allSatisfy {
                            guard let f = $0 else { return false }
                            return f.minX >= contentFrame.minX - 2
                                && f.maxX <= contentFrame.maxX + 2
                                && f.minY >= contentFrame.minY - 2
                                && f.maxY <= contentFrame.maxY + 2
                        }
                        let stable = editorFrame.map { e in
                            originalEditorFrame.map { abs(e.maxY - $0.maxY) < 2 } ?? false
                        } ?? false
                        let chip = frame("agent-remove-skill-\(references[0].id)")
                        let labelsAligned = count == 0 || (chip.map { c in
                            skill.map { abs(c.midY - $0.midY) < 2 } ?? false
                        } ?? false)
                        allAligned = allAligned && aligned
                        allInside = allInside && inside
                        allEditorStable = allEditorStable && stable
                        allLabelsAligned = allLabelsAligned && labelsAligned
                        geometry.append(["case": label, "controlsAligned": aligned,
                                         "insideWindow": inside, "editorStable": stable,
                                         "labelsAligned": labelsAligned,
                                         "skill": skill.map(NSStringFromRect) ?? "missing",
                                         "context": context.map(NSStringFromRect) ?? "missing",
                                         "chip": chip.map(NSStringFromRect) ?? "none",
                                         "editor": editorFrame.map(NSStringFromRect) ?? "missing"])
                        if count == 4 && (width == 480 || (mode == .agent && width == 360)) {
                            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: image)
                                try? image.representation(using: .png, properties: [:])?.write(
                                    to: directory.appendingPathComponent("skill-layout-\(label).png"))
                            }
                        }
                    }
                }
            }
        }
    }
    check(allAligned, "add and context controls share the bottom row across widths and themes")
    check(allInside, "composer controls stay within each tested window")
    check(allEditorStable, "adding Skill references does not move the editor vertically")
    check(allLabelsAligned, "selected Skill labels align with the Skills control in the reference row")
    check(polishAndModelSeparated, "AI polish and model picker remain separate aligned controls in all widths and four themes")
    let nodes = elements(host)
    if let remove = nodes.first(where: {
        ($0.accessibilityIdentifier?() ?? "") == "agent-remove-skill-\(references[0].id)"
    }) {
        _ = remove.accessibilityPerformPress?()
        await settle()
        check(model.draftSkillReferences.count == 3 && model.draft == "布局验证草稿🙂",
              "native Skill removal preserves the draft and other references")
    } else {
        check(false, "native Skill removal is accessible")
    }
    for _ in 0..<20 {
        if !AgentSkillLibrary.shared.isScanning { break }
        await settle()
    }
    if let skill = elements(host).first(where: {
        ($0.accessibilityIdentifier?() ?? "") == "agent-reference-skill"
    }) {
        _ = skill.accessibilityPerformPress?()
        await settle()
        let popoverElements = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
        check(popoverElements.contains {
            ($0.accessibilityIdentifier?() ?? "") == "agent-skill-search"
        }, "toolbar Skills action opens its selection popover")
        if let pick = popoverElements.first(where: {
            ($0.accessibilityIdentifier?() ?? "").hasPrefix("agent-skill-pick-")
                && ($0.accessibilityIdentifier?() ?? "").contains("composer-fixture")
        }) {
            _ = pick.accessibilityPerformPress?()
            for _ in 0..<20 {
                await settle()
                if !model.isAddingSkill { break }
            }
            check(model.draftSkillReferences.contains { $0.name == "composer-fixture" }
                  && model.draft == "布局验证草稿🙂",
                  "native Skills selection preserves draft and adds its frozen reference")
        } else {
            check(false, "selection popover exposes the local fixture Skill")
        }
    } else {
        check(false, "toolbar Skills action is accessible")
    }
    try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("skill-layout-geometry.json"))
    model.draft = ""
    await settle()
    let emptyPolish = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-ai-polish" }
    check(emptyPolish?.isAccessibilityEnabled?() == false, "empty draft disables the direct AI polish action")
    model.draft = "润色前🙂"
    let transport = AgentScriptedTransport(steps: [.sse(
        "data: {\"choices\":[{\"delta\":{\"content\":\"润色后🙂\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
    model.setBackend(AgentService(transport: transport, secretStore: AgentInMemorySecretStore(key: "fixture")), kind: .deepseek)
    await settle()
    if let polish = elements(host).first(where: { ($0.accessibilityIdentifier?() ?? "") == "agent-ai-polish" }) {
        _ = polish.accessibilityPerformPress?()
        for _ in 0..<50 {
            await settle()
            if !model.isPolishing { break }
        }
        check(model.draft == "润色后🙂" && !model.isRunning,
              "native sparkle button polishes the draft without submitting an Agent task")
        let request = await transport.lastRequestJSON()
        check(request?["tools"] == nil && request?["model"] != nil,
              "direct AI polish uses the selected text model without tools")
    } else { check(false, "direct AI polish is accessible") }
    window.close()
}
#endif
