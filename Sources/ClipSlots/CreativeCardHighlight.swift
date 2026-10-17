import AppKit
import SwiftUI
import QuartzCore

/// Pointer movement updates a compositor layer. Only entry/exit changes SwiftUI
/// state, so moving across a card doesn't rebuild its text or the transcript.
struct CreativeCardHighlight: NSViewRepresentable {
    @Binding var hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.reduceMotion = reduceMotion
        view.onHoverChanged = { if hovered != $0 { hovered = $0 } }
    }

    final class Host: NSView {
        let spot = CALayer()
        var reduceMotion = false {
            didSet { if reduceMotion { spot.removeAllAnimations() } }
        }
        var onHoverChanged: ((Bool) -> Void)?
        private var inside = false
        private var area: NSTrackingArea?
        private var observer: NSObjectProtocol?
        // #region debug-point C:hover-lifecycle
        #if DEBUG
        private let debugProbe = ProcessInfo.processInfo.environment["CLIPSLOTS_CREATIVE_PROBE"] == "1"
        var debugEvents: [String: Int] = [:]
        var debugLastExit: [String: Double] = [:]
        #endif
        // #endregion
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 16; layer?.masksToBounds = true
            spot.bounds = CGRect(x: 0, y: 0, width: 360, height: 360)
            spot.contents = Self.texture
            spot.opacity = 0
            layer?.addSublayer(spot)
            setAccessibilityElement(false)
            // #region debug-point C:isolated-hover-input
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLIPSLOTS_CREATIVE_PROBE"] == "1" {
                observer = NotificationCenter.default.addObserver(forName: .init("CreativeProbeHover"), object: nil, queue: .main) { [weak self] event in
                    guard let self, let point = event.object as? CGPoint else { return }
                    self.move(to: .init(x: point.x * self.bounds.width, y: point.y * self.bounds.height))
                }
            }
            #endif
            // #endregion
        }
        required init?(coder: NSCoder) { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // #region debug-point C:hover-lifecycle
            #if DEBUG
            if debugProbe { debugEvents["tracking_updates", default: 0] += 1 }
            #endif
            // #endregion
            // .inVisibleRect follows layout automatically. Replacing the area
            // during a hover transform generates spurious exit/entry events.
            guard area == nil else { return }
            let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(next); area = next
        }
        override func mouseEntered(with event: NSEvent) {
            // #region debug-point C:hover-lifecycle
            #if DEBUG
            if debugProbe { debugEvents["entered", default: 0] += 1 }
            #endif
            // #endregion
            move(to: convert(event.locationInWindow, from: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            // #region debug-point C:hover-lifecycle
            #if DEBUG
            if debugProbe { debugEvents["moved", default: 0] += 1 }
            #endif
            // #endregion
            move(to: convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) {
            // #region debug-point C:hover-lifecycle
            #if DEBUG
            if debugProbe {
                debugEvents["exited", default: 0] += 1
                let point = convert(event.locationInWindow, from: nil)
                debugLastExit = ["x": point.x, "y": point.y, "width": bounds.width, "height": bounds.height,
                                 "inside_bounds": bounds.contains(point) ? 1 : 0]
            }
            #endif
            // #endregion
            setInside(false)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            spot.contentsScale = window?.backingScaleFactor ?? 2
            if window == nil { setInside(false); spot.removeAllAnimations() }
        }
        override func viewDidHide() {
            super.viewDidHide()
            // #region debug-point C:hover-lifecycle
            #if DEBUG
            if debugProbe { debugEvents["hidden", default: 0] += 1 }
            #endif
            // #endregion
            setInside(false); spot.removeAllAnimations()
        }

        func move(to point: CGPoint) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spot.position = point
            CATransaction.commit()
            setInside(true)
        }
        func setInside(_ value: Bool) {
            guard inside != value else { return }
            // #region debug-point C:hover-lifecycle
            #if DEBUG
            if debugProbe { debugEvents[value ? "state_on" : "state_off", default: 0] += 1 }
            #endif
            // #endregion
            inside = value
            let from = spot.presentation()?.opacity ?? spot.opacity
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spot.opacity = value ? 1 : 0
            CATransaction.commit()
            spot.removeAnimation(forKey: "hover")
            if !reduceMotion && window != nil {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from; fade.toValue = spot.opacity; fade.duration = 0.7
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                spot.add(fade, forKey: "hover")
            }
            onHoverChanged?(value)
        }
        private static let texture: CGImage? = {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: 720, height: 720, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let gradient = CGGradient(colorsSpace: space, colors: [
                    NSColor(srgbRed: 178 / 255, green: 239 / 255, blue: 1, alpha: 0.07).cgColor,
                    NSColor(srgbRed: 213 / 255, green: 241 / 255, blue: 1, alpha: 0.025).cgColor,
                    NSColor(srgbRed: 213 / 255, green: 241 / 255, blue: 1, alpha: 0).cgColor
                  ] as CFArray, locations: [0, 0.45, 1]) else { return nil }
            context.drawRadialGradient(gradient, startCenter: .init(x: 360, y: 360), startRadius: 0,
                                       endCenter: .init(x: 360, y: 360), endRadius: 360, options: [])
            return context.makeImage()
        }()
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
