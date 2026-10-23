#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runCanvasAgentProbe(store: SlotStoreObservable, directory: URL, check: (Bool, String) -> Void) async {
    NativeAccessibilityProbe.enable()
    func settle() async { try? await Task.sleep(for: .milliseconds(220)) }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        NativeAccessibilityProbe.elements(node)
    }
    do {
        let root = directory.appendingPathComponent("agent-canvas-state")
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root),
                                 projectStorage: CanvasProjectStorage(rootOverride: root))
        let group = try store.specialStorage.createSpecialSlot(name: "回填验证")
        var content = SlotContent(text: "海风拂过旧码头")
        content.htmlSource = "<b>海风拂过旧码头</b>"
        content.attachments = [.init(name: "灯塔参考.png", type: .file, data: Data([7, 2, 5]))]
        check(store.specialStorage.set(1, content: content, in: group.id), "canvas source fixture persisted")
        for slot in 1...4 {
            canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: slot, name: "测试\(slot)",
                             at: CGPoint(x: slot * 300, y: 200))
        }
        let node = canvas.nodes[0]
        canvas.selectedNodeIds = [node.id]
        let sessions = AgentSessionStore()
        let model = sessions.canvasSession(canvas: canvas, store: store)
        let backend = CanvasAgentFixtureBackend()
        model.setBackend(backend)
        guard let context = model.canvasContext else { check(false, "canvas context created"); return }
        let before = AgentSlotBody(content)
        context.addSelection(to: model)
        check(model.draftReferences.count == 1 && model.draftReferences[0].text == before.plainText,
              "explicit selection adds live body reference")
        check(model.draftReferences.first?.attachmentNames == ["灯塔参考.png"] && model.draftAttachments.isEmpty,
              "canvas reference carries names without importing media")
        check(model.draftReferences.first?.contentRevision == content.contentId
              && model.draftReferences.first?.title.contains(group.name) == true,
              "reference includes source revision and unambiguous slot path")
        canvas.selectedNodeIds = Set(canvas.nodes.prefix(3).map(\.id))
        context.addSelection(to: model)
        check(model.draftReferences.count == 3, "three explicit references supported")
        model.draftReferences.removeAll { $0.id != node.id }
        canvas.selectedNodeIds = Set(canvas.nodes.map(\.id))
        context.addSelection(to: model)
        check(model.draftReferences.count == 1 && context.error != nil, "reference limit rejects whole oversized selection")
        canvas.selectedNodeIds = [node.id]
        model.draft = "请改写为一段镜头描述"
        check(model.flushSession(), "canvas draft reference persisted")
        let draftID = model.selectedConversationID
        model.clearHistory()
        model.openConversation(id: draftID)
        check(model.draftReferences.count == 1 && !model.draft.isEmpty, "conversation restores its reference draft")
        model.selectAccessMode(.allDirectoriesReadOnly)
        model.send(text: model.draft, config: AgentConfig(), enabledSkills: [])
        for _ in 0..<150 {
            if !model.isRunning { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        check(!model.isRunning && model.draftReferences.isEmpty, "send freezes and consumes reference draft")
        check(backend.lastHistory.first?.canvasReferences?.first?.text == before.plainText,
              "backend sees frozen reference snapshot")
        check(!backend.previewOnly && backend.toolCount >= 5 && backend.writeDenied,
              "read-only canvas run publishes readers and refuses mutation at dispatch")
        let turn = model.messages.first?.canvasTurn
        check(turn?.nodeCount == 4 && turn?.projectID == canvas.activeProjectId,
              "send freezes full graph metadata beyond explicit references")
        check(turn.map { model.canvasReadReceipts(for: $0).contains { $0.field == "body" } } == true,
              "read receipt reaches project conversation")
        check(store.canvasSlotText(groupId: group.id, slot: 1) == before.plainText, "reply alone never changes slot")
        let answer = model.messages.last?.content ?? ""

        let host = NSHostingView(rootView: AnyView(AgentSidebarView(model: model, isVisible: .constant(true))))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 80, width: 360, height: 740),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.stop() }
        await settle()
        check(elements(host).contains { ($0.accessibilityIdentifier?() ?? "") == "agent-composer-add" },
              "native integrated composer add button accessible")
        check(!elements(host).contains { ["agent-external-handoff", "canvas-connect-agent"]
                .contains($0.accessibilityIdentifier?() ?? "") },
              "native sidebar has no redundant external Agent connection")
        check(elements(host).contains { ($0.accessibilityIdentifier?() ?? "") == "agent-canvas-coverage" },
              "native snapshot coverage visible")
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("canvas-agent-workflow-context.png"))
        }
        let previewButton = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "agent-canvas-preview" }
        check(previewButton?.accessibilityPerformPress?() == true, "native response opens preview")
        await settle()
        check(context.preview?.target.nodeID == node.id && !window.sheets.isEmpty, "preview sheet freezes explicit target")
        // Capture the actual sheet, including the original-body disclosure and editable result.
        if let sheet = window.sheets.first, let view = sheet.contentView {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("canvas-agent-text-preview.png"))
            }
            let apply = elements(view).first { ($0.accessibilityIdentifier?() ?? "") == "agent-canvas-apply" }
            check(apply?.accessibilityPerformPress?() == true, "native confirm apply responds")
            await settle()
            check(store.canvasSlotText(groupId: group.id, slot: 1) == answer, "native apply updates authoritative slot")
            check(canvas.agentFocusRequest?.nodeID == node.id, "applied result requests canvas focus")
            check(!context.apply(conversationID: model.selectedConversationID), "double apply is ignored")
            let undo = elements(view).first { ($0.accessibilityIdentifier?() ?? "") == "agent-canvas-undo" }
            check(undo?.accessibilityPerformPress?() == true, "native undo responds")
            await settle()
            check(AgentSlotBody(store.canvasReadFullContent(groupId: group.id, slot: 1)!) == before,
                  "native undo restores rich body")
        } else { check(false, "native preview sheet content available") }
        context.dismissPreview()
        await settle()
        check(canvas.redo() != nil && store.canvasSlotText(groupId: group.id, slot: 1) == answer, "canvas redo reapplies result")
        check(store.canvasSlotAttachments(groupId: group.id, slot: 1).first?.resolveData() == Data([7, 2, 5]),
              "apply undo redo preserves attachment bytes")
        // Body change after preview must refuse application; the target is independent of selection.
        context.prepare(text: "下一份结果", conversationID: model.selectedConversationID)
        canvas.selectedNodeIds = [canvas.nodes[1].id]
        check(store.writeCanvasSlotText(groupId: group.id, slot: 1, text: "后续手改"), "manual body edit fixture")
        if let turn {
            let frozen = try context.reader(for: turn).snapshot.graph
            check(frozen.nodes.first { $0.id == node.id }?.bodyText == before.plainText,
                  "reading old turn after edits uses original frozen body")
            context.locate(nodeID: node.id, turn: turn)
            check(canvas.agentFocusRequest?.nodeID == node.id, "read source locates live matching node")
        }
        let cursor = canvas.history.cursor
        check(!context.apply(conversationID: model.selectedConversationID) && canvas.history.cursor == cursor,
              "preview conflict never adds history")
        check(canvas.undo() == nil && canvas.history.cursor == cursor
              && store.canvasSlotText(groupId: group.id, slot: 1) == "后续手改",
              "undo refuses later manual edit without moving history cursor")
        check(store.canvasSlotText(groupId: group.id, slot: 2) != "下一份结果", "selection change cannot retarget preview")
        context.dismissPreview()
        canvas.selectedNodeIds = [node.id]
        context.prepare(text: "已删除目标", conversationID: model.selectedConversationID)
        _ = canvas.removeSelected()
        check(!context.apply(conversationID: model.selectedConversationID), "deleted target refuses apply")
        canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: 1, name: "重新创建", at: .zero)
        check(!context.apply(conversationID: model.selectedConversationID), "recreated node ID cannot inherit old preview")

        context.dismissPreview()
        model.draft = "项目A草稿"
        context.addSelection(to: model)
        let projectA = canvas.activeProjectId
        backend.delay = true
        model.send(text: "切换时仍在生成", config: AgentConfig(), enabledSkills: [])
        let projectB = canvas.createProject(name: "隔离项目")
        await settle()
        check(!model.isRunning && model.streamingContent.isEmpty, "project switch stops in-flight run")
        context.addSelection(to: model)
        check(context.error != nil, "inactive project cannot read another project's selection")
        if let turn {
            check((try? context.reader(for: turn)) == nil, "inactive project cannot create snapshot reader")
        }
        // Restore a reference-only draft to verify it survives the round trip.
        model.draftReferences = model.messages.first?.canvasReferences ?? []
        let other = sessions.canvasSession(canvas: canvas, store: store)
        check(projectB.id != projectA && other !== model && other.messages.isEmpty && other.draftReferences.isEmpty,
              "project B has isolated chat and references")
        model.send(text: "旧项目不得发送", config: AgentConfig(), enabledSkills: [])
        check(!model.isRunning, "inactive canvas project refuses send")
        canvas.switchProject(to: projectA)
        let returned = sessions.canvasSession(canvas: canvas, store: store)
        check(returned === model && returned.draft == "项目A草稿" && returned.draftReferences.count == 1,
              "returning to project restores original draft and references")
        returned.flushSession()
        let restarted = AgentSessionStore().canvasSession(canvas: canvas, store: store)
        check(restarted.draft == returned.draft && restarted.draftReferences == returned.draftReferences,
              "restart retains project-scoped draft references")
        check(restarted.messages.first?.canvasTurn == turn, "restart retains frozen turn metadata")
        check(model.messages.first?.canvasReferences?.first?.text == before.plainText, "later edits never alter sent snapshot")
        let currentGroup = store.currentSpecialSlotId
        check(store.writeCanvasSlotText(groupId: currentGroup, slot: 10, text: "排队中的原文"),
              "current-group write enqueued")
        for attempt in 0..<10 {
            do {
                try store.exchangeCanvasAgentBody(groupId: currentGroup, slot: 10,
                    expected: AgentSlotBody(text: "排队中的原文"), replacement: AgentSlotBody(text: "排队后的应用"))
                break
            } catch AgentCanvasError.busy where attempt < 9 {
                // The production 120 ms drain is deliberately bounded. A busy result
                // is safe; let queued writes finish before explicitly retrying.
                await settle()
            }
        }
        await settle()
        check(store.canvasSlotText(groupId: currentGroup, slot: 10) == "排队后的应用"
              && store.specialStorage.get(10, in: currentGroup).plainText == "排队后的应用",
              "queued older snapshots cannot overwrite current-group apply")
        canvas.flushSave()
        await runCanvasAgentActionsProbe(store: store, directory: directory, check: check)
    } catch { check(false, "canvas loop exception: \(error.localizedDescription)") }
}

private final class CanvasAgentFixtureBackend: AgentBackend, @unchecked Sendable {
    var lastHistory: [AgentMessage] = []
    var previewOnly = false
    var toolCount = -1
    var writeDenied = false
    var delay = false
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        lastHistory = history
        previewOnly = config.canvasPreviewOnly
        toolCount = tools?.specs().count ?? -1
        if delay { try await Task.sleep(for: .milliseconds(500)) }
        if let tools, let turn = history.last(where: { $0.role == .user })?.canvasTurn,
           let node = turn.directory.first {
            let args: JSONValue = ["snapshot_id": .string(turn.snapshotID.uuidString),
                                   "node_id": .string(node.id), "field": "body"]
            let call = AgentToolCall(id: UUID().uuidString, name: "canvas_read_node", argumentsJSON: try args.encodedText())
            await onEvent(.assistantCompleted(.init(role: .assistant, content: "", toolCalls: [call])))
            await onEvent(.toolStarted(call))
            let result = await tools.execute(call: call)
            await onEvent(.toolCompleted(callId: call.id, name: call.name, result: result))
            writeDenied = await tools.execute(call: .init(id: "denied", name: "write_slot", argumentsJSON: "{}")).isFailure
        }
        let answer = AgentMessage(role: .assistant, content: "镜头缓缓掠过旧码头，海风吹起衣角，远处的灯塔亮起暖光。")
        await onEvent(.assistantCompleted(answer))
        return [answer]
    }
}
#endif
