import AppKit
import SwiftUI

enum CanvasParameterPopoverSession {
    static weak var popover: NSPopover?
    static weak var anchorWindow: NSWindow?

    static func consumeEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              let popover, popover.isShown,
              event.window === anchorWindow || event.window === popover.contentViewController?.view.window else { return false }
        popover.performClose(nil)
        return true
    }
}

/// Keep one native presentation alive while a size change moves its node and composer.
/// Presentation and dismissal run after SwiftUI's update pass; AppKit never tears down
/// the hosting controller in the middle of a picker button's action.
extension View {
    func canvasParameterPopover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: () -> Content
    ) -> some View {
        background(CanvasParameterPopoverAnchor(isPresented: isPresented,
                                                content: AnyView(content().fixedSize())))
    }
}

private struct CanvasParameterPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) {
        let owner = context.coordinator
        owner.presentation = $isPresented
        owner.content = content
        owner.requested = isPresented
        owner.scheduleUpdate(anchor: view)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detached = true
        coordinator.requested = false
        DispatchQueue.main.async { coordinator.close() }
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var presentation: Binding<Bool>?
        var content = AnyView(EmptyView())
        var requested = false
        var detached = false
        private var scheduled = false
        private var popover: NSPopover?
        private var host: NSHostingController<AnyView>?
        private var outsideMonitor: Any?
        // AppKit can close one popover during the next mouse-down. Keep its
        // SwiftUI gesture closures alive until that whole event has returned.
        private var retiredHosts: [NSHostingController<AnyView>] = []

        func scheduleUpdate(anchor: NSView) {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self else { return }
                self.scheduled = false
                guard !self.detached, self.requested, let anchor,
                      let window = anchor.window, window.isVisible else {
                    self.close()
                    return
                }
                if let host = self.host, let popover = self.popover, popover.isShown {
                    host.rootView = self.content
                    popover.positioningRect = anchor.bounds
                    return
                }
                // Finish any IME/prompt edit before presenting another key window.
                if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
                let host = NSHostingController(rootView: self.content)
                let popover = NSPopover()
                // Parameter changes move the anchor. AppKit's transient
                // dismissal can race that move and close a live picker.
                // Dismiss only a real click outside this popover.
                popover.behavior = .applicationDefined
                popover.animates = false
                popover.delegate = self
                popover.contentViewController = host
                popover.contentSize = host.view.fittingSize
                self.host = host
                self.popover = popover
                CanvasParameterPopoverSession.popover?.performClose(nil)
                CanvasParameterPopoverSession.popover = popover
                CanvasParameterPopoverSession.anchorWindow = window
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                self.outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                    [weak self, weak popover] event in
                    guard let self, let popover, self.popover === popover, popover.isShown,
                          event.window !== popover.contentViewController?.view.window else { return event }
                    DispatchQueue.main.async { [weak popover] in popover?.performClose(nil) }
                    return event
                }
            }
        }

        func close() {
            if CanvasParameterPopoverSession.popover === popover {
                CanvasParameterPopoverSession.popover = nil
                CanvasParameterPopoverSession.anchorWindow = nil
            }
            let oldPopover = popover
            let oldHost = host
            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
            outsideMonitor = nil
            popover = nil
            host = nil
            oldPopover?.delegate = nil
            oldPopover?.close()
            if let oldHost {
                retiredHosts.append(oldHost)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self, oldPopover] in
                    retiredHosts.removeAll { $0 === oldHost }
                    _ = oldPopover
                }
            }
        }

        func popoverDidClose(_ notification: Notification) {
            requested = false
            // Retain the native host until its close callback and event have returned.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.requested else { return }
                self.close()
                if !self.detached { self.presentation?.wrappedValue = false }
            }
        }
    }
}
