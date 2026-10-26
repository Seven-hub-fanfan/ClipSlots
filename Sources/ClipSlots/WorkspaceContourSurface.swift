import AppKit
import SwiftUI
import QuartzCore

/// The render server advances these two layers even while the main thread is
/// preparing the next workspace. SwiftUI remains responsible for the buttons.
final class WorkspaceContourMotion {
    weak var surface: WorkspaceContourSurface.Host?
    func select(center: CGFloat, animated: Bool) {
        surface?.select(center: center, animated: animated)
    }
}

struct WorkspaceContourSurface: NSViewRepresentable {
    var center: CGFloat
    var halfWidth: CGFloat
    var animated: Bool
    var highContrast: Bool
    let motion: WorkspaceContourMotion

    func makeNSView(context: Context) -> Host {
        let view = Host()
        motion.surface = view
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        motion.surface = view
        view.configure(center: center, halfWidth: halfWidth,
                       animated: animated, highContrast: highContrast)
    }

    final class Host: NSView {
        private let gradient = CAGradientLayer()
        private let contour = CAShapeLayer()
        private let dot = CAShapeLayer()
        private var halfWidth: CGFloat = 0
        private var targetCenter: CGFloat?
        private var previousSize: CGSize = .zero
        private var highContrast = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [0, 0.20, 0.80, 1]
            gradient.mask = contour
            contour.fillColor = nil
            contour.strokeColor = NSColor.white.cgColor
            contour.lineCap = .round
            dot.path = CGPath(ellipseIn: CGRect(x: -1.5, y: -1.5, width: 3, height: 3),
                              transform: nil)
            layer?.addSublayer(gradient)
            layer?.addSublayer(dot)
            setAccessibilityElement(false)
            colors()
        }
        required init?(coder: NSCoder) { nil }

        func configure(center: CGFloat, halfWidth: CGFloat, animated: Bool, highContrast: Bool) {
            self.halfWidth = halfWidth
            self.highContrast = highContrast
            colors()
            select(center: center, animated: animated)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            colors()
        }

        private func colors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let ink = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor.white : NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 52 / 255, alpha: 1)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                gradient.colors = [0.02, 0.80, 0.80, 0.02].map { ink.withAlphaComponent($0).cgColor }
                contour.lineWidth = highContrast ? 1.5 : 1.05
                dot.fillColor = ink.cgColor
                CATransaction.commit()
            }
        }

        override func layout() {
            super.layout()
            guard previousSize != bounds.size else { return }
            previousSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = bounds.height / 2
            gradient.frame = bounds
            contour.frame = bounds
            if let targetCenter { setModel(center: targetCenter) }
            contour.removeAnimation(forKey: "workspace-slide")
            dot.removeAnimation(forKey: "workspace-slide")
            CATransaction.commit()
        }

        private func setModel(center: CGFloat) {
            contour.path = WorkspaceSelectionContour(center: center, halfWidth: halfWidth).path(in: bounds).cgPath
            dot.position = CGPoint(x: center, y: bounds.height - 4.5)
        }

        func select(center: CGFloat, animated: Bool) {
            let previous = targetCenter
            targetCenter = center
            guard previous != center || !animated else { return }
            let oldPath = contour.presentation()?.path ?? contour.path
            let oldPosition = dot.presentation()?.position ?? dot.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setModel(center: center)
            contour.removeAnimation(forKey: "workspace-slide")
            dot.removeAnimation(forKey: "workspace-slide")
            if animated, previous != nil, bounds.width > 0, let oldPath {
                let start = CACurrentMediaTime()
                let shape = spring(keyPath: "path", begin: start)
                shape.fromValue = oldPath
                shape.toValue = contour.path
                let point = spring(keyPath: "position", begin: start)
                point.fromValue = NSValue(point: oldPosition)
                point.toValue = NSValue(point: dot.position)
                contour.add(shape, forKey: "workspace-slide")
                dot.add(point, forKey: "workspace-slide")
            }
            CATransaction.commit()
            // Do not defer the first visible response until page preparation ends.
            CATransaction.flush()
        }

        private func spring(keyPath: String, begin: CFTimeInterval) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = 500
            animation.damping = 44
            animation.initialVelocity = 0
            animation.duration = 0.38
            animation.beginTime = begin
            return animation
        }

        #if DEBUG
        var debugTargetCenter: CGFloat? { targetCenter }
        var debugVisibleCenter: CGFloat { dot.presentation()?.position.x ?? dot.position.x }
        var debugHasAnimation: Bool { contour.animation(forKey: "workspace-slide") != nil }
        #endif
    }
}

/// The requested mode is observed only by the small navigation bar. Preparation
/// failure or cancellation restores the committed selection in the same bar.
final class WorkspaceNavigationState: ObservableObject {
    @Published var requestedMode: WorkspaceMode?
}

struct WorkspaceNavigationBar: View {
    @Binding var selection: WorkspaceMode
    @ObservedObject var navigation: WorkspaceNavigationState
    var animationsEnabled = true
    var body: some View {
        WorkspaceModeSwitcher(selection: Binding(
            get: { navigation.requestedMode ?? selection },
            set: { selection = $0 }), animationsEnabled: animationsEnabled)
    }
}
