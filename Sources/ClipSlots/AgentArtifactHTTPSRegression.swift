#if DEBUG
import AppKit
import WebKit
import Network
import Security
import CryptoKit
import ClipSlotsKit

/// Only a dedicated fixture WebView accepts its pinned synthetic certificate.
/// The production coordinator, system trust and production data store are unchanged.
@MainActor
final class ArtifactFixtureTLSDelegate: NSObject, WKNavigationDelegate {
    let coordinator: AgentArtifactHTMLPreview.Coordinator?
    let certificateHash: String
    let hosts: Set<String>
    var challenges: [[String: Any]] = []
    init(coordinator: AgentArtifactHTMLPreview.Coordinator?, hash: String, hosts: Set<String>) {
        self.coordinator = coordinator; certificateHash = hash; self.hosts = hosts
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            challenges.append(["host": space.host, "authenticationMethod": space.authenticationMethod,
                               "accepted": false, "reason": "no server trust"])
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Builds the chain for inspection; this result never changes system trust.
        _ = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            challenges.append(["host": space.host, "accepted": false, "reason": "no certificate chain"])
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        let accepted = hash == certificateHash && hosts.contains(space.host)
        challenges.append(["host": space.host, "certificateSHA256": hash, "accepted": accepted])
        completionHandler(accepted ? .useCredential : .cancelAuthenticationChallenge,
                          accepted ? URLCredential(trust: trust) : nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let coordinator { coordinator.webView(webView, decidePolicyFor: action, decisionHandler: decisionHandler) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let coordinator { coordinator.webView(webView, decidePolicyFor: response, decisionHandler: decisionHandler) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator?.webView(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        coordinator?.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        coordinator?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        coordinator?.webViewWebContentProcessDidTerminate(webView)
    }
}

@MainActor
func runArtifactHTTPSRegression(directory: URL) async -> [String: Any] {
    var checks: [String] = [], failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        (condition ? checks.append(name) : failures.append(name))
        try? JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks,
            "failures": failures, "partial": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("partial-report.json"), options: .atomic)
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
    func wait(_ predicate: () async -> Bool, attempts: Int = 300) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    do {
        guard #available(macOS 14, *) else { throw AgentArtifactRPCError.unsupported }
        let config = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: directory.appendingPathComponent("fixture-config.json")))
        let hosts = Set(config["hosts"]!.arrayValue!.compactMap(\.stringValue))
        let hash = config["certificateSHA256"]!.stringValue!
        guard let portNumber = config["proxyPort"]?.intValue, let port = UInt16(exactly: portNumber),
              let proxyPort = NWEndpoint.Port(rawValue: port) else { throw AgentArtifactRPCError.invalid }
        func dataStore() -> WKWebsiteDataStore {
            let store = WKWebsiteDataStore.nonPersistent()
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: proxyPort))
            proxy.allowFailover = false
            store.proxyConfigurations = [proxy]
            return store
        }
        let controlConfig = WKWebViewConfiguration()
        controlConfig.websiteDataStore = dataStore()
        let control = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: controlConfig)
        let controlWindow = NSWindow(contentRect: control.frame, styleMask: [.titled], backing: .buffered, defer: false)
        controlWindow.isReleasedWhenClosed = false; controlWindow.contentView = control
        defer { control.stopLoading(); control.navigationDelegate = nil; controlWindow.close() }
        let controlDelegate = ArtifactFixtureTLSDelegate(coordinator: nil, hash: hash, hosts: hosts)
        control.navigationDelegate = controlDelegate
        let controlHTML = try String(contentsOf: directory.appendingPathComponent("control.html"), encoding: .utf8)
        control.loadHTMLString(controlHTML, baseURL: nil)
        let controlReady = await wait({ await evaluate(control, "window.controlResults")?.objectValue != nil }, attempts: 1000)
        let controlResults = await evaluate(control, "window.controlResults")
        let controlRaw: [String: Any] = [
            "control": try JSONSerialization.jsonObject(with: JSONEncoder().encode(controlResults ?? .null), options: [.fragmentsAllowed]),
            "challenges": controlDelegate.challenges]
        try JSONSerialization.data(withJSONObject: controlRaw, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("control-webkit.json"))
        check(controlReady, "HTTPS proxy positive control completes actual WebKit requests")
        for name in ["image", "denied-host", "suffix-host", "wrong-port", "audio", "video", "script", "style"] {
            check(controlResults?[name]?["outcome"] == "loaded", "fixture endpoint is independently reachable for \(name)")
        }
        check(controlResults?["image"]?["width"] == 3 && controlResults?["image"]?["height"] == 2,
              "HTTPS image control decodes synthetic pixels")
        check(controlResults?["video"]?["width"] == 64 && controlResults?["video"]?["height"] == 36,
              "HTTPS video control decodes original 16:9 media dimensions")
        control.stopLoading(); control.navigationDelegate = nil
        guard controlReady else { throw AgentArtifactRPCError(-32000, "fixture TLS control unavailable") }
        if config["parserCases"]?.arrayValue?.isEmpty == false {
            let parserReport = await runArtifactHTMLParserRegression(directory: directory, config: config,
                makeDataStore: dataStore)
            checks.append(contentsOf: parserReport["checks"] as? [String] ?? [])
            failures.append(contentsOf: parserReport["failures"] as? [String] ?? ["parser report missing"])
            return ["passed": checks.count, "checks": checks, "failures": failures,
                    "foregroundAccepted": false, "M06Accepted": false, "goalComplete": false]
        }
        let coordinator = AgentArtifactHTMLPreview.Coordinator()
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = dataStore()
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
        webConfig.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "clipslots")
        webConfig.userContentController.addUserScript(WKUserScript(source: """
            window.matrixFrames=[]; window.matrixInitial=null; window.matrixResult=null;
            addEventListener('message',e=>{
              if(e.source!==document.querySelector('iframe')?.contentWindow || !e.data) return;
              window.matrixFrames.push(e.data);
              if(e.data.method==='fixture/report'&&e.data.params.tag==='initialized') window.matrixInitial=e.data.params;
              if(e.data.method==='fixture/resource-matrix') window.matrixResult=e.data.params;
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: webConfig)
        let delegate = ArtifactFixtureTLSDelegate(coordinator: coordinator, hash: hash, hosts: hosts)
        web.navigationDelegate = delegate; web.uiDelegate = coordinator
        coordinator.attach(web)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web
        defer {
            coordinator.detach(); web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
            web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
        }
        let key = try AgentArtifactKey(projectID: "fixture", canvasID: "fixture", path: "matrix.html")
        let identity = AgentArtifactPageIdentity(key: key, conversationID: UUID(), revision: 1)
        let projection = try AgentArtifactPageData(revision: .init(messageSequence: 1, partIndex: 0),
            toolInput: [:], toolResult: ["summary": "HTTPS matrix"])
        let base = config["baseURL"]!.stringValue!
        let endpoint = AgentArtifactPageResourceEndpoint(
            channelURL: URL(string: base + "/mcp-apps/channels/current.json"),
            proxyURL: URL(string: base + "/012345abcd/mcp-app-proxy.html")!, allowsLoopback: true)!
        var states: [AgentArtifactResourceState] = [], loaded: [String] = [], operations: [String] = []
        coordinator.update(source: "LOCAL_CACHE", onState: { states.append($0) }, onLink: { _ in },
            onRequest: { operation, _, _ in operations.append(operation); return [:] },
            identity: identity, pageProjection: projection, presentationExpanded: false,
            presentationResourceURI: "ui://tapnow/matrix@v3", pageResourceURI: "ui://tapnow/matrix@v3",
            pageResourceLoader: .init(allowsLoopback: true), pageResourceEndpoint: endpoint,
            onTemplateLoaded: { loaded.append($0.hash) })
        check(await wait {
            guard states.last == .ready && loaded == ["0123abcd"] else { return false }
            return await evaluate(web, "window.matrixInitial")?.objectValue != nil
        },
              "actual declared HTTPS template initializes before resource matrix")
        let initial = await evaluate(web, "window.matrixInitial")
        check(initial?["firstHead"]?.stringValue?.contains("img-src data: blob: https://files.tapnow.art") == true
              && initial?["firstHead"]?.stringValue?.contains("media-src blob: https://files.tapnow.media") == true,
              "actual enforcing policy preserves separate release image and media origins")
        let assets = config["assets"]!
        let message: JSONValue = ["jsonrpc": "2.0", "method": "fixture/resources", "params": assets]
        let text = try AgentArtifactTemplateHTML.literal(message)
        _ = await evaluate(web, "document.querySelector('iframe').contentWindow.postMessage(\(text),'*'); null")
        check(await wait({ await evaluate(web, "window.matrixResult")?.objectValue != nil }, attempts: 2200),
              "actual WebKit full resource matrix completes with raw reports")
        let matrix = await evaluate(web, "window.matrixResult")
        let results = matrix?["results"]?.arrayValue ?? []
        check(results.count == 44 && Set(results.compactMap { $0["name"]?.stringValue }).count == 44,
              "all 44 distinct resource scenarios have actual outcomes")
        for result in results {
            let name = result["name"]?.stringValue ?? "unnamed"
            let outcome = result["outcome"]?.stringValue ?? ""
            let violations = result["violations"]?.arrayValue ?? []
            switch result["expected"]?.stringValue {
            case "allowed":
                let expected = name == "inline-script" ? "executed" : name == "inline-style" ? "rgb(1, 2, 3)" : "loaded"
                check(outcome == expected && violations.isEmpty, "CSP permits actual \(name)")
            case "blocked":
                let blockedFrameLoadEvent = ["https-frame", "data-frame", "blob-frame"].contains(name)
                check(!violations.isEmpty && (!["loaded", "unexpected-response", "unexpected-open"].contains(outcome) || blockedFrameLoadEvent),
                      "CSP blocks actual \(name) with enforcing violation")
            case "inherited-sandbox":
                check(result["nested"]?["ran"] == true && result["nested"]?["parentDOM"] == "blocked"
                      && result["nested"]?["topDOM"] == "blocked" && result["nested"]?["native"] == "denied",
                      "nested srcdoc executes with inherited opaque sandbox and no native authority")
            case "host-blocked":
                check(outcome == "error", "WebKit or native policy denies actual \(name); no CSP attribution")
            case "sandbox-blocked":
                check(result["location"] == "about:srcdoc", "opaque frame form cannot navigate or submit")
            case "resource-error":
                check(outcome == "error" && violations.isEmpty, "allowed origin actual HTTP error remains explicit")
            default: check(false, "unclassified resource scenario \(name)")
            }
        }
        for name in ["data-image", "blob-image", "https-image"] {
            let result = results.first { $0["name"] == .string(name) }
            check(result?["width"] == 3 && result?["height"] == 2, "actual opaque \(name) decodes synthetic pixels")
        }
        for name in ["https-video", "blob-video"] {
            let result = results.first { $0["name"] == .string(name) }
            check(result?["width"] == 64 && result?["height"] == 36
                  && (result?["readyState"]?.intValue ?? 0) >= 2 && result?["duration"] == 0.6,
                  "actual opaque \(name) loads frame data with original 16:9 dimensions")
        }
        for name in ["https-audio", "blob-audio"] {
            let result = results.first { $0["name"] == .string(name) }
            check((result?["readyState"]?.intValue ?? 0) >= 2 && result?["duration"] == 0.5,
                  "actual opaque \(name) loads audio data with expected duration")
        }
        check(matrix?["externalScriptExecuted"] == false
              && matrix?["nestedReports"]?.arrayValue?.count == 1
              && matrix?["style"] == "rgb(1, 2, 3)", "denied scripts remote frames and external styles never execute")
        check(states.contains { if case .error = $0 { return true }; return false } && states.last != .ready,
              "actual enforcing violation closes native page lifecycle")
        check(operations == ["get_state"], "resource-denied page performs no native business operation")
        check(!delegate.challenges.isEmpty && delegate.challenges.allSatisfy { $0["accepted"] as? Bool == true },
              "fixture TLS only uses pinned certificate and explicit host set")
        let raw: [String: Any] = [
            "control": try JSONSerialization.jsonObject(with: JSONEncoder().encode(controlResults ?? .null), options: [.fragmentsAllowed]),
            "initial": try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial ?? .null), options: [.fragmentsAllowed]),
            "matrix": try JSONSerialization.jsonObject(with: JSONEncoder().encode(matrix ?? .null), options: [.fragmentsAllowed]),
            "states": states.map { String(describing: $0) }, "loaded": loaded, "operations": operations,
            "TLSChallenges": delegate.challenges, "controlTLSChallenges": controlDelegate.challenges,
            "proxyFailover": false, "productionDelegateModified": false, "systemTrustModified": false]
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("https-webkit.json"))
    } catch { failures.append("fixture error: \(error)") }
    return ["passed": checks.count, "checks": checks, "failures": failures,
            "foregroundAccepted": false, "M06Accepted": false, "goalComplete": false]
}
#endif
