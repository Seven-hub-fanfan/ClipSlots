#if DEBUG
import Foundation
import AppKit
import SwiftUI
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
        check(model.send(text: "稍后继续", config: AgentConfig(), enabledSkills: []),
              "a waiting run accepts a separate queued direction")
        check(model.flushSession(), "waiting run, original submission and queue survive a disk save")
        let restoredGateway = AgentGatewayBackend(baseURL: endpoint, binding: binding, journalRoot: runtime,
                                                  transport: transport)
        let restored = AgentChatModel(displayName: "续接验收", backend: restoredGateway,
            persistenceURL: sessionURL, canvasProjectID: canvas.activeProjectId, backendKind: .gateway)
        let restoredContext = CanvasAgentContext(canvas: canvas, store: store, projectID: canvas.activeProjectId)
        restored.canvasContext = restoredContext
        await wait { restored.canResumeGateway && restoredContext.pendingGraphPreviews.count == 1 }
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
        if let record = restored.artifacts.first {
            restored.selectedArtifact = record
            var previewReady = false
            var previewError: String?
            let host = NSHostingView(rootView: AgentArtifactPanel(record: record,
                onAction: restored.handleArtifactAction, onClose: {}, onPreviewState: { state in
                    if state == .ready { previewReady = true }
                    if case .error(let message) = state { previewError = message }
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
        await runAgentArtifactMediaProbe(directory: directory, check: check)
    } catch { check(false, "native gateway integration: \(error.localizedDescription)") }
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
