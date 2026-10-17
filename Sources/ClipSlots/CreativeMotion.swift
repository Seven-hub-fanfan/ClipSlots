import AppKit
import SwiftUI
import QuartzCore
import CoreImage

/// Timings measured from the supplied recording and checked against the public
/// frontend. Animations live on compositor layers, never on a published frame clock.
enum CreativeMotion {
    static let entranceDuration = 2.5
    static let morphDuration = 3.44
    static let breathDuration = 2.0
    static let refreshDuration = 0.6
    static let blue = NSColor(srgbRed: 144 / 255, green: 196 / 255, blue: 229 / 255, alpha: 1)
    static let lightBlue = NSColor(srgbRed: 144 / 255, green: 200 / 255, blue: 1, alpha: 1)
    static let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    static let refresh = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: refreshDuration)

    static func keyframes(_ key: String, values: [Any], times: [NSNumber],
                          duration: Double, repeats: Bool = false) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.timingFunctions = Array(repeating: curve, count: max(0, values.count - 1))
        animation.repeatCount = repeats ? .infinity : 0
        // ProMotion may otherwise choose a lower cadence for slow morphs.
        // The compositor clamps this preference to the current display's limits.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        return animation
    }

    /// One eased progress clock across all stops, baked once for compositor
    /// playback. Segment easing changes both the fade-out and breathing rhythm.
    static func easedKeyframes(_ key: String, values: [Double], times: [Double],
                               duration: Double, repeats: Bool = false,
                               curve: CAMediaTimingFunction) -> CAKeyframeAnimation {
        var c1 = [Float](repeating: 0, count: 2), c2 = c1
        curve.getControlPoint(at: 1, values: &c1); curve.getControlPoint(at: 2, values: &c2)
        func cubic(_ t: Double, _ a: Float, _ b: Float) -> Double {
            3 * (1 - t) * (1 - t) * t * Double(a) + 3 * (1 - t) * t * t * Double(b) + t * t * t
        }
        let samples = (0...300).map { frame -> Double in
            let progress = Double(frame) / 300
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let middle = (lo + hi) / 2
                if cubic(middle, c1[0], c2[0]) < progress { lo = middle } else { hi = middle }
            }
            let phase = cubic((lo + hi) / 2, c1[1], c2[1])
            let i = (0..<times.count - 1).first { phase <= times[$0 + 1] } ?? times.count - 2
            let fraction = (phase - times[i]) / (times[i + 1] - times[i])
            return values[i] + fraction * (values[i + 1] - values[i])
        }
        let animation = keyframes(key, values: samples,
            times: (0...300).map { NSNumber(value: Double($0) / 300) }, duration: duration, repeats: repeats)
        animation.timingFunctions = nil
        return animation
    }
    static func entranceOpacity(_ values: [Double], times: [Double],
                                curve: CAMediaTimingFunction) -> CAKeyframeAnimation {
        easedKeyframes("opacity", values: values, times: times, duration: entranceDuration, curve: curve)
    }
    static let borderEntrance = entranceOpacity([0.85, 1, 0.7, 0],
        times: [0, 0.2, 0.7, 1], curve: CAMediaTimingFunction(name: .easeInEaseOut))
    static let bottomEntrance = entranceOpacity([0.95, 0.9, 0.45, 0],
        times: [0, 0.35, 0.75, 1], curve: CAMediaTimingFunction(name: .easeInEaseOut))
    static let sweepEntrance = entranceOpacity([0.95, 1, 0.85, 0],
        times: [0, 0.26, 0.72, 1], curve: curve)
    static let loadingBreath = easedKeyframes("transform.scale", values: [0.95, 1.05, 0.95],
        times: [0, 0.5, 1], duration: breathDuration, repeats: true,
        curve: CAMediaTimingFunction(name: .easeInEaseOut))

    private static let contourBasis: [[Double]] = (0..<64).map { i in
        let angle = Double(i) * .pi * 2 / 64
        var row = [1.0]
        for harmonic in 1...CreativeLoadingGeometry.harmonics {
            let theta = angle * Double(harmonic)
            row.append(cos(theta)); row.append(sin(theta))
        }
        return row
    }
    static let unitLoadingPaths = (0...86).map { loadingPath(phase: Double($0) / 86, size: 1) }

    /// Periodic radial contours measured from the supplied recording. The
    /// B-spline is continuous at the loop seam; all paths share 64 cubic segments.
    /// Trigonometry is cached once, and only layer paths change during playback.
    static func loadingPath(phase: Double, size: CGFloat) -> CGPath {
        let controls = CreativeLoadingGeometry.controls
        let t = (phase.isFinite ? min(1, max(0, phase)) : 0) * Double(controls.count)
        let index = Int(t), u = t - Double(index)
        let w0 = pow(1 - u, 3) / 6
        let w1 = (3 * u * u * u - 6 * u * u + 4) / 6
        let w2 = (-3 * u * u * u + 3 * u * u + 3 * u + 1) / 6
        let w3 = u * u * u / 6
        let weights = [w0, w1, w2, w3]
        var coefficients = Array(repeating: 0.0, count: 1 + 2 * CreativeLoadingGeometry.harmonics)
        for j in 0..<4 {
            let row = controls[(index + j - 1 + controls.count) % controls.count]
            for k in coefficients.indices { coefficients[k] += row[k] * weights[j] }
        }
        var points: [CGPoint] = []; points.reserveCapacity(64)
        for i in 0..<64 {
            let basis = contourBasis[i]
            let radius = zip(coefficients, basis).reduce(0.0) { $0 + $1.0 * $1.1 }
            points.append(CGPoint(x: (0.5 + radius * basis[1]) * size,
                                  y: (0.5 + radius * basis[2]) * size))
        }
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 0..<points.count {
            let p0 = points[(i + 63) % 64], p1 = points[i]
            let p2 = points[(i + 1) % 64], p3 = points[(i + 2) % 64]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    /// Blur radii stay in points at every composer width. Transparent padding
    /// retains the filter tail; a separate rounded layer clips it at the input.
    static let textureQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "clipslots.creative.glow"
        queue.qualityOfService = .userInitiated; queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private static let textureCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>(); cache.countLimit = 12
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    static func gradientTexture(width: CGFloat, sweep: Bool, light: Bool = false) -> CGImage? {
        let key = "\(width)-\(sweep)-\(light)" as NSString
        if let cached = textureCache.object(forKey: key) { return cached }
        if light {
            // Recolor the finished alpha mask without changing its blur, extent
            // or strength. Source-in retains exactly the original coverage.
            guard let original = gradientTexture(width: width, sweep: sweep),
                  let context = CGContext(data: nil, width: original.width, height: original.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: original.width, height: original.height)
            context.draw(original, in: rect)
            context.setBlendMode(.sourceIn)
            context.setFillColor(lightBlue.cgColor)
            context.fill(rect)
            guard let result = context.makeImage() else { return nil }
            textureCache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
            return result
        }
        let height: CGFloat = sweep ? 178 : 118, blur: CGFloat = sweep ? 24 : 20
        let padding = blur * 3, scale: CGFloat = 2
        let pixelsWide = Int(ceil((width + 2 * padding) * scale))
        let pixelsHigh = Int((height + 2 * padding) * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Bitmap contexts use a bottom-left origin; layer contents use top-left.
        // Keep the CSS gradient's 64%/100% centers near the input's lower edge.
        context.translateBy(x: 0, y: height + 2 * padding); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: padding, y: padding)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if sweep { context.addEllipse(in: rect); context.clip() } else { context.clip(to: rect) }
        if sweep, let linear = CGGradient(colorsSpace: space, colors: [
            blue.withAlphaComponent(0).cgColor, blue.withAlphaComponent(36 / 255).cgColor,
            blue.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.54, 1]) {
            context.drawLinearGradient(linear, start: .zero, end: .init(x: 0, y: height), options: [])
        }
        let alphas: [CGFloat] = sweep ? [CGFloat(179) / 255, CGFloat(102) / 255, CGFloat(31) / 255, 0] : [0.4, 0.2, 0]
        let locations: [CGFloat] = sweep ? [0, 0.24, 0.46, 0.7] : [0, 0.34, 0.72]
        guard let radial = CGGradient(colorsSpace: space, colors: alphas.map { blue.withAlphaComponent($0).cgColor } as CFArray,
                                       locations: locations) else { return nil }
        let centerY: CGFloat = sweep ? 0.64 : 1
        context.translateBy(x: width / 2, y: height * centerY)
        // CSS ellipse/farthest-corner: expand the side ellipse by sqrt(2).
        context.scaleBy(x: width / 2 * sqrt(2), y: height * centerY * sqrt(2))
        context.drawRadialGradient(radial, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: 1, options: [])
        guard let image = context.makeImage() else { return nil }
        let blurred = CIImage(cgImage: image).applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur * scale])
        guard let result = imageContext.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)) else { return nil }
        textureCache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
        return result
    }
}

/// Stops all repeating work when detached, hidden, occluded, or offscreen.
/// The noninteractive backing view cannot steal composer focus or canvas gestures.
class CreativeMotionHost: NSView {
    var reduceMotion = false
    var enabled = true
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSView.boundsDidChangeNotification] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.synchronize()
            }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in self?.synchronize() }))
        synchronize()
    }
    override func layout() { super.layout(); synchronize() }
    override func viewDidHide() { super.viewDidHide(); synchronize() }
    override func viewDidUnhide() { super.viewDidUnhide(); synchronize() }
    var mayAnimate: Bool {
        enabled && !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty && !NSApp.isHidden
    }
    func synchronize() {}
    deinit { for (center, token) in observers { center.removeObserver(token) } }
}

struct CreativeLoadingMark: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var active = true
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.reduceMotion = reduceMotion; view.enabled = active
        view.shape.fillColor = (scheme == .dark ? NSColor.white : NSColor(white: 0.16, alpha: 1)).cgColor
        view.synchronize()
    }
    final class Host: CreativeMotionHost {
        let shape = CAShapeLayer()
        private var pathSize: CGFloat = 0
        private var paths: [CGPath] = []
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.addSublayer(shape)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func synchronize() {
            let size = min(bounds.width, bounds.height)
            guard size > 0 else { shape.removeAllAnimations(); return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shape.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            shape.contentsScale = window?.backingScaleFactor ?? 2
            if pathSize != size {
                pathSize = size
                var transform = CGAffineTransform(scaleX: size, y: size)
                paths = CreativeMotion.unitLoadingPaths.compactMap { $0.copy(using: &transform) }
                shape.removeAllAnimations()
                shape.path = CreativeMotion.loadingPath(phase: 0.3, size: size)
            }
            CATransaction.commit()
            guard mayAnimate else { shape.removeAllAnimations(); return }
            startAnimations()
        }
        func startAnimations() {
            guard !paths.isEmpty else { return }
            guard shape.animation(forKey: "morph") == nil else { return }
            let morph = CreativeMotion.keyframes("path", values: paths,
                times: (0...86).map { NSNumber(value: Double($0) / 86) }, duration: CreativeMotion.morphDuration, repeats: true)
            morph.timingFunctions = nil // Linear between the 40ms samples; poses already use smooth easing.
            shape.add(morph, forKey: "morph")
            shape.add(CreativeMotion.loadingBreath, forKey: "breath")
        }
    }
}

struct ComposerEntranceGlow: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    let token: String
    let active: Bool
    var repeating = false
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        let changed = view.token != token
        if changed { view.token = token; view.hasPlayed = false; view.stop() }
        view.repeating = repeating
        view.enabled = active; view.reduceMotion = reduceMotion
        view.isLight = scheme == .light
        view.reduceTransparency = reduceTransparency
        view.increasedContrast = contrast == .increased
        view.synchronize()
        // #region debug-point A-C:composer-appearance
        #if DEBUG
        if changed, let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_DEBUG_URL"],
           let url = URL(string: endpoint) {
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "sessionId": "light-agent-halo", "runId": ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_RUN"] ?? "pre-fix",
                "hypothesisId": "A-C", "msg": "[DEBUG] Composer appearance at session entrance",
                "data": ["scheme": context.environment.colorScheme == .dark ? "dark" : "light",
                         "active": active, "width": view.bounds.width,
                         "insetOpacity": view.inset.sublayers?.last?.shadowOpacity ?? -1,
                         "washOpacity": view.wash.opacity,
                         "blue": (view.isLight ? CreativeMotion.lightBlue : CreativeMotion.blue).description,
                         "textureReady": view.sweep.contents != nil]])
            URLSession.shared.dataTask(with: request).resume()
        }
        #endif
        // #endregion
    }
    final class Host: CreativeMotionHost {
        let glow = CALayer(), inner = CALayer(), bottom = CALayer(), sweep = CALayer()
        let inset = CALayer()
        let wash = CALayer()
        private let insetTop = CALayer(), insetBottom = CALayer()
        private let outerShadow = CALayer(), innerShadow = CALayer()
        private let outerShadowMask = CAShapeLayer(), innerShadowMask = CAShapeLayer()
        private var shadowSize: CGSize = .zero
        private var textureWidth: CGFloat = 0
        private var textureRequest: BlockOperation?
        private var textureVariants: [Bool: (bottom: CGImage, sweep: CGImage)] = [:]
        private var appliedLightTexture: Bool?
        var token = ""
        var hasPlayed = false
        var repeating = false
        var isLight = false
        var reduceTransparency = false
        var increasedContrast = false
        private var suppressDecoration: Bool {
            reduceTransparency || increasedContrast
                || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            for item in [glow, inner, inset, wash] { layer?.addSublayer(item) }
            for item in [bottom, sweep] { wash.addSublayer(item) }
            for item in [glow, inner, inset, bottom, sweep] { item.opacity = 0 }
            wash.cornerRadius = 16; wash.masksToBounds = true
            for mask in [outerShadowMask, innerShadowMask] {
                mask.fillRule = .evenOdd; mask.fillColor = NSColor.white.cgColor
            }
            glow.addSublayer(outerShadow); inner.addSublayer(innerShadow)
            glow.mask = outerShadowMask; inner.mask = innerShadowMask
            inset.cornerRadius = 16; inset.masksToBounds = true
            inset.borderColor = CreativeMotion.blue.withAlphaComponent(0.18).cgColor
            inset.borderWidth = 1
            inset.addSublayer(insetBottom); inset.addSublayer(insetTop)
            insetTop.shadowColor = NSColor(srgbRed: 130 / 255, green: 169 / 255, blue: 198 / 255, alpha: 1).cgColor
            insetTop.shadowOpacity = 0.27; insetTop.shadowOffset = CGSize(width: 0, height: 4)
            insetBottom.shadowColor = NSColor.white.cgColor
            insetBottom.shadowOpacity = 0.15; insetBottom.shadowOffset = CGSize(width: 0, height: -2)
            for shadow in [insetTop, insetBottom] { shadow.shadowRadius = 2 }
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        func stop() {
            for item in [glow, inner, inset, bottom, sweep] { item.removeAllAnimations() }
            if repeating { hasPlayed = false }
        }
        private func updatePalette() {
            let blue = isLight ? CreativeMotion.lightBlue : CreativeMotion.blue
            wash.opacity = 1
            inset.borderColor = blue.withAlphaComponent(0.18).cgColor
            insetTop.shadowColor = (isLight ? blue :
                NSColor(srgbRed: 130 / 255, green: 169 / 255, blue: 198 / 255, alpha: 1)).cgColor
            insetTop.shadowOpacity = 0.27
            insetBottom.shadowOpacity = 0.15
            outerShadow.shadowColor = blue.cgColor
            outerShadow.shadowOpacity = 0.22
            innerShadow.shadowOpacity = 0.25
            if appliedLightTexture != isLight, let textures = textureVariants[isLight] {
                bottom.contents = textures.bottom; sweep.contents = textures.sweep
                appliedLightTexture = isLight
            }
        }
        private func layoutShadows() {
            guard shadowSize != bounds.size else { return }
            shadowSize = bounds.size
            // The reference halo extends one point beyond the input. Exterior
            // shadows and interior shadows meet at this same rounded boundary.
            glow.frame = bounds.insetBy(dx: -96, dy: -96)
            inner.frame = glow.frame
            let inputRect = CGRect(x: 95, y: 95, width: bounds.width + 2, height: bounds.height + 2)
            for shadow in [outerShadow, innerShadow] { shadow.frame = inputRect }
            outerShadow.shadowPath = CGPath(roundedRect: outerShadow.bounds.insetBy(dx: -1, dy: -1),
                                           cornerWidth: 17, cornerHeight: 17, transform: nil)
            innerShadow.shadowPath = CGPath(roundedRect: innerShadow.bounds,
                                           cornerWidth: 16, cornerHeight: 16, transform: nil)
            outerShadow.shadowOffset = CGSize(width: 0, height: 10)
            // CSS blur is twice the Gaussian radius used by Core Animation.
            outerShadow.shadowRadius = 15
            innerShadow.shadowColor = NSColor(srgbRed: 211 / 255, green: 230 / 255, blue: 1, alpha: 1).cgColor
            innerShadow.shadowOffset = CGSize(width: 0, height: 5)
            innerShadow.shadowRadius = 5.7
            for mask in [outerShadowMask, innerShadowMask] {
                mask.frame = glow.bounds
                let cutout = CGMutablePath()
                cutout.addRect(mask.bounds)
                cutout.addRoundedRect(in: inputRect, cornerWidth: 16, cornerHeight: 16)
                mask.path = cutout
            }
            inset.frame = bounds.insetBy(dx: -1, dy: -1)
            let inverse = CGMutablePath()
            inverse.addRect(inset.bounds.insetBy(dx: -32, dy: -32))
            let hole = CGPath(roundedRect: inset.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
            // Reverse the symmetric rounded path so nonzero winding leaves a
            // hole. Its shadow falls inward; the parent clips the exterior.
            inverse.addPath(hole, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                               tx: inset.bounds.width, ty: 0))
            for shadow in [insetTop, insetBottom] {
                shadow.frame = inset.bounds; shadow.shadowPath = inverse
            }
        }
        override func synchronize() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            updatePalette()
            layer?.isHidden = suppressDecoration
            CATransaction.commit()
            guard !suppressDecoration else { stop(); textureRequest?.cancel(); textureWidth = 0; return }
            guard bounds.width > 0, bounds.height > 0 else {
                stop(); textureRequest?.cancel(); textureWidth = 0
                return
            }
            let width = ceil(bounds.width / 16) * 16
            if textureWidth != width {
                textureWidth = width
                textureRequest?.cancel()
                let request = BlockOperation()
                request.addExecutionBlock { [weak self, weak request] in
                    guard request?.isCancelled == false else { return }
                    var variants: [Bool: (bottom: CGImage, sweep: CGImage)] = [:]
                    for light in [false, true] {
                        guard request?.isCancelled == false,
                              let bottom = CreativeMotion.gradientTexture(width: width + 96, sweep: false, light: light),
                              let sweep = CreativeMotion.gradientTexture(width: width * 1.66, sweep: true, light: light)
                        else { return }
                        variants[light] = (bottom, sweep)
                    }
                    let completedVariants = variants
                    DispatchQueue.main.async { [weak self, weak request] in
                        guard let self, let request, !request.isCancelled,
                              self.textureRequest === request, self.textureWidth == width else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        self.textureVariants = completedVariants; self.appliedLightTexture = nil
                        self.updatePalette()
                        CATransaction.commit()
                        self.synchronize()
                    }
                }
                textureRequest = request
                CreativeMotion.textureQueue.addOperation(request)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // AppKit can restore backing-layer clipping when the view mounts.
            // Keep the exterior halo visible; the wash has its own inner clip.
            clipsToBounds = false; layer?.masksToBounds = false
            layoutShadows()
            wash.frame = bounds
            bottom.frame = CGRect(x: -108, y: bounds.height - 122, width: width + 216, height: 238)
            sweep.frame = CGRect(x: -72, y: -80, width: width * 1.66 + 144, height: 322)
            CATransaction.commit()
            guard mayAnimate else { stop(); return }
            startEntrance()
        }
        func startEntrance() {
            guard !hasPlayed, !suppressDecoration, !reduceMotion,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  bottom.contents != nil, sweep.contents != nil else { return }
            hasPlayed = true
            func play(_ animation: CAAnimation, on layer: CALayer, key: String) {
                guard let copy = animation.copy() as? CAAnimation else { return }
                if repeating { copy.repeatCount = .infinity }
                layer.add(copy, forKey: key)
            }
            for item in [glow, inner, inset] {
                play(CreativeMotion.borderEntrance, on: item, key: "entrance")
            }
            play(CreativeMotion.bottomEntrance, on: bottom, key: "entrance")
            play(CreativeMotion.sweepEntrance, on: sweep, key: "entrance")
            play(CreativeMotion.keyframes("transform.translation.x",
                values: [-0.72, -0.36, 0.18, 0.78].map { $0 * textureWidth * 1.66 },
                times: [0, 0.26, 0.72, 1], duration: CreativeMotion.entranceDuration), on: sweep, key: "sweep")
        }
        deinit { textureRequest?.cancel() }
    }
}

struct CreativeWelcomeReveal: ViewModifier {
    let token: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: visible)
            .task(id: token) {
                visible = false
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(750)) }
                guard !Task.isCancelled else { return }
                visible = true
            }
    }
}

/// State stays in each card; refreshing suggestions never animates the transcript.
struct CreativeSuggestionCard: View {
    // #region debug-point C:card-body-count
    #if DEBUG
    static var debugBodyCount = 0
    #endif
    // #endregion
    let category: String
    let symbol: String
    let title: String
    let detail: String
    let index: Int
    let compact: Bool
    let fill: Color
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var hovered = false
    var body: some View {
        // #region debug-point C:card-body-count
        #if DEBUG
        let _ = { if ProcessInfo.processInfo.environment["CLIPSLOTS_CREATIVE_PROBE"] == "1" { Self.debugBodyCount += 1 } }()
        #endif
        // #endregion
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(category, systemImage: symbol).font(.system(size: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 11))
                }.foregroundColor(TapSkin.faintInk)
                Text(title).font(.system(size: 14, weight: .medium))
                    .foregroundColor(TapSkin.ink).lineLimit(2)
                    .modifier(RevealText(visible: revealed, delay: Double(index) * 0.08, reduceMotion: reduceMotion))
                Text(detail).font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk).lineLimit(2)
                    .modifier(RevealText(visible: revealed, delay: Double(index) * 0.08 + 0.15, reduceMotion: reduceMotion))
            }
            .multilineTextAlignment(.leading).padding(14)
            .frame(maxWidth: .infinity, minHeight: compact ? 108 : 140, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(fill, in: RoundedRectangle(cornerRadius: 16))
            .overlay { CreativeCardHighlight(hovered: $hovered) }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(TapSkin.tone(0xe0e1e5, 0x2b2b2b), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(index == 0 ? -2.25 : 1.75))
        .offset(y: hovered && !reduceMotion ? -3 : 0)
        .scaleEffect(hovered && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hovered)
        .accessibilityLabel(title).help("填入输入框，编辑后发送")
        .task(id: title) {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { revealed = false }
            await Task.yield()
            guard !Task.isCancelled else { return }
            revealed = true
        }
    }
    private struct RevealText: ViewModifier {
        let visible: Bool
        let delay: Double
        let reduceMotion: Bool
        func body(content: Content) -> some View {
            content.drawingGroup()
                .opacity(visible || reduceMotion ? 1 : 0)
                .blur(radius: visible || reduceMotion ? 0 : 4)
                .offset(y: visible || reduceMotion ? 0 : 4)
                .animation(reduceMotion || !visible ? nil : CreativeMotion.refresh.delay(delay), value: visible)
        }
    }
}
