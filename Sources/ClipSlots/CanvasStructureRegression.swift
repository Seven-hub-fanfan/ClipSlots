#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runStructureReplicaProbe(directory: URL) async {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[StructureReplica] %@ %@", value ? "PASS" : "FAIL", name)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = .command) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            return live.inputRouter.routeForRegression(event)
        }
        canvas.isLibraryExpanded = false
        let a = live.createNode(kind: .text, at: CGPoint(x: 150, y: 180), parentNodeId: nil,
                                beginEditing: false, quiet: true)!
        let b = live.createNode(kind: .text, at: CGPoint(x: 650, y: 180), parentNodeId: a.id,
                                beginEditing: false, quiet: true)!
        live.commitEdit(a, text: "副本保留此正文🙂")
        live.commitEdit(b, text: "内部依赖")
        let group = canvas.groupNodes([a.id, b.id])!
        let before = canvas.gatewayDocument(), count = canvas.history.count
        await settle()
        window.makeFirstResponder(anchor)
        check(key(2), "Cmd D is handled by native canvas router")
        await settle()
        let after = canvas.gatewayDocument()
        let copies = after.nodes.filter { node in !before.nodes.contains { $0.id == node.id } }
        check(copies.count == 2 && after.groups.count == before.groups.count + 1,
              "native Cmd D duplicates group and both nodes")
        check(canvas.history.count == count + 1, "group copy is one history entry")
        check(copies.count == 2 && after.edges.contains { $0.fromNodeId == copies[0].id && $0.toNodeId == copies[1].id },
              "native copy remaps internal edge endpoints")
        check(copies.first.map { store.canvasSlotText(groupId: $0.groupId, slot: $0.slot) } == "副本保留此正文🙂",
              "native copy preserves complete body")
        if copies.count == 2 {
            check(key(6), "Cmd Z routes to graph undo")
            await settle()
            check(canvas.nodes == before.nodes && canvas.groups == before.groups && canvas.edges == before.edges,
                  "one native undo restores entire graph")
            check(key(6, [.command, .shift]), "Cmd Shift Z routes to graph redo")
            await settle()
            check(canvas.nodes == after.nodes && canvas.groups == after.groups && canvas.piles == after.piles,
                  "one native redo restores independent graph")
            check(store.canvasSlotText(groupId: copies[0].groupId, slot: copies[0].slot) == "副本保留此正文🙂",
                  "redo restores copied slot content from undo stash")
            check(canvas.flushSave(), "copied graph durably saves")
            let reloaded = CanvasStorage().load(projectId: canvas.activeProjectId)
            check(reloaded.nodes == canvas.nodes && reloaded.groups == canvas.groups, "fresh graph reload retains copy")
            canvas.selectGroup(group.id)
            window.makeFirstResponder(anchor)
            check(key(8), "Cmd C captures selected group")
            live.commitEdit(a, text: "复制后原文已更改")
            window.makeFirstResponder(anchor)
            check(key(9), "Cmd V pastes frozen structure")
            await settle()
            let latest = canvas.nodes.filter { node in !after.nodes.contains { $0.id == node.id } }
            check(latest.count == 2 && latest.first.map {
                store.canvasSlotText(groupId: $0.groupId, slot: $0.slot)
            } == "副本保留此正文🙂", "clipboard is a frozen content snapshot")
            let editor = NSTextView(frame: .zero)
            editor.isEditable = true
            window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
            let nodeCount = canvas.nodes.count
            check(!key(2) && !key(8) && !key(9) && canvas.nodes.count == nodeCount,
                  "text focus owns copy paste and duplicate keys")
            editor.removeFromSuperview(); window.makeFirstResponder(anchor)
            let originalPile = canvas.createPile([a.id, b.id])!
            let pileBefore = canvas.gatewayDocument(), pileHistory = canvas.history.count
            _ = key(2)
            await settle()
            let copiedPile = canvas.piles.last
            check(canvas.piles.count == pileBefore.piles.count + 1 && copiedPile?.id != originalPile.id
                  && copiedPile?.memberIDs.count == 2 && canvas.history.count == pileHistory + 1,
                  "native pile duplicate remaps member identities in one transaction")
            _ = key(6); await settle()
            check(canvas.piles == pileBefore.piles && canvas.nodes == pileBefore.nodes,
                  "pile duplicate undo restores original stack and members")
            var occupied = canvas.privateSlotsReferencedByNodes()
            for slot in 1...60 where !occupied.contains(slot) {
                _ = store.canvasStorage(groupId: canvas.privateGroupId).set(slot, content: SlotContent(text: "容量哨兵"),
                                                                         in: canvas.privateGroupId)
                occupied.insert(slot)
            }
            canvas.selectGroup(group.id)
            let fullGraph = canvas.gatewayDocument(), historyCount = canvas.history.count
            _ = key(2)
            check(canvas.gatewayDocument().nodes == fullGraph.nodes && canvas.history.count == historyCount,
                  "full capacity refusal has no partial nodes or history")
        }
        let graph = CanvasWorkflowCapture.snapshot(canvas: canvas, store: store).0
        let json = (try? JSONValue.decode(jsonText: String(decoding: JSONEncoder().encode(graph), as: UTF8.self))) ?? .null
        check(json["groups"]?.arrayValue?.count == canvas.groups.count, "Agent snapshot includes actual group tree")

        let session = AgentChatModel(displayName: "session identity", backend: StructureSilentBackend(),
                                    persistenceURL: directory.appendingPathComponent("structure-session.json"))
        let original = session.selectedConversationID
        session.clearHistory()
        check(session.selectedConversationID == original, "empty new conversation reuses identity")
        session.draft = "第一会话"; session.clearHistory()
        let second = session.selectedConversationID
        session.deleteConversation(second)
        check(session.selectedConversationID == original && session.draft == "第一会话",
              "active delete restores predecessor draft")
        session.deleteConversation(original)
        check(session.selectedConversationID == original && session.draft.isEmpty,
              "last session reset retains identity")
        let reopened = AgentChatModel(displayName: "reopened", backend: StructureSilentBackend(),
                                      persistenceURL: directory.appendingPathComponent("structure-session.json"))
        check(reopened.selectedConversationID == original && reopened.draft.isEmpty,
              "reset identity survives restart")
        await runAgentPanelResizeProbe(check: check)
        if let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("structure-native.png"))
        }
        let report: [String: Any] = ["passed": passed, "failures": failures, "complete": true,
            "expectedCrateSubmissions": 0,
            "scope": "native AppKit shortcut router, full production Store, session identity and persistence; isolated fixture"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}

private final class StructureSilentBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] { [] }
}
#endif
