import SwiftUI
import WebKit
import ClipSlotsKit

/// Shares only the bounded release/channel resolver caches. Template HTML remains per page.
enum AgentArtifactPageResources {
    static let loader = AgentArtifactPageResourceLoader()
}

/// Ephemeral execution: local HTML has no network; published templates use declared image/media origins.
struct AgentArtifactHTMLPreview: NSViewRepresentable {
    let source: String
    let onState: (AgentArtifactResourceState) -> Void
    let onLink: (URL) -> Void
    var actions: [AgentArtifactAppToolAction] = []
    var onTool: (AgentArtifactAppToolAction) -> Void = { _ in }
    var onRequest: ((String, String, JSONValue) async throws -> JSONValue)?
    var identity: AgentArtifactPageIdentity?
    var pageProjection: AgentArtifactPageData?
    var initialWidgetState: JSONValue?
    var onReplyEvents: ((String, String) throws -> AgentArtifactReplyObservation)?
    var conversationRunActive: Bool?
    var presentationExpanded: Bool?
    var onSizeChanged: (Double) -> Void = { _ in }
    var onCollapse: () -> Void = {}
    var presentationResourceURI: String?
    var pageResourceURI: String?
    var pageResourceLoader = AgentArtifactPageResources.loader
    var pageResourceEndpoint: AgentArtifactPageResourceEndpoint = .production
    var onTemplate: (AgentArtifactPageTemplate) -> Void = { _ in }
    var onTemplateLoaded: (AgentArtifactPageTemplate) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "clipslots")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(source: source, onState: onState, onLink: onLink, actions: actions, onTool: onTool,
                                   onRequest: onRequest, identity: identity, pageProjection: pageProjection,
                                   initialWidgetState: initialWidgetState, onReplyEvents: onReplyEvents,
                                   conversationRunActive: conversationRunActive,
                                   presentationExpanded: presentationExpanded, onSizeChanged: onSizeChanged,
                                   onCollapse: onCollapse, presentationResourceURI: presentationResourceURI,
                                   pageResourceURI: pageResourceURI, pageResourceLoader: pageResourceLoader,
                                   pageResourceEndpoint: pageResourceEndpoint, onTemplate: onTemplate,
                                   onTemplateLoaded: onTemplateLoaded)
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
        private var baseRules: WKContentRuleList?
        private var resourceTask: Task<Void, Never>?
        private var remoteTemplate: AgentArtifactPageTemplate?
        private var templateLoaded = false
        private var pageResourceURI: String?
        private var pageResourceLoader = AgentArtifactPageResources.loader
        private var pageResourceEndpoint: AgentArtifactPageResourceEndpoint = .production
        private var onTemplate: (AgentArtifactPageTemplate) -> Void = { _ in }
        private var onTemplateLoaded: (AgentArtifactPageTemplate) -> Void = { _ in }
        private var generation = UUID()
        private var identity: AgentArtifactPageIdentity?
        private var revision: String { String(identity?.revision ?? 0) }
        private var rpcInitializing = false
        private var rpcReady = false
        private var resourceFailed = false
        private var initializationTimer: Task<Void, Never>?
        private var hostContext: JSONValue = [:]
        private var pageProjection: AgentArtifactPageData?
        private var initialWidgetState: JSONValue?
        private var onState: (AgentArtifactResourceState) -> Void = { _ in }
        private var onLink: (URL) -> Void = { _ in }
        private var actions: [AgentArtifactAppToolAction] = []
        private var onTool: (AgentArtifactAppToolAction) -> Void = { _ in }
        private var calls: [String: String] = [:]
        private var requests: [String: (String, Task<JSONValue, Error>)] = [:]
        private var onRequest: ((String, String, JSONValue) async throws -> JSONValue)?
        private var onReplyEvents: ((String, String) throws -> AgentArtifactReplyObservation)?
        private var replyObservers: [String: (String, Task<Void, Never>)] = [:]
        private var conversationRunActive: Bool?
        private var lastConversationRunActive: Bool?
        private var presentationExpanded: Bool?
        private var lastPresentationExpanded: Bool?
        private var onSizeChanged: (Double) -> Void = { _ in }
        private var onCollapse: () -> Void = {}
        private var presentationResourceURI: String?

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
                        self.baseRules = list
                        view.configuration.userContentController.add(list)
                        self.rulesReady = true
                        self.loadIfNeeded()
                    } else {
                        #if DEBUG
            NSLog("[ArtifactPreview] rule initialization failed")
                        #endif
                        self.ruleError = "预览初始化失败，可切换源码查看。"
                        self.emit(.error(self.ruleError ?? "预览不可用。"))
                    }
                }
            }
        }

        func update(source: String, onState: @escaping (AgentArtifactResourceState) -> Void, onLink: @escaping (URL) -> Void,
                    actions: [AgentArtifactAppToolAction] = [], onTool: @escaping (AgentArtifactAppToolAction) -> Void = { _ in },
                    onRequest: ((String, String, JSONValue) async throws -> JSONValue)? = nil,
                    identity: AgentArtifactPageIdentity? = nil, pageProjection: AgentArtifactPageData? = nil,
                    initialWidgetState: JSONValue? = nil,
                    onReplyEvents: ((String, String) throws -> AgentArtifactReplyObservation)? = nil,
                    conversationRunActive: Bool? = nil,
                    presentationExpanded: Bool? = nil, onSizeChanged: @escaping (Double) -> Void = { _ in },
                    onCollapse: @escaping () -> Void = {}, presentationResourceURI: String? = nil,
                    pageResourceURI: String? = nil,
                    pageResourceLoader: AgentArtifactPageResourceLoader = AgentArtifactPageResources.loader,
                    pageResourceEndpoint: AgentArtifactPageResourceEndpoint = .production,
                    onTemplate: @escaping (AgentArtifactPageTemplate) -> Void = { _ in },
                    onTemplateLoaded: @escaping (AgentArtifactPageTemplate) -> Void = { _ in }) {
            let permissionsChanged = (self.onRequest == nil) != (onRequest == nil) || self.actions != actions
                || (self.onReplyEvents == nil) != (onReplyEvents == nil)
                || self.presentationResourceURI != presentationResourceURI
                || self.pageResourceURI != pageResourceURI || self.pageResourceEndpoint != pageResourceEndpoint
            self.onState = onState; self.onLink = onLink
            self.actions = actions; self.onTool = onTool
            self.onRequest = onRequest
            self.onReplyEvents = onReplyEvents
            self.onSizeChanged = onSizeChanged; self.onCollapse = onCollapse
            self.presentationResourceURI = presentationResourceURI
            self.pageResourceURI = pageResourceURI; self.pageResourceLoader = pageResourceLoader
            self.pageResourceEndpoint = pageResourceEndpoint
            self.onTemplate = onTemplate; self.onTemplateLoaded = onTemplateLoaded
            if self.source != source || self.identity != identity || permissionsChanged {
                invalidate()
                self.source = source; self.identity = identity; loadedSource = nil
                view?.stopLoading(); currentNavigation = nil
                emit(.loading)
            }
            if let pageProjection {
                do {
                    try pageProjection.validate()
                    if self.pageProjection.map({ pageProjection.revision > $0.revision }) ?? true {
                        self.pageProjection = pageProjection
                        if rpcReady, !resourceFailed {
                            notify("tapnow/updateData", params: pageProjection.updateParams)
                        }
                    }
                } catch { failResource("页面工具数据无效或过大，可查看源码。") }
            }
            // A remote template reads fresh persisted state within its initialization deadline.
            // SwiftUI presentation updates must not replace it with the local preview's cache.
            if pageResourceURI == nil { self.initialWidgetState = initialWidgetState }
            self.conversationRunActive = conversationRunActive
            self.presentationExpanded = presentationExpanded
            if let ruleError { emit(.error(ruleError)) }
            else { loadIfNeeded() }
            updateHostContext()
            notifyConversationState()
            notifyPresentationState()
        }

        private func loadIfNeeded() {
            guard rulesReady, !resourceFailed, let source, loadedSource != source, let view else { return }
            if let pageResourceURI {
                loadTemplate(resourceURI: pageResourceURI)
                return
            }
            guard source.utf8.count <= 8 * 1024 * 1024 else {
                failResource("HTML 过大，请切换源码查看。")
                return
            }
            loadedSource = source
            if pageProjection != nil { startInitializationTimer() }
            let resourceText = (try? resourceDescription.encodedText()) ?? "{}"
            let api = """
            <script>
            (() => {
            const nonce = '\(generation.uuidString)', revision = '\(revision)';
            const bridge = window.webkit.messageHandlers.clipslots;
            let initialized = false, resourceStopped = false, retries = 0, sequence = 0;
            Object.defineProperty(window, '__clipslotsNativeInstance', {value:nonce});
            // An in-memory about:blank document may not provide secure-context randomUUID.
            // Native instance nonce plus monotonic sequence supplies a unique local call identity.
            const callID = () => nonce + ':' + (++sequence);
            const post = message => bridge.postMessage({...message, nonce, revision});
            const notify = message => window.postMessage({...message, nonce, revision, clipslots_host: true}, '*');
            const resourceReady = () => {
              if (!initialized && !resourceStopped) notify({jsonrpc:'2.0', method:'ui/notifications/sandbox-resource-ready',
                params:{nonce, resource:\(resourceText),
                  csp:{connectDomains:[],resourceDomains:[]}}});
            };
            window.addEventListener('message', event => {
              const message = event.data;
              if (event.source === window && message && message.clipslots_host &&
                  message.nonce === nonce && message.method === 'ui/notifications/sandbox-resource-error')
                resourceStopped = true;
              if (event.source !== window || !message || message.clipslots_host ||
                  message.jsonrpc !== '2.0' || typeof message.method !== 'string') return;
              // Preserve caller identity: do not repair stale nonce or revision.
              bridge.postMessage({...message, revision:message.revision === undefined ? revision : message.revision}).then(response => {
                if (response) notify(response);
                if (message.method === 'ui/notifications/initialized' && response && !response.error)
                  initialized = true;
              }).catch(() => {});
            });
            window.clipslots = Object.freeze({
              request: function(operation, name, arguments, callID) {
                return bridge.postMessage({
                  operation: operation, name: name, arguments: arguments,
                  call_id: callID || nonce + ':' + (++sequence), instance: nonce, revision
                });
              },
              rpc: function(method, params, id) {
                return post({jsonrpc:'2.0',method,params:params === undefined ? {} : params,
                  id:id === undefined ? callID() : id});
              },
              initialize: async function() {
                const response = await this.rpc('ui/initialize', {protocolVersion:'2026-01-26'});
                if (response.error) return response;
                const ready = await post({jsonrpc:'2.0',method:'ui/notifications/initialized',params:{}});
                if (!ready.error) initialized = true;
                return response;
              },
              getState: function() { return this.request('get_state', '', {}); },
              setState: function(state) { return this.request('set_state', '', state); },
              updateModelContext: function(context) { return this.request('model_context', '', context); },
              tools: function() { return this.request('tools_list', '', {}); },
              executeTool: function(name, args, callID) { return this.request('tools_call', name, args, callID); },
              callTool: function(actionID, callID) {
                return bridge.postMessage({
                  action_id: actionID, call_id: callID || nonce + ':' + (++sequence),
                  instance: nonce, revision
                });
              }
            });
            window.addEventListener('securitypolicyviolation', event => {
              if (event.disposition === 'enforce')
                bridge.postMessage({resource_error:true,instance:nonce,revision}).catch(() => {});
            });
            window.addEventListener('error', event => {
              if (event.target && event.target !== window)
                bridge.postMessage({resource_error:true,instance:nonce,revision}).catch(() => {});
            }, true);
            window.addEventListener('DOMContentLoaded', resourceReady, {once:true});
            const timer = setInterval(() => {
              if (initialized || resourceStopped || ++retries >= 20) clearInterval(timer);
              else resourceReady();
            }, 800);
            window.addEventListener('pagehide', () => clearInterval(timer), {once:true});
            window.addEventListener('keydown', event => {
              const editable = event.composedPath().some(node => node instanceof Element &&
                (node.matches('input,textarea,select') || node.isContentEditable ||
                 node.getAttribute('role') === 'textbox'));
              if (!event.isTrusted || event.defaultPrevented || editable || event.isComposing ||
                  event.keyCode === 229 || event.ctrlKey || event.metaKey || event.altKey ||
                  (event.key === 'Enter' && event.repeat) ||
                  !['Escape','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Enter',' '].includes(event.key)) return;
              // Native state determines whether the current page is ready and expanded.
              if (window.__clipslotsPresentationExpanded !== true ||
                  (event.key !== 'Escape' && window.__clipslotsPresentationShortcuts !== true)) return;
              event.preventDefault();
              bridge.postMessage({presentation_key:event.key,instance:nonce,revision}).catch(() => {});
            });
            })();
            </script>
            """
            currentNavigation = view.loadHTMLString(AgentArtifactPreviewPolicy.sandboxedHTML(api + source, allowsScripts: true), baseURL: nil)
        }

        private func loadTemplate(resourceURI: String) {
            guard resourceTask == nil, let source else { return }
            let ticket = generation, loader = pageResourceLoader, endpoint = pageResourceEndpoint
            let stateReader = onRequest
            startInitializationTimer()
            resourceTask = Task { @MainActor [weak self] in
                do {
                    let template = try await loader.load(resourceURI: resourceURI, endpoint: endpoint)
                    let state: JSONValue?
                    if let stateReader {
                        state = try await stateReader("get_state", "", [:])
                        guard let state, state.objectValue != nil,
                              try state.encodedText().utf8.count <= 64 * 1024 else {
                            throw AgentArtifactRPCError.invalid
                        }
                    } else { state = nil }
                    try Task.checkCancellation()
                    guard let self, let view = self.view, self.generation == ticket, !self.resourceFailed else { return }
                    self.remoteTemplate = template
                    if stateReader != nil { self.initialWidgetState = state }
                    let rules = try AgentArtifactTemplateHTML.contentRules(csp: template.csp)
                    let document = try AgentArtifactTemplateHTML.document(template: template, nonce: ticket, revision: self.revision)
                    WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: "clipslots.artifact.template.\(ticket.uuidString)", encodedContentRuleList: rules
                    ) { [weak self] list, _ in
                        WKContentRuleListStore.default().removeContentRuleList(
                            forIdentifier: "clipslots.artifact.template.\(ticket.uuidString)", completionHandler: { _ in })
                        DispatchQueue.main.async {
                            guard let self, self.generation == ticket, !self.resourceFailed, self.view === view else { return }
                            guard let list else {
                                self.failResource("页面资源策略初始化失败，可重新加载预览。"); return
                            }
                            view.configuration.userContentController.removeAllContentRuleLists()
                            view.configuration.userContentController.add(list)
                            self.loadedSource = source
                            self.resourceTask = nil
                            self.onTemplate(template)
                            self.currentNavigation = view.loadHTMLString(document, baseURL: nil)
                        }
                    }
                } catch {
                    guard let self, self.generation == ticket, !Task.isCancelled else { return }
                    self.resourceTask = nil
                    self.failResource("页面正文加载失败，可重新加载预览或查看源码。")
                }
            }
        }

        private func emit(_ state: AgentArtifactResourceState) {
            let ticket = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view != nil, self.generation == ticket else { return }
                self.onState(state)
            }
        }

        func detach() {
            invalidate(); view = nil; onState = { _ in }; onLink = { _ in }
            onRequest = nil
            actions = []; calls = [:]; onTool = { _ in }
            onSizeChanged = { _ in }; onCollapse = {}
            onTemplate = { _ in }; onTemplateLoaded = { _ in }
        }

        private func invalidate() {
            generation = UUID()
            resourceTask?.cancel(); resourceTask = nil; remoteTemplate = nil; templateLoaded = false
            if let baseRules, let controller = view?.configuration.userContentController {
                controller.removeAllContentRuleLists(); controller.add(baseRules)
            }
            requests.values.forEach { $0.1.cancel() }; requests = [:]; calls = [:]
            replyObservers.values.forEach { $0.1.cancel() }; replyObservers = [:]
            initializationTimer?.cancel(); initializationTimer = nil
            rpcInitializing = false; rpcReady = false; resourceFailed = false; hostContext = [:]
            pageProjection = nil; initialWidgetState = nil
            lastConversationRunActive = nil
            lastPresentationExpanded = nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard view != nil, message.webView === view, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.absoluteString == "about:blank",
                  let body = message.body as? [String: Any] else {
                replyHandler(nil, "PAGE_NOT_ENABLED"); return
            }
            if body["jsonrpc"] != nil {
                dispatchRPC(body, replyHandler: replyHandler)
                return
            }
            if body["resource_loaded"] != nil {
                guard Set(body.keys) == ["resource_loaded", "instance", "revision"],
                      body["instance"] as? String == generation.uuidString,
                      body["revision"] as? String == revision, !resourceFailed, let remoteTemplate,
                      let bytes = try? JSONSerialization.data(withJSONObject: body["resource_loaded"] as Any),
                      let resource = try? JSONDecoder().decode(JSONValue.self, from: bytes),
                      resource == remoteTemplate.resourceDescription else {
                    replyHandler(nil, "PAGE_CLOSED"); return
                }
                if !templateLoaded { templateLoaded = true; onTemplateLoaded(remoteTemplate) }
                replyHandler(["status": "loaded"], nil); return
            }
            if body["resource_error"] != nil {
                guard Set(body.keys) == ["resource_error", "instance", "revision"],
                      body["instance"] as? String == generation.uuidString,
                      body["revision"] as? String == revision else {
                    replyHandler(nil, "PAGE_CLOSED"); return
                }
                failResource()
                replyHandler(["status": "resource_error"], nil)
                return
            }
            if body["presentation_key"] != nil {
                guard Set(body.keys) == ["presentation_key", "instance", "revision"],
                      body["instance"] as? String == generation.uuidString,
                      body["revision"] as? String == revision, let key = body["presentation_key"] as? String,
                      rpcReady, !resourceFailed, presentationExpanded == true else {
                    replyHandler(nil, "PAGE_CLOSED"); return
                }
                if key == "Escape" { onCollapse() }
                else { sendPresentationShortcut(key) }
                replyHandler([:], nil); return
            }
            guard !resourceFailed else { replyHandler(nil, "PAGE_CLOSED"); return }
            if let body = message.body as? [String: Any], body["operation"] != nil {
                dispatchRequest(message, body: body, replyHandler: replyHandler)
                return
            }
            guard view != nil, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.absoluteString == "about:blank",
                  let body = message.body as? [String: Any], Set(body.keys) == ["action_id", "call_id", "instance", "revision"],
                  body["instance"] as? String == generation.uuidString,
                  body["revision"] as? String == revision,
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
            guard requests[callID] == nil else { replyHandler(nil, "CALL_ID_CONFLICT"); return }
            guard calls.count + requests.count < 100 else { replyHandler(nil, "CALL_LIMIT"); return }
            calls[callID] = actionID
            onTool(action)
            replyHandler(["status": "dispatched", "action_id": actionID], nil)
        }

        private func dispatchRequest(_ message: WKScriptMessage, body: [String: Any],
                                     replyHandler: @escaping (Any?, String?) -> Void) {
            guard view != nil, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.absoluteString == "about:blank",
                  Set(body.keys) == ["operation", "name", "arguments", "call_id", "instance", "revision"],
                  body["instance"] as? String == generation.uuidString,
                  body["revision"] as? String == revision,
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
                    guard calls[callID] == nil else { replyHandler(nil, "CALL_ID_CONFLICT"); return }
                    guard requests.count + calls.count < 100 else {
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
                    } catch {
                        guard let self, self.view != nil, self.generation == ticket, !task.isCancelled else {
                            replyHandler(nil, "PAGE_CLOSED"); return
                        }
                        replyHandler(nil, "REQUEST_FAILED")
                    }
                }
            } catch { replyHandler(nil, "INVALID_ARGUMENTS"); }
        }

        private func dispatchRPC(_ body: [String: Any], replyHandler: @escaping (Any?, String?) -> Void) {
            let ticket = generation
            let replyRevision = revision
            func respond(_ value: JSONValue?, _ error: AgentArtifactRPCError? = nil) {
                do {
                    var response: [String: JSONValue] = [
                        "jsonrpc": "2.0", "nonce": .string(ticket.uuidString), "revision": .string(replyRevision)]
                    if let rawID = body["id"],
                       let data = try? JSONSerialization.data(withJSONObject: rawID, options: [.fragmentsAllowed]),
                       let id = try? JSONDecoder().decode(JSONValue.self, from: data) {
                        switch id {
                        case .string(let text) where !text.isEmpty && text.utf8.count <= 128:
                            response["id"] = id
                        case .number(let number) where number.isFinite && number == number.rounded()
                                && abs(number) < 9_007_199_254_740_992:
                            response["id"] = id
                        default: response["id"] = .null
                        }
                    }
                    if let error { response["error"] = error.value }
                    else { response["result"] = value ?? [:] }
                    let bytes = try JSONEncoder().encode(JSONValue.object(response))
                    guard bytes.count <= 72 * 1024 else {
                        replyHandler(nil, "RESULT_LIMIT"); return
                    }
                    replyHandler(try JSONSerialization.jsonObject(with: bytes), nil)
                } catch { replyHandler(nil, "INVALID_RESPONSE") }
            }
            do {
                let bytes = try JSONSerialization.data(withJSONObject: body)
                guard bytes.count <= 72 * 1024 else { throw AgentArtifactRPCError.invalid }
                var value = try JSONDecoder().decode(JSONValue.self, from: bytes)
                if value["method"] == "ui/notifications/sandbox-resource-error", value["nonce"] == nil,
                   let nonce = value["params"]?["nonce"], var fields = value.objectValue {
                    fields["nonce"] = nonce; value = .object(fields)
                }
                // Discovery has no authority; all business messages still require nonce and revision.
                if value["method"]?.stringValue == "ui/notifications/sandbox-proxy-ready" {
                    guard !resourceFailed else { throw AgentArtifactRPCError.closed }
                    if !rpcReady { startInitializationTimer() }
                    sendResourceReady(); respond([:]); return
                }
                let request = try AgentArtifactPageProtocol.parse(value, nonce: ticket.uuidString, revision: revision)
                if request.method == "ui/notifications/sandbox-resource-error" {
                    failResource(); respond([:]); return
                }
                guard !resourceFailed else { throw AgentArtifactRPCError.closed }
                if request.method == "ui/initialize" {
                    guard request.id != nil,
                          request.params["protocolVersion"]?.stringValue == AgentArtifactPageProtocol.version else {
                        throw AgentArtifactRPCError.invalid
                    }
                    if !rpcReady, !rpcInitializing {
                        rpcInitializing = true
                        emit(.loading)
                        startInitializationTimer()
                    }
                    updateHostContext()
                    let capabilities: JSONValue = onRequest == nil ? [:] : [
                        "serverTools": [:], "updateModelContext": ["text": [:]]]
                    respond(["protocolVersion": .string(AgentArtifactPageProtocol.version),
                             "hostInfo": ["name": "clipslots", "version": "1.0.0"],
                             "hostCapabilities": capabilities, "hostContext": hostContext])
                    return
                }
                if request.method == "ui/notifications/initialized" {
                    guard rpcInitializing || rpcReady else { throw AgentArtifactRPCError.notReady }
                    let first = !rpcReady
                    rpcInitializing = false; rpcReady = true
                    initializationTimer?.cancel(); initializationTimer = nil
                    if first {
                        notify("ui/notifications/tool-input", params: pageProjection?.inputParams ?? ["arguments": [:]])
                        if let result = pageProjection?.resultParams(widgetState: initialWidgetState) {
                            notify("ui/notifications/tool-result", params: result)
                        }
                        notifyPresentationState()
                        notifyConversationState()
                    }
                    guard !resourceFailed else { throw AgentArtifactRPCError.failed }
                    emit(.ready)
                    respond([:])
                    return
                }
                guard rpcReady, !resourceFailed else { throw AgentArtifactRPCError.notReady }
                if request.method == "ui/notifications/size-changed" {
                    guard let height = AgentArtifactResourceContract.finiteNumber(request.params["height"]), height > 0 else {
                        throw AgentArtifactRPCError.invalid
                    }
                    onSizeChanged(height)
                    respond([:]); return
                }
                if request.method == "ping" { respond([:]); return }
                if request.method == "ui/open-link" {
                    guard let text = request.params["url"]?.stringValue,
                          let url = URL(string: text), let safe = AgentArtifactPreviewPolicy.externalURL(url) else {
                        throw AgentArtifactRPCError.invalid
                    }
                    onLink(safe)
                    respond(["status": "awaiting_user_open"])
                    return
                }
                guard let cacheKey = request.cacheKey else { throw AgentArtifactRPCError.invalid }
                let (operation, name, arguments) = try AgentArtifactPageProtocol.nativeOperation(request)
                guard let handler = onRequest else { throw AgentArtifactRPCError.unsupported }
                let signature = request.method + "\u{0}" + (try request.params.encodedText())
                let task: Task<JSONValue, Error>
                if let prior = requests[cacheKey] {
                    guard prior.0 == signature else {
                        throw AgentArtifactRPCError(-32602, "request id conflict")
                    }
                    task = prior.1
                } else {
                    guard requests.count + calls.count < 100 else {
                        throw AgentArtifactRPCError(-32000, "request limit")
                    }
                    task = Task {
                        try Task.checkCancellation()
                        return try await handler(operation, name, arguments)
                    }
                    requests[cacheKey] = (signature, task)
                }
                Task { @MainActor [weak self] in
                    do {
                        let result = try await task.value
                        guard let self, self.view != nil, self.generation == ticket, !task.isCancelled else {
                            respond(nil, .closed); return
                        }
                        let mapped = try AgentArtifactPageProtocol.result(result, method: request.method)
                        guard try mapped.encodedText().utf8.count <= 64 * 1024 else {
                            respond(nil, AgentArtifactRPCError(-32000, "result limit")); return
                        }
                        if operation == "app_reply", let replyID = mapped["reply_id"]?.stringValue,
                           let runID = mapped["run_id"]?.stringValue {
                            self.observeReply(replyID: replyID, runID: runID, ticket: ticket)
                        }
                        respond(mapped)
                    } catch {
                        guard let self, self.view != nil, self.generation == ticket, !task.isCancelled else {
                            respond(nil, .closed); return
                        }
                        respond(nil, (error as? AgentAppReplyError)?.rpcError
                            ?? (error as? AgentArtifactRPCError) ?? .failed)
                    }
                }
            } catch { respond(nil, (error as? AgentArtifactRPCError) ?? .invalid) }
        }

        private func updateHostContext() {
            guard let view else { return }
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let allowsExpanded = remoteTemplate?.presentation.allowExpanded ?? (presentationExpanded != nil)
            let next: JSONValue = ["theme": .string(dark ? "dark" : "light"),
                                   "locale": .string(Locale.current.identifier),
                                   "displayMode": .string(allowsExpanded && presentationExpanded == true ? "fullscreen" : "inline"),
                                   "availableDisplayModes": allowsExpanded ? ["inline", "fullscreen"] : ["inline"]]
            guard next != hostContext else { return }
            hostContext = next
            if rpcReady { notify("ui/notifications/host-context-changed", params: next) }
        }

        private func notifyConversationState() {
            guard rpcReady, !resourceFailed, let conversationRunActive,
                  lastConversationRunActive != conversationRunActive else { return }
            lastConversationRunActive = conversationRunActive
            notify("tapnow/updateData", params: ["conversation_run_active": .bool(conversationRunActive)])
        }

        private func notifyPresentationState() {
            guard rpcReady, !resourceFailed, let presentationExpanded,
                  lastPresentationExpanded != presentationExpanded else { return }
            lastPresentationExpanded = presentationExpanded
            view?.evaluateJavaScript("""
                if (window.__clipslotsNativeInstance === '\(generation.uuidString)') {
                  window.__clipslotsPresentationExpanded = \(presentationExpanded ? "true" : "false");
                  window.__clipslotsPresentationShortcuts = \(presentationResourceURI == "ui://tapnow/previs@v3" ? "true" : "false");
                }
                """, completionHandler: nil)
            notify("tapnow/presentationState", params: ["expanded": .bool(presentationExpanded)])
        }

        func sendPresentationShortcut(_ key: String) {
            guard rpcReady, !resourceFailed, presentationExpanded == true,
                  presentationResourceURI == "ui://tapnow/previs@v3",
                  ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Enter", " "].contains(key) else { return }
            notify("tapnow/presentationShortcut", params: ["key": .string(key)])
        }

        private func observeReply(replyID: String, runID: String, ticket: UUID) {
            guard replyObservers[replyID] == nil, let onReplyEvents,
                  let observation = try? onReplyEvents(replyID, runID) else { return }
            let task = Task { @MainActor [weak self] in
                for await event in observation.events {
                    guard !Task.isCancelled, let self, self.view != nil, self.generation == ticket,
                          self.rpcReady, !self.resourceFailed, observation.isCurrent() else { return }
                    switch event {
                    case .conversationActive(let active):
                        self.conversationRunActive = active
                        self.notifyConversationState()
                    case .running:
                        self.notify("tapnow/updateData", params: [
                            "reply_id": .string(replyID), "reply_run_status": "running"])
                    case .completion(let outcome):
                        self.notify("tapnow/updateData", params: [
                            "reply_id": .string(replyID),
                            "reply_run_status": .string(outcome == "applied" ? "completed" : outcome)])
                        self.notify("tapnow/appReplyStatus", params: [
                            "reply_id": .string(replyID), "status": .string(outcome)])
                    }
                }
            }
            replyObservers[replyID] = (runID, task)
        }

        private func notify(_ method: String, params: JSONValue) {
            let value: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": params,
                                    "nonce": .string(generation.uuidString), "revision": .string(revision),
                                    "clipslots_host": true]
            guard let text = try? value.encodedText(), text.utf8.count <= 72 * 1024 else {
                if !resourceFailed { failResource("页面通知过大，可查看源码。") }
                return
            }
            view?.evaluateJavaScript("""
                if (window.__clipslotsNativeInstance === '\(generation.uuidString)')
                  window.postMessage(\(text), '*')
                """, completionHandler: nil)
        }

        private func sendResourceReady() {
            guard !rpcReady, !resourceFailed else { return }
            notify("ui/notifications/sandbox-resource-ready", params: [
                "nonce": .string(generation.uuidString),
                "resource": resourceDescription,
                "csp": remoteTemplate?.csp ?? ["connectDomains": [], "resourceDomains": []]])
        }

        private var resourceDescription: JSONValue {
            if let remoteTemplate { return remoteTemplate.resourceDescription }
            if let uri = presentationResourceURI, let resource = AgentArtifactResourceIdentity(uri: uri) {
                return ["name": .string(resource.name), "version": .string(resource.version)]
            }
            return ["name": "clipslots-local-artifact", "version": .string(revision)]
        }

        private func failResource(_ message: String = "页面资源被阻止或加载失败，可切换源码查看。") {
            guard !resourceFailed else { return }
            resourceFailed = true
            resourceTask?.cancel(); resourceTask = nil
            view?.evaluateJavaScript("window.__clipslotsPresentationExpanded = false", completionHandler: nil)
            initializationTimer?.cancel(); initializationTimer = nil
            requests.values.forEach { $0.1.cancel() }; requests = [:]; calls = [:]
            replyObservers.values.forEach { $0.1.cancel() }; replyObservers = [:]
            rpcReady = false; rpcInitializing = false
            notify("ui/notifications/sandbox-resource-error", params: [
                "nonce": .string(generation.uuidString), "message": .string(message)])
            emit(.error(message))
        }

        private func startInitializationTimer() {
            guard initializationTimer == nil, !rpcReady, !resourceFailed else { return }
            let ticket = generation
            initializationTimer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.generation == ticket, !self.rpcReady else { return }
                self.failResource("页面初始化超时，可重新打开或查看源码。")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .reload, action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.cancel)
                let projection = pageProjection, state = initialWidgetState
                invalidate()
                pageProjection = projection; initialWidgetState = state
                loadedSource = nil; currentNavigation = nil
                emit(.loading)
                loadIfNeeded()
                return
            }
            // Only WebKit's initial in-memory document load is allowed.
            if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            if remoteTemplate != nil, action.navigationType == .other, action.targetFrame?.isMainFrame == false,
               ["about:blank", "about:srcdoc"].contains(action.request.url?.absoluteString ?? "") {
                decisionHandler(.allow); return
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
            let url = response.response.url?.absoluteString
            decisionHandler(url == "about:blank" || (remoteTemplate != nil && !response.isForMainFrame && url == "about:srcdoc")
                ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, navigation === currentNavigation else { return }
            if !resourceFailed, !rpcInitializing, (pageProjection == nil && pageResourceURI == nil) || rpcReady { emit(.ready) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard let navigation, navigation === currentNavigation else { return }
            failResource("HTML 预览加载失败，可重新打开或查看源码。")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let navigation, navigation === currentNavigation else { return }
            failResource("HTML 预览加载失败，可重新打开或查看源码。")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === view else { return }
            invalidate()
            loadedSource = source
            failResource("预览已停止，可重新打开或查看源码。")
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, let safe = AgentArtifactPreviewPolicy.externalURL(url) { onLink(safe) }
            return nil
        }
    }
}
