#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
private final class NativeMCPApprovalDecision {
    var accept = true
}

@MainActor
func runAgentNativeMCPProbe(store: SlotStoreObservable, directory: URL,
                            check: (Bool, String) -> Void) async {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clipslots-mcp")
    let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clipslots-cli")
    let disabledCLI = cli.appendingPathExtension("disabled")
    var exportedModel: AgentChatModel?
    do {
        try FileManager.default.moveItem(at: cli, to: disabledCLI)
        defer { try? FileManager.default.moveItem(at: disabledCLI, to: cli); exportedModel?.stop() }
        check(!FileManager.default.isExecutableFile(atPath: cli.path), "MCP probe removes the bundled business CLI")
        let root = directory.appendingPathComponent("native-mcp-canvas")
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root),
                                 projectStorage: CanvasProjectStorage(rootOverride: root))
        let sessions = AgentSessionStore(dataRoot: directory.appendingPathComponent("native-mcp-sessions"))
        let model = sessions.sidebarSession(canvas: canvas, store: store)
        exportedModel = model
        model.selectAccessMode(.fullAccess)
        model.selectAutomaticApproval(false)
        let view = CanvasWorkspaceView(store: store, canvas: canvas, agentVisible: .constant(false))
        let handoff = try view.externalAgentHandoffContext(sessions: sessions)
        guard let lease = handoff.liveLease else { throw AgentOperationError("Canvas button exported no live MCP lease") }
        let configuration = try handoff.mcpConfiguration()["mcpServers"]?["clipslots-project"] ?? [:]
        let env = configuration["env"]?[AgentLiveMCPLease.environmentKey]?.stringValue ?? ""
        let connection = configuration["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let conversation = model.selectedConversationID
        check(configuration["command"] == .string(executable.path) && !env.isEmpty
            && connection.contains("--session-id") && handoff.sessionID == conversation
            && lease.accessMode == .fullAccess,
              "canvas button exports the dedicated MCP with the shared session and writable native lease")
        var approvals: [String] = []
        let decision = NativeMCPApprovalDecision()
        let approvalTask = Task { @MainActor in
            while !Task.isCancelled {
                for request in model.pendingInteractions where request.isPending {
                    approvals.append(request.params["command"]?.stringValue ?? "")
                    _ = try? await request.respond(["decision": decision.accept ? "accept" : "decline"])
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        defer { approvalTask.cancel() }
        var rpcEvidence: [JSONValue] = []
        func rpc(_ method: String, _ params: JSONValue = [:], live: Bool = true, readOnly: Bool = false) async throws -> JSONValue {
            let request: JSONValue = ["jsonrpc": "2.0", "id": .string("native-\(rpcEvidence.count)"), "method": .string(method),
                                      "params": params]
            let result = await AgentProcessRunner.run(executable: "/usr/bin/env",
                arguments: ["PATH=/nonexistent", AgentLiveMCPLease.environmentKey + "=" + env,
                            "/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny process-fork)", executable.path]
                    + (live ? connection : ["--slots"]) + (readOnly ? ["--read-only"] : []),
                standardInput: try request.encodedText() + "\n", timeout: 20, maxOutputBytes: 1_000_000)
            guard result.exitCode == 0, let line = result.stdout.split(separator: "\n").first else {
                throw AgentOperationError("MCP subprocess \(method) exit=\(result.exitCode) timeout=\(result.timedOut): \(result.stderr)")
            }
            let response = try JSONValue.decode(jsonText: String(line))
            rpcEvidence.append(["request": request, "response": response])
            return response
        }
        func call(_ name: String, _ args: JSONValue = [:], live: Bool = true, readOnly: Bool = false) async throws -> JSONValue {
            let response = try await rpc("tools/call", ["name": .string(name), "arguments": args], live: live, readOnly: readOnly)
            guard let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue else {
                throw AgentOperationError("Missing MCP tool result")
            }
            return try JSONValue.decode(jsonText: text)
        }
        let initResponse = try await rpc("initialize", ["protocolVersion": "2025-06-18"])
        check(initResponse["result"]?["serverInfo"]?["version"] == .string(AppVersion.current)
            && initResponse["result"]?["protocolVersion"] == "2025-06-18", "dedicated MCP negotiates protocol and current version")
        let names = Set(try await rpc("tools/list")["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        check(CanvasAgentActionTools.writers.isSubset(of: names) && names.contains("write_slot"),
              "real MCP catalog exposes native canvas actions and slot writes together")
        check(!names.contains("shell") && !names.contains("run_skill_script"), "dedicated MCP catalog contains no unrestricted shell or Skill subprocess")
        let identity = try await call("clipslots_context")
        check(identity["cli_required"] == false && identity["project_id"] == .string(canvas.activeProjectId),
              "MCP connects to the active scoped native host without CLI")
        check(identity["automatic_approval"] == false && identity["writes_require_native_confirmation"] == true,
              "manual MCP session reports its current native approval policy")

        let pages = try await call("list_pages", live: false)
        check(pages["ok"] == true && pages["backend"] == "native_data_layer", "standalone slots MCP reads real persisted pages with empty PATH")
        let newPage = try await call("create_page", ["name": "MCP独立测评", "first_group_name": "测试组"], live: false)
        let group = newPage["defaultGroup"]?["id"]?.stringValue ?? ""
        let first = try await call("write_slot", ["group": .string(group), "slot": 1, "text": "原文🙂\n`--ratio 16:9`"], live: false)
        let revision = first["revision"]?.stringValue ?? ""
        let read = try await call("read_slot", ["group": .string(group), "slot": 1], live: false)
        check(first["ok"] == true && read["text"] == "原文🙂\n`--ratio 16:9`" && read["revision"] == .string(revision),
              "dedicated slots MCP writes and reads exact Unicode text")
        let stale = try await call("write_slot", ["group": .string(group), "slot": 1, "text": "不应写入", "expected_revision": "stale"], live: false)
        check(stale["ok"] == false && stale["error_code"] == "REVISION_CONFLICT",
              "native slot compare-and-write rejects stale revisions")
        let rename = try await call("rename_group", ["group": .string(group), "new_name": "MCP重命名"], live: false)
        let groups = try await call("list_groups", live: false)
        check(rename["ok"] == true && groups["groups"]?.arrayValue?.contains { $0["id"] == .string(group) && $0["name"] == "MCP重命名" } == true,
              "native MCP group rename persists and is visible immediately")
        let emptyOnly = try await call("write_slot", ["group": .string(group), "slot": 1, "text": "不应覆盖", "if_empty": true], live: false)
        check(emptyOnly["error_code"] == "SLOT_NOT_EMPTY", "native MCP preserves occupied slots under if_empty")
        let inputImage = directory.appendingPathComponent("native-mcp-ingest.png")
        guard let brand = AgentBrandResources.iconURL(for: "deepseek") else { throw AgentOperationError("Missing bundled image fixture") }
        let imageBytes = try Data(contentsOf: brand)
        try imageBytes.write(to: inputImage)
        let attached = try await call("write_attachment", ["group": .string(group), "slot": 1,
            "files": [.string(inputImage.path)], "label": "附件测评"], live: false)
        try FileManager.default.removeItem(at: inputImage)
        let attachment = SpecialSlotStorage.shared.get(1, in: group).attachments.first
        check(attached["ok"] == true && attachment?.resolveData() == imageBytes
            && SpecialSlotStorage.shared.get(1, in: group).plainText == "原文🙂\n`--ratio 16:9`",
              "native MCP ingests immutable attachment bytes and preserves the slot body after source deletion")
        let rewritten = try await call("write_slot", ["group": .string(group), "slot": 1, "text": "附件仍保留🙂",
            "expected_revision": attached["revision"] ?? .null], live: false)
        check(rewritten["ok"] == true && SpecialSlotStorage.shared.get(1, in: group).attachments.first?.resolveData() == imageBytes,
              "native text replacement preserves already ingested attachment bytes")
        let covered = try await call("set_thumbnail", ["group": .string(group), "slot": 1, "image": .string(brand.path)], live: false)
        let duplicateCover = try await call("set_thumbnail", ["group": .string(group), "slot": 1,
            "image": .string(brand.path), "if_absent": true], live: false)
        let removedCover = try await call("clear_thumbnail", ["group": .string(group), "slot": 1], live: false)
        check(covered["manual_thumbnail"] == true && duplicateCover["error_code"] == "THUMBNAIL_ALREADY_SET"
            && removedCover["manual_thumbnail"] == false,
              "native MCP sets, protects and clears thumbnail bytes without losing content")
        let searched = try await call("search_slots", ["query": "附件仍保留", "all_groups": true], live: false)
        check(searched["matches"]?.arrayValue?.contains { $0["group"] == .string(group) && $0["slot"] == 1 } == true,
              "native MCP searches the real stored library after writes")
        let clipboardBefore = ClipboardManager.shared.capture()
        let pasted = try await call("paste_slot", ["group": .string(group), "slot": 1], live: false)
        let copiedText = NSPasteboard.general.string(forType: .string)
        if copiedText == "附件仍保留🙂" { _ = ClipboardManager.shared.restore(clipboardBefore) }
        check(pasted["copied"] == true && copiedText == "附件仍保留🙂",
              "native MCP copies slot text to clipboard and the probe restores the prior clipboard")
        let repaired = try await call("repair_index", live: false)
        check(repaired["ok"] == true && SpecialSlotStorage.shared.loadIndex().specialSlots.contains { $0.id == group },
              "native MCP index health check retains the real library")
        let clear = try await call("clear_slot", ["group": .string(group), "slot": 1], live: false)
        check(clear["cleared"] == true && SpecialSlotStorage.shared.get(1, in: group).isEmpty,
              "native MCP clear removes body and attachments together")
        let extraGroup = try await call("create_group", ["page": newPage["page"]?["id"] ?? .null, "name": "删除测试"], live: false)
        let deleteGroup = try await call("delete_group", ["group": extraGroup["id"] ?? .null], live: false)
        let protectedPage = try await call("delete_page", ["page": "default_page"], live: false)
        let deletePage = try await call("delete_page", ["page": newPage["page"]?["id"] ?? .null], live: false)
        check(deleteGroup["deleted"] == true && protectedPage["error_code"] == "DEFAULT_PAGE_PROTECTED"
            && deletePage["deleted"] == true, "native MCP soft-deletes explicit groups and pages while protecting the default page")

        let created = try await call("canvas_create_node", ["kind": "text", "text": "MCP画布正文🙂", "x": 200, "y": 200])
        let id = created["nodes"]?.arrayValue?.first?["node_id"]?.stringValue ?? ""
        let live = try await call("canvas_get_node", ["node_id": .string(id)])
        check(created["ok"] == true && live["body_text"] == "MCP画布正文🙂" && canvas.node(id: id) != nil,
              "real stdio MCP creates a native canvas node, saves body and returns its real ID")
        let edited = try await call("canvas_edit_node", ["node_id": .string(id),
            "expected_revision": live["node_revision"] ?? .null, "text": "最新正文🙂"])
        let current = try await call("canvas_get_node", ["node_id": .string(id)])
        check(edited["ok"] == true && current["body_text"] == "最新正文🙂",
              "MCP canvas reads observe the latest body after a confirmed edit")
        let staleCanvas = try await call("canvas_edit_node", ["node_id": .string(id),
            "expected_revision": live["node_revision"] ?? .null, "text": "不应写入"])
        check(staleCanvas["ok"] == false && store.canvasReadFullContent(groupId: canvas.node(id: id)!.groupId,
            slot: canvas.node(id: id)!.slot)?.plainText == "最新正文🙂", "MCP rejects stale canvas edits without changing bytes")
        let second = try await call("canvas_create_node", ["kind": "image", "text": "只创建，不生成", "x": 600, "y": 200])
        let secondID = second["nodes"]?.arrayValue?.first?["node_id"]?.stringValue ?? ""
        let beforeConnect = try await call("canvas_current")
        let connected = try await call("canvas_connect_nodes", ["from_node_id": .string(id), "to_node_id": .string(secondID),
            "expected_graph_revision": beforeConnect["graph_revision"] ?? .null])
        check(connected["ok"] == true && canvas.edges.contains { $0.fromNodeId == id && $0.toNodeId == secondID },
              "MCP connects native nodes through actual connection validation")
        let beforeLayout = try await call("canvas_current")
        let layout = try await call("canvas_layout_nodes", ["node_ids": [.string(id), .string(secondID)], "layout": "horizontal",
            "expected_graph_revision": beforeLayout["graph_revision"] ?? .null])
        check(layout["ok"] == true && canvas.node(id: id)!.x < canvas.node(id: secondID)!.x,
              "MCP lays out connected native nodes in one durable transaction")
        if let history = layout["history_id"]?.stringValue {
            let undo = try await call("canvas_undo", ["history_id": .string(history)])
            let redo = try await call("canvas_redo", ["history_id": .string(history)])
            check(undo["ok"] == true && redo["ok"] == true, "MCP native undo and redo preserve the history transaction")
        } else { check(false, "MCP layout produced a history receipt") }
        decision.accept = false
        let beforeDecline = try await call("canvas_get_node", ["node_id": .string(id)])
        let declined = try await call("canvas_edit_node", ["node_id": .string(id), "text": "不应写入",
            "expected_revision": beforeDecline["node_revision"] ?? .null])
        check(declined["error_code"] == "DECLINED" && approvals.contains("canvas_edit_node"),
              "declined native MCP approval leaves the canvas unchanged")
        let approvalCount = approvals.count
        model.selectAutomaticApproval(true)
        let automaticIdentity = try await call("clipslots_context")
        check(automaticIdentity["automatic_approval"] == true
            && automaticIdentity["writes_require_native_confirmation"] == false
            && automaticIdentity["deletions_require_native_confirmation"] == true
            && automaticIdentity["preview_mutations_require_native_confirmation"] == true,
              "existing MCP connection follows automatic mode while retaining delete and preview confirmations")
        let automaticCreated = try await call("canvas_create_node", ["kind": "text",
            "text": "自动创建🙂", "x": 1000, "y": 200])
        check(automaticCreated["ok"] == true && approvals.count == approvalCount,
              "automatic MCP creates native nodes without requesting approval")
        let beforeAutomaticEdit = try await call("canvas_get_node", ["node_id": .string(id)])
        let automaticEdited = try await call("canvas_edit_node", ["node_id": .string(id),
            "expected_revision": beforeAutomaticEdit["node_revision"] ?? .null, "text": "自动更新🙂"])
        check(automaticEdited["ok"] == true && approvals.count == approvalCount,
              "automatic MCP saves canvas text without requesting approval")
        let beforeAutomaticConfigure = try await call("canvas_get_node", ["node_id": .string(secondID)])
        let automaticConfigured = try await call("canvas_configure_node", ["node_id": .string(secondID),
            "expected_revision": beforeAutomaticConfigure["node_revision"] ?? .null,
            "ratio": "4:3", "count": 1])
        check(automaticConfigured["ok"] == true && approvals.count == approvalCount,
              "automatic MCP configures generation parameters without requesting approval")
        var generationTargets: Set<String> = []
        let priorGenerationHandler = canvas.agentGenerationHandler
        canvas.agentGenerationHandler = { ids in generationTargets = ids; return nil }
        let beforeAutomaticGenerate = try await call("canvas_current")
        let automaticGeneration = try await call("canvas_generate", ["node_ids": [.string(secondID)],
            "expected_graph_revision": beforeAutomaticGenerate["graph_revision"] ?? .null])
        canvas.agentGenerationHandler = priorGenerationHandler
        check(generationTargets == [secondID] && approvals.count == approvalCount
            && automaticGeneration["error_code"] == "CANVAS_ACTION_FAILED",
              "automatic MCP reaches the native generation handler without approval and reports a refused submission truthfully")
        let automaticGroup = try await call("create_group", ["page": "default_page", "name": "MCP自动槽位"])
        let automaticGroupID = automaticGroup["id"]?.stringValue ?? ""
        let automaticSlot = try await call("write_slot", ["group": .string(automaticGroupID),
            "slot": 1, "text": "自动槽位正文🙂"])
        let automaticRead = try await call("read_slot", ["group": .string(automaticGroupID), "slot": 1])
        check(automaticGroup["ok"] == true && automaticSlot["ok"] == true
            && automaticRead["text"] == "自动槽位正文🙂" && approvals.count == approvalCount,
              "automatic MCP group and slot writes execute without approval and persist exact bytes")
        let beforeDelete = try await call("canvas_current")
        let protectedDelete = try await call("canvas_delete_nodes", ["node_ids": [.string(secondID)],
            "expected_graph_revision": beforeDelete["graph_revision"] ?? .null])
        check(protectedDelete["error_code"] == "DECLINED" && canvas.node(id: secondID) != nil
            && approvals.last == "canvas_delete_nodes" && approvals.count == approvalCount + 1,
              "automatic MCP still requires native confirmation before deleting canvas nodes")
        let protectedClear = try await call("clear_slot", ["group": .string(automaticGroupID), "slot": 1])
        check(protectedClear["error_code"] == "DECLINED"
            && SpecialSlotStorage.shared.get(1, in: automaticGroupID).plainText == "自动槽位正文🙂"
            && approvals.last == "clear_slot" && approvals.count == approvalCount + 2,
              "automatic MCP still requires native confirmation before clearing slot bytes")
        model.selectAutomaticApproval(false)
        let manualIdentity = try await call("clipslots_context")
        let beforeManualEdit = try await call("canvas_get_node", ["node_id": .string(id)])
        let manualEdit = try await call("canvas_edit_node", ["node_id": .string(id),
            "expected_revision": beforeManualEdit["node_revision"] ?? .null, "text": "不应写入"])
        let afterManualEdit = try await call("canvas_get_node", ["node_id": .string(id)])
        check(manualIdentity["automatic_approval"] == false
            && manualIdentity["writes_require_native_confirmation"] == true
            && manualEdit["error_code"] == "DECLINED" && afterManualEdit["body_text"] == "自动更新🙂",
              "switching the same MCP connection back to manual restores approval and preserves declined bytes")
        model.selectAutomaticApproval(true)
        decision.accept = true
        let fresh = try await call("canvas_overview", ["snapshot_id": .string(lease.snapshotID.uuidString)])
        check(fresh["node_count"] == .number(Double(canvas.nodes.count)),
              "legacy overview tools refresh live state instead of retaining the startup snapshot")
        let stableA = try await call("clipslots_context")
        let stableB = try await call("clipslots_context")
        check(stableA["snapshot_id"] == stableB["snapshot_id"]
            && stableA["snapshot_id"] != identity["snapshot_id"],
              "unchanged live reads share a stable paginated snapshot identity after mutations")
        let foreign = try await call("canvas_get_node", ["node_id": "other-project#1"])
        check(foreign["ok"] == false, "live MCP rejects foreign node IDs")
        let reloaded = CanvasStorage(rootOverride: root).load(projectId: canvas.activeProjectId)
        check(reloaded.nodes.count == canvas.nodes.count && reloaded.edges.count == canvas.edges.count,
              "MCP results survive reloading the durable native canvas")
        let readOnlyNames = Set(try await rpc("tools/list", readOnly: true)["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        let readOnlyContext = try await call("clipslots_context", readOnly: true)
        let forbidden = try await call("canvas_edit_node", ["node_id": .string(id), "text": "拒绝写入",
            "expected_revision": current["node_revision"] ?? .null], readOnly: true)
        check(!readOnlyNames.contains("write_slot") && !readOnlyNames.contains("canvas_edit_node")
            && readOnlyContext["read_only"] == true && forbidden["ok"] == false,
              "read-only stdio connection cannot escalate a writable live lease")
        try JSONEncoder().encode(rpcEvidence).write(to: directory.appendingPathComponent("native-mcp-wire.json"))
        let marker = lease.directory.appendingPathComponent("lease.json")
        model.stop()
        check(!FileManager.default.fileExists(atPath: marker.path), "closing a live MCP host revokes its lease")
        model.selectAccessMode(.allDirectoriesReadOnly)
        let readOnlyHandoff = try view.externalAgentHandoffContext(sessions: sessions)
        guard let readOnlyLease = readOnlyHandoff.liveLease else {
            throw AgentOperationError("Read-only export lost its live connection")
        }
        let reader = try AgentExternalReadOnlyMCPTools(configuration: .init(scope: readOnlyHandoff.scope,
            snapshotID: readOnlyLease.snapshotID, sessionID: readOnlyHandoff.sessionID))
        let readOnlyTools = try AgentExternalLiveMCPTools(reader: reader, lease: readOnlyLease)
        let restrictedNames = Set(readOnlyTools.specs().map(\.name))
        check(readOnlyLease.accessMode == .allDirectoriesReadOnly
            && !restrictedNames.contains("canvas_edit_node") && !restrictedNames.contains("write_slot"),
              "canvas button preserves an explicitly read-only session without granting writes")
        let readOnlyIdentity = try JSONValue.decode(jsonText: await readOnlyTools.execute(
            call: .init(id: "read-only-policy", name: "clipslots_context", argumentsJSON: "{}")).content)
        check(readOnlyIdentity["read_only"] == true && readOnlyIdentity["automatic_approval"] == false,
              "automatic preference never grants writes or automatic execution to a read-only MCP lease")
        model.selectAccessMode(.fullAccess)
        check(!FileManager.default.fileExists(atPath: readOnlyLease.directory.appendingPathComponent("lease.json").path),
              "changing directory access revokes the old MCP lease before granting a new scope")
    } catch { check(false, "native MCP probe: \(error.localizedDescription)"); exportedModel?.stop() }
}

@MainActor
func runAgentNativeMCPRegression(store: SlotStoreObservable, directory: URL) async {
    var passed: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        if value { passed.append(name) } else { failures.append(name) }
        NSLog("[NativeMCP] %@ %@", value ? "PASS" : "FAIL", name)
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await runAgentNativeMCPProbe(store: store, directory: directory, check: check)
        let report: JSONValue = ["passed": .array(passed.map(JSONValue.string)),
            "failures": .array(failures.map(JSONValue.string)), "ok": .bool(failures.isEmpty)]
        try report.encodedText(pretty: true).write(to: directory.appendingPathComponent("native-mcp-report.json"),
                                                   atomically: true, encoding: .utf8)
    } catch { NSLog("[NativeMCP] FAIL %@", error.localizedDescription) }
    NSApp.terminate(nil)
}
#endif
