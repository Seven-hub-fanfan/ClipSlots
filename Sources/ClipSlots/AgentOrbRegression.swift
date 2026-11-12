#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor enum AgentOrbRegression {
    private final class State: ObservableObject {
        @Published var open = false
        @Published var reduced = false
        @Published var highContrast = false
        var clicks = 0
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        var body: some View {
            AgentOrbButton(isOpen: state.open, action: { state.open.toggle(); state.clicks += 1 },
                           debugReduceMotion: state.reduced, debugHighContrast: state.highContrast)
                .frame(width: 160, height: 120)
        }
    }
    private static func settle(_ ms: Int = 120) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }
    static func run(root: URL) async {
        var passed = [String](), failed = [String]()
        func check(_ value: Bool, _ name: String) {
            if value { passed.append(name) } else { failed.append(name) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NativeAccessibilityProbe.enable()
            guard let poster = AgentOrbRimTexture.poster else {
                throw NSError(domain: "AgentOrbTexture", code: 1)
            }
            check(poster.width == 120 && poster.height == 120, "4pt reference poster is bundled at 2x")
            let bitmap = NSBitmapImageRep(cgImage: poster)
            var holeAlpha: CGFloat = 0, outsideAlpha: CGFloat = 0
            var bodyOpaque = 0, bodyCount = 0, colorful = 0, dark = 0
            var minimumBrightness: CGFloat = 1, maximumBrightness: CGFloat = 0
            for y in 0..<120 {
                for x in 0..<120 {
                    let r = hypot((Double(x) + 0.5) / 2 - 30, (Double(y) + 0.5) / 2 - 30)
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if r < 17.5 { holeAlpha = max(holeAlpha, c.alphaComponent) }
                    if r > 26 { outsideAlpha = max(outsideAlpha, c.alphaComponent) }
                    if r > 18.5 && r < 21.5 {
                        bodyCount += 1
                        if c.alphaComponent > 0.95 { bodyOpaque += 1 }
                        let rgb = [c.redComponent, c.greenComponent, c.blueComponent]
                        if (rgb.max() ?? 0) - (rgb.min() ?? 0) > 0.14 { colorful += 1 }
                        let brightness = rgb.reduce(0, +) / 3
                        minimumBrightness = min(minimumBrightness, brightness)
                        maximumBrightness = max(maximumBrightness, brightness)
                        if brightness < 0.3 { dark += 1 }
                    }
                }
            }
            check(holeAlpha < 0.02 && outsideAlpha < 0.02,
                  "36pt center is transparent and reference glow stays outside the 44pt body")
            check(bodyCount > 500 && Double(bodyOpaque) / Double(bodyCount) > 0.99,
                  "the entire 4pt annulus carries material rather than a single outline")
            check(colorful > 50 && dark > 50 && maximumBrightness - minimumBrightness > 0.8,
                  "4pt material retains rainbow highlights and dark reflections")
            try JSONSerialization.data(withJSONObject: [
                "annulusPixels": bodyCount, "opaquePixels": bodyOpaque,
                "coloredPixels": colorful, "darkReflectionPixels": dark,
                "minimumBrightness": minimumBrightness, "maximumBrightness": maximumBrightness,
                "holeMaximumAlpha": holeAlpha, "outsideMaximumAlpha": outsideAlpha
            ], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("material.json"))
            for darkMode in [false, true] {
                let name = "agent-\(darkMode ? "dark" : "light")"
                let state = State()
                let host = NSHostingView(rootView: Fixture(state: state))
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 160, height: 120),
                                      styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.backgroundColor = darkMode ? NSColor(white: 0.12, alpha: 1)
                    : NSColor(white: 0.98, alpha: 1)
                window.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                await settle(300)
                host.layoutSubtreeIfNeeded()
                let nodes = NativeAccessibilityProbe.elements(host)
                let rim = nodes.compactMap { $0 as? AgentOrbRim.Host }.first
                let gif = nodes.compactMap { $0 as? OrbImage.ImageView }.first
                check(rim?.bounds.size == CGSize(width: 60, height: 60)
                      && gif?.bounds.size == CGSize(width: 36, height: 36),
                      "\(name) mounts the approved 36pt center and 60pt transparent glow")
                check(rim?.debugRunning == true && rim?.debugAtlasSize == CGSize(width: 1200, height: 1800),
                      "\(name) runs all 150 frames from one shared atlas")
                check(rim?.hitTest(CGPoint(x: 30, y: 30)) == nil
                      && gif?.hitTest(CGPoint(x: 18, y: 18)) == nil,
                      "\(name) decorative layers never intercept the button")
                func button() -> AnyObject? {
                    NativeAccessibilityProbe.elements(host).first {
                        $0.accessibilityIdentifier?() == "workspace-agent-orb"
                    }
                }
                check(button()?.accessibilityLabel?() == "打开 Agent", "\(name) announces the closed launcher")
                _ = button()?.accessibilityPerformPress?()
                await settle()
                check(state.open && state.clicks == 1 && gif?.asset == "agent-orb-active",
                      "\(name) native press opens once and uses the original active GIF")
                check(button()?.accessibilityLabel?() == "收起 Agent", "\(name) updates the open accessibility label")
                _ = button()?.accessibilityPerformPress?()
                await settle()
                check(!state.open && state.clicks == 2, "\(name) second native press closes once")
                // Exercise AppKit event routing through the transparent animation.
                let location = host.convert(CGPoint(x: 80, y: 60), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
                }
                await settle()
                check(state.open && state.clicks == 3, "\(name) center mouse event reaches the unchanged click action")
                state.reduced = true
                await settle()
                check(rim?.debugRunning == false && gif?.animates == false,
                      "\(name) reduce motion stops both ring and center animation")
                state.reduced = false
                await settle()
                check(rim?.debugRunning == true && gif?.animates == true, "\(name) animation resumes")
                state.highContrast = true
                await settle()
                check(rim?.debugHiddenForContrast == true && rim?.debugRunning == false,
                      "\(name) increased contrast uses a stationary neutral outline")
                state.highContrast = false
                await settle()
                host.isHidden = true
                await settle()
                check(rim?.debugRunning == false && gif?.animates == false, "\(name) hidden ancestor stops animation")
                host.isHidden = false
                await settle()
                check(rim?.debugRunning == true && gif?.animates == true, "\(name) unhidden ancestor resumes animation")
                window.miniaturize(nil)
                await settle(250)
                check(rim?.debugRunning == false && gif?.animates == false, "\(name) minimized window stops animation")
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                await settle(250)
                check(rim?.debugRunning == true && gif?.animates == true, "\(name) restored window resumes animation")
                window.orderOut(nil)
                await settle()
                check(rim?.debugRunning == false && gif?.animates == false, "\(name) offscreen window stops animation")
                window.makeKeyAndOrderFront(nil)
                await settle()
                // Capture the ring alone; GIF motion cannot conceal a static or absent ring.
                if #available(macOS 14.4, *) {
                    do {
                        let motion = try await OwnWindowCompositorProbe.start(window: window)
                        motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
                        let started = motion.now
                        await settle(350)
                        _ = await motion.report(since: started, until: motion.now, expectedText: nil,
                                               directory: root, name: name + "-button")
                        await motion.stop()
                    } catch { check(false, "\(name) full button capture: \(error)") }
                }
                window.contentView = NSView(frame: host.frame)
                await settle()
                check(rim?.debugRunning == false && gif?.animates == false, "\(name) detached views release playback")
                window.close()
                await isolatedRing(root: root, dark: darkMode, check: check)
            }
        } catch { check(false, "Agent fixture completes: \(error)") }
        let report: [String: Any] = ["ok": failed.isEmpty, "passed": passed, "failed": failed,
            "realPaidRequests": 0, "systemInputValidated": false,
            "scope": "4pt Agent texture, native input routing, both appearances, own-window compositor and lifecycle"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }

    private static func isolatedRing(root: URL, dark: Bool, check: (Bool, String) -> Void) async {
        let name = "agent-\(dark ? "dark" : "light")-rim"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1)
                                           : NSColor(white: 0.98, alpha: 1)).cgColor
        let rim = AgentOrbRim.Host(frame: NSRect(x: 10, y: 10, width: 60, height: 60))
        container.addSubview(rim)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        rim.configure(animated: true, highContrast: false)
        window.makeKeyAndOrderFront(nil)
        await settle(220)
        if #available(macOS 14.4, *) {
            do {
                let motion = try await OwnWindowCompositorProbe.start(window: window)
                motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
                let started = motion.now
                await settle(1600)
                let ended = motion.now
                let report = await motion.report(since: started, until: ended, expectedText: nil,
                                                directory: root, name: name)
                check((report["changedPixelSamples"] as? Int ?? 0) >= 20,
                      "\(name) alone animates actual system compositor pixels")
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                    .write(to: root.appendingPathComponent(name + "-motion.json"))
                _ = await motion.exportAnimation(since: started, until: ended,
                                                directory: root.appendingPathComponent(name))
                motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
                await settle(120)
                let busyStart = motion.now
                usleep(300_000)
                let busy = await motion.report(since: busyStart, until: motion.now, expectedText: nil,
                                               directory: root, name: name + "-busy")
                check((busy["changedPixelSamples"] as? Int ?? 0) >= 3,
                      "\(name) keeps animating while the main thread is occupied")
                try? JSONSerialization.data(withJSONObject: busy, options: [.prettyPrinted])
                    .write(to: root.appendingPathComponent(name + "-busy.json"))
                await motion.stop()
            } catch { check(false, "\(name) compositor starts: \(error)") }
        } else { check(false, "\(name) compositor requires macOS 14.4") }
        window.close()
    }
}
#endif
