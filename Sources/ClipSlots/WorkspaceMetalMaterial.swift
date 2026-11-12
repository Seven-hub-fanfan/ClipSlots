import AppKit
import SwiftUI
import QuartzCore
import ImageIO
import ClipSlotsKit

/// B's sampled optics are baked into small 2x atlases. Core Animation owns
/// playback, so mounting a workspace cannot interrupt the reflection.
enum WorkspaceMetalMaterial {
    enum Kind: String { case arch, brand, edit, canvas, model }
    static let cycle: CFTimeInterval = 5
    static let epoch = CACurrentMediaTime() - 2.2
    private static let queue = DispatchQueue(label: "clipslots.navigation-metal", qos: .userInitiated)
    private static let cache: NSCache<NSString, Frames> = {
        let cache = NSCache<NSString, Frames>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private final class Poster {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let posters = NSCache<NSString, Poster>()
    private static let posterLock = NSLock()
    final class Frames {
        let images: [CGImage]
        init(_ images: [CGImage]) { self.images = images }
    }
    static func url(_ kind: Kind, dark: Bool, poster: Bool) -> URL? {
        WorkspaceBrandResources.markURL?.deletingLastPathComponent()
            .appendingPathComponent("NavigationMetal")
            .appendingPathComponent("\(kind.rawValue)-\(dark ? "dark" : "light")\(poster ? "-poster" : "").png")
    }
    static func poster(_ kind: Kind, dark: Bool) -> CGImage? {
        let key = "\(kind.rawValue)-\(dark)" as NSString
        posterLock.lock()
        defer { posterLock.unlock() }
        if let cached = posters.object(forKey: key) { return cached.image }
        guard let url = url(kind, dark: dark, poster: true),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        if let image { posters.setObject(Poster(image), forKey: key) }
        return image
    }
    static func load(_ kind: Kind, dark: Bool, completion: @escaping (Frames?) -> Void) {
        let key = "\(kind.rawValue)-\(dark)" as NSString
        queue.async {
            if let frames = cache.object(forKey: key) {
                DispatchQueue.main.async { completion(frames) }
                return
            }
            guard let url = url(kind, dark: dark, poster: false),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let atlas = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  atlas.height % 150 == 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let height = atlas.height / 150
            let images = (0..<150).compactMap {
                atlas.cropping(to: CGRect(x: 0, y: $0 * height, width: atlas.width, height: height))
            }
            let frames = images.count == 150 ? Frames(images) : nil
            if let frames { cache.setObject(frames, forKey: key, cost: atlas.width * atlas.height * 4) }
            DispatchQueue.main.async { completion(frames) }
        }
    }
}

final class WorkspaceMetalPlayback {
    let layer = CALayer()
    private var kind: WorkspaceMetalMaterial.Kind?
    private var dark = false
    private var frames: WorkspaceMetalMaterial.Frames?
    private var loading = false
    private var loadFailed = false
    private var generation = 0
    private var running = false
    static let animationKey = "workspace-light-orbit"

    init() {
        layer.contentsGravity = .resize
        layer.contentsScale = 2
        layer.magnificationFilter = .linear
    }
    func configure(kind: WorkspaceMetalMaterial.Kind, dark: Bool) {
        guard self.kind != kind || self.dark != dark else { return }
        self.kind = kind
        self.dark = dark
        generation += 1
        loading = false
        loadFailed = false
        frames = nil
        layer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = WorkspaceMetalMaterial.poster(kind, dark: dark)
        CATransaction.commit()
        resume()
    }
    func setRunning(_ running: Bool) {
        self.running = running
        if running {
            resume()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let frames {
                let elapsed = CACurrentMediaTime() - WorkspaceMetalMaterial.epoch
                let index = Int(elapsed.truncatingRemainder(dividingBy: 5) * 30) % 150
                layer.contents = frames.images[max(0, index)]
            }
            layer.removeAnimation(forKey: Self.animationKey)
            CATransaction.commit()
        }
    }
    private func resume() {
        guard running, let kind else { return }
        if let frames {
            guard layer.animation(forKey: Self.animationKey) == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames.images + [frames.images[0]]
            animation.keyTimes = (0...150).map { NSNumber(value: Double($0) / 150) }
            animation.calculationMode = .discrete
            animation.duration = WorkspaceMetalMaterial.cycle
            animation.repeatCount = .infinity
            animation.beginTime = layer.convertTime(WorkspaceMetalMaterial.epoch, from: nil)
            layer.add(animation, forKey: Self.animationKey)
        } else if !loading && !loadFailed {
            loading = true
            let requested = generation
            WorkspaceMetalMaterial.load(kind, dark: dark) { [weak self] frames in
                guard let self, self.generation == requested else { return }
                self.loading = false
                self.loadFailed = frames == nil
                self.frames = frames
                self.resume()
            }
        }
    }
    #if DEBUG
    var debugFrameCount: Int { frames?.images.count ?? 0 }
    var debugRunning: Bool { layer.animation(forKey: Self.animationKey) != nil }
    #endif
}

/// Brand and selected SF Symbols use the same studio-strip reflection.
/// Decoration stays transparent to input; SwiftUI owns the three route buttons.
struct WorkspaceMetalArtwork: NSViewRepresentable {
    var kind: WorkspaceMetalMaterial.Kind
    var animated: Bool
    var highContrast: Bool
    var hovered = false
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.configure(kind: kind, animated: animated, highContrast: highContrast, hovered: hovered)
    }
    final class Host: NSView {
        private let playback = WorkspaceMetalPlayback()
        private let reflection = CAGradientLayer()
        private let reflectionMask = CALayer()
        private var kind: WorkspaceMetalMaterial.Kind = .brand
        private var animated = true
        private var highContrast = false
        private var hovered = false
        private var observers: [NSObjectProtocol] = []
        private var visibility: NSKeyValueObservation?
        private var tracking: NSTrackingArea?
        private var pressMonitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(playback.layer)
            reflection.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.24).cgColor,
                                 NSColor.clear.cgColor]
            reflection.locations = [0.35, 0.5, 0.65]
            reflection.startPoint = CGPoint(x: 0, y: 0)
            reflection.endPoint = CGPoint(x: 1, y: 1)
            reflection.mask = reflectionMask
            layer?.addSublayer(reflection)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
        }
        func configure(kind: WorkspaceMetalMaterial.Kind, animated: Bool, highContrast: Bool, hovered: Bool) {
            self.kind = kind
            self.animated = animated
            self.highContrast = highContrast
            self.hovered = hovered
            appearance()
            updateMotion()
            needsLayout = true
        }
        private func appearance() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            playback.configure(kind: kind, dark: dark)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reflectionMask.contents = WorkspaceMetalMaterial.poster(kind, dark: dark)
            reflection.opacity = hovered && !highContrast ? 1 : 0
            playback.layer.isHidden = highContrast
            CATransaction.commit()
            needsDisplay = true
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            appearance()
        }
        override func draw(_ dirtyRect: NSRect) {
            guard highContrast else { return }
            let image: NSImage?
            if kind == .brand {
                image = WorkspaceBrandResources.markURL.flatMap { NSImage(contentsOf: $0) }
            } else {
                let symbol = kind == .edit ? "rectangle.stack.fill" : kind == .canvas ? "viewfinder" : "cube.fill"
                image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = NSGraphicsContext.current?.cgContext else { return }
            let box = kind == .brand ? bounds.insetBy(dx: 9, dy: 8) : bounds
            let scale = min(box.width / CGFloat(cg.width), box.height / CGFloat(cg.height))
            let rect = CGRect(x: bounds.midX - CGFloat(cg.width) * scale / 2,
                              y: bounds.midY - CGFloat(cg.height) * scale / 2,
                              width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: rect, mask: cg)
            ctx.setFillColor((effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua
                ? NSColor.white : NSColor.darkGray).cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playback.layer.frame = bounds
            reflection.frame = bounds
            reflectionMask.frame = bounds
            CATransaction.commit()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            visibility = window?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in self?.updateMotion() }
            if let window {
                for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didChangeOcclusionStateNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window,
                        queue: .main) { [weak self] _ in self?.updateMotion() })
                }
            }
            if let pressMonitor { NSEvent.removeMonitor(pressMonitor); self.pressMonitor = nil }
            if window != nil {
                pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    if let self, self.kind == .brand, event.window === self.window {
                        let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                        if event.type == .leftMouseUp || inside {
                            self.feedback(pressed: event.type == .leftMouseDown && inside)
                        }
                    }
                    return event
                }
            }
            updateMotion()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved,
                .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) {
            if kind == .brand { hovered = true; appearance() }
        }
        override func mouseExited(with event: NSEvent) {
            if kind == .brand { hovered = false; appearance(); feedback(pressed: false) }
        }
        override func mouseMoved(with event: NSEvent) {
            guard hovered, !highContrast, animated else { return }
            let point = convert(event.locationInWindow, from: nil)
            let x = point.x / max(1, bounds.width) - 0.5
            let y = point.y / max(1, bounds.height) - 0.5
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reflection.startPoint = CGPoint(x: x * 0.3, y: y * 0.3)
            reflection.endPoint = CGPoint(x: 1 + x * 0.3, y: 1 + y * 0.3)
            CATransaction.commit()
        }
        private func feedback(pressed: Bool) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(animated ? 0.16 : 0)
            playback.layer.transform = CATransform3DMakeScale(pressed ? 0.95 : 1, pressed ? 0.95 : 1, 1)
            CATransaction.commit()
        }
        private func updateMotion() {
            playback.setRunning(animated && !highContrast && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true)
        }
        override func viewDidHide() { super.viewDidHide(); updateMotion() }
        override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }
        #if DEBUG
        var debugKind: WorkspaceMetalMaterial.Kind { kind }
        var debugRunning: Bool { playback.debugRunning }
        var debugFrameCount: Int { playback.debugFrameCount }
        #endif
    }
}
