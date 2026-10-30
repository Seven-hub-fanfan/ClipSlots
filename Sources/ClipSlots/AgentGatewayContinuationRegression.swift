#if DEBUG
import Foundation
import AppKit
import SwiftUI
import WebKit
import Speech
import ClipSlotsKit

@MainActor
func runAgentGatewayContinuationProbe(store: SlotStoreObservable, directory: URL,
                                      check: (Bool, String) -> Void) async {
    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<150 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    do {
        let root = directory.appendingPathComponent("gateway-native-state")
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root),
                                 projectStorage: CanvasProjectStorage(rootOverride: root))
        let group = try store.specialStorage.createSpecialSlot(name: "恢复链路验证")
        check(store.specialStorage.set(1, content: SlotContent(text: "保持此原文🙂"), in: group.id),
              "gateway fixture stores a real local slot")
        let node = canvas.placeSlot(pageId: group.pageId, groupId: group.id, slot: 1,
                                   name: "恢复测试", at: CGPoint(x: 120, y: 150)).node
        check(canvas.flushSave(), "gateway graph baseline is durably saved")
        // Use the production directory layout so the real CLI sees the same
        // persisted artifact repository and snapshots as the native model.
        let sessionURL = ClipSlotsPaths.dataRoot.appendingPathComponent("agent-sessions/gateway-native.json")
        let model = AgentChatModel(displayName: "续接验收", persistenceURL: sessionURL,
                                   canvasProjectID: canvas.activeProjectId)
        let binding = AgentRunBinding(sessionID: model.selectedConversationID.uuidString,
            projectID: canvas.activeProjectId, canvasID: canvas.activeProjectId)
        let runtime = directory.appendingPathComponent("agent-runtime")
        let endpoint = URL(string: "http://127.0.0.1:49001/v1")!
        var after = node
        after.width += 40
        let mutation = AgentCanvasMutation(projectID: canvas.activeProjectId,
            conversationID: binding.sessionID, runID: "fixture-run", mutationID: "fixture-mutation",
            changes: [.init(before: node, after: after)])
        let transport = GatewayNativeFixtureTransport(binding: binding, mutation: mutation)
        let gateway = AgentGatewayBackend(baseURL: endpoint, binding: binding, journalRoot: runtime,
                                         transport: transport)
        model.setBackend(gateway, kind: .gateway)
        let context = CanvasAgentContext(canvas: canvas, store: store, projectID: canvas.activeProjectId)
        model.canvasContext = context
        check(model.send(text: "继续这个画布工作", config: AgentConfig(), enabledSkills: []),
              "gateway starts from the actual native conversation model")
        await wait { model.runPhase == .waiting && !model.artifacts.isEmpty }
        NSLog("[GatewayNative] waiting artifacts=%d modelError=%@ contextError=%@", model.artifacts.count,
              model.errorText ?? "none", context.error ?? "none")
        check(model.isRunning && model.canResumeGateway && model.runPhase == .waiting,
              "suspension stays waiting and is never falsely marked completed")
        check(model.artifacts.first?.text?.contains("产物🙂") == true,
              "artifact stream populates durable native preview records")
        check(context.pendingGraphPreviews.count == 1 && canvas.node(id: node.id)?.width == node.width,
              "canvas events only prepare a preview before user confirmation")
        await wait { !context.isLoadingReferences }
        check(model.send(text: "稍后继续", config: AgentConfig(), enabledSkills: []),
              "a waiting run accepts a separate queued direction")
        check(model.flushSession(), "waiting run, original submission and queue survive a disk save")
        let restoredGateway = AgentGatewayBackend(baseURL: endpoint, binding: binding, journalRoot: runtime,
                                                  transport: transport)
        let restored = AgentChatModel(displayName: "续接验收", backend: restoredGateway,
            persistenceURL: sessionURL, canvasProjectID: canvas.activeProjectId, backendKind: .gateway)
        let restoredContext = CanvasAgentContext(canvas: canvas, store: store, projectID: canvas.activeProjectId)
        restored.canvasContext = restoredContext
        // Artifact bytes are read on a detached task. A prepared graph proposal
        // alone does not mean that the independent artifact reload has finished.
        await wait {
            restored.canResumeGateway && restoredContext.pendingGraphPreviews.count == 1
                && restored.artifacts.count == 1
        }
        check(restored.selectedConversationID == model.selectedConversationID && restored.queuedSubmissions.count == 1,
              "reopening restores the original conversation and paused queue")
        check(restored.artifacts.count == 1 && restoredContext.pendingGraphPreviews.count == 1,
              "gateway journal rehydrates artifacts and unconfirmed canvas proposals after reopening")
        restored.resumeGateway()
        await wait { !restored.isRunning && restored.runPhase == .applied }
        let count = await transport.createCount
        let cursors = await transport.cursors
        check(count == 1 && cursors.last == "event-5",
              "native resume uses the committed cursor and does not submit a new run")
        check(restored.messages.filter { $0.role == .assistant && !$0.isFailure }
            .map(\.content) == ["部分🙂文字＋续接完成"],
              "split UTF-8 and replayed events produce one complete native assistant message")
        check(restored.queuedSubmissions.count == 1 && !restored.canResumeGateway,
              "restart-paused queue is retained after recovery completes")
        canvas.moveNodes(ids: [node.id], by: CGSize(width: 77, height: 12))
        let localPosition = canvas.node(id: node.id)
        if let pending = restoredContext.pendingGraphPreviews.first {
            restoredContext.presentMutation(pending, conversationID: restored.selectedConversationID)
            restoredContext.applyMutation(conversationID: restored.selectedConversationID)
        }
        NSLog("[GatewayNative] applyError=%@ status=%@", restoredContext.error ?? "none",
              restoredContext.status ?? "none")
        check(restoredContext.graphPreview?.isApplied == true
            && canvas.node(id: node.id)?.width == after.width
            && canvas.node(id: node.id)?.x == localPosition?.x,
              "confirmed remote configuration preserves an intervening local drag")
        let historyCount = canvas.history.count
        restoredContext.applyMutation(conversationID: restored.selectedConversationID)
        check(canvas.history.count == historyCount, "repeated confirmation cannot duplicate the graph mutation")
        check(canvas.undo() != nil && canvas.node(id: node.id)?.width == node.width
            && canvas.node(id: node.id)?.x == localPosition?.x,
              "native history undo reverses only the confirmed remote edit")
        let reloaded = CanvasStorage(rootOverride: root).load(projectId: canvas.activeProjectId)
        check(!reloaded.appliedAgentMutationIDs.isEmpty, "mutation receipt is committed with the graph")
        check(store.canvasReadFullContent(groupId: node.groupId, slot: node.slot)?.plainText == "保持此原文🙂",
              "gateway graph recovery preserves actual slot body bytes")
        let handoff = try restored.externalHandoffContext()
        let args = try handoff.mcpConfiguration().encodedText()
        check(args.contains("--snapshot-id") && args.contains(binding.sessionID),
              "external handoff uses the saved snapshot and original project/session scope")
        if let lease = handoff.liveLease {
            let config = AgentExternalReadOnlyMCPConfiguration(scope: handoff.scope,
                snapshotID: handoff.snapshotID, sessionID: handoff.sessionID)
            let tools = try AgentExternalLiveMCPTools(reader: AgentExternalReadOnlyMCPTools(configuration: config), lease: lease)
            do {
                let wrongSession = AgentExternalReadOnlyMCPConfiguration(scope: handoff.scope,
                    snapshotID: handoff.snapshotID, sessionID: UUID())
                _ = try AgentExternalLiveMCPTools(reader: AgentExternalReadOnlyMCPTools(configuration: wrongSession), lease: lease)
                check(false, "live lease rejects a mismatched reader conversation")
            } catch { check(true, "live lease rejects a mismatched reader conversation") }
            let expired = AgentLiveMCPLease(directory: lease.directory, token: lease.token, runID: lease.runID,
                expiresAt: .distantPast, scope: handoff.scope, sessionID: lease.sessionID, snapshotID: lease.snapshotID)
            do {
                _ = try AgentExternalLiveMCPTools(reader: AgentExternalReadOnlyMCPTools(configuration: config), lease: expired)
                check(false, "expired live leases cannot initialize a client")
            } catch { check(true, "expired live leases cannot initialize a client") }
            let identity = await tools.execute(call: .init(id: "identity", name: "clipslots_context", argumentsJSON: "{}"))
            let identityJSON = try JSONValue.decode(jsonText: identity.content)
            check(identityJSON["live_run_id"]?.stringValue == lease.runID
                && identityJSON["writes_require_native_confirmation"]?.boolValue
                    == !(restored.automaticApproval && lease.accessMode != .allDirectoriesReadOnly),
                "live MCP exposes the actual scoped run and current native approval policy")
            let current = canvas.node(id: node.id)!
            var changed = current; changed.height += 31
            let liveMutation = AgentCanvasMutation(projectID: handoff.scope.projectID,
                conversationID: restored.selectedConversationID.uuidString, runID: lease.runID,
                mutationID: "live-native-1", changes: [.init(before: current, after: changed)])
            let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(liveMutation))
            let proposal = AgentToolCall(id: "proposal", name: "preview_canvas_mutation",
                argumentsJSON: try JSONValue.object(["mutation": payload]).encodedText())
            let first = await tools.execute(call: proposal)
            check(!first.isFailure && canvas.node(id: node.id)?.height == current.height,
                  "live MCP mailbox submits a native preview without prematurely changing the graph")
            let rpc: [JSONValue] = [
                ["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": ["name": "canvas_mutation_status", "arguments": ["mutation_id": "live-native-1"]]]
            ]
            let encodedLease = String(decoding: try JSONEncoder().encode(lease), as: UTF8.self)
            let cliResult = await AgentProcessRunner.run(executable: "/usr/bin/env",
                arguments: [AgentLiveMCPLease.environmentKey + "=" + encodedLease,
                            handoff.cliPath, "--mcp", "--project-id", handoff.scope.projectID,
                            "--canvas-id", handoff.scope.canvasID, "--snapshot-id", lease.snapshotID.uuidString,
                            "--session-id", lease.sessionID.uuidString],
                standardInput: try rpc.map { try $0.encodedText() }.joined(separator: "\n") + "\n",
                timeout: 15)
            let wire = cliResult.stdout.split(separator: "\n").compactMap { try? JSONValue.decode(jsonText: String($0)) }
            check(cliResult.exitCode == 0 && wire.count == 2
                && wire[0]["result"]?["tools"]?.arrayValue?.contains(where: { $0["name"]?.stringValue == "preview_canvas_mutation" }) == true
                && wire[1]["result"]?["isError"]?.boolValue == false,
                "actual stdio CLI advertises live tools and queries the running native instance")
            let pendingCount = restoredContext.pendingGraphPreviews.count
            let replay = await tools.execute(call: proposal)
            check(!replay.isFailure && restoredContext.pendingGraphPreviews.count == pendingCount,
                  "replayed live proposal does not duplicate pending previews")
            var altered = payload.objectValue!
            altered["changes"] = []
            let reused = await tools.execute(call: .init(id: "reused", name: "preview_canvas_mutation",
                argumentsJSON: try JSONValue.object(["mutation": .object(altered)]).encodedText()))
            check(reused.isFailure, "live MCP refuses different payloads sharing one mutation identity")
            var foreign = payload.objectValue!
            foreign["project_id"] = "another-project"
            foreign["mutation_id"] = "foreign-mutation"
            let rejected = await tools.execute(call: .init(id: "foreign", name: "preview_canvas_mutation",
                argumentsJSON: try JSONValue.object(["mutation": .object(foreign)]).encodedText()))
            check(rejected.isFailure && canvas.node(id: node.id)?.height == current.height,
                  "live MCP rejects cross-project changes before any graph write")
            if let pending = restoredContext.pendingGraphPreviews.first(where: { $0.id == "live-native-1" }) {
                restoredContext.presentMutation(pending, conversationID: restored.selectedConversationID)
                restoredContext.applyMutation(conversationID: restored.selectedConversationID)
            }
            let query = AgentToolCall(id: "status", name: "canvas_mutation_status",
                argumentsJSON: #"{"mutation_id":"live-native-1"}"#)
            let status = await tools.execute(call: query)
            check((try? JSONValue.decode(jsonText: status.content))?["status"]?.stringValue == "applied"
                && canvas.node(id: node.id)?.height == changed.height,
                "native confirmation writes the live MCP proposal and exposes its receipt")
            check(canvas.undo() != nil && canvas.node(id: node.id)?.height == current.height,
                  "live MCP writes use the actual durable canvas undo transaction")
            let replayAfterUndo = await tools.execute(call: proposal)
            check((try? JSONValue.decode(jsonText: replayAfterUndo.content))?["status"]?.stringValue == "applied"
                && canvas.node(id: node.id)?.height == current.height,
                "replay after undo returns the committed receipt without reapplying the edit")
            restored.stop()
            let cancelled = await tools.execute(call: query)
            let cancelledRead = await tools.execute(call: .init(id: "cancel-read", name: "clipslots_context", argumentsJSON: "{}"))
            check(cancelled.isFailure && cancelledRead.isFailure && !FileManager.default.fileExists(atPath: lease.directory.path),
                  "stop revokes live MCP reads and proposals even when no internal run is active")
        } else { check(false, "external handoff creates a live native lease") }
        if let record = restored.artifacts.first {
            let conversation = restored.selectedConversationID
            let savedState: JSONValue = ["counter": 7, "text": "状态🙂"]
            let identity = restored.artifactPageIdentity(key: record.key, revision: record.revision)
            let saved = try await restored.artifactRequest(identity: identity,
                operation: "set_state", name: "", arguments: savedState)
            let loaded = try await restored.artifactRequest(identity: identity,
                operation: "get_state", name: "", arguments: [:])
            check(saved["status"]?.stringValue == "saved" && loaded == savedState,
                  "native artifact request saves and reloads real widget state")
            let read = try await restored.artifactRequest(identity: identity,
                operation: "tools_call", name: "canvas_overview", arguments: [:])
            check(read["status"]?.stringValue == "completed" && read["result"]?.objectValue != nil,
                  "native widget tool request returns actual canvas tool result")
            let currentNode = canvas.node(id: node.id)!
            var widgetNode = currentNode; widgetNode.width += 19
            let widgetMutation = AgentCanvasMutation(projectID: canvas.activeProjectId,
                conversationID: conversation.uuidString, runID: "page-untrusted", mutationID: "widget-mutation",
                changes: [.init(before: currentNode, after: widgetNode)])
            let widgetPayload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(widgetMutation))
            let proposal = try await restored.artifactRequest(identity: identity,
                operation: "tools_call", name: "preview_canvas_mutation",
                arguments: ["mutation": widgetPayload])
            check(proposal["status"]?.stringValue == "pending" && canvas.node(id: node.id)?.width == currentNode.width,
                  "widget mutation returns pending without writing before native confirmation")
            if let preview = restoredContext.pendingGraphPreviews.first(where: { $0.id == "widget-mutation" }) {
                restoredContext.presentMutation(preview, conversationID: conversation)
                restoredContext.applyMutation(conversationID: conversation)
            }
            check(canvas.node(id: node.id)?.width == widgetNode.width && canvas.undo() != nil,
                  "widget proposal uses durable native confirmation and undo")
            _ = try await restored.artifactRequest(identity: identity,
                operation: "model_context", name: "", arguments: ["note": "模型补充🙂"])
            check(restored.snapshot.widgetContext?["note"]?.stringValue == "模型补充🙂",
                  "widget model-context supplement is saved in actual conversation snapshot")
            do {
                _ = try await restored.artifactRequest(identity: .init(key: record.key, conversationID: UUID(),
                    revision: record.revision, runtimeEpoch: identity.runtimeEpoch, canvasEpoch: identity.canvasEpoch),
                    operation: "get_state", name: "", arguments: [:])
                check(false, "widget request rejects stale conversation")
            } catch { check(true, "widget request rejects stale conversation") }
            restored.selectedArtifact = record
            let panelIdentity = restored.artifactPageIdentity(key: record.key, revision: record.revision)
            var previewReady = false
            var previewError: String?
            let host = NSHostingView(rootView: AgentArtifactPanel(record: record,
                pageIdentity: panelIdentity, onAction: { restored.handleArtifactAction($0, identity: panelIdentity) },
                onClose: {}, onPreviewState: { state in
                    if state == .ready { previewReady = true }
                    if case .error(let message) = state { previewError = message }
                }, onRequest: { operation, name, arguments in
                    try await restored.artifactRequest(identity: panelIdentity,
                        operation: operation, name: name, arguments: arguments)
                }))
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 560),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            await wait { previewReady || previewError != nil }
            check(previewReady, "HTML artifact WebKit navigation actually finishes: \(previewError ?? "no error")")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])
                try data?.write(to: directory.appendingPathComponent("agent-artifact-native.png"))
                check(data != nil, "HTML artifact renders in a real native preview host")
            } else { check(false, "HTML artifact native host capture") }
            window.close()
        }
        restored.removeQueuedSubmission(restored.queuedSubmissions.first?.id ?? UUID())
        restored.flushSession()
        let supplementTransport = AgentScriptedTransport(steps: [.sse(
            "data: {\"choices\":[{\"delta\":{\"content\":\"已收到资料\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
        restored.setBackend(AgentService(transport: supplementTransport,
            secretStore: AgentInMemorySecretStore(key: "fixture")), kind: .deepseek)
        check(restored.send(text: "读取组件补充", config: AgentConfig(), enabledSkills: []),
              "widget supplement starts a real subsequent native submission")
        await wait { !restored.isRunning }
        let supplementRequest = await supplementTransport.lastRequestJSON()
        check(supplementRequest?["messages"]?.arrayValue?.first?["content"]?.stringValue?
            .contains("模型补充🙂") == true,
              "widget supplement reaches the actual next backend request after normalization")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        let imageBytes = bitmap.representation(using: .png, properties: [:])!
        let imageURL = directory.appendingPathComponent("agent-image.png")
        try imageBytes.write(to: imageURL)
        restored.draftAttachments = [try AgentAttachmentImport.capture(imageURL)]
        check(restored.flushSession(), "native image draft persists its captured bytes")
        try FileManager.default.removeItem(at: imageURL)
        check(!restored.send(text: "看图", config: AgentConfig(), enabledSkills: [])
            && restored.draftAttachments.count == 1,
              "native send preserves image draft when model has no declared image support")
        let imageTransport = AgentScriptedTransport(steps: [.sse(
            "data: {\"choices\":[{\"delta\":{\"content\":\"图片已传入\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
        restored.setBackend(AgentService(transport: imageTransport,
            secretStore: AgentInMemorySecretStore(key: "fixture")), kind: .deepseek)
        var imageConfig = AgentConfig(); imageConfig.supportsImageInput = true
        check(restored.send(text: "看图", config: imageConfig, enabledSkills: []),
              "native sends supported image after original source is removed")
        await wait { !restored.isRunning }
        let imageRequest = await imageTransport.lastRequestJSON()
        let imageParts = imageRequest?["messages"]?.arrayValue?.last?["content"]?.arrayValue
        check(imageParts?.last?["image_url"]?["url"]?.stringValue
            == "data:image/png;base64," + imageBytes.base64EncodedString(),
              "native actual backend request receives the exact saved image bytes")
        var referenceContent = SlotContent(text: "引用图像正文")
        referenceContent.attachments = [.init(name: "引用.png", type: .image, data: imageBytes)]
        check(store.specialStorage.set(1, content: referenceContent, in: group.id),
              "native canvas image source persisted")
        canvas.selectedNodeIds = [node.id]
        restoredContext.addSelection(to: restored)
        restoredContext.captureReferenceImages(to: restored)
        await wait { !restoredContext.isLoadingReferences }
        let capturedReference = restored.draftReferences.first?.images?.first
        check(capturedReference?.imageSnapshot.flatMap(NSImage.init(data:)) != nil
            && store.specialStorage.get(1, in: group.id).attachments.first?.resolveData() == imageBytes,
              "native explicit image capture reads actual stored canvas bytes")
        let referenceTransport = AgentScriptedTransport(steps: [.sse(
            "data: {\"choices\":[{\"delta\":{\"content\":\"引用已传入\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
        restored.setBackend(AgentService(transport: referenceTransport,
            secretStore: AgentInMemorySecretStore(key: "fixture")), kind: .deepseek)
        check(restored.send(text: "分析引用图片", config: imageConfig, enabledSkills: []),
              "native canvas image submission succeeds")
        await wait { !restored.isRunning }
        let referenceRequest = await referenceTransport.lastRequestJSON()
        let capturedURL = capturedReference.flatMap { file in
            file.imageSnapshot.map { "data:\(file.imageMIMEType ?? "image/jpeg");base64," + $0.base64EncodedString() }
        }
        check(capturedURL != nil && referenceRequest?["messages"]?.arrayValue?.last?["content"]?.arrayValue?.last?["image_url"]?["url"]?.stringValue
            == capturedURL,
              "native canvas reference reaches the actual backend as image bytes")
        await runAgentModelNetworkProbe(directory: directory, check: check)
        await runAgentArtifactScriptProbe(directory: directory, check: check)
        await runAgentArtifactMediaProbe(directory: directory, check: check)
        await runAgentNativeMCPProbe(store: store, directory: directory, check: check)
    } catch { check(false, "native gateway integration: \(error.localizedDescription)") }
}

@MainActor
private func runAgentModelNetworkProbe(directory: URL, check: (Bool, String) -> Void) async {
    guard let port = ProcessInfo.processInfo.environment["CLIPSLOTS_FIXTURE_PORT"],
          let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
        check(false, "catalog listener endpoint available"); return
    }
    do {
        let path = directory.appendingPathComponent("v1/models")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"data":[{"id":"fixture-vision","context_window":32768,"capabilities":{"image_input":true}}]}"#.utf8).write(to: path)
        let catalog = AgentModelCatalogStore(credentials: { _, _ in nil })
        catalog.refresh(endpoint: endpoint, gateway: false)
        for _ in 0..<200 {
            if !catalog.isLoading { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(catalog.models.first?.id == "fixture-vision" && catalog.error == nil,
              "actual URLSession localhost model discovery receives and parses HTTP response")
        check(catalog.supportsImages(model: "fixture-vision", endpoint: endpoint, gateway: false)
            && !catalog.supportsImages(model: "fixture-vision", endpoint: endpoint, gateway: true),
              "image capability binds to the discovered endpoint and provider")
        try Data("invalid JSON".utf8).write(to: path)
        catalog.refresh(endpoint: endpoint, gateway: false)
        for _ in 0..<200 {
            if !catalog.isLoading { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(catalog.error != nil && catalog.models.isEmpty,
              "actual malformed HTTP model response clears stale capabilities")
        let status = SFSpeechRecognizer.authorizationStatus()
        let recognizer = SFSpeechRecognizer(locale: .current)
        let evidence: [String: Any] = [
            "authorizationStatus": status.rawValue, "locale": Locale.current.identifier,
            "available": recognizer?.isAvailable ?? false,
            "supportsOnDeviceRecognition": recognizer?.supportsOnDeviceRecognition ?? false,
            "microphoneRequested": false, "audioTranscriptionValidated": false
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("voice-availability.json"))
    } catch { check(false, "actual model discovery network fixture: \(error)") }
}

@MainActor
private func runAgentArtifactScriptProbe(directory: URL, check: (Bool, String) -> Void) async {
    var ready = false
    var calls = 0
    var requests = 0
    let action = AgentArtifactAppToolAction(id: "canvas-preview", label: "预览文字", toolName: "preview_canvas_text")
    let source = """
    <button id="counter" onclick="this.textContent=String(Number(this.textContent)+1)">0</button>
    <button onclick="clipslots.callTool('canvas-preview', 'button-call')">预览文字</button>
    <p>交互产物测试🙂</p>
    """
    let host = NSHostingView(rootView: AgentArtifactHTMLPreview(source: source,
        onState: { if $0 == .ready { ready = true } }, onLink: { _ in },
        actions: [action], onTool: { _ in calls += 1 }, onRequest: { _, _, arguments in
            requests += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return ["status": "completed", "result": arguments]
        }))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    for _ in 0..<150 {
        if ready { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    func webView(_ root: NSView) -> WKWebView? {
        if let view = root as? WKWebView { return view }
        return root.subviews.compactMap(webView).first
    }
    guard ready, let view = webView(host) else { check(false, "interactive artifact loads native WebKit"); return }
    func js(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result) }
        }
    }
    let counter = await js("document.getElementById('counter').click(); document.getElementById('counter').textContent")
    check(counter as? String == "1", "artifact inline JavaScript updates a real DOM button")
    _ = await js("clipslots.callTool('canvas-preview','same-call').then(x => window.firstStatus=x.status)")
    for _ in 0..<50 {
        if calls == 1 { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    _ = await js("clipslots.callTool('canvas-preview','same-call').then(x => window.replayStatus=x.status)")
    _ = await js("clipslots.callTool('unknown-tool','bad-call').catch(x => window.badStatus=String(x))")
    _ = await js("fetch('https://example.com/').catch(x => window.networkBlocked=true)")
    for _ in 0..<50 {
        if await js("window.replayStatus") as? String == "already_dispatched" { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let replayStatus = await js("window.replayStatus")
    let rejected = await js("window.badStatus")
    let blocked = await js("window.networkBlocked")
    check(calls == 1 && replayStatus as? String == "already_dispatched",
          "artifact tool bridge dispatches one native allowlisted action despite replay")
    check((rejected as? String)?.contains("TOOL_NOT_ENABLED") == true && calls == 1,
          "artifact JavaScript cannot call unadvertised native tools")
    check(blocked as? Bool == true, "interactive artifact CSP blocks script network requests")
    _ = await js("Promise.all([clipslots.executeTool('canvas_overview',{label:'回传🙂'},'async-1'),clipslots.executeTool('canvas_overview',{label:'回传🙂'},'async-1')]).then(x=>window.actualResult=x[1].result.label)")
    _ = await js("clipslots.executeTool('canvas_nodes',{},'async-1').catch(x=>window.conflict=String(x))")
    for _ in 0..<50 {
        if await js("window.actualResult") as? String == "回传🙂" { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let actualResult = await js("window.actualResult")
    let conflict = await js("window.conflict")
    check(requests == 1 && actualResult as? String == "回传🙂",
          "WebKit asynchronous tool bridge returns actual JSON and executes concurrent replay once")
    check((conflict as? String)?.contains("CALL_ID_CONFLICT") == true,
          "WebKit bridge rejects different payload under the same call identity")
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(
            to: directory.appendingPathComponent("agent-artifact-interactive.png"))
    }
}

private actor GatewayNativeFixtureTransport: AgentGatewayTransport {
    let binding: AgentRunBinding
    let mutation: AgentCanvasMutation
    let messageID = UUID()
    var createCount = 0
    var cursors: [String] = []
    var streams = 0
    var requestKey: String?

    init(binding: AgentRunBinding, mutation: AgentCanvasMutation) {
        self.binding = binding; self.mutation = mutation
    }
    func value<T: Encodable>(_ source: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(source))
    }
    func descriptor() throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["schemaVersion": 1, "binding": try value(binding),
            "runID": "fixture-run", "phase": "streaming",
            "requestKey": requestKey.map(JSONValue.string) ?? .null]))
    }
    func send(request: URLRequest) async throws -> AgentGatewayHTTPResponse {
        if request.httpMethod == "POST", request.url?.lastPathComponent == "runs" {
            createCount += 1
            requestKey = request.value(forHTTPHeaderField: "Idempotency-Key")
        }
        return try .init(statusCode: 200, body: descriptor())
    }
    func frame(_ event: String, _ ordinal: Int, _ payload: JSONValue) throws -> Data {
        let envelope: JSONValue = ["schemaVersion": 1, "binding": try value(binding), "runID": "fixture-run",
            "eventID": .string("event-\(ordinal)"), "payload": payload]
        return Data("event: \(event)\nid: event-\(ordinal)\ndata: \(try envelope.encodedText())\n\n".utf8)
    }
    func stream(request: URLRequest) async throws -> AgentHTTPStream {
        streams += 1
        cursors.append(request.value(forHTTPHeaderField: "Last-Event-ID") ?? "")
        var bytes = Data()
        if streams == 1 {
            bytes.append(try frame("initial", 1, ["messageID": .string(messageID.uuidString)]))
            bytes.append(try frame("content", 2, ["messageID": .string(messageID.uuidString), "delta": "部分🙂文字"]))
            bytes.append(try frame("artifact_updated", 3, ["artifactID": "artifact-1", "path": "preview.html",
                "revision": 1, "mimeType": "text/html", "title": "镜头预览",
                "content": "<h1>产物🙂</h1><p>从原运行恢复的画布结果</p>"]))
            bytes.append(try frame("canvas_changed", 4, value(mutation)))
            bytes.append(try frame("waiting_suspended", 5, [:]))
        } else {
            bytes.append(try frame("waiting_suspended", 5, [:]))
            bytes.append(try frame("content", 6, ["messageID": .string(messageID.uuidString), "delta": "＋续接完成"]))
            bytes.append(try frame("run_completed", 7, ["messageID": .string(messageID.uuidString)]))
        }
        let chunks = stride(from: 0, to: bytes.count, by: 2).map { offset in
            Data(bytes[offset..<min(offset + 2, bytes.count)])
        }
        return AgentHTTPStream(statusCode: 200, chunks: AsyncThrowingStream { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
        })
    }
}
#endif
