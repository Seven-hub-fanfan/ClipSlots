import SwiftUI
import WebKit
import ClipSlotsKit

/// A separate ephemeral WebKit instance, with no script handlers or execution bridge.
struct AgentArtifactHTMLPreview: NSViewRepresentable {
    let source: String
    let onState: (AgentArtifactResourceState) -> Void
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(source: source, onState: onState, onLink: onLink)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var view: WKWebView?
        private var source: String?
        private var loadedSource: String?
        private var currentNavigation: WKNavigation?
        private var rulesReady = false
        private var ruleError: String?
        private var generation = UUID()
        private var onState: (AgentArtifactResourceState) -> Void = { _ in }
        private var onLink: (URL) -> Void = { _ in }

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

        func update(source: String, onState: @escaping (AgentArtifactResourceState) -> Void, onLink: @escaping (URL) -> Void) {
            self.onState = onState; self.onLink = onLink
            if self.source != source {
                self.source = source; generation = UUID()
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
            currentNavigation = view.loadHTMLString(AgentArtifactPreviewPolicy.sandboxedHTML(source), baseURL: nil)
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
