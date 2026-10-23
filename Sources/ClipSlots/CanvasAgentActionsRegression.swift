#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runCanvasAgentActionsProbe(store: SlotStoreObservable, directory: URL,
                                check: (Bool, String) -> Void) async {
    let root = directory.appendingPathComponent("agent-actions-state")
    let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root),
                             projectStorage: CanvasProjectStorage(rootOverride: root))
    _ = canvas.createProject(name: "画布工具验收")
    let model = AgentSessionStore().canvasSession(canvas: canvas, store: store)
    let backend = CanvasAgentActionsFixtureBackend()
    model.setBackend(backend)
    model.selectAccessMode(.fullAccess)
    model.send(text: "创建镜头文本和16:9图片节点，连接并编组。", config: AgentConfig(), enabledSkills: [])
    for _ in 0..<150 where model.isRunning { try? await Task.sleep(for: .milliseconds(80)) }
    check(!model.isRunning && model.errorText == nil, "full access Agent run settles through real host")
    check(backend.failure == nil, "full access native tool chain: \(backend.failure ?? "complete")")
    check(backend.writerCount >= 10 && !backend.previewOnly, "full access publishes native canvas mutation tools")
    check(canvas.nodes.count == 2 && canvas.edges.count == 1 && canvas.groups.count == 1,
          "Agent creates real nodes edges and group")
    let image = canvas.nodes.first { $0.kind == .image }
    let imageAspect = Double(image?.width ?? 0) / max(1.0, Double(image?.height ?? 0))
    let aspectMatches = abs(imageAspect - 16.0 / 9.0) < 0.01
    check(image?.ratio == "16:9" && image?.canGenerate == true && aspectMatches,
          "Agent configuration updates native image dimensions and generation role")
    check(canvas.nodes.filter { $0.kind == .text }.allSatisfy {
        store.canvasSlotText(groupId: $0.groupId, slot: $0.slot) == "镜头缓缓推向海边灯塔"
    }, "Agent body edit reaches authoritative private slot")
    check(backend.conflictDenied && backend.replayPrevented, "stale revision rejected and journal replay has no duplicate effect")
    check(backend.undoRedo && canvas.history.entries.count == 9, "Agent native edits have one undo entry each")
    check(backend.layoutApplied && backend.layoutReplayPrevented,
          "Agent dispatches grid and horizontal layout with real receipts and no replay")
    check(backend.layoutUndoRedo && backend.layoutNoOp,
          "Agent batch layout is one undo redo and unchanged layout has no history")
    check(canvas.flushSave(), "Agent graph durable save succeeds")
    let restored = CanvasStore(storage: CanvasStorage(rootOverride: root),
                               projectStorage: CanvasProjectStorage(rootOverride: root))
    check(restored.nodes == canvas.nodes && restored.edges == canvas.edges && restored.groups == canvas.groups,
          "relaunch reloads Agent-created graph and configuration")
    check(restored.nodes.allSatisfy { store.canvasReadFullContent(groupId: $0.groupId, slot: $0.slot) != nil },
          "relaunch graph references real persisted bodies")
    let context = model.canvasContext
    let turn = try? context?.captureTurn(supportsTools: true)
    if let context, let turn {
        do {
            let readOnly = try context.actionTools(for: turn, mode: .allDirectoriesReadOnly,
                conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { _ in })
            let denied = await readOnly.execute(call: .init(id: "readonly-create", name: "canvas_create_node",
                argumentsJSON: #"{"kind":"text","text":"不能写","x":0,"y":0}"#))
            check(denied.isFailure && canvas.nodes.count == 2
                  && !readOnly.specs().contains { $0.name == "canvas_create_node" },
                  "read-only hides and rejects genuine canvas writers")
            let scope = CanvasAgentFixtureScope()
            let guarded = try context.actionTools(for: turn, mode: .fullAccess,
                conversationID: model.selectedConversationID, isCurrent: { scope.active }, onInteraction: { _ in })
            scope.active = false
            let stale = await guarded.execute(call: .init(id: "old-conversation", name: "canvas_create_node",
                argumentsJSON: #"{"kind":"text","text":"不能写","x":0,"y":0}"#))
            check(stale.isFailure && canvas.nodes.count == 2, "old run or conversation cannot mutate active project")
            let approval = try context.actionTools(for: turn, mode: .selectedDirectories,
                conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { request in
                    _ = try? await request.respond(["decision": "decline"])
                })
            let declined = await approval.execute(call: .init(id: "declined", name: "canvas_create_node",
                argumentsJSON: #"{"kind":"text","text":"不能写","x":0,"y":0}"#))
            check(declined.isFailure && canvas.nodes.count == 2, "declined canvas approval leaves graph and body unchanged")
            let original = canvas.gatewayDocument(), oldHistory = canvas.history.entries.count
            let ids = canvas.nodes.map { JSONValue.string($0.id) }
            func layoutCall(_ id: String, revision: String? = nil, targetIDs: [JSONValue]? = nil) throws -> AgentToolCall {
                .init(id: id, name: "canvas_layout_nodes", argumentsJSON: try JSONValue.object([
                    "node_ids": .array(targetIDs ?? ids), "layout": "grid",
                    "expected_graph_revision": .string(revision ?? AgentCanvasSync.revision(canvas.gatewayDocument()))
                ]).encodedText())
            }
            let layoutDenied = await readOnly.execute(call: try layoutCall("readonly-layout"))
            let layoutDeclined = await approval.execute(call: try layoutCall("declined-layout"))
            let layoutStaleScope = await guarded.execute(call: try layoutCall("old-layout"))
            let direct = try context.actionTools(for: turn, mode: .fullAccess,
                conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { _ in })
            let layoutStaleGraph = await direct.execute(call: try layoutCall("stale-layout", revision: "old-graph"))
            let layoutDuplicate = await direct.execute(call: try layoutCall("duplicate-layout", targetIDs: [ids[0], ids[0]]))
            let layoutMissing = await direct.execute(call: try layoutCall("missing-layout", targetIDs: [ids[0], "missing"]))
            canvas.connectionPolicy.lockedNodeIDs = [canvas.nodes[0].id]
            let layoutLocked = await direct.execute(call: try layoutCall("locked-layout"))
            canvas.connectionPolicy.lockedNodeIDs = []
            canvas.connectionPolicy.readOnly = true
            let layoutCanvasReadOnly = await direct.execute(call: try layoutCall("canvas-readonly-layout"))
            canvas.connectionPolicy.readOnly = false
            let generatingID = canvas.nodes[0].id
            canvas.updateNode(id: generatingID) { $0.state = .queued(ahead: 0) }
            let layoutGenerating = await direct.execute(call: try layoutCall("generating-layout"))
            canvas.updateNode(id: generatingID) { $0.state = .idle }
            check([layoutDenied, layoutDeclined, layoutStaleScope, layoutStaleGraph, layoutDuplicate,
                   layoutMissing, layoutLocked, layoutCanvasReadOnly, layoutGenerating].allSatisfy(\.isFailure),
                  "layout rejects read-only decline stale scope graph duplicate missing lock and generation")
            let stableNodes = canvas.nodes.map { node -> CanvasNode in
                var value = node
                value.updatedAt = original.nodes.first(where: { $0.id == node.id })?.updatedAt ?? node.updatedAt
                return value
            }
            check(stableNodes == original.nodes && canvas.edges == original.edges
                  && canvas.groups == original.groups && canvas.piles == original.piles,
                  "rejected batch layouts preserve graph and media configuration")
            check(canvas.history.entries.count == oldHistory, "rejected layouts add no history")
            let create = try context.actionTools(for: turn, mode: .selectedDirectories,
                conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { request in
                    _ = try? await request.respond(["decision": "accept"])
                })
            let beforeApprovedLayout = canvas.nodes.map(\.frame)
            let layoutApproved = await create.execute(call: try layoutCall("approved-layout"))
            let layoutResult = try JSONValue.decode(jsonText: layoutApproved.content)
            check(!layoutApproved.isFailure && canvas.nodes.map(\.frame) != beforeApprovedLayout
                  && canvas.history.entries.count == oldHistory + 1,
                  "accepted layout approval reaches native Store and one history entry")
            if let id = layoutResult["history_id"]?.stringValue {
                let undoLayout = await create.execute(call: .init(id: "undo-approved-layout", name: "canvas_undo",
                    argumentsJSON: try JSONValue.object(["history_id": .string(id)]).encodedText()))
                check(!undoLayout.isFailure && canvas.groups == original.groups,
                      "accepted batch layout undo restores group layout")
            } else { check(false, "accepted batch layout has real history receipt") }
            let approved = await create.execute(call: .init(id: "approved", name: "canvas_create_node",
                argumentsJSON: #"{"kind":"text","text":"确认后创建","x":700,"y":100}"#))
            let result = try JSONValue.decode(jsonText: approved.content)
            check(!approved.isFailure && canvas.nodes.count == 3, "accepted canvas approval performs real creation")
            if let id = result["history_id"]?.stringValue {
                let undo = await create.execute(call: .init(id: "undo-approved", name: "canvas_undo",
                    argumentsJSON: try JSONValue.object(["history_id": .string(id)]).encodedText()))
                check(!undo.isFailure && canvas.nodes.count == 2, "one undo removes approved node and restores empty body")
            }
        } catch { check(false, "canvas actions guard exception: \(error.localizedDescription)") }
    } else { check(false, "canvas actions frozen turn available") }
    runNativeCanvasLayoutProbe(directory: directory, check: check)
    let host = NSHostingView(rootView: AgentSidebarView(model: model, isVisible: .constant(true)))
    let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 440, height: 740),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    try? await Task.sleep(for: .milliseconds(220))
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("canvas-agent-direct-actions.png"))
    }
    await runAgentScreenCaptureProbe(model: model, host: host, check: check)
    window.close(); model.stop()
}

@MainActor
private final class CanvasAgentFixtureScope { var active = true }

private final class CanvasAgentActionsFixtureBackend: AgentBackend, @unchecked Sendable {
    var failure: String?
    var writerCount = 0
    var previewOnly = true
    var conflictDenied = false
    var replayPrevented = false
    var undoRedo = false
    var layoutApplied = false
    var layoutReplayPrevented = false
    var layoutUndoRedo = false
    var layoutNoOp = false

    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        guard let tools else { failure = "no tools"; return [] }
        previewOnly = config.canvasPreviewOnly
        writerCount = tools.specs().filter { CanvasAgentActionTools.writers.contains($0.name) }.count
        func execute(_ name: String, _ args: JSONValue, id: String = UUID().uuidString,
                     expectFailure: Bool = false) async throws -> JSONValue {
            let call = AgentToolCall(id: id, name: name, argumentsJSON: try args.encodedText())
            await onEvent(.assistantCompleted(.init(role: .assistant, content: "", toolCalls: [call])))
            await onEvent(.toolStarted(call))
            let result = await tools.execute(call: call)
            await onEvent(.toolCompleted(callId: call.id, name: call.name, result: result))
            if result.isFailure != expectFailure { throw AgentOperationError("\(name): \(result.content)") }
            return try JSONValue.decode(jsonText: result.content)
        }
        do {
            let first = try await execute("canvas_create_node", ["kind": "text", "text": "海边灯塔", "x": 100, "y": 120], id: "first-create")
            let replay = try await execute("canvas_create_node", ["kind": "text", "text": "海边灯塔", "x": 100, "y": 120], id: "first-create")
            replayPrevented = first == replay
            guard let nodeID = first["nodes"]?.arrayValue?.first?["node_id"]?.stringValue,
                  let version = first["nodes"]?.arrayValue?.first?["node_revision"]?.stringValue else {
                throw AgentOperationError("creation has no node receipt")
            }
            let edited = try await execute("canvas_edit_node",
                ["node_id": .string(nodeID), "expected_revision": .string(version), "text": "镜头缓缓推向海边灯塔"])
            let rejected = try await execute("canvas_edit_node",
                ["node_id": .string(nodeID), "expected_revision": .string(version), "text": "过期覆盖"], expectFailure: true)
            conflictDenied = rejected["ok"] == false
            guard let editHistory = edited["history_id"]?.stringValue else { throw AgentOperationError("no edit history") }
            _ = try await execute("canvas_undo", ["history_id": .string(editHistory)])
            let undone = try await execute("canvas_get_node", ["node_id": .string(nodeID)])
            _ = try await execute("canvas_redo", ["history_id": .string(editHistory)])
            let redone = try await execute("canvas_get_node", ["node_id": .string(nodeID)])
            undoRedo = undone["body_text"] == "海边灯塔" && redone["body_text"] == "镜头缓缓推向海边灯塔"
            let second = try await execute("canvas_create_node", ["kind": "image", "text": "灯塔镜头", "x": 450, "y": 120])
            guard let imageID = second["nodes"]?.arrayValue?.first?["node_id"]?.stringValue,
                  let imageVersion = second["nodes"]?.arrayValue?.first?["node_revision"]?.stringValue else {
                throw AgentOperationError("no image receipt")
            }
            _ = try await execute("canvas_configure_node", ["node_id": .string(imageID),
                "expected_revision": .string(imageVersion), "ratio": "16:9", "count": 1])
            var current = try await execute("canvas_current", [:])
            _ = try await execute("canvas_connect_nodes", ["from_node_id": .string(nodeID),
                "to_node_id": .string(imageID), "role": "prompt",
                "expected_graph_revision": current["graph_revision"]!])
            current = try await execute("canvas_current", [:])
            _ = try await execute("canvas_group_nodes", ["node_ids": [.string(nodeID), .string(imageID)],
                "name": "灯塔镜头", "expected_graph_revision": current["graph_revision"]!])
            let live = try await execute("canvas_get_node", ["node_id": .string(imageID)])
            _ = try await execute("canvas_move_node", ["node_id": .string(imageID),
                "expected_revision": live["node_revision"]!, "x": 480, "y": 180])
            current = try await execute("canvas_current", [:])
            let beforeLayout = current["nodes"]
            let gridInput: JSONValue = ["node_ids": [.string(nodeID), .string(imageID)],
                                       "layout": "grid", "expected_graph_revision": current["graph_revision"]!]
            let grid = try await execute("canvas_layout_nodes", gridInput, id: "layout-grid")
            let replayGrid = try await execute("canvas_layout_nodes", gridInput, id: "layout-grid")
            layoutReplayPrevented = grid == replayGrid
            guard let gridHistory = grid["history_id"]?.stringValue else { throw AgentOperationError("no layout history") }
            let gridState = try await execute("canvas_current", [:])
            _ = try await execute("canvas_undo", ["history_id": .string(gridHistory)])
            let undoState = try await execute("canvas_current", [:])
            _ = try await execute("canvas_redo", ["history_id": .string(gridHistory)])
            let redoState = try await execute("canvas_current", [:])
            layoutUndoRedo = undoState["nodes"] == beforeLayout && redoState["nodes"] == gridState["nodes"]
                && undoState["edges"] == gridState["edges"] && redoState["groups"] == gridState["groups"]
            let horizontal = try await execute("canvas_layout_nodes", ["node_ids": [.string(nodeID), .string(imageID)],
                "layout": "horizontal", "expected_graph_revision": redoState["graph_revision"]!])
            let finalState = try await execute("canvas_current", [:])
            let unchanged = try await execute("canvas_layout_nodes", ["node_ids": [.string(nodeID), .string(imageID)],
                "layout": "horizontal", "expected_graph_revision": finalState["graph_revision"]!])
            layoutNoOp = unchanged["history_id"] == .null && unchanged["graph_revision"] == finalState["graph_revision"]
            layoutApplied = grid["nodes"]?.arrayValue?.count == 2 && horizontal["nodes"]?.arrayValue?.count == 2
                && horizontal["history_id"]?.stringValue != nil && gridState["nodes"] != beforeLayout
                && finalState["nodes"] != gridState["nodes"]
            let answer = AgentMessage(role: .assistant, content: "已创建文本和 16:9 图片节点，连接提示词并编组。")
            await onEvent(.assistantCompleted(answer))
            return [answer]
        } catch { failure = error.localizedDescription; throw error }
    }
}

@MainActor
private func runNativeCanvasLayoutProbe(directory: URL, check: (Bool, String) -> Void) {
    do {
        func fixture(_ name: String, _ document: CanvasDocument) throws -> CanvasStore {
            let root = directory.appendingPathComponent("layout-" + name)
            let storage = CanvasStorage(rootOverride: root), projects = CanvasProjectStorage(rootOverride: root)
            let projectID = projects.load().activeProjectId
            guard storage.save(document, projectId: projectID) else { throw AgentCanvasError.writeFailed }
            return CanvasStore(storage: storage, projectStorage: projects)
        }
        func edit(_ store: CanvasStore, _ ids: Set<String>, _ layout: CanvasGroupLayoutType) throws -> String? {
            try store.performAgentEdit(detail: "布局验收") { try store.layoutAgentNodes(ids, layout: layout) }
        }
        func matches(_ store: CanvasStore, _ original: CanvasDocument) -> Bool {
            var current = store.gatewayDocument()
            current.updatedAt = original.updatedAt
            return current == original
        }
        func configurationUnchanged(_ store: CanvasStore, _ original: CanvasDocument) -> Bool {
            store.nodes.map { node -> CanvasNode in
                var value = node
                if let before = original.nodes.first(where: { $0.id == node.id }) {
                    value.x = before.x; value.y = before.y
                    value.updatedAt = before.updatedAt
                }
                return value
            } == original.nodes && store.edges == original.edges
        }
        let a = CanvasNode(pageId: "page", groupId: "layout", slot: 1, kind: .text,
                           x: 140, y: 180, width: 320, height: 240)
        var b = CanvasNode(pageId: "page", groupId: "layout", slot: 2, kind: .image,
                           x: 470, y: 270, width: 640, height: 360)
        var c = CanvasNode(pageId: "page", groupId: "layout", slot: 3, kind: .video,
                           x: 800, y: 380, width: 720, height: 405)
        b.ratio = "16:9"; c.ratio = "16:9"
        let d = CanvasNode(pageId: "page", groupId: "layout", slot: 4, kind: .text,
                           x: 2200, y: 100, width: 260, height: 220)
        let edges = [CanvasEdge(fromNodeId: a.id, toNodeId: b.id),
                     CanvasEdge(fromNodeId: b.id, toNodeId: c.id)]
        let group = CanvasNodeGroup(id: "flat", nodeIDs: [a.id, b.id, c.id],
            containerFrame: CGRect(x: 100, y: 100, width: 1600, height: 1100),
            layoutType: .horizontal, createdBy: .client)
        let flatDocument = CanvasDocument(nodes: [a, b, c, d], edges: edges, groups: [group])
        let flat = try fixture("partial", flatDocument)
        let partial = try edit(flat, [a.id, b.id], .grid)
        check(partial != nil && flat.history.entries.count == 1 && flat.node(id: c.id) == c && flat.node(id: d.id) == d,
              "native partial layout moves only requested nodes with one undo")
        check(configurationUnchanged(flat, flatDocument) && flat.groups[0].nodeIDs == group.nodeIDs,
              "native partial layout preserves media ratios edges and group membership")
        let arranged = flat.gatewayDocument()
        let noOp = try edit(flat, [a.id, b.id], .grid)
        check(noOp == nil && matches(flat, arranged) && flat.history.entries.count == 1,
              "native repeated partial grid has no positional drift or extra history")
        _ = flat.undo()
        check(matches(flat, flatDocument), "native batch undo restores all coordinates and containers")
        _ = flat.redo()
        check(matches(flat, arranged), "native batch redo restores saved layout")
        let reloaded = CanvasStore(storage: CanvasStorage(rootOverride: directory.appendingPathComponent("layout-partial")),
            projectStorage: CanvasProjectStorage(rootOverride: directory.appendingPathComponent("layout-partial")))
        check(flat.flushSave() && reloaded.nodes == flat.nodes && reloaded.groups == flat.groups,
              "native layout reload retains real geometry and group bounds")

        let parent = CanvasNodeGroup(id: "parent", nodeIDs: [a.id],
            containerFrame: CGRect(x: 100, y: 100, width: 1700, height: 1200), createdBy: .server)
        let child = CanvasNodeGroup(id: "child", nodeIDs: [b.id, c.id],
            containerFrame: CGRect(x: 420, y: 220, width: 1150, height: 650),
            parentGroupID: parent.id, createdBy: .server)
        let nestedDocument = CanvasDocument(nodes: [a, b, c, d], edges: edges, groups: [child, parent])
        let nested = try fixture("nested", nestedDocument)
        let offset = CGPoint(x: c.x - b.x, y: c.y - b.y)
        _ = try edit(nested, [b.id, c.id, d.id], .grid)
        check(nested.node(id: a.id) == a && nested.node(id: c.id)!.x - nested.node(id: b.id)!.x == offset.x
              && nested.node(id: c.id)!.y - nested.node(id: b.id)!.y == offset.y,
              "native mixed selection moves complete child container without flattening or touching parent member")
        check(configurationUnchanged(nested, nestedDocument) && nested.history.entries.count == 1
              && nested.groups.first(where: { $0.id == child.id })?.parentGroupID == parent.id,
              "native nested layout preserves hierarchy media and edges")
        _ = nested.undo()
        check(matches(nested, nestedDocument), "native nested layout undo restores exact hierarchy")
        _ = try edit(nested, [a.id, b.id, c.id], .grid)
        check(nested.node(id: d.id) == d && nested.node(id: c.id)!.x - nested.node(id: b.id)!.x == offset.x
              && nested.node(id: c.id)!.y - nested.node(id: b.id)!.y == offset.y,
              "native complete parent layout uses child as atomic unit")
        _ = nested.undo()
        _ = try edit(nested, [b.id, c.id], .horizontal)
        let parentFrame = nested.groups.first(where: { $0.id == parent.id })!.containerFrame!
        let childFrame = nested.groups.first(where: { $0.id == child.id })!.containerFrame!
        check(parentFrame.contains(childFrame) && nested.node(id: a.id) == a && nested.node(id: d.id) == d,
              "native child-only layout expands parent boundary while retaining other nodes")

        let pile = CanvasPile(id: "pile", memberIDs: [a.id, b.id], at: CGPoint(x: 600, y: 600), groupID: group.id)
        let pileDocument = CanvasDocument(nodes: [a, b, c, d], edges: edges, groups: [group], piles: [pile])
        let piled = try fixture("pile", pileDocument)
        do {
            _ = try edit(piled, [a.id, d.id], .grid)
            check(false, "native partial pile must be rejected")
        } catch {
            check(matches(piled, pileDocument) && piled.history.entries.isEmpty,
                  "native partial pile rejection leaves graph pile and history unchanged")
        }
        _ = try edit(piled, [a.id, b.id, d.id], .horizontal)
        check(piled.node(id: a.id) == a && piled.node(id: b.id) == b && piled.node(id: c.id) == c
              && piled.piles[0].memberIDs == pile.memberIDs && piled.piles[0].groupID == pile.groupID
              && CGPoint(x: piled.piles[0].x, y: piled.piles[0].y) != CGPoint(x: pile.x, y: pile.y)
              && piled.history.entries.count == 1,
              "native pile layout moves presentation entity and preserves hidden member coordinates")
        _ = piled.undo()
        check(matches(piled, pileDocument), "native pile layout undo restores exact document")
        _ = try edit(piled, [a.id, b.id, c.id], .grid)
        check(piled.node(id: a.id) == a && piled.node(id: b.id) == b
              && piled.groups[0].layoutType == .grid && configurationUnchanged(piled, pileDocument),
              "native complete flat group layout retains pile and media dimensions")

        var nestedPile = pile; nestedPile.groupID = child.id
        let pileChild = CanvasNodeGroup(id: child.id, nodeIDs: [a.id, b.id],
            containerFrame: child.containerFrame, parentGroupID: parent.id, createdBy: .server)
        let pileParent = CanvasNodeGroup(id: parent.id, nodeIDs: [c.id],
            containerFrame: parent.containerFrame, createdBy: .server)
        let blockedDocument = CanvasDocument(nodes: [a, b, c, d], edges: edges,
            groups: [pileChild, pileParent], piles: [nestedPile])
        let blocked = try fixture("nested-pile", blockedDocument)
        do {
            _ = try edit(blocked, [a.id, b.id, c.id], .horizontal)
            check(false, "native unsupported nested pile cannot report success")
        } catch {
            check(matches(blocked, blockedDocument) && blocked.history.entries.isEmpty,
                  "native nested pile layout error rolls back graph and history")
        }
        let failing = try fixture("rollback", flatDocument)
        do {
            _ = try failing.performAgentEdit(detail: "布局回滚验收") {
                try failing.layoutAgentNodes([a.id, b.id], layout: .horizontal)
                throw AgentOperationError("fixture commit failure")
            }
        } catch {
            check(matches(failing, flatDocument) && failing.history.entries.isEmpty,
                  "native failure after layout restores exact saved document and history")
        }
    } catch { check(false, "native batch layout fixture: \(error.localizedDescription)") }
}
#endif
