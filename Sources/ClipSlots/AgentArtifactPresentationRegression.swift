#if DEBUG
import AppKit
import WebKit
import ClipSlotsKit
import SwiftUI

/// Exercises real WKWebView notifications without foreground activation or cloud calls.
@MainActor
func runArtifactPresentationRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ value: Bool, _ name: String) { (value ? checks.append(name) : failures.append(name)) }
    let coordinator = AgentArtifactHTMLPreview.Coordinator()
    let web = AgentArtifactHTMLPreview.makeWebView(coordinator: coordinator)
    web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web
    defer {
        coordinator.detach(); web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        window.close()
    }
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
    func wait(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    func promise(_ code: String) async -> JSONValue? {
        let key = "promise" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = await evaluate("Promise.resolve(\(code)).then(x=>window.\(key)=x).catch(()=>window.\(key)={caught:true}); null")
        guard await wait({ await evaluate("window.\(key)") != nil }) else { return nil }
        return await evaluate("window.\(key)")
    }
    let source = """
    <script>
    window.notifications=[];
    window.addEventListener('message', e=>{
      if(e.source===window && e.data.clipslots_host && e.data.method) window.notifications.push(e.data);
    });
    document.addEventListener('DOMContentLoaded',()=>clipslots.initialize().then(x=>window.initialized=x));
    </script><input id="draft" value="草稿🙂"><p>Presentation fixture</p>
    """
    do {
        let key = try AgentArtifactKey(projectID: "fixture", canvasID: "fixture", path: "presentation.html")
        let identity = AgentArtifactPageIdentity(key: key, conversationID: UUID(), revision: 1)
        let projection = try AgentArtifactPageData(revision: .init(messageSequence: 1, partIndex: 0),
                                                   toolInput: [:], toolResult: ["summary": "fixture"])
        var sizes: [Double] = [], collapses = 0
        func update(_ expanded: Bool, page: AgentArtifactPageIdentity? = nil, html: String? = nil) {
            coordinator.update(source: html ?? source, onState: { _ in }, onLink: { _ in },
                               identity: page ?? identity, pageProjection: projection,
                               presentationExpanded: expanded, onSizeChanged: { sizes.append($0) },
                               onCollapse: { collapses += 1 }, presentationResourceURI: "ui://tapnow/previs@v3")
        }
        update(false)
        check(await wait { await evaluate("window.initialized.result.protocolVersion") == "2026-01-26" },
              "actual page initializes")
        _ = await promise("clipslots.rpc('ping',{})")
        let initial = await evaluate("window.notifications")
        try JSONEncoder().encode(initial ?? .null).write(to: directory.appendingPathComponent("initial-notifications.json"))
        check(initial?.arrayValue?.contains { $0["method"] == "tapnow/presentationState" } == true,
              "initialized page receives tracked presentation state")
        check(initial?.arrayValue?.first { $0["method"] == "ui/notifications/sandbox-resource-ready" }?["params"]?["resource"]
              == ["name": "previs", "version": "v3"],
              "local ready notice preserves declared widget identity without claiming a remote hash")
        check(initial?.arrayValue?.filter { $0["method"] != "ui/notifications/sandbox-resource-ready" }
            .map { $0["method"]?.stringValue ?? "" } == [
                "ui/notifications/tool-input", "ui/notifications/tool-result", "tapnow/presentationState"],
              "source initialization notification order is preserved")
        let size = await promise("clipslots.rpc('ui/notifications/size-changed',{height:280})")
        try JSONEncoder().encode(size ?? .null).write(to: directory.appendingPathComponent("size-response.json"))
        check(size?["error"] == nil, "actual page size notification is accepted")
        check(sizes == [280], "size callback reaches native host exactly once")
        for height in ["0", "-1", "'230'", "true", "null"] {
            let invalid = await promise("clipslots.rpc('ui/notifications/size-changed',{height:\(height)})")
            check(invalid?["error"]?["code"] == -32602 && sizes == [280], "invalid size \(height) has no layout effect")
        }
        let nonce = await evaluate("window.__clipslotsNativeInstance")
        _ = await evaluate("document.getElementById('draft').value='保留草稿🙂'; null")
        update(true)
        check(await wait { await evaluate("window.notifications.filter(x=>x.method==='tapnow/presentationState').length") == 2 },
              "expanding sends changed presentation state")
        let expandedState = await evaluate("window.notifications.filter(x=>x.method==='tapnow/presentationState')[1].params.expanded")
        let expandedNonce = await evaluate("window.__clipslotsNativeInstance")
        let expandedDraft = await evaluate("document.getElementById('draft').value")
        check(expandedState == true && expandedNonce == nonce && expandedDraft == "保留草稿🙂",
              "expansion preserves actual WebKit instance and draft")
        check(await evaluate("window.notifications.find(x=>x.method==='ui/notifications/host-context-changed').params.displayMode") == "fullscreen",
              "expanded native host context advertises fullscreen")
        update(true)
        _ = await promise("clipslots.rpc('ping',{})")
        check(await evaluate("window.notifications.filter(x=>x.method==='tapnow/presentationState').length") == 2,
              "equal presentation state does not repeat notifications")
        coordinator.sendPresentationShortcut("ArrowRight")
        check(await wait { await evaluate("window.notifications.some(x=>x.method==='tapnow/presentationShortcut')") == true },
              "ready expanded previs receives native shortcut")
        coordinator.sendPresentationShortcut("Delete")
        _ = await evaluate("document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true})); null")
        _ = await promise("clipslots.rpc('ping',{})")
        check(await evaluate("window.notifications.filter(x=>x.method==='tapnow/presentationShortcut').length") == 1,
              "unsupported keys and synthetic DOM events cannot forward shortcuts")
        let escape = await promise("""
            window.webkit.messageHandlers.clipslots.postMessage({presentation_key:'Escape',
            instance:window.__clipslotsNativeInstance,revision:'1'})
            """)
        check(escape?["caught"] == nil && collapses == 1, "escape reaches current native collapse handler")
        update(false)
        check(await wait { await evaluate("window.notifications.filter(x=>x.method==='tapnow/presentationState').length") == 3 },
              "collapse sends changed presentation state")
        coordinator.sendPresentationShortcut("Enter")
        _ = await promise("clipslots.rpc('ping',{})")
        check(await evaluate("window.notifications.filter(x=>x.method==='tapnow/presentationShortcut').length") == 1,
              "collapsed page receives no native shortcuts")
        update(true)
        web.reload()
        check(await wait {
            let instance = await evaluate("window.__clipslotsNativeInstance")
            let notified = await evaluate("window.notifications.some(x=>x.method==='tapnow/presentationState'&&x.params.expanded)")
            return instance != nonce && notified == true
        }, "real WebKit reload rotates identity and replays current presentation")
        let reloaded = await evaluate("window.notifications")
        try JSONEncoder().encode(reloaded ?? .null).write(to: directory.appendingPathComponent("reloaded-notifications.json"))
        check(reloaded?.arrayValue?.filter { $0["method"] == "tapnow/presentationState" }.count == 1,
              "reload replays presentation only once")
        let old = await promise("""
            window.webkit.messageHandlers.clipslots.postMessage({presentation_key:'Escape',
            instance:\((try nonce?.encodedText()) ?? "null"),revision:'1'})
            """)
        check(old?["caught"] == true && collapses == 1, "pre-reload identity cannot collapse replacement page")
        update(true, html: "<img src='file:///fixture-resource-denied.png'>")
        check(await wait {
            let result = await promise("clipslots.rpc('ping',{})")
            return result?["error"]?["message"] == "page closed or replaced"
        }, "real resource failure ends presentation lifecycle")
        let count = sizes.count
        let closedSize = await promise("clipslots.rpc('ui/notifications/size-changed',{height:400})")
        coordinator.sendPresentationShortcut("ArrowRight")
        check(closedSize?["error"] != nil && sizes.count == count, "failed page cannot write native layout")
        let repository = try AgentArtifactRepository(directory: directory.appendingPathComponent("panel"))
        let record = try repository.merge(.init(key: key, revision: 1, content: Data(source.utf8), mimeType: "text/html",
            pageProjection: projection, pageProjectionConversationID: identity.conversationID,
            pageResourceURI: "ui://tapnow/previs@v3"))
        let panel = AgentArtifactPanel(record: record, pageIdentity: identity, onAction: { _ in }, onClose: {})
            .loadingPageResources(endpoint: nil)
        let host = NSHostingView(rootView: panel)
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 950),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        panelWindow.isReleasedWhenClosed = false; panelWindow.contentView = host
        defer { panelWindow.close() }
        func findWeb(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for child in view.subviews { if let web = findWeb(child) { return web } }
            return nil
        }
        func panelValue(_ code: String) async -> JSONValue? {
            host.layoutSubtreeIfNeeded()
            guard let web = findWeb(host) else { return nil }
            return await withCheckedContinuation { continuation in
                web.evaluateJavaScript(code) { value, error in
                    guard error == nil, let value,
                          let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                          let json = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: json)
                }
            }
        }
        check(await wait {
            await panelValue("window.notifications.some(x=>x.method==='tapnow/presentationState'&&x.params.expanded)") == true
        }, "actual SwiftUI artifact panel auto-expands declared previs on ready")
        let panelNonce = await panelValue("window.__clipslotsNativeInstance")
        check(findWeb(host).map { $0.frame.height >= 520 } == true,
              "actual native panel expansion changes the mounted WebKit height")
        _ = await panelValue("document.getElementById('draft').value='面板草稿🙂'; null")
        _ = await panelValue("""
            window.webkit.messageHandlers.clipslots.postMessage({presentation_key:'Escape',
            instance:window.__clipslotsNativeInstance,revision:'1'}); null
            """)
        check(await wait {
            await panelValue("window.notifications.filter(x=>x.method==='tapnow/presentationState').slice(-1)[0].params.expanded") == false
        }, "native panel collapse callback reaches presentation state")
        let collapsedNonce = await panelValue("window.__clipslotsNativeInstance")
        let panelDraft = await panelValue("document.getElementById('draft').value")
        check(collapsedNonce == panelNonce && panelDraft == "面板草稿🙂",
              "actual panel collapse keeps same mounted page and draft")
        let panelRaw = await panelValue("window.notifications")
        try JSONEncoder().encode(panelRaw ?? .null).write(to: directory.appendingPathComponent("panel-notifications.json"))
        host.rootView = AgentArtifactPanel(record: record,
            pageIdentity: .init(key: key, conversationID: UUID(), revision: 1), onAction: { _ in }, onClose: {})
            .loadingPageResources(endpoint: nil)
        check(await wait {
            let changed = await panelValue("window.__clipslotsNativeInstance")
            let ready = await panelValue("window.initialized.result.protocolVersion")
            return changed != nil && changed != panelNonce && ready == "2026-01-26"
        }, "another native conversation replaces the mounted page")
        let foreignRaw = await panelValue("window.notifications")
        check(foreignRaw?.arrayValue?.contains { $0["method"] == "tapnow/presentationState" } == false
              && foreignRaw?.arrayValue?.first { $0["method"] == "ui/notifications/sandbox-resource-ready" }?["params"]?["resource"]?["name"]
                  == "clipslots-local-artifact",
              "foreign conversation cannot borrow source resource identity or expansion policy")
        try JSONEncoder().encode(foreignRaw ?? .null).write(to: directory.appendingPathComponent("foreign-panel-notifications.json"))
    } catch { failures.append("fixture error: \(error)") }
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "foregroundAccepted": false, "M06Accepted": false, "goalComplete": false]
}
#endif
