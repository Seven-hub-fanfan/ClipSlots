import SwiftUI
import WebKit
import ClipSlotsKit

/// Ephemeral HTML execution with an explicit native action allowlist and no network access.
struct AgentArtifactHTMLPreview: NSViewRepresentable {
    let source: String
    let onState: (AgentArtifactResourceState) -> Void
    let onLink: (URL) -> Void
    var actions: [AgentArtifactAppToolAction] = []
    var onTool: (AgentArtifactAppToolAction) -> Void = { _ in }
    var onRequest: ((String, String, JSONValue) async throws -> JSONValue)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "clipslots")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(source: source, onState: onState, onLink: onLink, actions: actions, onTool: onTool,
                                   onRequest: onRequest)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        private weak var view: WKWebView?
        private var source: String?
        private var loadedSource: String?
        private var currentNavigation: WKNavigation?
        private var rulesReady = false
        private var ruleError: String?
        private var generation = UUID()
        private var onState: (AgentArtifactResourceState) -> Void = { _ in }
        private var onLink: (URL) -> Void = { _ in }
        private var actions: [AgentArtifactAppToolAction] = []
        private var onTool: (AgentArtifactAppToolAction) -> Void = { _ in }
        private var calls: [String: String] = [:]
        private var requests: [String: (String, Task<JSONValue, Error>)] = [:]
        private var onRequest: ((String, String, JSONValue) async throws -> JSONValue)?

        func attach(_ view: WKWebView) {
            self.view = view
            // CSP handles all schemes. This additionally blocks network and filesystem subresources.
            let rules = #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "clipslots.artifact.no-external-resources.v1", encodedContentRuleList: rules
            ) { [weak self] list, error in
                DispatchQueue.main.async {
                    guard let self, let view = self.view else { return }
                    if let list {
                        view.configuration.userContentController.add(list)
                        self.rulesReady = true
                        self.loadIfNeeded()
                    } else {
                        #if DEBUG
                        NSLog("[ArtifactPreview] rule initialization failed: %@", error?.localizedDescription ?? "unknown")
                        #endif
                        self.ruleError = "预览初始化失败，可切换源码查看。"
                        self.emit(.error(self.ruleError ?? "预览不可用。"))
                    }
                }
            }
        }

        func update(source: String, onState: @escaping (AgentArtifactResourceState) -> Void, onLink: @escaping (URL) -> Void,
                    actions: [AgentArtifactAppToolAction] = [], onTool: @escaping (AgentArtifactAppToolAction) -> Void = { _ in },
                    onRequest: ((String, String, JSONValue) async throws -> JSONValue)? = nil) {
            self.onState = onState; self.onLink = onLink
            self.actions = actions; self.onTool = onTool
            self.onRequest = onRequest
            if self.source != source {
                self.source = source; generation = UUID()
                requests.values.forEach { $0.1.cancel() }; requests = [:]
                calls = [:]
                view?.stopLoading(); currentNavigation = nil
                emit(.loading)
            }
            if let ruleError { emit(.error(ruleError)) }
            else { loadIfNeeded() }
        }

        private func loadIfNeeded() {
            guard rulesReady, let source, loadedSource != source, let view else { return }
            guard source.utf8.count <= 8 * 1024 * 1024 else {
                emit(.error("HTML 过大，请切换源码查看。"))
                return
            }
            loadedSource = source
            let api = """
            <script>
            window.clipslots = Object.freeze({
              request: function(operation, name, arguments, callID) {
                return window.webkit.messageHandlers.clipslots.postMessage({
                  operation: operation, name: name, arguments: arguments,
                  call_id: callID || crypto.randomUUID(), instance: '\(generation.uuidString)'
                });
              },
              getState: function() { return this.request('get_state', '', {}); },
              setState: function(state) { return this.request('set_state', '', state); },
              updateModelContext: function(context) { return this.request('model_context', '', context); },
              tools: function() { return this.request('tools_list', '', {}); },
              executeTool: function(name, args, callID) { return this.request('tools_call', name, args, callID); },
              callTool: function(actionID, callID) {
                return window.webkit.messageHandlers.clipslots.postMessage({
                  action_id: actionID, call_id: callID || crypto.randomUUID(),
                  instance: '\(generation.uuidString)'
                });
              }
            });
            </script>
            """
            currentNavigation = view.loadHTMLString(AgentArtifactPreviewPolicy.sandboxedHTML(api + source, allowsScripts: true), baseURL: nil)
        }

        private func emit(_ state: AgentArtifactResourceState) {
            let ticket = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view != nil, self.generation == ticket else { return }
                self.onState(state)
            }
        }

        func detach() {
            generation = UUID(); view = nil; onState = { _ in }; onLink = { _ in }
            requests.values.forEach { $0.1.cancel() }; requests = [:]; onRequest = nil
            actions = []; calls = [:]; onTool = { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            if let body = message.body as? [String: Any], body["operation"] != nil {
                dispatchRequest(message, body: body, replyHandler: replyHandler)
                return
            }
            guard view != nil, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.absoluteString == "about:blank",
                  let body = message.body as? [String: Any], Set(body.keys) == ["action_id", "call_id", "instance"],
                  body["instance"] as? String == generation.uuidString,
                  let actionID = body["action_id"] as? String, let callID = body["call_id"] as? String,
                  !callID.isEmpty, callID.utf8.count <= 128,
                  let action = actions.first(where: { $0.id == actionID }) else {
                replyHandler(nil, "TOOL_NOT_ENABLED"); return
            }
            if let prior = calls[callID] {
                if prior == actionID { replyHandler(["status": "already_dispatched"], nil) }
                else { replyHandler(nil, "CALL_ID_CONFLICT") }
                return
            }
            guard calls.count < 100 else { replyHandler(nil, "CALL_LIMIT"); return }
            calls[callID] = actionID
            onTool(action)
            replyHandler(["status": "dispatched", "action_id": actionID], nil)
        }

        private func dispatchRequest(_ message: WKScriptMessage, body: [String: Any],
                                     replyHandler: @escaping (Any?, String?) -> Void) {
            guard view != nil, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.absoluteString == "about:blank",
                  Set(body.keys) == ["operation", "name", "arguments", "call_id", "instance"],
                  body["instance"] as? String == generation.uuidString,
                  let operation = body["operation"] as? String,
                  ["get_state", "set_state", "model_context", "tools_list", "tools_call"].contains(operation),
                  let name = body["name"] as? String, name.utf8.count <= 128,
                  let callID = body["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 128,
                  let handler = onRequest else { replyHandler(nil, "REQUEST_NOT_ENABLED"); return }
            do {
                let data = try JSONSerialization.data(withJSONObject: body["arguments"] as Any, options: [.fragmentsAllowed])
                guard data.count <= 64 * 1024 else { replyHandler(nil, "PAYLOAD_LIMIT"); return }
                let arguments = try JSONDecoder().decode(JSONValue.self, from: data)
                let signature = operation + "\u{0}" + name + "\u{0}" + (try arguments.encodedText())
                let task: Task<JSONValue, Error>
                if let prior = requests[callID] {
                    guard prior.0 == signature else { replyHandler(nil, "CALL_ID_CONFLICT"); return }
                    task = prior.1
                } else {
                    guard requests.count + calls.count < 100, calls[callID] == nil else {
                        replyHandler(nil, "CALL_LIMIT"); return
                    }
                    task = Task { try Task.checkCancellation(); return try await handler(operation, name, arguments) }
                    requests[callID] = (signature, task)
                }
                let ticket = generation
                Task { @MainActor [weak self] in
                    do {
                        let result = try await task.value
                        guard let self, self.view != nil, self.generation == ticket, !task.isCancelled else {
                            replyHandler(nil, "PAGE_CLOSED"); return
                        }
                        let bytes = try JSONEncoder().encode(result)
                        guard bytes.count <= 64 * 1024 else { replyHandler(nil, "RESULT_LIMIT"); return }
                        replyHandler(try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]), nil)
                    } catch { replyHandler(nil, "REQUEST_FAILED: " + error.localizedDescription) }
                }
            } catch { replyHandler(nil, "INVALID_ARGUMENTS"); }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only WebKit's initial in-memory document load is allowed.
            if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let url = action.request.url,
               let safe = AgentArtifactPreviewPolicy.externalURL(url) {
                onLink(safe)
            } else {
                emit(.error("此预览不支持跳转或提交表单。"))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.response.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, navigation === currentNavigation else { return }
            emit(.ready)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard let navigation, navigation === currentNavigation else { return }
            emit(.error("HTML 预览失败：\(error.localizedDescription)"))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let navigation, navigation === currentNavigation else { return }
            emit(.error("HTML 预览失败：\(error.localizedDescription)"))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            emit(.error("预览已停止，可重新打开或查看源码。"))
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, let safe = AgentArtifactPreviewPolicy.externalURL(url) { onLink(safe) }
            return nil
        }
    }
}
