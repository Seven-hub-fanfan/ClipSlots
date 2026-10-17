// Appended to the actual CreativeMotion source by creative_visual_metrics.py.
// Renders fixed layer times offscreen; these images are not FPS evidence.
import ScreenCaptureKit
_ = NSApplication.shared
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleStep = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 0.05
let sampleCount = Int(round(CreativeMotion.entranceDuration / sampleStep))
let host = ComposerEntranceGlow.Host(frame: CGRect(x: 0, y: 0, width: 464, height: 121))
let captureScreen = ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_SCREEN"] == "1"
let lightMode = ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_LIGHT"] == "1"
var screenWindow: NSWindow?
if captureScreen {
    class FlippedSurface: NSView { override var isFlipped: Bool { true } }
    let surface = FlippedSurface(frame: CGRect(x: 0, y: 0, width: 476, height: 147))
    if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_UNCLIPPED"] == "1" {
        host.clipsToBounds = false
    }
    surface.wantsLayer = true
    surface.layer?.backgroundColor = (lightMode ? NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1) : NSColor(srgbRed: 17/255, green: 17/255, blue: 17/255, alpha: 1)).cgColor
    host.frame.origin = CGPoint(x: 6, y: 20)
    host.layer?.backgroundColor = (lightMode ? NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1) : NSColor(srgbRed: 22/255, green: 22/255, blue: 22/255, alpha: 1)).cgColor
    host.layer?.cornerRadius = 16
    surface.addSubview(host)
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 476, height: 147),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = surface
    window.orderFront(nil); NSApp.activate(ignoringOtherApps: true)
    screenWindow = window
}
host.synchronize()
let readyDeadline = Date().addingTimeInterval(8)
while host.sweep.contents == nil && Date() < readyDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
guard host.sweep.contents != nil else { throw CocoaError(.fileReadUnknown) }
for (name, layer) in [("bottom", host.bottom), ("sweep", host.sweep)] {
    if let image = layer.contents {
        let bitmap = NSBitmapImageRep(cgImage: image as! CGImage)
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent("texture-\(name).png"))
    }
}
host.startEntrance()
let animated = [host.glow, host.inner, host.inset, host.bottom, host.sweep].flatMap { layer in
    (layer.animationKeys() ?? []).compactMap { key -> (CALayer, CAKeyframeAnimation)? in
        guard let animation = layer.animation(forKey: key) as? CAKeyframeAnimation else { return nil }
        return (layer, animation)
    }
}
host.stop()
if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_UNCLIPPED"] == "1" {
    host.clipsToBounds = false
    host.layer?.masksToBounds = false
}
if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_SHADOW_FILL"] == "1" {
    host.glow.sublayers?.first?.backgroundColor = NSColor.white.cgColor
    host.inner.sublayers?.first?.backgroundColor = NSColor.white.cgColor
}
let inset = CALayer()
if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_INSET"] == "1" {
    inset.frame = host.bounds.insetBy(dx: -1, dy: -1)
    inset.cornerRadius = 16; inset.masksToBounds = true
    host.layer?.insertSublayer(inset, below: host.wash)
    for (offset, color) in [
        (-2.0, NSColor.white.withAlphaComponent(0.15)),
        (4.0, NSColor(srgbRed: 130/255, green: 169/255, blue: 198/255, alpha: 0.27))
    ] {
        let shadow = CALayer()
        shadow.frame = inset.bounds
        let path = CGMutablePath()
        path.addRect(inset.bounds.insetBy(dx: -32, dy: -32))
        let hole = CGPath(roundedRect: inset.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        path.addPath(hole, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: inset.bounds.width, ty: 0))
        shadow.shadowPath = path
        shadow.shadowColor = color.withAlphaComponent(1).cgColor
        shadow.shadowOpacity = Float(color.alphaComponent)
        shadow.shadowOffset = CGSize(width: 0, height: offset)
        shadow.shadowRadius = 2
        inset.addSublayer(shadow)
    }
    inset.borderColor = CreativeMotion.blue.withAlphaComponent(0.18).cgColor
    inset.borderWidth = 1
}
if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_HALF_SHADOW"] == "1" {
    for parent in [host.glow, host.inner] {
        guard let shadow = parent.sublayers?.first else { continue }
        shadow.shadowRadius *= 0.5
        let spread: CGFloat = parent === host.glow ? 2 : 1
        shadow.shadowPath = CGPath(roundedRect: shadow.bounds.insetBy(dx: -spread, dy: -spread),
                                  cornerWidth: 16 + spread - 1, cornerHeight: 16 + spread - 1, transform: nil)
    }
}
func value(_ animation: CAKeyframeAnimation, _ time: Double) -> Double {
    func eased(_ fraction: Double, _ curve: CAMediaTimingFunction) -> Double {
        var c1 = [Float](repeating: 0, count: 2), c2 = c1
        curve.getControlPoint(at: 1, values: &c1); curve.getControlPoint(at: 2, values: &c2)
        func cubic(_ t: Double, _ a: Float, _ b: Float) -> Double {
            3 * (1-t) * (1-t) * t * Double(a) + 3 * (1-t) * t * t * Double(b) + t*t*t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let middle = (lo+hi)/2
            if cubic(middle, c1[0], c2[0]) < fraction { lo = middle } else { hi = middle }
        }
        return cubic((lo+hi)/2, c1[1], c2[1])
    }
    let globalOpacity = (ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_GLOBAL_OPACITY"] == "1"
        && animation.keyPath == "opacity")
        || (ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_GLOBAL_SWEEP"] == "1"
            && animation.keyPath == "transform.translation.x")
    var phase = min(1, max(0, time / animation.duration))
    if globalOpacity, let curve = animation.timingFunctions?.first { phase = eased(phase, curve) }
    let times = animation.keyTimes!.map(\.doubleValue)
    let values = animation.values! as! [NSNumber]
    let i = (0..<times.count-1).first { phase <= times[$0+1] } ?? times.count-2
    var fraction = (phase-times[i]) / (times[i+1]-times[i])
    if !globalOpacity, let curve = animation.timingFunctions?[i] {
        fraction = eased(fraction, curve)
    }
    return values[i].doubleValue + fraction * (values[i+1].doubleValue-values[i].doubleValue)
}
for frame in 0...sampleCount {
    if captureScreen && ![0.0, 0.8, 1.4, 2.0, 2.5].map({ Int(round($0 / sampleStep)) }).contains(frame) { continue }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (layer, animation) in animated {
        let v = value(animation, Double(frame) * sampleStep)
        if animation.keyPath == "opacity" { layer.opacity = Float(v) }
        if animation.keyPath == "transform.translation.x" { layer.transform = CATransform3DMakeTranslation(v, 0, 0) }
    }
    inset.opacity = host.inner.opacity
    if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_NO_WASH"] == "1" { host.wash.isHidden = true }
    if ProcessInfo.processInfo.environment["CREATIVE_DIAGNOSTIC_NO_INSET"] == "1" { host.inset.isHidden = true }
    CATransaction.commit()
    if captureScreen {
        let debug: [String: Any] = [
            "glowOpacity": host.glow.opacity, "innerOpacity": host.inner.opacity,
            "glowFrame": NSStringFromRect(host.glow.frame),
            "glowBounds": NSStringFromRect(host.glow.bounds),
            "maskFrame": NSStringFromRect(host.glow.mask?.frame ?? .zero),
            "clip": host.clipsToBounds, "layerClip": host.layer?.masksToBounds ?? false,
            "shadowOpacity": host.glow.sublayers?.first?.shadowOpacity ?? -1,
            "shadowFrame": NSStringFromRect(host.glow.sublayers?.first?.frame ?? .zero),
            "shadowPath": NSStringFromRect(host.glow.sublayers?.first?.shadowPath?.boundingBox ?? .zero)
        ]
        try JSONSerialization.data(withJSONObject: debug, options: .prettyPrinted).write(
            to: directory.appendingPathComponent(String(format: "layers-%02d.json", frame)))
        // #region debug-point A-B:fixed-halo-layers
        if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_DEBUG_URL"], let url = URL(string: endpoint) {
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "sessionId": "light-agent-halo", "runId": ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_RUN"] ?? "pre-fix",
                "hypothesisId": "A-B", "msg": "[DEBUG] Fixed light/dark layer snapshot",
                "data": ["lightMode": lightMode, "time": Double(frame) * sampleStep,
                         "insetShadowColor": host.inset.sublayers?.last?.shadowColor?.components ?? [],
                         "insetShadowOpacity": host.inset.sublayers?.last?.shadowOpacity ?? -1,
                         "washHidden": host.wash.isHidden, "insetHidden": host.inset.isHidden,
                         "sweepColorSpace": (host.sweep.contents as! CGImage).colorSpace?.name as String? ?? "unknown",
                         "layers": debug] as [String: Any]])
            URLSession.shared.dataTask(with: request).resume()
        }
        // #endregion
    }
    let context = CGContext(data: nil, width: 952, height: 294, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 294); context.scaleBy(x: 2, y: -2)
    context.translateBy(x: 6, y: 20)
    host.layer!.render(in: context)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: directory.appendingPathComponent(String(format: "glow-%02d.png", frame)))
    if let window = screenWindow {
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var finished = false
        Task { @MainActor in
            defer { finished = true }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: { $0.windowID == window.windowNumber }) else { return }
                let configuration = SCStreamConfiguration()
                configuration.width = 952; configuration.height = 294; configuration.showsCursor = false
                configuration.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: directory.appendingPathComponent(String(format: "screen-%02d.png", frame)))
            } catch { NSLog("Screen calibration failed: %@", String(describing: error)) }
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
}
screenWindow?.close()
