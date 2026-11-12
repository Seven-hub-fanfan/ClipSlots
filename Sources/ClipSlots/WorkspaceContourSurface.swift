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
        private let metal = WorkspaceMetalPlayback()
        private let silver = WorkspaceLightArch()
        private var darkAppearance = false
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
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let strength: CGFloat = highContrast ? 1 : dark ? 0.66 : 0.30
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
            light.addSublayer(metal.layer)
            light.addSublayer(silver.layer)
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
            for renderedLayer in [gradient, contour, contourOpacity, dot, light] {
                renderedLayer.contentsScale = scale
            }
            silver.scale(scale)
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
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                contour.lineWidth = highContrast ? 1.5 : dark ? 0.85 : 0.65
                dot.fillColor = ink.withAlphaComponent(highContrast ? 1 : 0.90).cgColor
                darkAppearance = dark
                metal.configure(kind: .arch, dark: true)
                metal.layer.isHidden = !dark
                silver.layer.isHidden = dark
                light.isHidden = highContrast
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
            metal.layer.frame = light.bounds
            silver.layout(in: light.bounds, halfWidth: halfWidth)
            if let targetCenter { setModel(center: targetCenter) }
            contour.removeAnimation(forKey: "workspace-slide")
            dot.removeAnimation(forKey: "workspace-slide")
            light.removeAnimation(forKey: "workspace-slide")
            gradient.removeAnimation(forKey: "workspace-ink")
            CATransaction.commit()
            updateLightMotion()
        }

        private func updateLightMotion() {
            let running = motionEnabled && !highContrast && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            // Hidden optics stay on the same compositor clock. Theme changes
            // only swap visibility rather than re-submitting color keyframes.
            metal.setRunning(running)
            silver.setRunning(running)
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
        var debugLightHasOrbit: Bool { darkAppearance ? metal.debugRunning : silver.running }
        var debugLightVisibleCenter: CGFloat { light.presentation()?.position.x ?? light.position.x }
        var debugLightIsHidden: Bool { light.isHidden }
        #endif
    }
}

/// Light mode has its own open, vector arch. The colored flank supports a
/// narrow white crest; neither a closed bottom edge nor a raster halo is added.
private final class WorkspaceLightArch {
    let layer = CALayer()
    private let flank = CAGradientLayer()
    private let bloom = CAGradientLayer()
    private let white = CAGradientLayer()
    private let flankMask = CAShapeLayer()
    private let bloomMask = CAShapeLayer()
    private let whiteMask = CAShapeLayer()
    private(set) var running = false
    private static let key = "workspace-silver-orbit"
    private static let palette: [[CGColor]] = (0..<150).map { frame in
        let phase = Double(frame) / 150 * .pi * 2
        return (0..<8).map { index in
            let x = CGFloat(index) / 7
            let hue = CGFloat(0.64 + 0.075 * sin(phase + Double(x) * 3))
            let alpha: CGFloat = [0, 0.38, 0.90, 1, 1, 0.90, 0.38, 0][index]
            return NSColor(calibratedHue: hue, saturation: 0.48,
                           brightness: 0.94, alpha: alpha).cgColor
        }
    }
    init() {
        layer.masksToBounds = false
        for (gradient, mask) in [(bloom, bloomMask), (flank, flankMask), (white, whiteMask)] {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [0, 0.22, 0.38, 0.48, 0.52, 0.62, 0.78, 1]
            gradient.mask = mask
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineCap = .round
            mask.lineJoin = .round
            layer.addSublayer(gradient)
        }
        flank.colors = Self.palette[66]
        bloom.colors = Self.palette[66]
        flankMask.lineWidth = 1.8
        bloomMask.lineWidth = 2.8
        bloomMask.shadowColor = NSColor.white.cgColor
        bloomMask.shadowOpacity = 1
        bloomMask.shadowRadius = 1.2
        bloomMask.shadowOffset = .zero
        bloom.opacity = 0.17
        whiteMask.lineWidth = 0.8
        white.colors = [0, 0, 0.24, 1, 1, 0.24, 0, 0].map {
            NSColor.white.withAlphaComponent(CGFloat($0)).cgColor
        }
    }
    func scale(_ scale: CGFloat) {
        for rendered in [layer, flank, bloom, white, flankMask, bloomMask, whiteMask] {
            rendered.contentsScale = scale
        }
    }
    func layout(in bounds: CGRect, halfWidth: CGFloat) {
        layer.frame = bounds
        let center = bounds.midX, bottom = bounds.maxY - 9.5, top = bounds.minY + 9.5
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
        for (gradient, mask) in [(bloom, bloomMask), (flank, flankMask), (white, whiteMask)] {
            gradient.frame = layer.bounds
            mask.frame = gradient.bounds
            mask.path = path
        }
    }
    func setRunning(_ running: Bool) {
        self.running = running
        for gradient in [flank, bloom] {
            if !running {
                if let colors = gradient.presentation()?.colors { gradient.colors = colors }
                gradient.removeAnimation(forKey: Self.key)
            } else if gradient.animation(forKey: Self.key) == nil {
                let animation = CAKeyframeAnimation(keyPath: "colors")
                animation.values = Self.palette + [Self.palette[0]]
                animation.keyTimes = (0...150).map { NSNumber(value: Double($0) / 150) }
                animation.duration = WorkspaceMetalMaterial.cycle
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                animation.beginTime = gradient.convertTime(WorkspaceMetalMaterial.epoch, from: nil)
                gradient.add(animation, forKey: Self.key)
            }
        }
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
