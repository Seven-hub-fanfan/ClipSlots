import AppKit
import SwiftUI
import QuartzCore
import ImageIO
import ClipSlotsKit

/// The approved 4pt annulus, including its radial reflections and outside glow.
/// One shared 2x atlas is moved by the compositor, without a SwiftUI frame clock.
enum AgentOrbRimTexture {
    static let count = 150
    static let cycle: Double = 5
    static let epoch = CACurrentMediaTime()
    private static let root = AgentBackgroundResources.pageURL?
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentRim")
    private static let queue = DispatchQueue(label: "clipslots.agent-orb-rim", qos: .userInitiated)
    private static var cached: CGImage?
    private static func image(_ name: String) -> CGImage? {
        guard let url = root?.appendingPathComponent(name + ".png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    static let poster = image("poster")
    static func rect(at index: Int) -> CGRect {
        CGRect(x: Double(index % 10) / 10, y: Double(index / 10) / 15,
               width: 0.1, height: 1.0 / 15)
    }
    static func load(completion: @escaping (CGImage?) -> Void) {
        queue.async {
            if cached == nil { cached = image("atlas") }
            let result = cached
            DispatchQueue.main.async { completion(result) }
        }
    }
}

struct AgentOrbRim: NSViewRepresentable {
    var animated: Bool
    var highContrast: Bool
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.configure(animated: animated, highContrast: highContrast)
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        private let texture = CALayer()
        private var atlas: CGImage?
        private var loading = false
        private var failed = false
        private var animated = false
        private var highContrast = false
        private var observers: [NSObjectProtocol] = []
        private var visibility: NSKeyValueObservation?
        private static let key = "agent-orb-rim-frames"
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 60) }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            texture.contents = AgentOrbRimTexture.poster
            texture.contentsGravity = .resize
            texture.minificationFilter = .linear
            texture.magnificationFilter = .linear
            layer?.addSublayer(texture)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func configure(animated: Bool, highContrast: Bool) {
            self.animated = animated
            self.highContrast = highContrast
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            texture.opacity = highContrast ? 0 : 1
            CATransaction.commit()
            updateMotion()
        }
        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            visibility = nil
            animated = false
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
            texture.contentsScale = window?.backingScaleFactor ?? 2
        }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            texture.frame = bounds
            CATransaction.commit()
        }
        private func updateMotion() {
            let running = animated && !highContrast && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
            if !running {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if texture.animation(forKey: Self.key) != nil {
                    texture.contentsRect = texture.presentation()?.contentsRect ?? texture.contentsRect
                    texture.removeAnimation(forKey: Self.key)
                }
                CATransaction.commit()
            } else if let atlas {
                guard texture.animation(forKey: Self.key) == nil else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                texture.contents = atlas
                texture.contentsRect = AgentOrbRimTexture.rect(at: 66)
                CATransaction.commit()
                let animation = CAKeyframeAnimation(keyPath: "contentsRect")
                animation.values = (0...AgentOrbRimTexture.count).map {
                    NSValue(rect: AgentOrbRimTexture.rect(at: $0 % AgentOrbRimTexture.count))
                }
                animation.keyTimes = (0...AgentOrbRimTexture.count).map {
                    NSNumber(value: Double($0) / Double(AgentOrbRimTexture.count))
                }
                animation.calculationMode = .discrete
                animation.duration = AgentOrbRimTexture.cycle
                animation.repeatCount = .infinity
                animation.beginTime = texture.convertTime(AgentOrbRimTexture.epoch, from: nil)
                texture.add(animation, forKey: Self.key)
            } else if !loading && !failed {
                loading = true
                AgentOrbRimTexture.load { [weak self] image in
                    guard let self else { return }
                    loading = false
                    failed = image == nil
                    atlas = image
                    updateMotion()
                }
            }
        }
        #if DEBUG
        var debugRunning: Bool { texture.animation(forKey: Self.key) != nil }
        var debugAtlasSize: CGSize { CGSize(width: atlas?.width ?? 0, height: atlas?.height ?? 0) }
        var debugHiddenForContrast: Bool { texture.opacity == 0 }
        #endif
    }
}
