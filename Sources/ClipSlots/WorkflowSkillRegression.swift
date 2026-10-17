#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runWorkflowSkillProbe(store: SlotStoreObservable, canvas: CanvasStore,
                           directory: URL, check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        return [node] + (children.isEmpty ? (node as? NSView)?.subviews ?? [] : children)
            .flatMap { elements($0 as AnyObject, depth: depth + 1) }
    }
    func find(_ view: NSView, _ id: String) -> AnyObject? {
        elements(view).first { ($0.accessibilityIdentifier?() ?? "") == id }
    }
    func press(_ view: NSView, _ id: String) -> Bool {
        find(view, id)?.accessibilityPerformPress?() == true
    }
    func fill(_ view: NSView, _ id: String, _ value: String) -> Bool {
        guard let field = find(view, id) else { return false }
        // AX value setters change AppKit display text without sending SwiftUI's edit
        // notifications. Use the real field editor, as keyboard input does.
        guard let control = (field as? NSTextField) ?? ((field as? NSCell)?.controlView as? NSTextField),
              let window = control.window else {
            NSLog("[WorkflowProbe] field %@ type %@", id, String(describing: type(of: field)))
            return false
        }
        window.makeFirstResponder(control)
        guard let editor = window.fieldEditor(true, for: control) as? NSTextView else { return false }
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        return control.stringValue == value
    }
    func capture(_ view: NSView, _ name: String) {
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
    }
    func deepestSheet(_ window: NSWindow) -> NSWindow {
        window.sheets.first.map(deepestSheet) ?? window
    }
    do {
        let sourceProject = canvas.createProject(name: "Skill 原生验收")
        let group = try store.specialStorage.createSpecialSlot(name: "Skill 源素材")
        for (index, text) in ["柠檬汽水，柔光产品特写", "保留瓶身比例与商标，浅色背景", "缓慢推进，三秒停留"].enumerated() {
            check(store.specialStorage.set(index + 1, content: SlotContent(text: text), in: group.id),
                  "workflow native source \(index + 1)")
            _ = store.specialStorage.setLabel(index + 1, label: ["产品", "审美约束", "镜头"][index], in: group.id)
            canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: index + 1,
                             name: ["产品", "审美约束", "镜头"][index],
                             at: [CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 360), CGPoint(x: 500, y: 205)][index])
        }
        for node in canvas.nodes { canvas.updateNode(id: node.id) { $0.kind = .text } }
        let sourceNodes = canvas.nodes
        check(canvas.connect(from: sourceNodes[0].id, to: sourceNodes[2].id, role: .prompt) == nil
              && canvas.connect(from: sourceNodes[1].id, to: sourceNodes[2].id, role: .prompt) == nil,
              "workflow native ordered prompt edges")
        canvas.selectedNodeIds = [sourceNodes[2].id]
        let sessions = AgentSessionStore()
        let model = sessions.canvasSession(canvas: canvas, store: store)
        model.setBackend(WorkflowSkillFixtureBackend())
        guard let context = model.canvasContext else { check(false, "workflow context exists"); return }
        model.send(text: CanvasAgentContext.summarizePrompt, config: AgentConfig(), enabledSkills: [])
        await settle()
        let host = NSHostingView(rootView: AnyView(AgentSidebarView(model: model, isVisible: .constant(true))))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 80, width: 400, height: 860),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.stop() }
        await settle()
        check(press(host, "agent-save-workflow-skill"), "native reply opens Skill editor")
        await settle()
        guard let editor = window.sheets.first?.contentView else {
            check(false, "native Skill sheet is presented"); return
        }
        check(context.skillDraft?.skill.graph.nodes.count == 3 && context.skillDraft?.skill.graph.edges.count == 2,
              "native Skill draft includes full graph and ordered edges")
        check(fill(editor, "workflow-skill-name", "柔光饮品工作流"), "native Skill name editable")
        await settle()
        check(fill(editor, "workflow-skill-summary", "适用于饮品静物与产品特写"), "native Skill scenario editable")
        await settle()
        capture(editor, "canvas-workflow-skill-editor.png")
        check(press(editor, "workflow-skill-save"), "native Skill save confirms")
        await settle()
        let libraryStore = WorkflowSkillStore()
        guard let entry = libraryStore.list(projectID: context.projectID).first(where: { $0.name == "柔光饮品工作流" }) else {
            check(false, "native save persists named Skill"); return
        }
        let original = try libraryStore.load(entry, projectID: context.projectID)
        check(original.version == 1 && original.summary.contains("饮品") && window.sheets.isEmpty,
              "native save commits version and dismisses sheet")
        check(original.method.contains("验收标准") && original.provenance.snapshotID == model.messages.first?.canvasTurn?.snapshotID,
              "native save retains method and frozen provenance")

        // Seed a field binding, then exercise the same native new-version editor used by the library.
        var changed = original
        let product = changed.graph.nodes.first { $0.body.contains("柠檬汽水") }!
        changed.graph.variables.append(.init(id: "product", name: "产品名称", kind: .text,
            defaultValue: .text("柠檬汽水"), bindings: [.init(nodeID: product.id, field: .body, match: "柠檬汽水")]))
        let versionHost = NSHostingView(rootView: WorkflowSkillEditor(draft: changed, context: context, original: original))
        let versionWindow = NSWindow(contentRect: NSRect(x: 160, y: 80, width: 780, height: 660),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        versionWindow.isReleasedWhenClosed = false; versionWindow.contentView = versionHost
        versionWindow.makeKeyAndOrderFront(nil)
        await settle()
        check(press(versionHost, "workflow-skill-save"), "native editor saves parameterized new version")
        await settle()
        versionWindow.close()
        guard let latest = libraryStore.list(projectID: context.projectID).first(where: { $0.id == entry.id }) else {
            check(false, "updated Skill remains discoverable"); return
        }
        let preserved = try libraryStore.load(entry, projectID: context.projectID)
        check(latest.version == 2 && preserved.graph.variables.isEmpty,
              "new version preserves old immutable graph")
        let saved = try libraryStore.load(latest, projectID: context.projectID)
        check(saved.graph.variables.count == 1, "native new version retains explicit field binding")
        check(press(host, "agent-workflow-skills"), "native composer opens Skill library")
        await settle()
        guard let library = window.sheets.first?.contentView else {
            check(false, "native library sheet exists"); return
        }
        check(fill(library, "workflow-skill-search", "不匹配的名字"), "native library search editable")
        await settle()
        check(find(library, "workflow-skill-reuse") == nil, "native library filters unmatched names")
        _ = fill(library, "workflow-skill-search", "饮品")
        await settle()
        capture(library, "canvas-workflow-skill-library.png")
        check(press(library, "workflow-skill-reference"), "native library reference responds")
        await settle()
        for _ in 0..<50 {
            if !model.isAddingSkill { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        NSLog("[WorkflowProbe] reference count=%d adding=%d error=%@",
              model.draftSkillReferences.count, model.isAddingSkill ? 1 : 0, model.errorText ?? "none")
        check(model.draftSkillReferences.first?.markdown.contains("验收标准") == true
              && model.draftSkillReferences.first?.markdown.contains("工作流版本：2") == true,
              "native reference freezes verified versioned method")
        model.draftSkillReferences = []
        model.draft = "$柔光"
        await settle()
        check(find(host, "agent-completion-" + libraryStore.markdownURL(latest).path) != nil,
              "dollar completion discovers personal workflow")
        model.draft = ""
        check(press(host, "agent-workflow-skills"), "native library reopens for reuse")
        await settle()
        guard let reopened = window.sheets.first?.contentView else {
            check(false, "native reuse library exists"); return
        }
        check(press(reopened, "workflow-skill-reuse"), "native library opens reuse form")
        await settle()
        guard let reuse = deepestSheet(window).contentView else { return }
        check(fill(reuse, "workflow-skill-value-product", "葡萄气泡水"), "native reuse variable editable")
        await settle()
        check(fill(reuse, "workflow-skill-project-name", "葡萄气泡水广告"), "native reuse project name editable")
        await settle()
        check(press(reuse, "workflow-skill-preview-graph"), "native reuse renders graph preview")
        await settle()
        capture(reuse, "canvas-workflow-skill-preview.png")
        check(canvas.activeProjectId == sourceProject.id && canvas.nodes == sourceNodes,
              "preview creates no project or node")
        check(press(reuse, "workflow-skill-create-project"), "native preview confirms complete project")
        await settle()
        check(canvas.activeProjectId != sourceProject.id && canvas.activeProject.name == "葡萄气泡水广告"
              && canvas.nodes.count == 3 && canvas.edges.count == 2, "native create activates entire new workflow")
        let newNodes = canvas.nodes, newEdges = canvas.edges
        guard let target = canvas.nodes.first(where: {
            store.canvasSlotText(groupId: $0.groupId, slot: $0.slot)?.contains("葡萄气泡水") == true
        }) else { check(false, "native creation persists substituted body"); return }
        check(store.canvasSlotText(groupId: target.groupId, slot: target.slot) == "葡萄气泡水，柔光产品特写",
              "native substitution preserves unbound prompt text")
        check(store.canvasSlotText(groupId: group.id, slot: 1) == "柠檬汽水，柔光产品特写",
              "native reuse leaves source content unchanged")
        check(canvas.undo() != nil && canvas.nodes.isEmpty && canvas.edges.isEmpty,
              "native whole-workflow undo removes all nodes and edges")
        check(canvas.redo() != nil && canvas.nodes == newNodes && canvas.edges == newEdges,
              "native whole-workflow redo restores stable identities")
        check(store.writeCanvasSlotText(groupId: target.groupId, slot: target.slot, text: "手改，保留这段"),
              "native workflow manual edit fixture")
        let cursor = canvas.history.cursor
        check(canvas.undo() == nil && canvas.history.cursor == cursor && canvas.agentHistoryError != nil
              && store.canvasSlotText(groupId: target.groupId, slot: target.slot) == "手改，保留这段",
              "native group undo refuses later manual content edits")

        // Mount the actual canvas with an imported image so asynchronous media probing is included.
        let png = directory.appendingPathComponent("workflow-reference.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!
        try bytes.write(to: png)
        let mediaNode = CanvasNode(pageId: "", groupId: "source", slot: 1, kind: .image, mediaRole: .source, x: 120, y: 100)
        let graph = CanvasWorkflowSnapshot(projectID: "media-test", facts: [
            .init(node: mediaNode, title: "产品参考", body: "柔光素材", bodyRevision: "r1")
        ], edges: [], selectionIDs: [])
        let mediaSkill = try WorkflowSkill(snapshot: .init(graph: graph, runs: []), method: "参考图复用", messageID: nil, receipts: [])
        let mediaInstance = try mediaSkill.instantiate(values: [mediaSkill.graph.variables[0].id: .resources([png.path])])
        try await canvas.createWorkflowProject(name: "媒体复用原生验收", instance: mediaInstance)
        let initialMedia = canvas.nodes[0]
        let canvasHost = NSHostingView(rootView: CanvasWorkspaceView(store: store, canvas: canvas, agentVisible: .constant(false)))
        let canvasWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 720),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        canvasWindow.isReleasedWhenClosed = false; canvasWindow.contentView = canvasHost
        canvasWindow.makeKeyAndOrderFront(nil)
        defer { canvasWindow.close() }
        for _ in 0..<10 {
            await settle()
            if canvas.nodes.first?.mediaLayoutAttachmentID != initialMedia.mediaLayoutAttachmentID { break }
        }
        check(canvas.nodes.first?.mediaLayoutAttachmentID != initialMedia.mediaLayoutAttachmentID,
              "actual canvas completes asynchronous media probe")
        check(canvas.nodes.first?.frame == initialMedia.frame, "media probe preserves reused layout")
        let screenMinX = initialMedia.frame.minX * canvas.zoom + canvas.pan.width
        let screenMaxX = initialMedia.frame.maxX * canvas.zoom + canvas.pan.width
        check(canvas.workflowFitRequest == nil
              && screenMinX >= CanvasSlotLibraryPanel.width(expanded: canvas.isLibraryExpanded)
              && screenMaxX <= canvasHost.bounds.width,
              "new workflow automatically fits visible canvas outside library")
        capture(canvasHost, "canvas-workflow-created-media.png")
        check(canvas.undo() != nil && canvas.nodes.isEmpty, "whole-workflow undo works after actual media probe")
        check(canvas.redo() != nil && canvas.nodes.count == 1
              && store.canvasSlotAttachments(groupId: initialMedia.groupId, slot: initialMedia.slot).first?.resolveData() == bytes,
              "whole-workflow redo restores actual managed media bytes")
        canvas.flushSave()
    } catch { check(false, "native workflow exception: \(error.localizedDescription)") }
}

private final class WorkflowSkillFixtureBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        let answer = AgentMessage(role: .assistant, content: """
        ## 柔光饮品创作方法
        适用场景：饮品静物与产品特写。
        可变输入：产品名称；保持正文中的柔光描述。
        稳定步骤：将产品描述与审美约束通过 prompt 连线汇入镜头节点，核对瓶身比例后生成。
        验收标准：商标可读、背景干净、光线一致。
        已知限制：本次为原生界面测试回复，没有调用真实模型或读取媒体内容。
        """)
        await onEvent(.assistantCompleted(answer))
        return [answer]
    }
}
#endif
