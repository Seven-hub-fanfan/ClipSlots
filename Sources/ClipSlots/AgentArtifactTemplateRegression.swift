#if DEBUG
import AppKit
import WebKit
import ClipSlotsKit

/// Actual WebKit, opaque-frame reports, loopback HTML and a frozen published SDK.
@MainActor
func runArtifactTemplateRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        (condition ? checks.append(name) : failures.append(name))
        try? JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks,
            "failures": failures, "partial": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("partial-report.json"), options: .atomic)
    }
    let coordinator = AgentArtifactHTMLPreview.Coordinator()
    let web = AgentArtifactHTMLPreview.makeWebView(coordinator: coordinator)
    web.configuration.userContentController.addUserScript(WKUserScript(source: """
        window.fixtureReports=[]; window.fixtureFrames=[];
        addEventListener('message',e=>{
          if(e.source!==document.querySelector('iframe')?.contentWindow || !e.data) return;
          window.fixtureFrames.push(e.data);
          if(e.data.method==='fixture/report') window.fixtureReports.push(e.data.params);
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
                      let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
                      let json = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: json)
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
    func send(_ method: String, _ params: JSONValue) async {
        let data: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        guard let text = try? AgentArtifactTemplateHTML.literal(data) else { return }
        _ = await evaluate("document.querySelector('iframe').contentWindow.postMessage(\(text),'*'); null")
    }
    func report(_ tag: String) async -> JSONValue? {
        let text = (try? AgentArtifactTemplateHTML.literal(.string(tag))) ?? "null"
        guard await wait({ await evaluate("window.fixtureReports.find(x=>x.tag===\(text))") != nil }) else { return nil }
        return await evaluate("window.fixtureReports.find(x=>x.tag===\(text))")
    }
    do {
        let key = try AgentArtifactKey(projectID: "fixture", canvasID: "fixture", path: "template.html")
        let identity = AgentArtifactPageIdentity(key: key, conversationID: UUID(), revision: 1)
        let projection = try AgentArtifactPageData(revision: .init(messageSequence: 1, partIndex: 0),
            toolInput: [:], toolResult: ["summary": "template"])
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("fixture-config.json")))
        guard let base = config["baseURL"]?.stringValue,
              let endpoint = AgentArtifactPageResourceEndpoint(
                channelURL: URL(string: base + "/mcp-apps/channels/current.json"),
                proxyURL: URL(string: base + "/012345abcd/mcp-app-proxy.html")!, allowsLoopback: true) else {
            throw AgentArtifactRPCError.invalid
        }
        let loader = AgentArtifactPageResourceLoader(allowsLoopback: true)
        var states: [AgentArtifactResourceState] = [], loaded: [String] = [], policies: [Double?] = [], sizes: [Double] = []
        var widgetState: JSONValue = ["draft": "原状态🙂"]
        var operations: [String] = []
        func update(_ expanded: Bool = false, page: AgentArtifactPageIdentity? = nil,
                    uri: String = "ui://tapnow/previs@v3", enabled: Bool = true) {
            let handler: ((String, String, JSONValue) async throws -> JSONValue)? = enabled ? { operation, _, args in
                operations.append(operation)
                switch operation {
                case "get_state": return widgetState
                case "set_state": widgetState = args; return [:]
                case "model_context": return [:]
                case "tools_call": return ["result": ["value": "tool fixture"]]
                default: throw AgentArtifactRPCError.unsupported
                }
            } : nil
            coordinator.update(source: "<p id='local'>LOCAL_CACHE</p>", onState: { states.append($0) }, onLink: { _ in },
                onRequest: handler, identity: page ?? identity, pageProjection: projection, presentationExpanded: expanded,
                onSizeChanged: { sizes.append($0) }, presentationResourceURI: uri,
                pageResourceURI: uri, pageResourceLoader: loader, pageResourceEndpoint: endpoint,
                onTemplate: { policies.append($0.presentation.maxInlineHeight) }, onTemplateLoaded: { loaded.append($0.hash) })
        }
        update()
        let initial = await report("initialized")
        check(await evaluate("document.querySelector('iframe')?.getAttribute('sandbox')") == "allow-scripts",
              "declared resource runs inside opaque iframe")
        let remoteSource = await evaluate("document.querySelector('iframe').srcdoc.includes('remote-template')")
        let localMounted = await evaluate("!!document.getElementById('local')")
        check(initial != nil && remoteSource == true && localMounted == false,
              "declared resource loads published template")
        check(initial?["initialized"]?["result"]?["protocolVersion"] == "2026-01-26",
              "standard SDK postMessage initialize receives response")
        guard initial != nil else { throw AgentArtifactRPCError(-32000, "initial iframe unavailable") }
        check(await wait { states.contains(.ready) && loaded == ["0123abcd"] },
              "ready page reports the actual loaded template hash exactly once")
        check(policies == [520], "release presentation reaches native host")
        for name in ["parentDOM", "parentNonce", "localStorage", "sessionStorage"] {
            check(initial?["isolation"]?[name] == "blocked", "opaque template cannot read \(name)")
        }
        check(initial?["cookieRead"] == "blocked" || (initial?["cookieBefore"] == "" && initial?["cookieAfter"] == ""),
              "opaque template cannot read origin cookies or persist cookie writes")
        check(initial?["firstHead"]?.stringValue?.contains("Content-Security-Policy") == true,
              "CSP precedes true head despite deceptive comment title and textarea")
        check(initial?["notifications"]?.arrayValue?.map { $0["method"]?.stringValue ?? "" } == [
            "ui/notifications/tool-input", "ui/notifications/tool-result", "tapnow/presentationState"],
              "opaque frame receives original input result presentation order")
        check(initial?["notifications"]?.arrayValue?.allSatisfy {
            $0["nonce"] == nil && $0["revision"] == nil && $0["clipslots_host"] == nil
        } == true, "standard template messages contain no native instance credentials")
        await send("fixture/native", ["tag": "direct"])
        check(await report("direct")?["directNative"] == "denied", "subframe cannot directly use native message handler")
        await send("fixture/draft", ["tag": "draft", "text": "保留草稿🙂"])
        _ = await report("draft")
        let nonce = await evaluate("window.__clipslotsNativeInstance")
        update(true)
        await send("fixture/probe", ["tag": "expanded"])
        let expanded = await report("expanded")
        let expandedNonce = await evaluate("window.__clipslotsNativeInstance")
        check(expanded?["draft"] == "保留草稿🙂" && expandedNonce == nonce && loaded.count == 1,
              "expanded page retains actual iframe draft instance and template fetch")
        await send("fixture/rpc", ["tag": "size", "method": "ui/notifications/size-changed", "arguments": ["height": 280], "id": "size-1"])
        let sized = await report("size")
        check(sized?["responses"]?["size"]?["error"] == nil && sizes == [280],
              "opaque size notification reaches native layout once")
        await send("fixture/rpc", ["tag": "set", "method": "tapnow/setWidgetState", "arguments": ["state": ["draft": "新状态🙂"]], "id": "state-1"])
        _ = await report("set")
        check(widgetState == ["draft": "新状态🙂"], "opaque state setter reaches current native owner")
        await send("fixture/rpc", ["tag": "tool", "method": "tools/call", "arguments": ["name": "fixture", "arguments": [:]], "id": "tool-1"])
        let tool = await report("tool")
        check(tool?["responses"]?["tool"]?["result"]?["structuredContent"] == ["value": "tool fixture"],
              "opaque tools call maps current native result")
        web.reload()
        check(await wait { loaded.count == 2 && states.last == .ready }, "real reload fetches and initializes new template generation")
        let reloaded = await report("initialized")
        let reloadedNonce = await evaluate("window.__clipslotsNativeInstance")
        check(reloadedNonce != nonce && reloaded?["notifications"]?.arrayValue?
            .first { $0["method"] == "ui/notifications/tool-result" }?["params"]?["_meta"]?["tapnow/widgetState"]
                == ["draft": "新状态🙂"], "reload rotates nonce and reads current persisted widget state")
        _ = await evaluate("""
            window.staleResult=null;
            window.webkit.messageHandlers.clipslots.postMessage({jsonrpc:'2.0',id:'old',method:'tools/call',
              params:{name:'fixture',arguments:{}},nonce:\((try nonce?.encodedText()) ?? "null"),revision:'1'})
              .then(x=>window.staleResult=x); null
            """)
        check(await wait { await evaluate("window.staleResult.error.code") == -32600 },
              "pre-reload native nonce cannot invoke replacement tools")
        update(enabled: false)
        check(await wait { loaded.count == 3 && states.last == .ready }, "permission revocation rotates and initializes page")
        await send("fixture/rpc", ["tag": "denied", "method": "tools/call", "arguments": ["name": "fixture", "arguments": [:]], "id": "tool-1"])
        let denied = await report("denied")
        check(denied?["responses"]?["denied"]?["error"]?["code"] == -32601 && operations.filter { $0 == "tools_call" }.count == 1,
              "revoked page cannot invoke native tools")
        states = []
        update(uri: "ui://tapnow/missing@v3")
        check(await wait { if case .error = states.last { return true }; return false },
              "actual missing HTTP template ends with explicit error")
        states = []
        update()
        check(await wait { loaded.count == 4 && states.last == .ready }, "same owner can explicitly retry after template failure")
        update(uri: "ui://tapnow/slow@v3")
        try? await Task.sleep(for: .milliseconds(50))
        let other = AgentArtifactPageIdentity(key: key, conversationID: UUID(), revision: 2)
        update(page: other)
        check(await wait { loaded.count == 5 && states.last == .ready }, "replacement owner loads current template")
        try? await Task.sleep(for: .milliseconds(350))
        check(loaded.count == 5 && states.last == .ready,
              "cancelled slow template cannot replace newer owner or emit late error")
        states = []
        update(uri: "ui://tapnow/blocked@v3")
        check(await wait { if case .error = states.last { return true }; return false },
              "actual iframe resource denial ends native page lifecycle")
        let sdkBase = config["sdkBaseURL"]!.stringValue!
        let sdkEndpoint = AgentArtifactPageResourceEndpoint(
            channelURL: URL(string: sdkBase + "/mcp-apps/channels/current.json"),
            proxyURL: URL(string: sdkBase + "/012345abcd/mcp-app-proxy.html")!, allowsLoopback: true)!
        states = []
        let loadedBeforeSDK = loaded.count
        coordinator.update(source: "LOCAL_CACHE", onState: { states.append($0) }, onLink: { _ in },
            identity: other, pageProjection: projection, presentationResourceURI: "ui://tapnow/previs@v3",
            pageResourceURI: "ui://tapnow/previs@v3", pageResourceLoader: loader, pageResourceEndpoint: sdkEndpoint,
            onTemplateLoaded: { loaded.append($0.hash) })
        check(await wait { loaded.count == loadedBeforeSDK + 1 && states.last == .ready },
              "frozen published previs SDK initializes through actual opaque iframe postMessage")
        let sdkFrames = await evaluate("window.fixtureFrames")
        check(sdkFrames?.arrayValue?.contains { $0["method"] == "ui/initialize" && $0["params"]?["appInfo"] != nil } == true
              && sdkFrames?.arrayValue?.contains { $0["method"] == "ui/notifications/initialized" } == true
              && loaded.last == config["sdkHash"]?.stringValue,
              "published SDK raw initialize initialized and loaded build identity are retained")
        let raw: JSONValue = ["states": .array(states.map { .string(String(describing: $0)) }),
            "initial": initial ?? .null, "expanded": expanded ?? .null, "reloaded": reloaded ?? .null,
            "tool": tool ?? .null, "denied": denied ?? .null, "publishedSDKFrames": sdkFrames ?? .null,
            "loaded": .array(loaded.map(JSONValue.string)), "operations": .array(operations.map(JSONValue.string))]
        try JSONEncoder().encode(raw).write(to: directory.appendingPathComponent("template-webkit.json"))
    } catch { failures.append("fixture error: \(error)") }
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "foregroundAccepted": false, "M06Accepted": false, "goalComplete": false]
}
#endif
