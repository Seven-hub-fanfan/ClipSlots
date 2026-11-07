import SwiftUI
import AppKit
import WebKit
import ClipSlotsKit

/// Only brand identifiers cross this bridge. API fields are native SecureField /
/// TextField controls and are never passed to WebKit.
struct AgentLineArtwork: NSViewRepresentable {
    var mode: String
    var light: Bool
    var onSelect: (AgentAPIProvider) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "selectProvider")
        let view = AgentLineHostWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.apply(mode: mode, light: light, reduceMotion: reduceMotion, onSelect: onSelect)
        view.onWindowChanged = { [weak coordinator = context.coordinator] in coordinator?.sync() }
        context.coordinator.observe()
        if let page = AgentBackgroundResources.pageURL {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.apply(mode: mode, light: light, reduceMotion: reduceMotion, onSelect: onSelect)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "selectProvider")
        (view as? AgentLineHostWebView)?.onWindowChanged = nil
        (view as? AgentLineHostWebView)?.stopScrollForwarding()
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        var mode = "picker", light = true, reduceMotion = false
        var onSelect: (AgentAPIProvider) -> Void = { _ in }
        private var ready = false
        private var applied = ""
        private var observers: [NSObjectProtocol] = []
        func apply(mode: String, light: Bool, reduceMotion: Bool, onSelect: @escaping (AgentAPIProvider) -> Void) {
            self.mode = mode; self.light = light; self.reduceMotion = reduceMotion; self.onSelect = onSelect
            sync()
        }
        func observe() {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sync() })
            }
        }
        func sync() {
            guard ready, let view else { return }
            let playing = !reduceMotion && !NSApp.isHidden && (view.window?.occlusionState.contains(.visible) == true)
            let value: [String: Any] = ["mode": mode, "light": light, "playing": playing, "reduced": reduceMotion]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8), applied != json else { return }
            applied = json
            view.evaluateJavaScript("window.setNativeState(\(json))", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  mode == "picker", let value = message.body as? String,
                  let provider = AgentAPIProvider(rawValue: value), provider != .custom else { return }
            onSelect(provider)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; applied = ""; sync() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func stop() {
            view?.evaluateJavaScript("window.setNativeState({playing:false})", completionHandler: nil)
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

final class AgentLineHostWebView: WKWebView {
    var onWindowChanged: (() -> Void)?
    private var scrollMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopScrollForwarding()
        if window != nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scroll = self.scrollDestination(for: event) else { return event }
                // Forward the original event, including precise deltas and
                // momentum phases, exactly once before WKContentView consumes it.
                scroll.scrollWheel(with: event)
                return nil
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onWindowChanged?() }
    }
    func scrollDestination(for event: NSEvent) -> NSScrollView? {
        guard event.window === window, let content = window?.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
              hit === self || hit.isDescendant(of: self) else { return nil }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
    func stopScrollForwarding() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
    deinit { stopScrollForwarding() }
}
