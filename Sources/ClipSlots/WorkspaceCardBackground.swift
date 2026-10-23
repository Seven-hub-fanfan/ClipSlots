import AppKit
import SwiftUI

/// The card's rounded silhouette is known. Core Animation can use it directly
/// for the shadow instead of deriving a new alpha mask from the card each frame.
struct WorkspaceCardBackground: NSViewRepresentable {
    static var useNativeSurface: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_SWIFTUI_CARD_BACKGROUND"] != "1"
        #else
        return true
        #endif
    }
    @Environment(\.colorScheme) private var colorScheme
    let fill: Color
    let shadow: Color
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowOffset: CGFloat

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.fill = NSColor(fill)
        view.shadowInk = NSColor(shadow)
        view.radius = cornerRadius
        view.blur = shadowRadius
        view.offset = shadowOffset
        view.synchronize()
    }

    final class Surface: NSView {
        var fill = NSColor.clear
        var shadowInk = NSColor.clear
        var radius: CGFloat = 0
        var blur: CGFloat = 0
        var offset: CGFloat = 0
        private var pathSize = CGSize.zero
        private var pathRadius: CGFloat = -1
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            synchronize()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            synchronize()
        }
        func synchronize() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.backgroundColor = fill.cgColor
                layer.shadowColor = shadowInk.cgColor
            }
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
            layer.shadowOpacity = 1
            layer.shadowRadius = blur
            layer.shadowOffset = CGSize(width: 0, height: -offset)
            if pathSize != bounds.size || pathRadius != radius {
                pathSize = bounds.size
                pathRadius = radius
                layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                          cornerHeight: radius, transform: nil)
            }
            CATransaction.commit()
        }
    }
}
