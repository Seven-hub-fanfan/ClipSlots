#if DEBUG
import AppKit
import ClipSlotsKit

@MainActor
func runAgentSidebarParityProbe(store: SlotStoreObservable, directory: URL,
                                check: (Bool, String) -> Void) async {
    do {
        let root = directory.appendingPathComponent("sidebar-parity")
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root),
                                 projectStorage: CanvasProjectStorage(rootOverride: root))
        _ = canvas.createProject(name: "四节点引用与审批验收")
        let group = try store.specialStorage.createSpecialSlot(name: "四节点引用验收")
        let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<40 { for y in 0..<24 {
            pixel.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
        } }
        let png = pixel.representation(using: .png, properties: [:])!
        for (index, name) in ["Video.mp4", "Audio.wav", "Video2.mp4", "Image.png"].enumerated() {
            var content = SlotContent(text: "REFERENCE_MARKER_\(index)")
            content.attachments = [.init(name: name, type: .file, data: index == 3 ? png : Data())]
            check(store.specialStorage.set(index + 1, content: content, in: group.id),
                  "parity reference \(index) persists in isolated storage")
            canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: index + 1, name: name,
                             at: CGPoint(x: index * 200, y: 200))
        }
        let backend = SidebarParityBackend()
        let model = AgentSessionStore().canvasSession(canvas: canvas, store: store)
        model.setBackend(backend)
        guard let context = model.canvasContext else { throw AgentCanvasError.unavailable }
        model.draft = "正文保留🙂"
        canvas.selectedNodeIds = Set(canvas.nodes.map(\.id))
        for _ in 0..<120 {
            if model.draftReferences.count == 4 && !context.isLoadingReferences { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try JSONEncoder().encode(model.draftReferences).write(to: root.appendingPathComponent("captured-references.json"))
        check(model.draftReferences.count == 4 && context.referenceCaptureErrors.isEmpty,
              "real canvas selection automatically imports four references without plus action")
        check(model.draftReferences.map(\.mediaKind) == [.video, .audio, .video, .image],
              "four reference types match Video Audio Video Image")
        check(model.draftReferences.last?.images?.first?.imageSnapshot != nil
              && model.draftReferences.last?.previewImage == model.draftReferences.last?.images?.first?.imageSnapshot,
              "image preview is the exact captured image sent to backend")
        let all = model.draftReferences
        model.draftReferences.remove(at: 1)
        try? await Task.sleep(for: .milliseconds(120))
        check(model.draftReferences.count == 3 && model.draft == "正文保留🙂" && canvas.nodes.count == 4,
              "removing an auto reference preserves draft graph and other references without resurrection")
        model.draftReferences = all
        var config = AgentConfig(model: "reference-model")
        config.supportsImageInput = true
        check(model.send(text: model.draft, config: config, enabledSkills: []), "four captured references are accepted for send")
        for _ in 0..<120 where model.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        check(backend.references.count == 4 && backend.model == "reference-model"
              && backend.imageBytes == all.last?.images?.first?.imageSnapshot,
              "actual backend receives four snapshots exact image bytes and selected model")
        check(!backend.wire.contains("previewImage") && backend.wire.contains("REFERENCE_MARKER_3"),
              "backend metadata excludes UI preview bytes and retains actual reference text")
        check(model.reportedPromptTokens == 500 && model.contextUsage?.model == "reference-model",
              "service prompt usage is attributed to the model used by the actual request")
        model.selectAutomaticApproval(true)
        model.selectAccessMode(.selectedDirectories)
        model.selectAccessMode(.fullAccess)
        check(model.automaticApproval, "directory scope changes preserve automatic approval choice")
        model.selectAutomaticApproval(false)
        model.selectAccessMode(.selectedDirectories)
        model.selectAccessMode(.fullAccess)
        check(!model.automaticApproval, "full access never silently grants automatic approval")
        model.clearHistory()
        check(model.contextUsage == nil && model.reportedPromptTokens == nil,
              "new conversation clears all previous context statistics")
        canvas.selectedNodeIds = Set(canvas.nodes.prefix(2).map(\.id))
        model.draft = "切换前草稿"
        model.clearHistory()
        try? await Task.sleep(for: .milliseconds(180))
        check(model.draftReferences.isEmpty && !context.isLoadingReferences,
              "debounced selection cannot cross conversation boundaries")

        let turn = try context.captureTurn(supportsTools: true)
        let scope = SidebarParityScope()
        let original = canvas.gatewayDocument()
        let originalHistoryCount = canvas.history.entries.count
        let args: JSONValue = [
            "node_ids": .array([.string(canvas.nodes[0].id)]),
            "expected_graph_revision": .string(AgentCanvasSync.revision(original))
        ]
        func delete(_ id: String) throws -> AgentToolCall {
            .init(id: id, name: "canvas_delete_nodes", argumentsJSON: try args.encodedText())
        }
        var approvals = 0
        var duplicateReplyAccepted: Bool?
        let declined = try context.actionTools(for: turn, mode: .fullAccess, automaticApproval: true,
            conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { request in
                _ = try? await request.respond(["decision": "decline"])
            })
        let no = await declined.execute(call: try delete("auto-delete-decline"))
        check(no.isFailure && canvas.nodes == original.nodes && canvas.history.entries.count == originalHistoryCount,
              "automatic mode deletion refusal preserves real graph and history")
        let invalidated = try context.actionTools(for: turn, mode: .fullAccess, automaticApproval: true,
            conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { request in request.invalidate() })
        let invalid = await invalidated.execute(call: try delete("auto-delete-invalidated"))
        check(invalid.isFailure && canvas.nodes == original.nodes,
              "invalidated deletion approval terminates without mutation or waiting until expiry")
        let stale = try context.actionTools(for: turn, mode: .fullAccess, automaticApproval: true,
            conversationID: model.selectedConversationID, isCurrent: { scope.active }, onInteraction: { request in
                await MainActor.run { scope.active = false }
                _ = try? await request.respond(["decision": "accept"])
            })
        let staleResult = await stale.execute(call: try delete("auto-delete-stale"))
        check(staleResult.isFailure && canvas.nodes == original.nodes,
              "approval cannot mutate a project after the bound run becomes stale")
        let accepted = try context.actionTools(for: turn, mode: .fullAccess, automaticApproval: true,
            conversationID: model.selectedConversationID, isCurrent: { true }, onInteraction: { request in
                await MainActor.run { approvals += 1 }
                _ = try? await request.respond(["decision": "accept"])
                let duplicate = try? await request.respond(["decision": "accept"])
                await MainActor.run { duplicateReplyAccepted = duplicate }
            })
        let journal = AgentJournaledTools(base: accepted, journal: AgentExecutionJournal(root: root),
            scope: AgentExecutionScope(sessionID: model.selectedConversationID.uuidString,
                projectID: canvas.activeProjectId, turnID: "delete-approval"))
        let approvedCall = try delete("auto-delete-approved")
        let approved = await journal.execute(call: approvedCall)
        let after = canvas.gatewayDocument()
        let approvedHistoryCount = canvas.history.entries.count
        let replay = await journal.execute(call: approvedCall)
        check(!approved.isFailure && canvas.nodes.count == 3 && approvals == 1,
              "automatic deletion executes only after explicit approval")
        check(duplicateReplyAccepted == false, "double approval reply is rejected")
        var replayedDocument = canvas.gatewayDocument()
        // gatewayDocument stamps each read with Date(); this is not a graph mutation.
        replayedDocument.updatedAt = after.updatedAt
        check(replay == approved, "journal replay returns the exact persisted deletion result")
        check(replayedDocument == after && canvas.history.entries.count == approvedHistoryCount && approvals == 1,
              "deletion replay preserves graph viewport and history without another approval")
        _ = canvas.undo()
        check(canvas.nodes == original.nodes, "approved deletion supports real canvas undo")
        check(all.allSatisfy {
            store.canvasReadFullContent(groupId: $0.groupID, slot: $0.slot) != nil
        }, "reference removal and canvas deletion preserve source library files")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: local.appendingPathComponent("sample.txt"))
        let access = try AgentDirectoryAccess(url: local)
        let reader = AgentDirectoryTools(base: AgentPreviewTools(), access: access, confirmReads: true) { request in
            _ = try? await request.respond(["decision": "decline"])
        }
        let refusedRead = await reader.execute(call: .init(id: "manual-read", name: "local_read_file",
            argumentsJSON: #"{"path":"sample.txt"}"#))
        check(refusedRead.isFailure && !refusedRead.content.contains("before"),
              "manual directory mode requires approval before reading local contents")
        let writer = AgentDirectoryTools(base: AgentPreviewTools(), access: access) { request in
            _ = try? await request.respond(["decision": "decline"])
        }
        let refusedWrite = await writer.execute(call: .init(id: "manual-write", name: "local_write_file",
            argumentsJSON: try JSONValue.object(["path": "sample.txt", "content": "after",
                "expected_sha256": .string(AgentDirectoryAccess.digest(Data("before".utf8)))]).encodedText()))
        let retainedFile = try Data(contentsOf: local.appendingPathComponent("sample.txt"))
        check(refusedWrite.isFailure && retainedFile == Data("before".utf8),
              "manual local write refusal preserves exact on-disk bytes")
        await runAgentSidebarPagesProbe(model: model, directory: directory, references: all, check: check)
        model.stop()
    } catch { check(false, "Agent sidebar parity exception: \(error.localizedDescription)") }
}

@MainActor
private final class SidebarParityScope { var active = true }

private final class SidebarParityBackend: AgentBackend, @unchecked Sendable {
    var references: [AgentCanvasReference] = []
    var model = ""
    var wire = ""
    var imageBytes: Data?
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        let message = history.last { $0.role == .user }
        references = message?.canvasReferences ?? []
        model = config.model; wire = message?.wireContent ?? ""
        imageBytes = message?.inputAttachments.first?.imageSnapshot
        await onEvent(.usage(.init(promptTokens: 500, completionTokens: 10, totalTokens: 510, cachedTokens: nil)))
        let reply = AgentMessage(role: .assistant, content: "isolated reference reply")
        await onEvent(.assistantCompleted(reply))
        return [reply]
    }
}
#endif
