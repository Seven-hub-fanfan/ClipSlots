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
    var body: some View {
        Button(action: action) {
            OrbImage(active: hovering || isOpen, animate: !reduceMotion)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .allowsHitTesting(false)
                .frame(width: 44, height: 44)
                .background(Color(white: 0.13), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(isOpen ? 0.5 : hovering ? 0.3 : 0.16),
                                              lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help(isOpen ? "收起 Agent" : "打开 Agent")
        .accessibilityLabel(isOpen ? "收起 Agent" : "打开 Agent")
        .accessibilityIdentifier("workspace-agent-orb")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isOpen ? [.isSelected] : [])
        .accessibilityAction { action() }
    }
}

private struct OrbImage: NSViewRepresentable {
    let active: Bool
    let animate: Bool
    final class ImageView: NSImageView {
        var asset = ""
        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
        CGSize(width: 32, height: 32)
    }
    func updateNSView(_ view: ImageView, context: Context) {
        let name = active ? "agent-orb-active" : "agent-orb-idle"
        if view.asset != name {
            view.asset = name
            if let root = AgentBackgroundResources.pageURL?.deletingLastPathComponent().deletingLastPathComponent() {
                view.image = NSImage(contentsOf: root.appendingPathComponent("TapNowMotion/\(name).gif"))
            }
        }
        view.animates = animate
    }
    static func dismantleNSView(_ view: ImageView, coordinator: ()) { view.animates = false }
}
