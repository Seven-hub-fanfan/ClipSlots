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
    func makeNSView(context: Context) -> AgentArtworkHostView {
        let host = AgentArtworkHostView()
        context.coordinator.host = host
        context.coordinator.apply(mode: mode, light: light, reduceMotion: reduceMotion, onSelect: onSelect)
        host.startRenderer = { [weak host, weak coordinator = context.coordinator] in
            guard let host, let coordinator else { return }
            coordinator.installRenderer(in: host)
        }
        return host
    }
    func updateNSView(_ view: AgentArtworkHostView, context: Context) {
        context.coordinator.apply(mode: mode, light: light, reduceMotion: reduceMotion, onSelect: onSelect)
    }
    static func dismantleNSView(_ host: AgentArtworkHostView, coordinator: Coordinator) {
        coordinator.stop()
        host.stop()
        guard let view = host.webView else { return }
        view.configuration.userContentController.removeScriptMessageHandler(forName: "selectProvider")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "artworkReady")
        view.onWindowChanged = nil
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        weak var host: AgentArtworkHostView?
        var mode = "picker", light = true, reduceMotion = false
        var onSelect: (AgentAPIProvider) -> Void = { _ in }
        private var ready = false
        private var applied = ""
        private var observers: [NSObjectProtocol] = []
        private var revision = 0
        private var recoveryAttempts = 0
        var initialState: String {
            stateJSON(playing: false) ?? "{}"
        }
        func installRenderer(in host: AgentArtworkHostView) {
            guard view == nil, host.window != nil else { return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "selectProvider")
            configuration.userContentController.add(self, name: "artworkReady")
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.__nativeArtworkState = \(initialState);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = AgentLineHostWebView(frame: host.bounds, configuration: configuration)
            view.setValue(false, forKey: "drawsBackground")
            view.navigationDelegate = self
            self.view = view
            host.install(view)
            view.onWindowChanged = { [weak self] in self?.sync() }
            observe()
            if let page = AgentBackgroundResources.pageURL {
                view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        }
        func apply(mode: String, light: Bool, reduceMotion: Bool, onSelect: @escaping (AgentAPIProvider) -> Void) {
            if self.mode != mode {
                revision += 1
                host?.showNative()
            }
            self.mode = mode; self.light = light; self.reduceMotion = reduceMotion; self.onSelect = onSelect
            host?.configure(mode: mode, light: light, reduceMotion: reduceMotion, onSelect: onSelect)
            sync()
        }
        private func stateJSON(playing: Bool) -> String? {
            let value: [String: Any] = ["mode": mode, "light": light, "playing": playing,
                                       "reduced": reduceMotion, "revision": revision]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        func observe() {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sync() })
            }
        }
        func sync() {
            host?.updateLoadingAnimation(reduceMotion: reduceMotion)
            guard ready, let view else { return }
            let playing = !reduceMotion && !NSApp.isHidden && (view.window?.occlusionState.contains(.visible) == true)
            guard let json = stateJSON(playing: playing), applied != json else { return }
            applied = json
            view.evaluateJavaScript("window.setNativeState(\(json))", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  message.frameInfo.request.url?.standardizedFileURL == AgentBackgroundResources.pageURL?.standardizedFileURL
            else { return }
            if message.name == "artworkReady" {
                guard let state = message.body as? [String: Any],
                      state["mode"] as? String == mode,
                      (state["revision"] as? NSNumber)?.intValue == revision else { return }
                host?.showWeb(reduceMotion: reduceMotion)
                return
            }
            guard message.name == "selectProvider", mode == "picker", let value = message.body as? String,
                  let provider = AgentAPIProvider(rawValue: value), provider != .custom else { return }
            onSelect(provider)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; applied = ""; sync() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }
        private func failed() { ready = false; applied = ""; host?.showNative() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failed()
            guard recoveryAttempts == 0, host?.window != nil else { return }
            recoveryAttempts += 1
            webView.reload()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func stop() {
            view?.evaluateJavaScript("window.setNativeState({playing:false})", completionHandler: nil)
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            onSelect = { _ in }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// Native gradient cards are clickable from the first frame. Keep one scroll
/// owner throughout loading and the renderer-ready crossfade.
final class AgentArtworkHostView: NSView {
    private(set) var webView: AgentLineHostWebView?
    var startRenderer: (() -> Void)?
    private var cards: [AgentArtworkPosterCard] = []
    private var mode = ""
    private var loadingReducedMotion = false
    private var showingWeb = false
    private var handoff: DispatchWorkItem?
    private var startup: DispatchWorkItem?
    private var pointerTracking: NSTrackingArea?
    private var pointerMonitor: Any?
    private var scrollMonitor: Any?
    private var pointerTask: DispatchWorkItem?
    private var pendingPointer: (x: CGFloat, y: CGFloat, active: Bool)?
    private var pointerInFlight = false
    private var pointerActive = false
    private weak var trackingWindow: NSWindow?
    private static var mouseMoveLeases: [ObjectIdentifier: (count: Int, previous: Bool)] = [:]
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    func install(_ webView: AgentLineHostWebView) {
        self.webView = webView
        webView.frame = bounds
        webView.alphaValue = 0
        addSubview(webView)
        needsLayout = true
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startup?.cancel(); startup = nil
        stopPointerTracking()
        stopScrollForwarding()
        updateLoadingAnimation(reduceMotion: loadingReducedMotion)
        if let window {
            trackingWindow = window
            let key = ObjectIdentifier(window)
            let lease = Self.mouseMoveLeases[key] ?? (count: 0, previous: window.acceptsMouseMovedEvents)
            Self.mouseMoveLeases[key] = (lease.count + 1, lease.previous)
            window.acceptsMouseMovedEvents = true
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.trackPointer(event.locationInWindow)
                return event
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scroll = self.scrollDestination(for: event) else { return event }
                // Preserve the event's precise deltas, phase and momentum.
                // This host also covers the native buttons and crossfade.
                scroll.scrollWheel(with: event)
                self.trackPointer(event.locationInWindow)
                return nil
            }
        }
        guard window != nil, webView == nil else { return }
        // Mount the native buttons before WebKit's first process startup. The
        // 120 ms delay overlaps the local reveal, and does not delay interaction.
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            self.startRenderer?()
        }
        startup = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        pointerTracking = area
        addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { trackPointer(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { trackPointer(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { queuePointer(x: 0, y: 0, active: false) }
    private func trackPointer(_ point: NSPoint) {
        guard showingWeb, let webView, let content = window?.contentView else { return }
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        let active = hit.map { $0 === webView || $0.isDescendant(of: webView) } ?? false
        let local = webView.convert(point, from: nil)
        queuePointer(x: local.x, y: webView.isFlipped ? local.y : webView.bounds.height - local.y, active: active)
    }
    private func queuePointer(x: CGFloat, y: CGFloat, active: Bool) {
        guard showingWeb, active || pointerActive || pendingPointer != nil else { return }
        pointerActive = active
        pendingPointer = (x, y, active)
        guard pointerTask == nil, !pointerInFlight else { return }
        // High-rate mice produce one latest coordinate per display interval.
        let task = DispatchWorkItem { [weak self] in self?.sendPointer() }
        pointerTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: task)
    }
    private func sendPointer() {
        pointerTask = nil
        guard showingWeb, let webView, let pointer = pendingPointer else { return }
        pendingPointer = nil
        pointerInFlight = true
        let x = Double(pointer.x), y = Double(pointer.y)
        guard x.isFinite, y.isFinite else { pointerInFlight = false; return }
        webView.evaluateJavaScript("window.setNativePointer?.(\(x),\(y),\(pointer.active))") { [weak self] _, _ in
            guard let self else { return }
            self.pointerInFlight = false
            if let latest = self.pendingPointer {
                self.queuePointer(x: latest.x, y: latest.y, active: latest.active)
            }
        }
    }
    private func stopPointerTracking() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        pointerTask?.cancel(); pointerTask = nil
        pendingPointer = nil; pointerActive = false
        if let trackingWindow {
            let key = ObjectIdentifier(trackingWindow)
            if let lease = Self.mouseMoveLeases[key] {
                if lease.count == 1 {
                    trackingWindow.acceptsMouseMovedEvents = lease.previous
                    Self.mouseMoveLeases.removeValue(forKey: key)
                } else { Self.mouseMoveLeases[key] = (lease.count - 1, lease.previous) }
            }
        }
        trackingWindow = nil
    }
    func configure(mode: String, light: Bool, reduceMotion: Bool = false,
                   onSelect: @escaping (AgentAPIProvider) -> Void) {
        if self.mode != mode {
            self.mode = mode
            cards.forEach { $0.removeFromSuperview() }
            let providers: [AgentAPIProvider] = mode == "picker"
                ? [.claude, .gemini, .gpt, .deepseek, .grok, .kimi]
                : AgentAPIProvider(rawValue: mode).map { [$0] } ?? []
            cards = providers.filter { $0 != .custom }.map { provider in
                let card = AgentArtworkPosterCard(provider: provider, picker: mode == "picker")
                if let webView { addSubview(card, positioned: .below, relativeTo: webView) }
                else { addSubview(card) }
                return card
            }
            needsLayout = true
        }
        cards.forEach {
            $0.selection = onSelect
            $0.isHidden = showingWeb
            $0.needsDisplay = true
        }
        updateLoadingAnimation(reduceMotion: reduceMotion)
    }
    func updateLoadingAnimation(reduceMotion: Bool) {
        loadingReducedMotion = reduceMotion
        let animate = !showingWeb && !reduceMotion && !NSApp.isHidden &&
            window?.occlusionState.contains(.visible) == true
        cards.forEach { $0.setLoadingAnimation(animate) }
    }
    override func layout() {
        super.layout()
        webView?.frame = bounds
        for (index, card) in cards.enumerated() {
            card.frame = mode == "picker"
                ? CGRect(x: CGFloat(index % 2) * ((bounds.width - 12) / 2 + 12),
                         y: CGFloat(index / 2) * 184, width: max(0, (bounds.width - 12) / 2), height: 172)
                : bounds
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, alphaValue > 0, bounds.contains(local) else { return nil }
        guard !showingWeb else { return super.hitTest(point) }
        return cards.first(where: { $0.frame.contains(local) }) ?? self
    }
    func scrollDestination(for event: NSEvent) -> NSScrollView? {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, alphaValue > 0,
              visibleRect.contains(convert(event.locationInWindow, from: nil)),
              let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                        ?? event.locationInWindow),
              hit === self || hit.isDescendant(of: self) else { return nil }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
    private func stopScrollForwarding() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
    func showNative() {
        handoff?.cancel(); handoff = nil
        webView?.layer?.removeAllAnimations()
        showingWeb = false
        webView?.alphaValue = 0
        pointerTask?.cancel(); pointerTask = nil
        pendingPointer = nil; pointerActive = false
        cards.forEach {
            if $0.superview == nil {
                if let webView { addSubview($0, positioned: .below, relativeTo: webView) }
                else { addSubview($0) }
            }
            $0.isHidden = false
        }
        updateLoadingAnimation(reduceMotion: loadingReducedMotion)
        needsLayout = true
    }
    func showWeb(reduceMotion: Bool) {
        guard !showingWeb, let webView else { return }
        showingWeb = true
        if reduceMotion {
            webView.alphaValue = 1
            cards.forEach { $0.removeFromSuperview() }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                webView.animator().alphaValue = 1
            }
            let completion = DispatchWorkItem { [weak self] in
                guard let self, self.showingWeb else { return }
                self.cards.forEach { $0.removeFromSuperview() }
                if let window = self.window {
                    self.trackPointer(window.mouseLocationOutsideOfEventStream)
                }
            }
            handoff = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: completion)
        }
        if let window { trackPointer(window.mouseLocationOutsideOfEventStream) }
    }
    func stop() {
        handoff?.cancel(); handoff = nil
        startup?.cancel(); startup = nil
        startRenderer = nil
        stopPointerTracking()
        stopScrollForwarding()
        cards.forEach { $0.selection = { _ in }; $0.setLoadingAnimation(false) }
    }
    deinit { stopPointerTracking(); stopScrollForwarding() }
}

/// A compositor-only loading gradient avoids resizing a raster preview into a
/// different canvas pattern. Brand labels and buttons stay usable while loading.
final class AgentArtworkPosterCard: NSButton {
    private static var icons: [AgentAPIProvider: NSImage] = [:]
    let provider: AgentAPIProvider
    private let picker: Bool
    var selection: (AgentAPIProvider) -> Void = { _ in }
    private let loadingGradient = CAGradientLayer()
    private var icon: NSImage?
    override var isFlipped: Bool { true }
    init(provider: AgentAPIProvider, picker: Bool) {
        self.provider = provider; self.picker = picker
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        target = self; action = #selector(selectProvider)
        setAccessibilityLabel(picker ? "连接 \(brandName)" : "\(brandName) 图案")
        setAccessibilityIdentifier("agent-api-poster-\(provider.rawValue)")
        wantsLayer = true
        layer?.cornerRadius = picker ? 12 : 10
        layer?.masksToBounds = true
        let ink = color(palette.1)
        loadingGradient.colors = [ink.withAlphaComponent(0.01).cgColor,
                                  ink.withAlphaComponent(0.035).cgColor,
                                  ink.withAlphaComponent(0.01).cgColor]
        loadingGradient.locations = [0, 0.5, 1]
        loadingGradient.startPoint = CGPoint(x: 0, y: 0)
        loadingGradient.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(loadingGradient)
        if let cached = Self.icons[provider] { icon = cached }
        else if let url = AgentBackgroundResources.pageURL?.deletingLastPathComponent()
            .appendingPathComponent("icon-\(provider.rawValue).png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 13, height: 13)
            Self.icons[provider] = image; icon = image
        }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loadingGradient.frame = bounds
        CATransaction.commit()
    }
    func setLoadingAnimation(_ enabled: Bool) {
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            loadingGradient.removeAnimation(forKey: "loading"); return
        }
        guard loadingGradient.animation(forKey: "loading") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.4
        animation.toValue = 1.0
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        loadingGradient.add(animation, forKey: "loading")
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setLoadingAnimation(false) }
    }
    @objc private func selectProvider() { if picker { selection(provider) } }
    private var brandName: String {
        switch provider {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .gpt: return "GPT"
        case .deepseek: return "DeepSeek"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        case .custom: return "API"
        }
    }
    private var palette: (UInt32, UInt32, String) {
        switch provider {
        case .claude: return (0xefe8df, 0xbf684c, "Anthropic")
        case .gemini: return (0x175bed, 0xf1f6ff, "Google")
        case .gpt: return (0xffffff, 0x151515, "OpenAI")
        case .deepseek: return (0xe9eefb, 0x163374, "DeepSeek")
        case .grok: return (0x0d0e10, 0xf4f4f2, "xAI")
        case .kimi: return (0xedf0f4, 0x20252e, "Moonshot AI")
        case .custom: return (0xffffff, 0x151515, "")
        }
    }
    private func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
    override func draw(_ dirtyRect: NSRect) {
        let (background, foreground, company) = palette
        let outline = NSBezierPath(roundedRect: bounds, xRadius: picker ? 12 : 10, yRadius: picker ? 12 : 10)
        color(background).setFill(); outline.fill()
        if isHighlighted {
            color(foreground).withAlphaComponent(0.08).setFill()
            outline.fill()
        }
        if picker {
            let ink = color(foreground)
            icon?.draw(in: CGRect(x: 13, y: 13, width: 13, height: 13), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (brandName as NSString).draw(at: NSPoint(x: 32, y: 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: ink])
            (company as NSString).draw(at: NSPoint(x: 13, y: bounds.height - 24),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink.withAlphaComponent(0.75)])
            ("↗" as NSString).draw(at: NSPoint(x: bounds.width - 23, y: bounds.height - 24),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink.withAlphaComponent(0.75)])
            NSColor.black.withAlphaComponent(0.04).setStroke()
            outline.lineWidth = 1; outline.stroke()
        }
    }
}

final class AgentLineHostWebView: WKWebView {
    var onWindowChanged: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.onWindowChanged?() }
    }
    func scrollDestination(for event: NSEvent) -> NSScrollView? {
        (superview as? AgentArtworkHostView)?.scrollDestination(for: event)
    }
}
