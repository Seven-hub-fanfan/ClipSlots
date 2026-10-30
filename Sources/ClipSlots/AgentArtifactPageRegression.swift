#if DEBUG
import AppKit
import WebKit
import ClipSlotsKit
import SwiftUI

/// Actual WebKit document and durable local state. No foreground input or cloud acceptance.
@MainActor
func runArtifactPageRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) { (value ? checks.append(name) : failures.append(name)) }
    let restarted = ProcessInfo.processInfo.environment["CLIPSLOTS_ARTIFACT_PAGE_RESTART"] == "1"
    let coordinator = AgentArtifactHTMLPreview.Coordinator()
    let web = AgentArtifactHTMLPreview.makeWebView(coordinator: coordinator)
    web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    defer {
        coordinator.detach(); web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        window.close()
    }
    var states: [AgentArtifactResourceState] = []
    var responses: [String: JSONValue] = [:]
    var nativeCalls = 0, actions = 0, cancelledCalls = 0
    let source = "<button id='counter' onclick='this.textContent=String(Number(this.textContent)+1)'>0</button>"
    func evaluate(_ code: String) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(code) { result, error in
                guard error == nil, let result,
                      let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: value)
            }
        }
    }
    func wait(_ predicate: () async -> Bool, iterations: Int = 200) async -> Bool {
        for _ in 0..<iterations {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }
    func promise(_ code: String) async -> JSONValue? {
        let key = "r" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = await evaluate("Promise.resolve(\(code)).then(x=>window['\(key)']=x).catch(x=>window['\(key)']={caught:String(x)}); null")
        _ = await wait { await evaluate("window['\(key)']") != nil }
        let result = await evaluate("window['\(key)']")
        responses[code] = result ?? .null
        return result
    }
    do {
        let key = try AgentArtifactKey(projectID: "fixture-project", canvasID: "fixture-canvas", path: "page.html")
        let identityFile = directory.appendingPathComponent("page-identity.txt")
        let conversation: UUID
        if restarted, let text = try? String(contentsOf: identityFile), let saved = UUID(uuidString: text) {
            conversation = saved
        } else {
            conversation = UUID()
            try conversation.uuidString.write(to: identityFile, atomically: true, encoding: .utf8)
        }
        let stateStore = try AgentWidgetStateStore(directory: directory.appendingPathComponent("widget-state"))
        let identity = AgentArtifactPageIdentity(key: key, conversationID: conversation, revision: 4)
        let action = AgentArtifactAppToolAction(id: "allowlisted", label: "测试", toolName: "preview_canvas_text")
        func update(_ identity: AgentArtifactPageIdentity, html: String = source, enabled: Bool = true,
                    projection: AgentArtifactPageData? = nil, widgetState: JSONValue? = nil) {
            states = []
            coordinator.update(source: html, onState: { states.append($0) }, onLink: { _ in },
                actions: enabled ? [action] : [], onTool: { _ in actions += 1 },
                onRequest: enabled ? { operation, name, args in
                    nativeCalls += 1
                    if operation == "set_state" {
                        try stateStore.save(args, key: identity.key, conversationID: identity.conversationID,
                                            revision: identity.revision)
                        return ["status": "saved"]
                    }
                    if operation == "get_state" {
                        return try stateStore.load(key: identity.key, conversationID: identity.conversationID,
                                                   revision: identity.revision)
                    }
                    if name == "slow" {
                        do { try await Task.sleep(for: .seconds(1)) }
                        catch { cancelledCalls += 1 }
                    }
                    if name == "fail" { throw AgentOperationError("fixture-secret-must-not-leak") }
                    if name == "large" { return ["result": .string(String(repeating: "x", count: 65537))] }
                    if operation == "tools_list" {
                        return ["tools": [["type": "function", "function": [
                            "name": "fixture", "description": "local fixture",
                            "parameters": ["type": "object"]]]]]
                    }
                    if name == "fixture" {
                        let counter = directory.appendingPathComponent("actual-tool-count.txt")
                        let count = (try? String(contentsOf: counter)).flatMap(Int.init) ?? 0
                        try String(count + 1).write(to: counter, atomically: true, encoding: .utf8)
                    }
                    return ["status": "completed", "result": args]
                } : nil, identity: identity, pageProjection: projection, initialWidgetState: widgetState)
        }
        update(identity)
        check(await wait { states.contains(.ready) }, "actual WebKit navigation completes without a visible window")
        check(await evaluate("document.getElementById('counter').click(); document.getElementById('counter').textContent") == "1",
              "real inline DOM remains interactive")
        let early = await promise("clipslots.rpc('ping',{})")
        check(early?["error"]?["code"] == -32000, "JSON-RPC operations require initialized notification")
        let initialization = await promise("clipslots.initialize()")
        try JSONEncoder().encode(initialization ?? .null).write(to: directory.appendingPathComponent("initialization.json"))
        check(initialization?["result"]?["protocolVersion"] == "2026-01-26"
              && initialization?["result"]?["hostInfo"]?["name"] == "clipslots"
              && initialization?["result"]?["hostCapabilities"]?["serverTools"]?.objectValue != nil
              && initialization?["result"]?["hostCapabilities"]?["message"] == nil,
              "initialization exposes actual capabilities and native host identity")
        let nonce = initialization?["nonce"]?.stringValue ?? ""
        let ping = await promise("clipslots.rpc('ping',{})")
        check(ping?["result"]?.objectValue != nil && ping?["revision"] == "4", "initialized ping preserves resource revision")
        let zeroID = await promise("clipslots.rpc('ping',{},0)")
        let booleanID = await promise("clipslots.rpc('ping',{},true)")
        check(zeroID?["id"] == 0 && zeroID?["result"]?.objectValue != nil
              && booleanID?["id"] == .null && booleanID?["error"]?["code"] == -32602,
              "actual WebKit preserves zero id and returns null for invalid boolean id")
        let expected: JSONValue = ["text": "完整原文🙂\n汉字", "empty": "", "counter": 7, "enabled": false]
        if restarted {
            let restored = await promise("clipslots.rpc('tapnow/getWidgetState',{})")
            check(restored?["result"] == expected, "independent App process restores exact widget state")
            check(nativeCalls == 1 && actions == 0, "page reload performs no tool or legacy action automatically")
        } else {
            let stateText = try expected.encodedText()
            let saved = await promise("clipslots.rpc('tapnow/setWidgetState',{state:\(stateText)},'save')")
            let loaded = await promise("clipslots.rpc('tapnow/getWidgetState',{})")
            check(saved?["result"]?.objectValue != nil && loaded?["result"] == expected,
                  "RPC state roundtrip reaches the real temporary state file")
        }
        let before = nativeCalls
        let diskBefore = (try? String(contentsOf: directory.appendingPathComponent("actual-tool-count.txt"))).flatMap(Int.init) ?? 0
        let repeated = await promise("Promise.all([clipslots.rpc('tools/call',{name:'fixture',arguments:{text:'回传🙂'}},'repeat'),clipslots.rpc('tools/call',{name:'fixture',arguments:{text:'回传🙂'}},'repeat')])")
        check(nativeCalls == before + 1 && repeated?.arrayValue?.last?["result"]?["structuredContent"]?["text"] == "回传🙂",
              "concurrent identical JSON-RPC calls execute the actual file tool once")
        check((try? String(contentsOf: directory.appendingPathComponent("actual-tool-count.txt"))) == String(diskBefore + 1),
              "disk side effect count agrees with independent process history")
        let conflict = await promise("clipslots.rpc('tools/call',{name:'fixture',arguments:{text:'changed'}},'repeat')")
        check(conflict?["error"]?["code"] == -32602 && nativeCalls == before + 1,
              "conflicting payload cannot reuse a JSON-RPC request id")
        let list = await promise("clipslots.rpc('tools/list',{})")
        check(list?["result"]?["tools"]?.arrayValue?.first?["inputSchema"]?["type"] == "object",
              "native function schema is adapted to MCP inputSchema")
        let invalid = await promise("clipslots.rpc('tapnow/setWidgetState',{state:[]})")
        check(invalid?["error"]?["code"] == -32602, "source widget state rejects arrays")
        let badTool = await promise("clipslots.rpc('tools/call',{name:'fixture',arguments:[]})")
        check(badTool?["error"]?["code"] == -32602, "tool arguments reject arrays")
        let failed = await promise("clipslots.rpc('tools/call',{name:'fail',arguments:{}})")
        let failureText = try failed?.encodedText() ?? "fixture-secret-must-not-leak"
        check(failed?["error"]?["code"] == -32000
              && !failureText.contains("fixture-secret-must-not-leak"),
              "RPC failure exposes classification without underlying error text")
        let large = await promise("clipslots.rpc('tools/call',{name:'large',arguments:{}})")
        check(large?["error"]?["message"] == "result limit", "actual oversized tool result is rejected")
        let unknown = await promise("clipslots.rpc('method/not-supported',{})")
        check(unknown?["error"]?["code"] == -32601, "unsupported methods return standard JSON-RPC error")
        let reply = await promise("clipslots.rpc('ui/message',{details:{type:'app_reply'}})")
        check(reply?["error"]?["code"] == -32602, "invalid structured reply fails before any submission")
        let legacy = await promise("clipslots.callTool('allowlisted','legacy')")
        let replay = await promise("clipslots.callTool('allowlisted','legacy')")
        check(legacy?["status"] == "dispatched" && replay?["status"] == "already_dispatched" && actions == 1,
              "legacy allowlisted action remains compatible and deduplicated")
        let legacyState = await promise("clipslots.getState()")
        _ = await promise("clipslots.executeTool('fixture',{},'shared-identity')")
        let crossed = await promise("clipslots.callTool('allowlisted','shared-identity')")
        check(legacyState == expected && crossed?["caught"]?.stringValue?.contains("CALL_ID_CONFLICT") == true
              && actions == 1, "legacy default ids work and tool/action identity collisions are rejected")
        let revisionMismatch = await promise("window.webkit.messageHandlers.clipslots.postMessage({jsonrpc:'2.0',id:'old-revision',method:'ping',params:{},nonce:'\(nonce)',revision:'3'})")
        check(revisionMismatch?["error"]?["message"] == "stale resource revision", "old resource revision is rejected by native bridge")
        _ = await evaluate("window.addEventListener('message',e=>{if(e.data.id==='post-test'&&e.data.result)window.postResult=e.data}); window.postMessage({jsonrpc:'2.0',id:'post-test',method:'ping',params:{},nonce:'\(nonce)'},'*'); null")
        check(await wait { await evaluate("window.postResult.result")?.objectValue != nil },
              "source style window postMessage completes JSON-RPC roundtrip")
        let slowStarted = nativeCalls
        _ = await evaluate("clipslots.rpc('tools/call',{name:'slow',arguments:{}},'slow').then(x=>window.lateResult=x); null")
        check(await wait { nativeCalls == slowStarted + 1 }, "slow native request starts in original instance")
        let other = AgentArtifactPageIdentity(key: key, conversationID: UUID(), revision: 4)
        update(other)
        check(await wait { states.contains(.ready) }, "same HTML in another conversation creates new page instance")
        let newInitialization = await promise("clipslots.initialize()")
        check(newInitialization?["nonce"]?.stringValue.map { !$0.isEmpty && $0 != nonce } == true,
              "conversation switch rotates native nonce")
        let oldInstance = await promise("window.webkit.messageHandlers.clipslots.postMessage({jsonrpc:'2.0',id:'old-instance',method:'ping',params:{},nonce:'\(nonce)',revision:'4'})")
        let otherState = await promise("clipslots.rpc('tapnow/getWidgetState',{})")
        check(oldInstance?["error"]?["code"] == -32600 && otherState?["result"] == .null,
              "old page nonce rejected and new conversation cannot read original state")
        let lateResult = await evaluate("window.lateResult")
        check(cancelledCalls == 1 && lateResult == nil,
              "noncooperative late request cannot publish into replacement document")
        let reactivated = AgentArtifactPageIdentity(key: key, conversationID: other.conversationID, revision: 4,
                                                    runtimeEpoch: UUID(), canvasEpoch: UUID())
        update(reactivated)
        check(await wait { states.contains(.ready) }, "same conversation and HTML reload on native authority epoch change")
        let reactivationInitialization = await promise("clipslots.initialize()")
        let reactivationNonce = reactivationInitialization?["nonce"]?.stringValue ?? ""
        check(!reactivationNonce.isEmpty && reactivationNonce != newInitialization?["nonce"]?.stringValue,
              "reactivating native authority rotates page nonce independently of conversation UUID")
        update(reactivated, enabled: false)
        check(await wait { states.contains(.ready) }, "permission revocation reloads same HTML")
        let readOnly = await promise("clipslots.initialize()")
        let disabled = await promise("clipslots.rpc('tapnow/getWidgetState',{})")
        check(readOnly?["result"]?["hostCapabilities"]?.objectValue?.isEmpty == true
              && disabled?["error"]?["code"] == -32601, "revoked callbacks are absent and inaccessible")
        update(reactivated, html: "<img src='file:///clipslots-fixture-resource-unavailable.png'>")
        check(await wait { states.contains { if case .error = $0 { return true }; return false } },
              "actual denied local resource reports preview failure")
        check(states.last != .ready, "navigation finish cannot overwrite resource failure with ready")
        let callsBeforeResourceFailure = nativeCalls
        let resourceCall = await promise("clipslots.executeTool('fixture',{},'resource-failed')")
        check(resourceCall?["caught"]?.stringValue?.contains("PAGE_CLOSED") == true
              && nativeCalls == callsBeforeResourceFailure,
              "failed resource revokes the private native tool bridge")
        let notificationHTML = """
        <script>
        window.hostNotifications=[];
        window.addEventListener('message',e=>{
          if(e.source===window && e.data.clipslots_host && e.data.method)
            window.hostNotifications.push(e.data);
        });
        document.addEventListener('DOMContentLoaded',()=>clipslots.initialize());
        </script><p>Projection fixture</p>
        """
        let projectionRepository = try AgentArtifactRepository(directory: directory.appendingPathComponent("page-projection"))
        let initialProjection = try AgentArtifactPageData(revision: .init(messageSequence: 7, partIndex: 2),
            toolInput: ["prompt": "工具原文🙂e\u{301}", "media_ref": "private-input",
                        "nested": [["poster_ref": "private-poster", "enabled": false]]],
            toolResult: ["summary": "完整结果🙂e\u{301}", "full": [1, .null, false], "media_ref": "private-result"])
        if !restarted {
            let event: JSONValue = ["artifactID": "page-projection", "path": .string(key.path),
                "revision": 4, "mimeType": "text/html", "content": .string(notificationHTML),
                "pageProjection": try JSONValue.decode(jsonText: String(decoding: JSONEncoder().encode(initialProjection), as: UTF8.self))]
            _ = try projectionRepository.merge(AgentArtifactGatewayPayload.update(event, scope: key.scope,
                                                                                  conversationID: conversation))
        }
        guard let projectionRecord = try projectionRepository.record(for: key),
              let persistedProjection = projectionRecord.pageProjection else { throw AgentArtifactError.invalidMetadata }
        check(persistedProjection == initialProjection && projectionRecord.text == notificationHTML
              && projectionRecord.pageProjectionConversationID == conversation,
              "actual App process restores persisted source projection with exact original input and result")
        update(reactivated, html: notificationHTML, projection: persistedProjection, widgetState: expected)
        check(await wait { await evaluate("window.hostNotifications.some(x=>x.method==='ui/notifications/tool-input')") == true },
              "initialized page receives source tool-input notification")
        check(await wait { await evaluate("window.hostNotifications.some(x=>x.method==='ui/notifications/tool-result')") == true },
              "initialized page receives source tool-result notification")
        let initialInput = await evaluate("window.hostNotifications.find(x=>x.method==='ui/notifications/tool-input').params")
        let initialResult = await evaluate("window.hostNotifications.find(x=>x.method==='ui/notifications/tool-result').params")
        check(initialInput == initialProjection.inputParams && initialResult == initialProjection.resultParams(widgetState: expected),
              "actual WebKit initial notifications preserve public arrays, exact text and native widget metadata")
        check(initialInput?["arguments"]?["media_ref"] == nil
              && initialResult?["structuredContent"]?["media_ref"] == nil,
              "actual page does not receive internal media transport references")
        func panelNotifications(_ panelConversation: UUID) async throws -> JSONValue {
            let panel = AgentArtifactPanel(record: projectionRecord,
                pageIdentity: .init(key: key, conversationID: panelConversation, revision: 4),
                onAction: { _ in }, onClose: {}, onRequest: { operation, _, _ in
                    if operation == "get_state" { return expected }
                    throw AgentArtifactRPCError.unsupported
                })
            let host = NSHostingView(rootView: panel)
            let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                styleMask: [.titled], backing: .buffered, defer: false)
            panelWindow.isReleasedWhenClosed = false; panelWindow.contentView = host
            defer { panelWindow.close() }
            func findWeb(_ node: NSView) -> WKWebView? {
                if let web = node as? WKWebView { return web }
                for child in node.subviews { if let web = findWeb(child) { return web } }
                return nil
            }
            func notifications() async -> JSONValue? {
                host.layoutSubtreeIfNeeded()
                guard let panelWeb = findWeb(host) else { return nil }
                return await withCheckedContinuation { continuation in
                    panelWeb.evaluateJavaScript("window.hostNotifications") { result, error in
                        guard error == nil, let result,
                              let bytes = try? JSONSerialization.data(withJSONObject: result),
                              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
                            continuation.resume(returning: nil); return
                        }
                        continuation.resume(returning: value)
                    }
                }
            }
            guard await wait({
                await notifications()?.arrayValue?.contains { $0["method"] == "ui/notifications/tool-input" } == true
            }) else { throw AgentArtifactError.storageUnavailable }
            return await notifications() ?? .null
        }
        let ownedPanel = try await panelNotifications(conversation)
        check(ownedPanel.arrayValue?.first { $0["method"] == "ui/notifications/tool-result" }?["params"] == initialResult,
              "actual native artifact panel loads current conversation widget state into source result metadata")
        let foreignPanel = try await panelNotifications(UUID())
        check(foreignPanel.arrayValue?.first { $0["method"] == "ui/notifications/tool-input" }?["params"] == ["arguments": [:]]
              && foreignPanel.arrayValue?.contains { $0["method"] == "ui/notifications/tool-result" } == false,
              "actual same-project artifact panel hides original conversation tool input and result")
        let projectionInit = await promise("clipslots.initialize()")
        let projectionNonce = projectionInit?["nonce"]?.stringValue ?? ""
        check(await evaluate("window.hostNotifications.filter(x=>x.method==='ui/notifications/tool-input').length") == 1,
              "duplicate initialized notification does not resend tool input")
        let newerProjection = try AgentArtifactPageData(revision: .init(messageSequence: 7, partIndex: 3),
            toolInput: ["prompt": "后续输入🙂"], toolResult: ["summary": "后续结果", "all": [3, 2, 1]])
        update(reactivated, html: notificationHTML, projection: newerProjection, widgetState: expected)
        check(await wait { await evaluate("window.hostNotifications.filter(x=>x.method==='tapnow/updateData').length") == 1 },
              "same HTML instance receives source updateData for higher part index")
        let actualUpdate = await evaluate("window.hostNotifications.find(x=>x.method==='tapnow/updateData').params")
        check(actualUpdate == newerProjection.updateParams, "actual updateData carries toolInput, toolResult and source revision")
        update(reactivated, html: notificationHTML, projection: initialProjection)
        let conflictingProjection = try AgentArtifactPageData(revision: newerProjection.revision,
            toolInput: ["prompt": "冲突"], toolResult: ["summary": "错误"])
        update(reactivated, html: notificationHTML, projection: conflictingProjection)
        _ = await promise("clipslots.rpc('ping',{})")
        check(await evaluate("window.hostNotifications.filter(x=>x.method==='tapnow/updateData').length") == 1,
              "late and equal source revisions cannot overwrite current WebKit tool projection")
        let nextMessage = try AgentArtifactPageData(revision: .init(messageSequence: 8, partIndex: 0),
            toolInput: ["prompt": "新消息"], toolResult: nil)
        update(reactivated, html: notificationHTML, projection: nextMessage)
        check(await wait { await evaluate("window.hostNotifications.filter(x=>x.method==='tapnow/updateData').length") == 2 },
              "higher message sequence accepts lower part index without reloading HTML")
        check(await evaluate("window.hostNotifications.filter(x=>x.method==='tapnow/updateData')[1].params.toolResult") == .null,
              "new source input does not borrow prior message tool result")
        web.reload()
        check(await wait {
            let instance = await evaluate("window.__clipslotsNativeInstance")
            let inputReady = await evaluate("window.hostNotifications.some(x=>x.method==='ui/notifications/tool-input')")
            return instance.map { $0 != .string(projectionNonce) } == true && inputReady == true
        }, "actual WebKit reload rotates page nonce and reinitializes source notifications")
        let reloadedInput = await evaluate("window.hostNotifications.find(x=>x.method==='ui/notifications/tool-input').params")
        let reloadedResultCount = await evaluate("window.hostNotifications.filter(x=>x.method==='ui/notifications/tool-result').length")
        check(reloadedInput == nextMessage.inputParams
              && reloadedResultCount == 0,
              "reloaded page projects current input without resurrecting old result")
        let preReload = await promise("window.webkit.messageHandlers.clipslots.postMessage({jsonrpc:'2.0',id:'pre-reload',method:'ping',params:{},nonce:'\(projectionNonce)',revision:'4'})")
        check(preReload?["error"]?["code"] == -32600, "actual reloaded page rejects pre-reload nonce")
        let timeoutIdentity = AgentArtifactPageIdentity(key: key, conversationID: conversation, revision: 4,
                                                       runtimeEpoch: UUID())
        update(timeoutIdentity, html: "<p>App deliberately never initializes</p>", projection: initialProjection)
        let timeoutStarted = Date()
        check(await wait({
            states.contains { if case .error(let text) = $0 { return text.contains("初始化超时") }; return false }
        }, iterations: 1200), "actual uninitialized MCP resource times out from load without any initialize request")
        check(Date().timeIntervalSince(timeoutStarted) >= 14 && !states.contains(.ready),
              "navigation completion never marks an uninitialized MCP resource ready")
        let afterTimeout = await promise("clipslots.initialize()")
        let beforeTimeoutCall = nativeCalls
        let timedOutPrivate = await promise("clipslots.executeTool('fixture',{},'timed-out-private')")
        check(afterTimeout?["error"]?["message"] == "page closed or replaced"
              && timedOutPrivate?["caught"]?.stringValue?.contains("PAGE_CLOSED") == true
              && nativeCalls == beforeTimeoutCall,
              "late initialized and private tool requests cannot revive timed-out resource")
        let reopenedIdentity = AgentArtifactPageIdentity(key: key, conversationID: conversation, revision: 4,
                                                        runtimeEpoch: UUID())
        update(reopenedIdentity, html: notificationHTML, projection: initialProjection)
        check(await wait { states.contains(.ready) }, "explicit fresh instance recovers after initialization timeout")
        let beforeDetach = nativeCalls
        coordinator.detach()
        let detached = await promise("clipslots.executeTool('fixture',{},'detached')")
        check(detached?["caught"]?.stringValue?.contains("PAGE_NOT_ENABLED") == true
              && nativeCalls == beforeDetach, "closed WebKit coordinator cannot execute native page tool")
        check(try stateStore.load(key: key, conversationID: conversation, revision: 4) == expected,
              "original durable state remains after instance and permission changes")
        await runNativeArtifactSessionBoundary(directory: directory, restarted: restarted, check: check)
        await runNativeArtifactCallbackBoundary(directory: directory, restarted: restarted, check: check)
    } catch { failures.append("WebKit fixture: \(error)") }
    try? JSONEncoder().encode(responses).write(to: directory.appendingPathComponent("rpc-responses.json"))
    return ["passed": checks.count, "checks": checks, "failures": failures, "phase": restarted ? "restart" : "session",
            "webKit": true, "foreground": false, "guiAccepted": false, "remoteProviderRequests": 0,
            "appReplyBackendAccepted": false, "M06Accepted": false, "goalComplete": false]
}

@MainActor
private func runNativeArtifactCallbackBoundary(directory: URL, restarted: Bool,
                                               check: (Bool, String) -> Void) async {
    do {
        let root = directory.appendingPathComponent(restarted ? "callback-restart" : "callback-session")
        let store = SlotStoreObservable()
        let storage = CanvasStorage(rootOverride: root.appendingPathComponent("canvas"))
        let projectStorage = CanvasProjectStorage(rootOverride: root.appendingPathComponent("canvas"))
        let initial = projectStorage.load()
        guard let active = initial.projects.first(where: { $0.id == initial.activeProjectId }) else {
            throw AgentArtifactError.storageUnavailable
        }
        let node = CanvasNode(pageId: SpecialSlotStorage.canvasPrivatePageId, groupId: active.privateGroupId,
                              slot: restarted ? 9 : 8, kind: .text, x: 0, y: 0)
        guard storage.save(.init(nodes: [node]), projectId: active.id) else { throw AgentArtifactError.storageUnavailable }
        let canvas = CanvasStore(storage: storage, projectStorage: projectStorage)
        let project = canvas.activeProjectId
        let originalContent = SlotContent(items: [[.init(type: "public.utf8-plain-text", data: Data("原槽位正文🙂".utf8))]])
        _ = try store.canvasStorage(groupId: node.groupId).ensureReservedGroup(
            id: node.groupId, name: active.privateGroupName)
        guard store.canvasStorage(groupId: node.groupId).set(node.slot, content: originalContent, in: node.groupId) else {
            throw AgentArtifactError.storageUnavailable
        }
        canvas.selectedNodeIds = [node.id]
        let context = CanvasAgentContext(canvas: canvas, store: store, projectID: project)
        let model = AgentChatModel(displayName: "原生回调边界", service: AgentService(
            transport: AgentScriptedTransport(steps: []), secretStore: AgentInMemorySecretStore(key: "fixture")),
            persistenceURL: root.appendingPathComponent("agent-sessions/callback.json"), canvasProjectID: project)
        model.canvasContext = context
        let repository = try AgentArtifactRepository(directory: root.appendingPathComponent("agent_artifacts"))
        let key = try AgentArtifactKey(projectID: project, canvasID: project, path: "shared.html")
        let record = try repository.merge(.init(key: key, revision: 1, content: Data("<p>旧页面正文🙂</p>".utf8)))
        func refresh() async throws {
            model.refreshArtifacts()
            for _ in 0..<200 {
                if model.artifacts.contains(where: { $0.key == key && $0.revision == 1 }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AgentArtifactError.storageUnavailable
        }
        try await refresh()
        let conversation = model.selectedConversationID
        let action = AgentArtifactPanelAction.appTool(.init(key: key, revision: 1,
            action: .init(id: "canvas-text", label: "预览", toolName: "preview_canvas_text")))
        // Capture exactly the callbacks held by the original sheet before SwiftUI updates.
        let oldIdentity = model.artifactPageIdentity(key: key, revision: 1)
        let oldAction: (AgentArtifactPanelAction) -> Void = { model.handleArtifactAction($0, identity: oldIdentity) }
        let oldClose = { model.dismissArtifact(identity: oldIdentity) }
        let oldRequest: (String, JSONValue) async throws -> JSONValue = { operation, arguments in
            try await model.artifactRequest(identity: oldIdentity, operation: operation, name: "", arguments: arguments)
        }
        let originalState: JSONValue = ["original": "不可被旧回调覆盖🙂"]
        _ = try await oldRequest("set_state", originalState)
        model.draft = "保留原会话"
        model.clearHistory()
        let replacement = model.selectedConversationID
        try await refresh()
        model.selectedArtifact = record
        let errorBefore = context.error
        oldAction(action)
        model.artifactPanelDismissed()
        check(model.selectedArtifact == record && context.error == errorBefore && context.preview == nil,
              "old native action cannot close replacement sheet or prepare text in another conversation")
        oldClose()
        let replacementError = model.errorText
        oldAction(.retry(key))
        check(model.selectedArtifact == record && model.errorText == replacementError,
              "old close and retry callbacks cannot mutate replacement conversation UI")
        do {
            _ = try await oldRequest("set_state", ["stale": true])
            check(false, "old native request rejects replacement conversation")
        } catch { check(true, "old native request rejects replacement conversation") }
        model.openConversation(id: conversation)
        try await refresh()
        check(model.selectedConversationID == conversation && replacement != conversation,
              "actual model returns to original conversation with shared project artifact")
        model.selectedArtifact = record
        oldAction(action)
        check(model.selectedArtifact == record, "old native action rejects same-conversation reactivation")
        do {
            _ = try await oldRequest("set_state", ["reactivated": "must-not-write"])
            check(false, "old native request rejects same-conversation reactivation before disk write")
        } catch { check(true, "old native request rejects same-conversation reactivation before disk write") }
        model.selectAccessMode(.allDirectoriesReadOnly)
        model.selectedArtifact = record
        model.handleArtifactAction(action, identity: model.artifactPageIdentity(key: key, revision: 1))
        check(model.selectedArtifact == record, "current native text preview obeys read-only access mode")
        let revokedIdentity = model.artifactPageIdentity(key: key, revision: 1)
        model.selectAccessMode(.fullAccess)
        model.selectedArtifact = record
        model.handleArtifactAction(action, identity: revokedIdentity)
        check(model.selectedArtifact == record, "restoring access does not revive revoked native callbacks")
        do {
            _ = try await model.artifactRequest(identity: revokedIdentity, operation: "set_state",
                                               name: "", arguments: ["revoked": true])
            check(false, "restoring access does not revive revoked state requests")
        } catch { check(true, "restoring access does not revive revoked state requests") }
        let projectIdentity = model.artifactPageIdentity(key: key, revision: 1)
        let other = canvas.createProject(name: "暂时切换")
        _ = canvas.switchProject(to: other.id)
        _ = canvas.switchProject(to: project)
        model.handleArtifactAction(action, identity: projectIdentity)
        check(model.selectedArtifact == record, "returning to active project does not revive old page callback")
        do {
            _ = try await model.artifactRequest(identity: projectIdentity, operation: "set_state",
                                               name: "", arguments: ["old_project": true])
            check(false, "project reactivation rejects stale state request before disk write")
        } catch { check(true, "project reactivation rejects stale state request before disk write") }
        canvas.selectedNodeIds = [node.id]
        model.handleArtifactAction(action, identity: model.artifactPageIdentity(key: key, revision: 1))
        check(model.selectedArtifact == nil, "current allowed native text preview remains available")
        model.artifactPanelDismissed()
        check(context.preview?.conversationID == conversation && context.preview?.target.nodeID == node.id
              && context.preview?.text == record.text && context.preview?.before == AgentSlotBody(originalContent),
              "allowed native callback prepares actual selected-node preview in original conversation")
        check(store.canvasReadFullContent(groupId: node.groupId, slot: node.slot)?.plainText == "原槽位正文🙂",
              "native artifact preview leaves actual original slot body unchanged before confirmation")
        context.dismissPreview()
        model.selectedArtifact = record
        let closedIdentity = model.artifactPageIdentity(key: key, revision: 1)
        model.dismissArtifact(identity: closedIdentity)
        model.selectedArtifact = record
        model.handleArtifactAction(action, identity: closedIdentity)
        check(model.selectedArtifact == record && context.preview == nil,
              "closing and reopening the same artifact does not revive old callbacks")
        model.dismissArtifact(identity: model.artifactPageIdentity(key: key, revision: 1))
        let restoredState = try await model.artifactRequest(identity: model.artifactPageIdentity(key: key, revision: 1),
            operation: "get_state", name: "", arguments: [:])
        check(restoredState == originalState, "stale native callbacks preserve original durable state after reactivation")
        check(model.flushSession() && canvas.flushSave(), "callback boundary fixture persists isolated model state")
    } catch { check(false, "native artifact callback fixture: \(error)") }
}

@MainActor
private func runNativeArtifactSessionBoundary(directory: URL, restarted: Bool,
                                              check: (Bool, String) -> Void) async {
    do {
        let store = SlotStoreObservable()
        let canvas = CanvasStore(storage: CanvasStorage(rootOverride: directory.appendingPathComponent("native-canvas")),
            projectStorage: CanvasProjectStorage(rootOverride: directory.appendingPathComponent("native-canvas")))
        let projectID = canvas.activeProjectId
        let sessionURL = directory.appendingPathComponent("agent-sessions/native-page.json")
        let model = AgentChatModel(displayName: "页面边界", service: AgentService(
            transport: AgentScriptedTransport(steps: []), secretStore: AgentInMemorySecretStore(key: "fixture")),
            persistenceURL: sessionURL, canvasProjectID: projectID)
        let context = CanvasAgentContext(canvas: canvas, store: store, projectID: projectID)
        model.canvasContext = context
        let repository = try AgentArtifactRepository(directory: directory.appendingPathComponent("agent_artifacts"))
        let key = try AgentArtifactKey(projectID: projectID, canvasID: projectID, path: "native-page.html")
        let record = try repository.merge(.init(key: key, revision: restarted ? 2 : 1,
            content: Data("<p>实际会话🙂</p>".utf8), title: "页面", mimeType: "text/html"))
        model.refreshArtifacts()
        for _ in 0..<200 {
            if model.artifacts.contains(where: { $0.key == key && $0.revision == record.revision }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let conversation = model.selectedConversationID
        let saved: JSONValue = ["original": "实际会话完整状态🙂"]
        func request(_ operation: String, _ args: JSONValue = [:], revision: UInt64? = nil,
                     conversation target: UUID? = nil, name: String = "") async throws -> JSONValue {
            let current = model.artifactPageIdentity(key: key, revision: revision ?? record.revision)
            let identity = AgentArtifactPageIdentity(key: key, conversationID: target ?? conversation,
                revision: current.revision, runtimeEpoch: current.runtimeEpoch, canvasEpoch: current.canvasEpoch)
            return try await model.artifactRequest(identity: identity, operation: operation, name: name, arguments: args)
        }
        if restarted {
            let restored = try await request("get_state")
            let observation: JSONValue = ["conversation": .string(conversation.uuidString),
                "project": .string(projectID), "revision": .string(String(record.revision)),
                "runBinding": model.snapshot.runBindingID.map { .string($0.uuidString) } ?? .null,
                "state": restored]
            try JSONEncoder().encode(observation).write(to: directory.appendingPathComponent("native-restore-observation.json"))
            check(restored == saved, "actual AgentChatModel independently restores bound widget state")
        } else {
            _ = try await request("set_state", saved)
            check(try await request("get_state") == saved, "actual AgentChatModel saves and reads original conversation state")
        }
        let list = try await request("tools_list")
        check(list["tools"]?.arrayValue?.contains { $0["function"]?["name"] == "canvas_overview" } == true,
              "actual page tool list comes from active canvas snapshot")
        let overview = try await request("tools_call", name: "canvas_overview")
        check(overview["status"] == "completed", "actual page read tool executes against isolated canvas")
        do {
            _ = try await request("get_state", conversation: UUID())
            check(false, "actual model rejects another conversation")
        } catch { check(true, "actual model rejects another conversation") }
        if !restarted {
            _ = try repository.merge(.init(key: key, revision: 2, content: Data("<p>实际会话🙂</p>".utf8)))
            model.refreshArtifacts()
            for _ in 0..<200 {
                if model.artifacts.first(where: { $0.key == key })?.revision == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            do {
                _ = try await request("set_state", ["stale": true], revision: 1)
                check(false, "actual model rejects prior content revision")
            } catch { check(true, "actual model rejects prior content revision") }
            _ = try await request("set_state", saved, revision: 2)
        }
        _ = try await request("model_context", ["content": [["type": "text", "text": "保留的模型资料🙂"]]], revision: 2)
        let prior = model.snapshot.widgetContext
        let parent = sessionURL.deletingLastPathComponent()
        let backup = directory.appendingPathComponent("native-session-backup")
        try FileManager.default.moveItem(at: parent, to: backup)
        let blocker = Data("fixture-persistence-blocker".utf8)
        try blocker.write(to: parent)
        do {
            _ = try await request("model_context", ["new": "must-not-remain"], revision: 2)
            check(false, "actual context persistence failure is surfaced")
        } catch { check(model.snapshot.widgetContext == prior, "actual context persistence failure restores prior memory value") }
        guard try Data(contentsOf: parent) == blocker else { throw AgentArtifactError.storageUnavailable }
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: backup, to: parent)
        check(model.flushSession(), "actual session persists after temporary filesystem failure is removed")
        model.selectAccessMode(.allDirectoriesReadOnly)
        let limited = try await request("tools_list", revision: 2)
        check(limited["tools"]?.arrayValue?.contains { $0["function"]?["name"] == "preview_canvas_mutation" } == false,
              "actual read-only page capability omits mutation preview")
        do {
            _ = try await request("tools_call", ["mutation": [:]], revision: 2, name: "preview_canvas_mutation")
            check(false, "actual read-only page rejects mutation invocation")
        } catch { check(true, "actual read-only page rejects mutation invocation") }
        let another = canvas.createProject(name: "other")
        _ = canvas.switchProject(to: another.id)
        do {
            _ = try await request("get_state", revision: 2)
            check(false, "actual inactive project rejects page requests")
        } catch { check(true, "actual inactive project rejects page requests") }
        let switchedBack = canvas.switchProject(to: projectID)
        let diskIndex = CanvasProjectStorage(rootOverride: directory.appendingPathComponent("native-canvas")).load()
        check(switchedBack && canvas.activeProjectId == projectID && diskIndex.activeProjectId == projectID,
              "actual workspace switch persists incoming project ID for independent restart")
        check(model.flushSession() && canvas.flushSave(), "actual canvas and conversation finish with durable original identity")
    } catch { check(false, "actual artifact session fixture: \(error)") }
}
#endif
