import SwiftUI
import AppKit
import ClipSlotsKit

/// Fixed 44pt launcher. Animation stays in a tiny native image view, outside the
/// workspace's update cycle; the button never scales with the canvas or sidebar.
struct AgentOrbButton: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    #if DEBUG
    var debugReduceMotion: Bool? = nil
    var debugHighContrast: Bool? = nil
    #endif
    private var motionReduced: Bool {
        #if DEBUG
        if let debugReduceMotion { return debugReduceMotion }
        #endif
        return reduceMotion
    }
    private var increasedContrast: Bool {
        #if DEBUG
        if let debugHighContrast { return debugHighContrast }
        #endif
        return contrast == .increased
    }
    var body: some View {
        Button(action: action) {
            OrbImage(active: hovering || isOpen, animate: !motionReduced)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .allowsHitTesting(false)
                .frame(width: 44, height: 44)
                .background(Color.black, in: Circle())
                .overlay {
                    AgentOrbRim(animated: !motionReduced, highContrast: increasedContrast)
                        .frame(width: 60, height: 60)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if increasedContrast {
                        Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .scaleEffect(hovering && !motionReduced ? 1.05 : 1)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .localizedHelp(isOpen ? "收起 Agent" : "打开 Agent")
        .localizedAccessibilityLabel(isOpen ? "收起 Agent" : "打开 Agent")
        .accessibilityIdentifier("workspace-agent-orb")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isOpen ? [.isSelected] : [])
        .accessibilityAction { action() }
    }
}

struct OrbImage: NSViewRepresentable {
    let active: Bool
    let animate: Bool
    final class ImageView: NSImageView {
        var asset = ""
        private var requestedAnimation = false
        private var observers: [NSObjectProtocol] = []
        private var visibility: NSKeyValueObservation?
        override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 36) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        func configure(animate: Bool) {
            requestedAnimation = animate
            updateMotion()
        }
        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            visibility = nil
            requestedAnimation = false
            updateMotion()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            visibility = window?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                self?.updateMotion()
            }
            if let window {
                for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didChangeOcclusionStateNotification] {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in self?.updateMotion() })
                }
            }
            updateMotion()
        }
        override func viewDidHide() { super.viewDidHide(); updateMotion() }
        override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
        private func updateMotion() {
            animates = requestedAnimation && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
        }
    }
    func makeNSView(context: Context) -> ImageView {
        let view = ImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setAccessibilityElement(false)
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ImageView, context: Context) -> CGSize? {
        CGSize(width: 36, height: 36)
    }
    func updateNSView(_ view: ImageView, context: Context) {
        let name = active ? "agent-orb-active" : "agent-orb-idle"
        if view.asset != name {
            view.asset = name
            if let root = AgentBackgroundResources.pageURL?.deletingLastPathComponent().deletingLastPathComponent() {
                view.image = NSImage(contentsOf: root.appendingPathComponent("TapNowMotion/\(name).gif"))
            }
        }
        view.configure(animate: animate)
    }
    static func dismantleNSView(_ view: ImageView, coordinator: ()) { view.detach() }
}
