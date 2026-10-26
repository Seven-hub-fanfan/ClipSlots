import AppKit
import SwiftUI

extension View {
    func agentModelPopover<Content: View>(isPresented: Binding<Bool>,
                                         @ViewBuilder content: () -> Content) -> some View {
        background(AgentModelPopoverAnchor(isPresented: isPresented,
            content: isPresented.wrappedValue ? AnyView(content()) : AnyView(EmptyView())))
    }
}

/// A model hover must never resize an anchored SwiftUI popover outside the screen.
/// Reserve both columns before showing and position the native panel explicitly.
private struct AgentModelPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: AnyView
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.binding = $isPresented
        context.coordinator.content = content
        context.coordinator.requested = isPresented
        context.coordinator.update(anchor: view)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.requested = false
        DispatchQueue.main.async { coordinator.close(reset: false) }
    }
    private final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    final class Coordinator {
        var binding: Binding<Bool>?
        var content = AnyView(EmptyView())
        var requested = false
        private weak var anchor: NSView?
        private var panel: Panel?
        private var host: NSHostingController<AnyView>?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var retired: [NSHostingController<AnyView>] = []
        func update(anchor: NSView) {
            self.anchor = anchor
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.requested, let anchor = self.anchor,
                      let window = anchor.window, window.isVisible else {
                    #if DEBUG
                    if self.requested { NSLog("[ModelPanel] missing anchor/window %@", String(describing: self.anchor?.window)) }
                    #endif
                    self.close(reset: false)
                    return
                }
                if let host = self.host {
                    host.rootView = self.content
                    self.position()
                    return
                }
                let host = NSHostingController(rootView: self.content)
                let panel = Panel(contentRect: .zero, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = true
                panel.level = .popUpMenu
                panel.contentViewController = host
                panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
                panel.onEscape = { [weak self] in self?.close(reset: true) }
                self.panel = panel
                self.host = host
                self.position()
                window.addChildWindow(panel, ordered: .above)
                panel.orderFront(nil)
                #if DEBUG
                NSLog("[ModelPanel] presented %@ visible=%d", NSStringFromRect(panel.frame), panel.isVisible)
                #endif
                self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
                    [weak self, weak panel] event in
                    guard let self, let panel, panel.isVisible else { return event }
                    if event.type == .keyDown, event.keyCode == 53 {
                        self.close(reset: true)
                        return nil
                    }
                    if event.type != .keyDown, event.window !== panel {
                        if let anchor = self.anchor, event.window === anchor.window,
                           anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) {
                            return event
                        }
                        #if DEBUG
                        NSLog("[ModelPanel] outside event %@", String(describing: event.window))
                        #endif
                        DispatchQueue.main.async { [weak self] in self?.close(reset: true) }
                    }
                    return event
                }
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    self.observers.append(NotificationCenter.default.addObserver(forName: name,
                        object: window, queue: .main) { [weak self] _ in self?.position() })
                }
                self.observers.append(NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                        [weak self] _ in
                        #if DEBUG
                        NSLog("[ModelPanel] application resigned active")
                        #endif
                        self?.close(reset: true)
                    })
            }
        }
        private func position() {
            guard let anchor, let window = anchor.window, let panel,
                  let screen = window.screen ?? NSScreen.main else { return }
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let size = CGSize(width: min(484, visible.width), height: min(440, visible.height))
            let below = rect.minY - size.height - 8
            let y = rect.maxY + size.height + 8 <= visible.maxY ? rect.maxY + 8 : below
            let origin = CGPoint(x: max(visible.minX, min(rect.maxX - size.width + 8, visible.maxX - size.width)),
                                 y: max(visible.minY, min(y, visible.maxY - size.height)))
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        func close(reset: Bool) {
            #if DEBUG
            if panel != nil { NSLog("[ModelPanel] close reset=%d", reset) }
            #endif
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
            }
            panel = nil
            if let host {
                retired.append(host)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    retired.removeAll { $0 === host }
                }
            }
            host = nil
            if reset {
                requested = false
                DispatchQueue.main.async { [weak self] in self?.binding?.wrappedValue = false }
            }
        }
    }
    private final class Panel: NSPanel {
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }
}
