#if DEBUG
import AppKit
import WebKit
import ClipSlotsKit

/// Independent frame observer remains active after the native bridge reaches a terminal error.
/// Parser variants use the production remote loader, HTML compiler, content rules and coordinator.
@MainActor
func runArtifactHTMLParserRegression(directory: URL, config: JSONValue,
    makeDataStore: () -> WKWebsiteDataStore) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = [], records: [[String: Any]] = []
    func persist() {
        try? JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks,
            "failures": failures, "partial": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("parser-partial-report.json"), options: .atomic)
        try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("parser-webkit.json"), options: .atomic)
    }
    func check(_ condition: Bool, _ name: String) {
        (condition ? checks.append(name) : failures.append(name)); persist()
    }
    func evaluate(_ web: WKWebView, _ code: String) async -> JSONValue? {
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
    func wait(_ predicate: () async -> Bool, attempts: Int = 250) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    func object(_ json: JSONValue?) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(json ?? .null), options: [.fragmentsAllowed])
    }
    do {
        let base = config["baseURL"]!.stringValue!
        let endpoint = AgentArtifactPageResourceEndpoint(
            channelURL: URL(string: base + "/mcp-apps/channels/current.json"),
            proxyURL: URL(string: base + "/012345abcd/mcp-app-proxy.html")!, allowsLoopback: true)!
        let loader = AgentArtifactPageResourceLoader(allowsLoopback: true)
        let hosts = Set(config["hosts"]!.arrayValue!.compactMap(\.stringValue))
        let hash = config["certificateSHA256"]!.stringValue!
        let cases = config["parserCases"]?.arrayValue ?? []
        check(cases.count == 26 && Set(cases.compactMap { $0["label"]?.stringValue }).count == 26,
              "all 26 declared parser variants are distinct and retained")
        for variant in cases {
            let name = variant["name"]!.stringValue!, label = variant["label"]!.stringValue!
            let expected = variant["expected"]!.stringValue!, action = variant["action"]!.stringValue!
            let coordinator = AgentArtifactHTMLPreview.Coordinator()
            let webConfig = WKWebViewConfiguration()
            webConfig.websiteDataStore = makeDataStore()
            webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
            webConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
            webConfig.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "clipslots")
            webConfig.userContentController.addUserScript(WKUserScript(source: """
                window.parserInitial=null; window.parserFinal=null; window.parserFrames=[]; window.parserForeign=[];
                addEventListener('message',e=>{
                  if(e.source!==document.querySelector('iframe')?.contentWindow) {
                    if(e.data)window.parserForeign.push(e.data); return;
                  }
                  if(!e.data)return;window.parserFrames.push(e.data);
                  if(e.data.method==='fixture/parser-initial')window.parserInitial=e.data.params;
                  if(e.data.method==='fixture/parser-final')window.parserFinal=e.data.params;
                });
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: webConfig)
            let delegate = ArtifactFixtureTLSDelegate(coordinator: coordinator, hash: hash, hosts: hosts)
            web.navigationDelegate = delegate; web.uiDelegate = coordinator; coordinator.attach(web)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web
            defer {
                coordinator.detach(); web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
                web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
            }
            let key = try AgentArtifactKey(projectID: "fixture", canvasID: "fixture", path: name + ".html")
            let identity = AgentArtifactPageIdentity(key: key, conversationID: UUID(), revision: 1)
            let projection = try AgentArtifactPageData(revision: .init(messageSequence: 1, partIndex: 0),
                toolInput: [:], toolResult: ["summary": "parser"])
            var states: [AgentArtifactResourceState] = [], operations: [String] = [], loaded: [String] = []
            let started = ContinuousClock.now
            coordinator.update(source: "LOCAL_CACHE", onState: { states.append($0) }, onLink: { _ in },
                onRequest: { operation, _, _ in operations.append(operation); return [:] },
                identity: identity, pageProjection: projection, presentationResourceURI: "ui://tapnow/\(name)@v3",
                pageResourceURI: "ui://tapnow/\(name)@v3", pageResourceLoader: loader, pageResourceEndpoint: endpoint,
                onTemplateLoaded: { loaded.append($0.hash) })
            check(await wait { await evaluate(web, "document.querySelector('iframe')?.hasAttribute('srcdoc')") == true },
                  "\(label): actual declared source mounts")
            check(await evaluate(web, "document.querySelector('iframe')?.getAttribute('sandbox')") == "allow-scripts",
                  "\(label): only script permission is granted to opaque template")
            let initial: JSONValue?
            if variant["probeExpected"] == true {
                let observed = await wait { await evaluate(web, "window.parserInitial")?.objectValue != nil }
                check(observed, "\(label): reparsed document emits actual script report")
                initial = await evaluate(web, "window.parserInitial")
                check(initial?["firstHead"]?.stringValue?.contains("Content-Security-Policy") == true,
                      "\(label): enforcing meta remains first actual head element")
                check(["parentDOM", "topDOM", "parentNonce", "localStorage", "sessionStorage", "cookie"]
                        .allSatisfy { initial?["isolation"]?[$0] == "blocked" }
                      && initial?["directNative"] == "denied",
                      "\(label): parent top nonce storage cookies and direct native authority are denied")
                check(initial?["externalScript"] == false
                      && initial?["bodyText"]?.stringValue?.contains("preserved") == true,
                      "\(label): required body content survives and external script never executes")
            } else {
                initial = nil
            }
            if expected == "ready" {
                check(await wait { states.last == .ready && loaded == ["0123abcd"] },
                      "\(label): normal parser variant preserves SDK initialization")
                check(initial?["initialized"]?["result"]?["protocolVersion"] == "2026-01-26",
                      "\(label): actual opaque SDK receives current protocol response")
            } else {
                check(await wait({
                    if case .error = states.last { return true }; return false
                }, attempts: expected == "timeout" ? 900 : 250),
                      "\(label): unusable or resource-denied template has explicit terminal error")
                check(states.last != .ready, "\(label): failed template is never left ready")
            }
            if action != "none" {
                let message: JSONValue = ["jsonrpc": "2.0", "method": "fixture/parser-run",
                                          "params": ["action": .string(action)]]
                let literal = try AgentArtifactTemplateHTML.literal(message)
                _ = await evaluate(web, "document.querySelector('iframe').contentWindow.postMessage(\(literal),'*'); null")
                check(await wait { await evaluate(web, "window.parserFinal")?.objectValue != nil },
                      "\(label): observer retains outcomes after native lifecycle stops")
                let final = await evaluate(web, "window.parserFinal")
                if label == "svg-reparse" {
                    check(final?["mutation"] == true,
                          "\(label): actual reparsing executes permitted inline code without crossing sandbox")
                }
                if label == "noscript-reparse" {
                    check(final?["mutation"] == false,
                          "\(label): actual noscript markup stays inert before and after resource probe")
                }
                if label == "base-injection" {
                    check(final?["baseURI"] == "about:blank",
                          "\(label): enforcing base-uri rejects the injected target origin")
                }
                if label == "allowed-static-image" {
                    check(final?["images"]?.arrayValue?.contains {
                        $0["id"] == "allowed" && $0["width"] == 3 && $0["height"] == 2
                    } == true, "\(label): original declared static image really decodes after reparsing")
                }
                if action == "nested" {
                    let nested = final?["nested"]?.arrayValue?.first
                    check(nested?["ran"] == true && nested?["parentDOM"] == "blocked" && nested?["topDOM"] == "blocked"
                          && nested?["native"] == "denied" && nested?["sandbox"] == "blocked",
                          "\(label): nested srcdoc runs with inherited opaque origin and cannot remove sandbox")
                    check(await evaluate(web, "window.parserForeign.some(x=>x.id==='nested-forged')") == true,
                          "\(label): actual forged nested request reaches outer observer for rejection")
                    check(states.last == .ready, "\(label): rejected nested requests preserve current page lifecycle")
                } else {
                    check(final?["externalScript"] == false
                          && final?["violations"]?.arrayValue?.contains { $0["directive"] == "script-src-elem"
                                && $0["disposition"] == "enforce" } == true
                          && final?["violations"]?.arrayValue?.contains { $0["directive"] == "img-src"
                                && $0["disposition"] == "enforce" } == true,
                          "\(label): reparsed or weakened policy still enforces script and image origins")
                    check(await wait { if case .error = states.last { return true }; return false },
                          "\(label): actual resource violation stops native lifecycle")
                }
            } else {
                check(await evaluate(web, "window.parserInitial") == .null,
                      "\(label): disabled or unterminated template code never initializes")
            }
            check(operations == ["get_state"], "\(label): direct and forged requests cause no business operation")
            let elapsed = Double(started.duration(to: .now).components.seconds)
                + Double(started.duration(to: .now).components.attoseconds) / 1e18
            records.append(["name": name, "label": label, "expected": expected, "action": action,
                "initial": try object(initial), "final": try object(await evaluate(web, "window.parserFinal")),
                "frames": try object(await evaluate(web, "window.parserFrames")),
                "foreign": try object(await evaluate(web, "window.parserForeign")),
                "actualSrcdoc": try object(await evaluate(web, "document.querySelector('iframe').srcdoc")),
                "states": states.map { String(describing: $0) }, "loaded": loaded, "operations": operations,
                "elapsedSeconds": elapsed, "TLSChallenges": delegate.challenges])
            persist()
        }
    } catch { failures.append("parser fixture error: \(error)"); persist() }
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "foregroundAccepted": false, "M06Accepted": false, "goalComplete": false]
}
#endif
