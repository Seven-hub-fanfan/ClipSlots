import AppKit
import SwiftUI
import QuartzCore
import ImageIO
import ClipSlotsKit

/// A compact angular palette from B's reference, rather than another RGBA
/// atlas of the full navigation bar. Core Animation interpolates the colors.
private enum WorkspaceRimPalette {
    static let stops = 128
    static let count = 150
    static let posterIndex = 66
    static let url = WorkspaceBrandResources.markURL?.deletingLastPathComponent()
        .appendingPathComponent("NavigationMetal/outer-rim-spectrum.png")
    private static let queue = DispatchQueue(label: "clipslots.navigation-rim", qos: .userInitiated)
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let pixels: [UInt8]? = {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == stops, image.height == count else { return nil }
        var bytes = [UInt8](repeating: 0, count: stops * count * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: stops, height: count,
                bitsPerComponent: 8, bytesPerRow: stops * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: stops, height: count))
            return true
        }
        return rendered ? bytes : nil
    }()
    final class Frames {
        let colors: [[CGColor]]
        let lightColors: [[CGColor]]
        init(_ colors: [[CGColor]]) {
            self.colors = colors
            lightColors = colors.map(WorkspaceRimPalette.lightColors)
        }
    }
    static func lightColors(_ colors: [CGColor]) -> [CGColor] {
        colors.map { color in
            let values = color.components ?? [0, 0, 0, 1]
            let peak = max(values[0], values[1], values[2])
            // Black in the sampled spectrum means absence of light. On a
            // white surface it must be transparent rather than a dark stripe.
            return CGColor(colorSpace: colorSpace, components: [
                0.62 + values[0] * 0.38, 0.62 + values[1] * 0.38,
                0.62 + values[2] * 0.38, peak
            ])!
        }
    }
    private static var cached: Frames?
    static func colors(at frame: Int) -> [CGColor]? {
        guard let pixels else { return nil }
        let row = max(0, min(count - 1, frame)) * stops * 4
        let colors = (0..<stops).map { index -> CGColor in
            let offset = row + index * 4
            return CGColor(colorSpace: colorSpace, components: [
                CGFloat(pixels[offset]) / 255, CGFloat(pixels[offset + 1]) / 255,
                CGFloat(pixels[offset + 2]) / 255, 1
            ])!
        }
        return colors + [colors[0]]
    }
    static func load(completion: @escaping (Frames?) -> Void) {
        queue.async {
            if cached == nil {
                let palette = (0..<count).compactMap { colors(at: $0) }
                if palette.count == count { cached = Frames(palette) }
            }
            let frames = cached
            DispatchQueue.main.async { completion(frames) }
        }
    }
}

struct WorkspaceOuterRim: NSViewRepresentable {
    var animated: Bool
    var highContrast: Bool
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.configure(animated: animated, highContrast: highContrast)
    }

    final class Host: NSView {
        private let core = CAGradientLayer()
        private let halo = CAGradientLayer()
        private let coreMask = CAShapeLayer()
        private let haloMask = CAShapeLayer()
        private let lightCore = CAGradientLayer()
        private let lightHalo = CAGradientLayer()
        private let lightCoreMask = CAShapeLayer()
        private let lightHaloMask = CAShapeLayer()
        private var frames: WorkspaceRimPalette.Frames?
        private var loading = false
        private var loadFailed = false
        private var animated = false
        private var highContrast = false
        private var observers: [NSObjectProtocol] = []
        private var visibility: NSKeyValueObservation?
        private static let animationKey = "workspace-outer-rim-orbit"
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            for (gradient, mask) in [(halo, haloMask), (core, coreMask),
                                     (lightHalo, lightHaloMask), (lightCore, lightCoreMask)] {
                gradient.type = .conic
                gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                gradient.endPoint = CGPoint(x: 1, y: 0.5)
                gradient.locations = (0...WorkspaceRimPalette.stops).map {
                    NSNumber(value: Double($0) / Double(WorkspaceRimPalette.stops))
                }
                mask.fillColor = nil
                mask.strokeColor = NSColor.white.cgColor
                gradient.mask = mask
                layer?.addSublayer(gradient)
            }
            coreMask.lineWidth = 0.95
            haloMask.lineWidth = 1.2
            haloMask.shadowColor = NSColor.white.cgColor
            haloMask.shadowOpacity = 1
            haloMask.shadowRadius = 1.7
            haloMask.shadowOffset = .zero
            lightCoreMask.lineWidth = 0.7
            lightHaloMask.lineWidth = 0.9
            lightHaloMask.shadowColor = NSColor.white.cgColor
            lightHaloMask.shadowOpacity = 1
            lightHaloMask.shadowRadius = 1.1
            lightHaloMask.shadowOffset = .zero
            setAccessibilityElement(false)
            appearance()
        }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func configure(animated: Bool, highContrast: Bool) {
            self.animated = animated
            self.highContrast = highContrast
            appearance()
            updateMotion()
        }
        private func appearance() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            core.opacity = highContrast ? 0 : 0.96
            halo.opacity = highContrast ? 0 : 0.18
            lightCore.opacity = highContrast ? 0 : 0.72
            lightHalo.opacity = highContrast ? 0 : 0.06
            core.isHidden = !dark
            halo.isHidden = !dark
            lightCore.isHidden = dark
            lightHalo.isHidden = dark
            if core.colors == nil {
                let poster = WorkspaceRimPalette.colors(at: WorkspaceRimPalette.posterIndex)
                core.colors = poster
                halo.colors = poster
                let light = poster.map(WorkspaceRimPalette.lightColors)
                lightCore.colors = light
                lightHalo.colors = light
            }
            CATransaction.commit()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            appearance()
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
            updateScale()
            updateMotion()
        }
        override func viewDidHide() { super.viewDidHide(); updateMotion() }
        override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateScale()
        }
        private func updateScale() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for rendered in [core, halo, coreMask, haloMask, lightCore, lightHalo, lightCoreMask, lightHaloMask] {
                rendered.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            }
            CATransaction.commit()
        }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let rect = bounds.insetBy(dx: 0.7, dy: 0.7)
            let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                              cornerHeight: rect.height / 2, transform: nil)
            for (gradient, mask) in [(core, coreMask), (halo, haloMask),
                                     (lightCore, lightCoreMask), (lightHalo, lightHaloMask)] {
                gradient.frame = bounds
                mask.frame = gradient.bounds
                mask.path = path
            }
            CATransaction.commit()
        }
        private func updateMotion() {
            let running = animated && !highContrast && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            if !running {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for gradient in [core, halo, lightCore, lightHalo] {
                    if let current = gradient.presentation()?.colors { gradient.colors = current }
                    gradient.removeAnimation(forKey: Self.animationKey)
                }
                CATransaction.commit()
                return
            }
            if let frames {
                guard core.animation(forKey: Self.animationKey) == nil else { return }
                // Submit each theme's palette once. Hidden layers remain on
                // the same render-server clock; appearance swaps no keyframes.
                for gradient in [core, halo, lightCore, lightHalo] {
                    let animation = CAKeyframeAnimation(keyPath: "colors")
                    let colors = gradient === lightCore || gradient === lightHalo ? frames.lightColors : frames.colors
                    animation.values = colors + [colors[0]]
                    animation.keyTimes = (0...WorkspaceRimPalette.count).map {
                        NSNumber(value: Double($0) / Double(WorkspaceRimPalette.count))
                    }
                    animation.calculationMode = .linear
                    animation.duration = WorkspaceMetalMaterial.cycle
                    animation.repeatCount = .infinity
                    animation.beginTime = gradient.convertTime(WorkspaceMetalMaterial.epoch, from: nil)
                    gradient.add(animation, forKey: Self.animationKey)
                }
            } else if !loading && !loadFailed {
                loading = true
                WorkspaceRimPalette.load { [weak self] frames in
                    guard let self else { return }
                    self.loading = false
                    self.loadFailed = frames == nil
                    self.frames = frames
                    self.updateMotion()
                }
            }
        }
        #if DEBUG
        var debugRunning: Bool { core.animation(forKey: Self.animationKey) != nil }
        var debugFrameCount: Int { frames?.colors.count ?? 0 }
        var debugHiddenForContrast: Bool {
            [core, halo, lightCore, lightHalo].allSatisfy { $0.opacity == 0 }
        }
        #endif
    }
}
