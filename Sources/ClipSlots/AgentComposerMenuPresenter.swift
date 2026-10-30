import AppKit
import SwiftUI

private struct ComposerMenuSize: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct ComposerMenuRoot<Content: View>: View {
    let content: Content
    let sizeChanged: (CGSize) -> Void
    var body: some View {
        content.fixedSize().padding(8)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ComposerMenuSize.self, value: geometry.size)
            })
            .onPreferenceChange(ComposerMenuSize.self, perform: sizeChanged)
    }
}

/// Both panes share one event surface while preserving their separate outlines.
struct AgentComposerMenuPresenter<Content: View>: NSViewRepresentable {
    @Binding var presented: Bool
    let content: Content
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Anchor: NSView {
        var attach: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?() }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        context.coordinator.anchor = view
        view.attach = { [weak coordinator = context.coordinator] in coordinator?.update() }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.current = self
        let visible = presented
        DispatchQueue.main.async { context.coordinator.update(expectedPresented: visible) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }
    @MainActor final class Coordinator {
        final class MenuPanel: NSPanel { override var canBecomeKey: Bool { true } }
        var current: AgentComposerMenuPresenter?
        weak var anchor: NSView?
        var panel: NSPanel?
        var monitor: Any?
        var observers: [NSObjectProtocol] = []
        func update(expectedPresented: Bool? = nil) {
            guard let current else { return }
            if let expectedPresented, expectedPresented != current.presented { return }
            guard current.presented, let anchor, let owner = anchor.window else { close(); return }
            if let panel {
                panel.appearance = owner.effectiveAppearance
                if let view = panel.contentView as? NSHostingView<ComposerMenuRoot<Content>> {
                    view.rootView = menuRoot(current.content)
                }
                return
            }
            let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.appearance = owner.effectiveAppearance
            let view = NSHostingView(rootView: menuRoot(current.content))
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = view
            self.panel = panel
            position(view.fittingSize)
            owner.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if let self, let panel = self.panel { self.position(panel.frame.size) }
                    }
                })
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let panel = self.panel else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss(); return nil }
                    return event
                }
                if event.window === panel { return event }
                if let anchor = self.anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
                self.dismiss(); return event
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self, let panel = self.panel { self.position(panel.frame.size) } }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        private func menuRoot(_ content: Content) -> ComposerMenuRoot<Content> {
            ComposerMenuRoot(content: content, sizeChanged: { [weak self] size in
                DispatchQueue.main.async { self?.position(size) }
            })
        }
        func position(_ size: CGSize) {
            guard size.width > 0, size.height > 0, let panel, let anchor, let owner = anchor.window else { return }
            let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            guard let screen = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
            let x = max(screen.minX, min(rect.minX - (size.width - 252), screen.maxX - size.width))
            let y = max(screen.minY, min(rect.maxY, screen.maxY - size.height))
            panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        }
        func dismiss() { current?.presented = false; close() }
        func close() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            if let panel { panel.parent?.removeChildWindow(panel); panel.close() }
            panel = nil
        }
    }
}
