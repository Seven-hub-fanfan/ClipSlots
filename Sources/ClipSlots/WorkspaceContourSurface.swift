import AppKit
import SwiftUI
import QuartzCore

/// The render server advances these layers even while the main thread is
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
        private let contourOpacity = CAGradientLayer()
        private let dot = CAShapeLayer()
        private let light = CALayer()
        private let lightBands = (0..<3).map { _ in CALayer() }
        private let lightMasks = (0..<3).map { _ in CAShapeLayer() }
        private let prisms = (0..<3).map { _ in CAGradientLayer() }
        private var halfWidth: CGFloat = 0
        private var targetCenter: CGFloat?
        private var previousSize: CGSize = .zero
        private var highContrast = false
        private var motionEnabled = false
        private var windowObservers: [NSObjectProtocol] = []
        private var visibilityObservation: NSKeyValueObservation?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func gradientColors(center: CGFloat?) -> [CGColor] {
            let ink = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white : NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 52 / 255, alpha: 1)
            // Keep the last arch out of the fixed right fade, preserving the
            // existing rail fade for the first two selections.
            let trailingArch = center.map { $0 - halfWidth * 0.34 > bounds.width * 0.72 } ?? false
            let stops: [CGFloat] = trailingArch ? [0, 0.42, 1, 1, 1, 1] : [0, 0.42, 1, 1, 0.42, 0]
            let strength: CGFloat = highContrast ? 1 : 0.66
            return stops.map { ink.withAlphaComponent($0 * strength).cgColor }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            // Let the small bloom breathe above the arch without enlarging the
            // navigation's hit area or tinting the capsule's other segments.
            layer?.masksToBounds = false
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [0, 0.12, 0.28, 0.72, 0.88, 1]
            gradient.mask = contour
            contour.fillColor = nil
            contour.strokeColor = NSColor.white.cgColor
            contour.lineCap = .round
            contour.lineJoin = .round
            // Keep the arch readable while the horizontal rails settle into
            // the surface instead of competing with the capsule's hairline.
            contourOpacity.startPoint = CGPoint(x: 0.5, y: 0)
            contourOpacity.endPoint = CGPoint(x: 0.5, y: 1)
            contourOpacity.locations = [0, 0.55, 1]
            contour.mask = contourOpacity
            dot.path = CGPath(ellipseIn: CGRect(x: -1.5, y: -1.5, width: 3, height: 3),
                              transform: nil)
            layer?.addSublayer(gradient)
            for index in prisms.indices {
                let prism = prisms[index], mask = lightMasks[index], band = lightBands[index]
                prism.type = .conic
                prism.startPoint = CGPoint(x: 0.5, y: 0.5)
                prism.endPoint = CGPoint(x: 0.5, y: 0)
                prism.locations = [0, 0.06, 0.10, 0.135, 0.16, 0.19, 0.22, 0.26, 0.32, 0.40,
                                   0.50, 0.56, 0.60, 0.635, 0.66, 0.69, 0.72, 0.76, 0.82, 0.90, 1]
                mask.fillColor = nil
                mask.strokeColor = NSColor.white.cgColor
                mask.lineCap = .round
                mask.lineJoin = .round
                band.addSublayer(prism)
                band.mask = mask
                light.addSublayer(band)
            }
            layer?.addSublayer(light)
            layer?.addSublayer(dot)
            setAccessibilityElement(false)
            colors()
        }
        required init?(coder: NSCoder) { nil }
        deinit {
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func configure(center: CGFloat, halfWidth: CGFloat, animated: Bool, highContrast: Bool) {
            let geometryChanged = self.halfWidth != halfWidth
            self.halfWidth = halfWidth
            self.highContrast = highContrast
            motionEnabled = animated
            colors()
            if geometryChanged { previousSize = .zero; needsLayout = true }
            select(center: center, animated: animated)
            updateLightMotion()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            colors()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
            windowObservers = []
            visibilityObservation = window?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                self?.updateLightMotion()
            }
            if let window {
                for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didChangeOcclusionStateNotification] {
                    windowObservers.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in self?.updateLightMotion() })
                }
            }
            updateBackingScale()
            updateLightMotion()
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateLightMotion()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateLightMotion()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateBackingScale()
        }

        private func updateBackingScale() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for renderedLayer in [gradient, contour, contourOpacity, dot, light]
                + lightBands + lightMasks + prisms {
                renderedLayer.contentsScale = scale
            }
            CATransaction.commit()
        }

        private func colors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let ink = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor.white : NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 52 / 255, alpha: 1)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                gradient.colors = gradientColors(center: targetCenter)
                contourOpacity.colors = (highContrast ? [1, 1, 0.72] : [1, 0.90, 0.22]).map {
                    NSColor.white.withAlphaComponent(CGFloat($0)).cgColor
                }
                contour.lineWidth = highContrast ? 1.5 : 0.85
                dot.fillColor = ink.withAlphaComponent(highContrast ? 1 : 0.90).cgColor
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // Two compact white highlights with cyan, amber and violet
                // fringes. The low-alpha stretches keep this from reading as
                // a uniformly illuminated rainbow outline.
                let spectrum: [(UInt32, CGFloat)] = [
                    (0x303a82, 0.12), (0x4156cf, 0.32), (0x23cfff, 0.90),
                    (0xc3f5ff, 1), (0xffffff, 1), (0xfff4ca, 1),
                    (0xffb948, 0.95), (0xee72c9, 0.72), (0x6650d7, 0.36),
                    (0x29377c, 0.12)
                ]
                let cycle = spectrum + spectrum + [spectrum[0]]
                let colors = cycle.map { hex, alpha in
                    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                            green: CGFloat((hex >> 8) & 255) / 255,
                            blue: CGFloat(hex & 255) / 255,
                            alpha: alpha * (dark ? 1 : 0.92)).cgColor
                }
                for index in prisms.indices {
                    prisms[index].colors = colors
                    lightMasks[index].lineWidth = [7, 3.5, 1.6][index]
                    lightBands[index].opacity = highContrast ? 0
                        : (dark ? [0.12, 0.28, 1] : [0.055, 0.16, 1])[index]
                }
                CATransaction.commit()
            }
            updateLightMotion()
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
            contourOpacity.frame = contour.bounds
            let lightSize = CGSize(width: halfWidth * 2 + 16, height: bounds.height + 16)
            light.bounds = CGRect(origin: .zero, size: lightSize)
            let square = max(lightSize.width, lightSize.height) + 8
            for index in prisms.indices {
                lightBands[index].frame = light.bounds
                lightMasks[index].frame = light.bounds
                prisms[index].bounds = CGRect(x: 0, y: 0, width: square, height: square)
                prisms[index].position = CGPoint(x: lightSize.width / 2, y: lightSize.height / 2)
                lightMasks[index].path = activeLightPath(in: light.bounds.insetBy(dx: 8, dy: 8))
            }
            if let targetCenter { setModel(center: targetCenter) }
            contour.removeAnimation(forKey: "workspace-slide")
            dot.removeAnimation(forKey: "workspace-slide")
            light.removeAnimation(forKey: "workspace-slide")
            gradient.removeAnimation(forKey: "workspace-ink")
            CATransaction.commit()
            updateLightMotion()
        }

        private func activeLightPath(in rect: CGRect) -> CGPath {
            let center = rect.midX, bottom = rect.maxY - 1.5, top = rect.minY + 1.5
            let crown = halfWidth * 0.34
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center - halfWidth, y: bottom))
            path.addCurve(to: CGPoint(x: center - crown, y: top),
                          control1: CGPoint(x: center - halfWidth * 0.52, y: bottom),
                          control2: CGPoint(x: center - halfWidth * 0.78, y: top))
            path.addLine(to: CGPoint(x: center + crown, y: top))
            path.addCurve(to: CGPoint(x: center + halfWidth, y: bottom),
                          control1: CGPoint(x: center + halfWidth * 0.78, y: top),
                          control2: CGPoint(x: center + halfWidth * 0.52, y: bottom))
            path.closeSubpath()
            return path
        }

        private func updateLightMotion() {
            let running = motionEnabled && !highContrast && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            let start = CACurrentMediaTime()
            for prism in prisms {
                if running {
                    guard prism.animation(forKey: "workspace-light-orbit") == nil else { continue }
                    let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
                    orbit.fromValue = 0
                    orbit.toValue = CGFloat.pi * 2
                    orbit.duration = 5
                    orbit.repeatCount = .infinity
                    orbit.timingFunction = CAMediaTimingFunction(name: .linear)
                    // All three bands share a clock, including when restored
                    // after occlusion. Selection never restarts the orbit.
                    orbit.beginTime = start
                    prism.add(orbit, forKey: "workspace-light-orbit")
                } else {
                    prism.removeAnimation(forKey: "workspace-light-orbit")
                }
            }
        }

        private func setModel(center: CGFloat) {
            gradient.colors = gradientColors(center: center)
            contour.path = WorkspaceSelectionContour(center: center, halfWidth: halfWidth).path(in: bounds).cgPath
            dot.position = CGPoint(x: center, y: bounds.height - 4.5)
            light.position = CGPoint(x: center, y: bounds.midY)
        }

        func select(center: CGFloat, animated: Bool) {
            let previous = targetCenter
            targetCenter = center
            guard previous != center || !animated else { return }
            let oldPath = contour.presentation()?.path ?? contour.path
            let oldPosition = dot.presentation()?.position ?? dot.position
            let oldLightPosition = light.presentation()?.position ?? light.position
            let oldColors = gradient.presentation()?.colors ?? gradient.colors
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setModel(center: center)
            contour.removeAnimation(forKey: "workspace-slide")
            dot.removeAnimation(forKey: "workspace-slide")
            light.removeAnimation(forKey: "workspace-slide")
            gradient.removeAnimation(forKey: "workspace-ink")
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
                let glow = spring(keyPath: "position", begin: start)
                glow.fromValue = NSValue(point: oldLightPosition)
                glow.toValue = NSValue(point: light.position)
                light.add(glow, forKey: "workspace-slide")
                let ink = CABasicAnimation(keyPath: "colors")
                ink.fromValue = oldColors
                ink.toValue = gradient.colors
                ink.duration = shape.duration
                ink.beginTime = start
                ink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gradient.add(ink, forKey: "workspace-ink")
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
        var debugLightHasOrbit: Bool { prisms.allSatisfy { $0.animation(forKey: "workspace-light-orbit") != nil } }
        var debugLightVisibleCenter: CGFloat { light.presentation()?.position.x ?? light.position.x }
        var debugLightIsHidden: Bool { lightBands.allSatisfy { $0.opacity == 0 } }
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
