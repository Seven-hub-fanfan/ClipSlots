import AppKit
import SwiftUI

/// One child panel for the shared connection request. Child windows do not
/// enter an application-wide modal loop, so the application menu stays usable.
struct AgentApplicationConnectionPresenter: NSViewRepresentable {
    @ObservedObject var sync: AgentMarketSyncStore
    func makeCoordinator() -> Coordinator { Coordinator(sync: sync) }
    func makeNSView(context: Context) -> NSView {
        let view = AgentApplicationManagerPresenter.OwnerProbe()
        view.attached = { [weak coordinator = context.coordinator] owner in
            DispatchQueue.main.async { coordinator?.update(owner: owner) }
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.update(owner: view.window) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        final class ConnectionPanel: NSPanel {
            var onClose: (() -> Void)?
            override var canBecomeKey: Bool { true }
            override func cancelOperation(_ sender: Any?) { onClose?() }
            override func performClose(_ sender: Any?) { onClose?() }
            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers?.lowercased() == "w" {
                    onClose?(); return true
                }
                return super.performKeyEquivalent(with: event)
            }
        }
        private final class Shade: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        }
        let sync: AgentMarketSyncStore
        let id = UUID()
        private(set) var panel: ConnectionPanel?
        private var shade: NSView?
        private weak var owner: NSWindow?
        private var generation: UUID?
        private var observers: [NSObjectProtocol] = []
        init(sync: AgentMarketSyncStore) { self.sync = sync }
        func update(owner: NSWindow?) {
            // A manager/wizard child may disappear during the connection
            // handoff. Only a stable top-level host can claim the request.
            guard owner?.parent == nil else { return }
            if panel != nil, generation != sync.connectionGeneration || sync.connectingItem == nil || owner == nil {
                close(clearRequest: false)
            }
            guard panel == nil, let owner, owner.isVisible, let content = owner.contentView,
                  let item = sync.connectingItem, sync.claimConnectionPresenter(id) else { return }
            self.owner = owner
            let generation = sync.connectionGeneration
            self.generation = generation
            let shade = Shade(frame: content.bounds)
            shade.wantsLayer = true
            shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            shade.autoresizingMask = [.width, .height]
            content.addSubview(shade); self.shade = shade
            let panel = ConnectionPanel(contentRect: .init(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.appearance = owner.appearance
            panel.title = "连接" + item.title
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.onClose = { [weak self] in self?.close() }
            panel.contentView = NSHostingView(rootView: AgentApplicationConnection(item: item, sync: sync,
                generation: generation, onClose: { [weak self] in self?.close() }))
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = 20
            panel.contentView?.layer?.masksToBounds = true
            self.panel = panel
            owner.addChildWindow(panel, ordered: .above)
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.center() }
                })
            }
            for (name, object) in [(NSWindow.willCloseNotification, owner as AnyObject),
                                   (NSApplication.willTerminateNotification, NSApp as AnyObject)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                })
            }
            center(); panel.makeKeyAndOrderFront(nil)
        }
        private func center() {
            guard let owner, let content = owner.contentView, let panel else { return }
            let frame = owner.convertToScreen(content.bounds)
            let width = min(480, max(280, frame.width - 32))
            let height = min(520, max(200, frame.height - 32))
            panel.setFrame(.init(x: frame.midX - width / 2, y: frame.midY - height / 2,
                                 width: width, height: height), display: true)
        }
        func close(clearRequest: Bool = true) {
            let owner = self.owner
            if clearRequest, let generation { sync.closeConnection(generation: generation) }
            sync.releaseConnectionPresenter(id)
            if let panel { owner?.removeChildWindow(panel); panel.orderOut(nil); panel.contentView = nil; panel.onClose = nil }
            panel = nil; generation = nil; shade?.removeFromSuperview(); shade = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            self.owner = nil
            if owner?.isVisible == true { owner?.makeKey() }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    }
}
