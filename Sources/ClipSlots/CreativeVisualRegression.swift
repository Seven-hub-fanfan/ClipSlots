#if DEBUG
import AppKit
import SwiftUI
import CoreVideo
import ScreenCaptureKit
import CoreMedia
import ClipSlotsKit

/// Samples the display clock and main-queue latency independently of screenshots.
/// These are scheduling measurements, not proof of presented GPU frames.
private final class CreativeFrameSampler {
    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var last: Double?
    private var intervals: [Double] = []
    private var latencies: [Double] = []
    private var ping: DispatchSourceTimer?
    func start() -> Bool {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "clipslots.creative.queue-probe"))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            let now = CACurrentMediaTime()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.latencies.append((CACurrentMediaTime() - now) * 1000)
                self.lock.unlock()
            }
        }
        ping = timer; timer.resume()
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return false }
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let sampler = Unmanaged<CreativeFrameSampler>.fromOpaque(context).takeUnretainedValue()
            sampler.tick()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        return CVDisplayLinkStart(link) == kCVReturnSuccess
    }
    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        if let last { intervals.append((now - last) * 1000) }
        last = now
        lock.unlock()
    }
    func stop() -> [String: Any] {
        if let link { CVDisplayLinkStop(link) }
        ping?.cancel(); ping = nil
        lock.lock(); defer { lock.unlock() }
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["count": 0] }
            return ["count": sorted.count, "p50_ms": sorted[sorted.count / 2],
                    "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                    "p99_ms": sorted[Int(Double(sorted.count - 1) * 0.99)],
                    "max_ms": sorted.last!, "over_16_67_ms": sorted.filter { $0 > 16.67 }.count]
        }
        return ["display_callback": summary(intervals), "main_queue_latency": summary(latencies),
                "metric_scope": "display-clock scheduling, not measured presented-frame FPS"]
    }
    deinit { ping?.cancel(); if let link { CVDisplayLinkStop(link) } }
}

/// Captures only the isolated test window. Timestamps come from completed
/// WindowServer frames, not a timer or a count of SwiftUI body evaluations.
private final class CreativePresentedFrames: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "clipslots.creative.presented-frames")
    private var timestamps: [Double] = []
    func start(windowID: CGWindowID, scale: CGFloat = 2) async throws {
        queue.sync { timestamps.removeAll(keepingCapacity: true) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 8
        config.showsCursor = false
        let next = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                            configuration: config, delegate: nil)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = next
        try await next.startCapture()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete else { return }
        timestamps.append(CMTimeGetSeconds(buffer.presentationTimeStamp))
    }
    func stop() async -> [String: Any] {
        try? await stream?.stopCapture()
        return queue.sync {
            let gaps = zip(timestamps.dropFirst(), timestamps).map { ($0 - $1) * 1000 }.sorted()
            guard let first = timestamps.first, let last = timestamps.last, last > first, !gaps.isEmpty else {
                return ["complete_frames": timestamps.count, "measured_fps": NSNull()]
            }
            return ["complete_frames": timestamps.count, "measured_seconds": last - first,
                    "measured_fps": Double(timestamps.count - 1) / (last - first),
                    "p95_frame_ms": gaps[Int(Double(gaps.count - 1) * 0.95)],
                    "p99_frame_ms": gaps[Int(Double(gaps.count - 1) * 0.99)],
                    "max_frame_ms": gaps.last!, "frames_over_16_67_ms": gaps.filter { $0 > 16.67 }.count,
                    "scope": "ScreenCaptureKit complete frames of isolated animation window; capture overhead included"]
        }
    }
}

extension CanvasWorkspaceView {
    @MainActor func runCreativeVisualProbe(directory: URL) async {
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failures.append(label) }
            NSLog("[CreativeVisual] \(value ? "PASS" : "FAIL") \(label)")
        }
        func settle(_ seconds: Double = 0.18) async { try? await Task.sleep(for: .seconds(seconds)) }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 35 else { return [] }
            let children = node.accessibilityChildren?() ?? []
            let fallback = (node as? NSView)?.subviews ?? []
            return [node] + (children.isEmpty ? fallback : children).flatMap { elements($0 as AnyObject, depth: depth + 1) }
        }
        func find(_ host: NSView, _ id: String) -> AnyObject? {
            elements(host).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        func popover(_ id: String) -> NSView? {
            NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first { find($0, id) != nil }
        }
        func capture(_ host: NSView, _ name: String) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        _ = await AgentProcessRunner.run(executable: "/usr/bin/swift", arguments: ["-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            print(AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)
            var windows: CFTypeRef?
            print(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows).rawValue)
            """, String(ProcessInfo.processInfo.processIdentifier)], timeout: 15)
        UserDefaults.standard.set("deepseek", forKey: AgentPreferences.workspaceBackendKey)
        UserDefaults.standard.set("deepseek", forKey: TikaBackendPreferences.backendKindKey)
        let longSampling = ProcessInfo.processInfo.environment["CLIPSLOTS_CREATIVE_LONG_PROBE"] == "1"
        let haloOnly = ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_PROBE"] == "1"
        let displayUsable = CGDisplayIsActive(CGMainDisplayID()) != 0
            && CGDisplayIsAsleep(CGMainDisplayID()) == 0
            && (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true
        var timing: [String: Any] = ["long_sampling": longSampling]
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for mode in [WorkspaceMode.canvas, .agent] {
                let key = "\(dark ? "dark" : "light")-\(mode.rawValue)"
                let model = AgentChatModel(displayName: "视觉回归", service: AgentService(
                    transport: AgentScriptedTransport(steps: []), secretStore: AgentInMemorySecretStore(key: "fixture")),
                    persistenceURL: directory.appendingPathComponent(key + ".json"))
                func root(dark: Bool) -> some View {
                    AgentSidebarView(model: model, isVisible: .constant(true), workspaceMode: mode)
                        .environment(\.colorScheme, dark ? .dark : .light)
                }
                let host = NSHostingView(rootView: root(dark: dark))
                let window = NSWindow(contentRect: .init(x: 150, y: 100, width: mode == .agent ? 940 : 430, height: 840),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                await settle(1.2)
                if haloOnly {
                    guard let halo = views(host).compactMap({ $0 as? ComposerEntranceGlow.Host }).first else {
                        check(false, "\(key) composer halo mounted"); window.close(); continue
                    }
                    for (name, layer) in [("bottom", halo.bottom), ("sweep", halo.sweep)] {
                        if let image = layer.contents as! CGImage? {
                            let bitmap = NSBitmapImageRep(cgImage: image)
                            try? bitmap.representation(using: .png, properties: [:])?.write(
                                to: directory.appendingPathComponent("creative-halo-\(key)-texture-\(name).png"))
                        }
                    }
                    // Deterministic layer-state screenshots work without an active
                    // display. They verify compositing, not presented-frame cadence.
                    halo.enabled = false; halo.hasPlayed = false; halo.startEntrance()
                    let layers = [halo.glow, halo.inner, halo.inset, halo.bottom, halo.sweep]
                    let animations = layers.flatMap { layer in
                        (layer.animationKeys() ?? []).compactMap { name -> (CALayer, CAKeyframeAnimation)? in
                            guard let animation = layer.animation(forKey: name) as? CAKeyframeAnimation else { return nil }
                            return (layer, animation)
                        }
                    }
                    halo.stop()
                    func scalar(_ animation: CAKeyframeAnimation, at time: Double) -> Double {
                        let phase = min(1, max(0, time / animation.duration))
                        let times = animation.keyTimes!.map(\.doubleValue)
                        let values = animation.values! as! [NSNumber]
                        let index = (0..<times.count-1).first { phase <= times[$0+1] } ?? times.count-2
                        var fraction = (phase-times[index])/(times[index+1]-times[index])
                        if let curve = animation.timingFunctions?[index] {
                            var a = [Float](repeating: 0, count: 2), b = a
                            curve.getControlPoint(at: 1, values: &a); curve.getControlPoint(at: 2, values: &b)
                            func cubic(_ t: Double, _ x: Float, _ y: Float) -> Double {
                                3*(1-t)*(1-t)*t*Double(x)+3*(1-t)*t*t*Double(y)+t*t*t
                            }
                            var lo = 0.0, hi = 1.0
                            for _ in 0..<24 {
                                let mid = (lo+hi)/2
                                if cubic(mid,a[0],b[0]) < fraction { lo = mid } else { hi = mid }
                            }
                            fraction = cubic((lo+hi)/2,a[1],b[1])
                        }
                        return values[index].doubleValue + fraction*(values[index+1].doubleValue-values[index].doubleValue)
                    }
                    for time in [0.0, 0.8, 1.4, 2.5] {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        for (layer, animation) in animations {
                            let value = scalar(animation, at: time)
                            if animation.keyPath == "opacity" { layer.opacity = Float(value) }
                            if animation.keyPath == "transform.translation.x" {
                                layer.transform = CATransform3DMakeTranslation(value, 0, 0)
                            }
                        }
                        CATransaction.commit()
                        capture(host, "creative-halo-\(key)-\(Int(time*10))")
                    }
                    check(!animations.isEmpty, "\(key) captured product animation stops")
                    if ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_EXTENDED"] == "1" {
                        check(halo.isLight == !dark && halo.wash.opacity == 1,
                              "\(key) native appearance preserves full halo strength")
                        let texture = halo.sweep.contents as! CGImage?
                        check(halo.hitTest(.init(x: 20, y: 20)) == nil,
                              "\(key) decoration never intercepts editor or menu clicks")
                        check(!views(host).compactMap { $0 as? AgentDraftEditor.Editor }.isEmpty,
                              "\(key) native text editor remains mounted")
                        // Product animation changes presentation transforms only.
                        // Undo the screenshot's model transform before layout;
                        // assigning frame while translated would move its position.
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        for layer in layers { layer.opacity = 0; layer.transform = CATransform3DIdentity }
                        CATransaction.commit()
                        halo.synchronize()
                        let restingSweepFrame = halo.sweep.frame
                        halo.hasPlayed = true
                        host.rootView = root(dark: !dark)
                        await settle()
                        check(views(host).compactMap { $0 as? ComposerEntranceGlow.Host }.first === halo
                              && halo.isLight == dark, "\(key) theme switch updates existing halo")
                        check(halo.hasPlayed && halo.sweep.contents as! CGImage? !== texture,
                              "\(key) theme switch changes tint without replaying entrance")
                        host.rootView = root(dark: dark)
                        await settle()
                        check(halo.sweep.contents as! CGImage? === texture,
                              "\(key) theme roundtrip reuses cached color texture")
                        check(halo.sweep.frame == restingSweepFrame, "\(key) theme roundtrip preserves sweep geometry")
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        for (layer, animation) in animations {
                            if animation.keyPath == "opacity" { layer.opacity = Float(scalar(animation, at: 0.8)) }
                            if animation.keyPath == "transform.translation.x" {
                                layer.transform = CATransform3DMakeTranslation(scalar(animation, at: 0.8), 0, 0)
                            }
                        }
                        CATransaction.commit()
                        capture(host, "creative-halo-\(key)-roundtrip")
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        for layer in layers { layer.opacity = 0; layer.transform = CATransform3DIdentity }
                        CATransaction.commit()
                        // Accessibility environment keys are read-only. Exercise
                        // the native host policy without changing OS preferences.
                        halo.reduceTransparency = true; halo.synchronize()
                        halo.hasPlayed = false; halo.startEntrance()
                        check(halo.reduceTransparency && halo.layer?.isHidden == true
                              && layers.allSatisfy { $0.animationKeys()?.isEmpty != false },
                              "\(key) reduce transparency removes decoration and animation")
                        capture(host, "creative-halo-\(key)-opaque")
                        halo.reduceTransparency = false; halo.increasedContrast = true; halo.synchronize()
                        halo.hasPlayed = false; halo.startEntrance()
                        check(halo.increasedContrast && halo.layer?.isHidden == true
                              && layers.allSatisfy { $0.animationKeys()?.isEmpty != false },
                              "\(key) high contrast removes decoration and animation")
                        capture(host, "creative-halo-\(key)-contrast")
                        halo.increasedContrast = false; halo.reduceMotion = true; halo.synchronize()
                        await settle(0.5)
                        halo.hasPlayed = false; halo.startEntrance()
                        check(halo.reduceMotion && layers.allSatisfy { $0.animationKeys()?.isEmpty != false },
                              "\(key) reduced motion prevents entrance replay")
                        halo.reduceMotion = false; halo.synchronize()
                        await settle(0.5)
                        check(halo.layer?.isHidden == false && halo.sweep.contents != nil,
                              "\(key) restoring accessibility settings restores ready decoration")
                        if mode == .agent {
                            for width in [420.0, 1200, 560, 420] {
                                window.setContentSize(.init(width: width, height: 700))
                                await settle(0.04)
                            }
                            await settle(0.5)
                            let pixels = (halo.sweep.contents as! CGImage?)?.width
                            let roundedWidth = ceil(Double(halo.bounds.width) / 16) * 16
                            let expected = Int(ceil((roundedWidth * 1.66 + 144) * 2))
                            check(pixels == expected && halo.inset.frame == halo.bounds.insetBy(dx: -1, dy: -1),
                                  "\(key) rapid resize retains latest texture and rounded alignment")
                            capture(host, "creative-halo-\(key)-narrow")
                        }
                    }
                    if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_DEBUG_URL"],
                       let url = URL(string: endpoint) {
                        var request = URLRequest(url: url); request.httpMethod = "POST"
                        request.httpBody = try? JSONSerialization.data(withJSONObject: [
                            "sessionId": "light-agent-halo", "runId": ProcessInfo.processInfo.environment["CLIPSLOTS_HALO_RUN"] ?? "pre-fix",
                            "hypothesisId": "A-C-D", "msg": "[DEBUG] Native Agent deterministic halo captures",
                            "data": ["mode": key, "width": host.bounds.width, "height": host.bounds.height,
                                     "haloBounds": NSStringFromRect(halo.bounds),
                                     "washOpacity": halo.wash.opacity, "isLight": halo.isLight,
                                     "insetOpacity": halo.inset.sublayers?.last?.shadowOpacity ?? -1,
                                     "locked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] ?? false,
                                     "captureMethod": "AppKit cacheDisplay at fixed model layer values, not SCK/FPS"]])
                        _ = try? await URLSession.shared.data(for: request)
                    }
                    window.close(); continue
                }
                check(!views(host).compactMap { $0 as? AgentDraftEditor.Editor }.isEmpty, "\(key) native editor mounted")
                let refresh = find(host, "agent-refresh-suggestions")
                // #region debug-point C:full-agent-refresh-and-hover
                if dark && mode == .agent && displayUsable && CGPreflightScreenCaptureAccess() {
                    let frames = CreativePresentedFrames(), clock = CreativeFrameSampler()
                    do {
                        if ProcessInfo.processInfo.environment["CLIPSLOTS_CREATIVE_SAMPLE"] == "1" {
                            try String(ProcessInfo.processInfo.processIdentifier).write(
                                to: directory.appendingPathComponent("creative-sample-ready"),
                                atomically: true, encoding: .utf8)
                            await settle(0.3)
                        }
                        try await frames.start(windowID: CGWindowID(window.windowNumber))
                        let bodies = CreativeSuggestionCard.debugBodyCount
                        var pressDurations: [Double] = []
                        _ = clock.start()
                        for _ in 0..<5 {
                            let began = CACurrentMediaTime()
                            _ = refresh?.accessibilityPerformPress?()
                            pressDurations.append((CACurrentMediaTime() - began) * 1000)
                            await settle(0.72)
                        }
                        var result = clock.stop()
                        result["presented_frames"] = await frames.stop()
                        result["card_body_evaluations"] = CreativeSuggestionCard.debugBodyCount - bodies
                        result["ax_press_ms"] = pressDurations
                        timing["full_agent_refresh"] = result
                        if ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1",
                           (try? String(contentsOf: directory.appendingPathComponent("mouse-ready"))) == "ready",
                           let rect = refresh?.accessibilityFrame?(), !rect.isEmpty {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                            await settle(0.4)
                            let point = CGPoint(x: rect.midX, y: CGDisplayBounds(CGMainDisplayID()).height - rect.midY)
                            let mouseClock = CreativeFrameSampler()
                            try await frames.start(windowID: CGWindowID(window.windowNumber))
                            let before = CreativeSuggestionCard.debugBodyCount
                            _ = mouseClock.start()
                            var eventLines = ""
                            let clicks = longSampling ? 32 : 5
                            for _ in 0..<clicks {
                                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                                    let event: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                        "window": window.windowNumber, "type": type.rawValue,
                                        "x": point.x, "y": point.y, "clicks": 1]
                                    let data = try JSONSerialization.data(withJSONObject: event)
                                    eventLines += String(decoding: data, as: UTF8.self) + "\n"
                                }
                                try eventLines.write(to: directory.appendingPathComponent("mouse-events.jsonl"),
                                                     atomically: true, encoding: .utf8)
                                await settle(0.72)
                            }
                            var mouseResult = mouseClock.stop()
                            mouseResult["presented_frames"] = await frames.stop()
                            mouseResult["card_body_evaluations"] = CreativeSuggestionCard.debugBodyCount - before
                            mouseResult["system_clicks"] = clicks
                            mouseResult["scope"] = "system mouse clicks from independent event producer"
                            timing["full_agent_system_refresh"] = mouseResult
                            check(CreativeSuggestionCard.debugBodyCount - before >= 20,
                                  "system mouse refresh changes suggestion cards")
                        }
                        try await frames.start(windowID: CGWindowID(window.windowNumber))
                        let hoverBodies = CreativeSuggestionCard.debugBodyCount
                        let hoverStart = CACurrentMediaTime()
                        for i in 0..<240 {
                            let t = Double(i) / 240
                            NotificationCenter.default.post(name: .init("CreativeProbeHover"),
                                object: CGPoint(x: 0.5 + 0.4 * sin(t * .pi * 4), y: 0.5 + 0.4 * cos(t * .pi * 4)))
                            await settle(1 / 120)
                        }
                        timing["full_agent_hover"] = [
                            "presented_frames": await frames.stop(),
                            "card_body_evaluations": CreativeSuggestionCard.debugBodyCount - hoverBodies,
                            "injected_move_events": 240, "elapsed_seconds": CACurrentMediaTime() - hoverStart,
                            "scope": "local pointer-position injection; not system mouse/focus validation"]
                        if ProcessInfo.processInfo.environment["CANVAS_SYSTEM_MOUSE"] == "1",
                           (try? String(contentsOf: directory.appendingPathComponent("mouse-ready"))) == "ready",
                           let card = views(host).compactMap({ $0 as? CreativeCardHighlight.Host }).first {
                            // Reset the synthetic hover before checking real window routing.
                            for item in views(host).compactMap({ $0 as? CreativeCardHighlight.Host }) {
                                item.setInside(false)
                            }
                            let file = directory.appendingPathComponent("mouse-events.jsonl")
                            var lines = (try? String(contentsOf: file)) ?? ""
                            func post(_ type: CGEventType, local: CGPoint) throws {
                                let screen = window.convertPoint(toScreen: card.convert(local, to: nil))
                                let event: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                    "window": window.windowNumber, "type": type.rawValue, "clicks": 1,
                                    "x": screen.x, "y": CGDisplayBounds(CGMainDisplayID()).height - screen.y]
                                lines += String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n"
                                try lines.write(to: file, atomically: true, encoding: .utf8)
                            }
                            let systemHoverClock = CreativeFrameSampler()
                            try await frames.start(windowID: CGWindowID(window.windowNumber))
                            _ = systemHoverClock.start()
                            let before = CreativeSuggestionCard.debugBodyCount
                            let beforeEvents = card.debugEvents
                            let moves = longSampling ? 1200 : 24
                            for index in 0..<moves {
                                let x = longSampling
                                    ? 0.4875 - 0.2875 * cos(Double(index) / Double(moves - 1) * .pi * 39)
                                    : 0.2 + Double(index) / 40
                                try post(.mouseMoved, local: .init(x: card.bounds.width * x,
                                                                  y: card.bounds.midY))
                                await settle(1 / 60)
                            }
                            await settle(0.25)
                            check(card.spot.opacity == 1, "system mouse enters card highlight")
                            check(abs(card.spot.position.x - card.bounds.width * 0.775) < 24,
                                  "system mouse moves highlight in card coordinates")
                            timing["system_hover_card_body_evaluations"] = CreativeSuggestionCard.debugBodyCount - before
                            timing["system_hover_events"] = card.debugEvents.mapValues { $0 }.reduce(into: [String: Int]()) {
                                $0[$1.key] = $1.value - (beforeEvents[$1.key] ?? 0)
                            }
                            timing["system_hover_last_exit"] = card.debugLastExit
                            timing["system_hover_opacity"] = card.spot.opacity
                            var systemHover = systemHoverClock.stop()
                            systemHover["presented_frames"] = await frames.stop()
                            systemHover["system_moves"] = moves
                            timing["full_agent_system_hover"] = systemHover
                            check(CreativeSuggestionCard.debugBodyCount - before <= 6,
                                  "system pointer movement does not repeatedly rebuild cards")
                            try post(.mouseMoved, local: .init(x: card.bounds.midX, y: -40))
                            await settle(0.3)
                            check(card.spot.opacity == 0, "system mouse exit clears card highlight")
                            let center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
                            try post(.leftMouseDown, local: center); try post(.leftMouseUp, local: center)
                            await settle(0.4)
                            check(!model.draft.isEmpty && model.messages.isEmpty,
                                  "system card click fills draft without sending")
                            model.draft = ""
                        }
                    } catch { timing["agent_capture_error"] = String(describing: error) }
                }
                // #endregion
                check(refresh?.accessibilityPerformPress?() == true, "\(key) refresh button responds")
                _ = refresh?.accessibilityPerformPress?()
                _ = refresh?.accessibilityPerformPress?()
                await settle(0.95)
                check(model.messages.isEmpty && model.draft.isEmpty, "\(key) rapid refresh never submits or edits draft")
                capture(host, "creative-welcome-" + key)
                model.draft = "未发送的中文🙂"
                let skill = find(host, "agent-reference-skill")
                check(skill?.accessibilityPerformPress?() == true, "\(key) skill picker opens")
                await settle()
                if let panel = popover("agent-skill-search") { capture(panel, "creative-skills-" + key) }
                check(popover("agent-skill-search") != nil, "\(key) skill search visible")
                let models = find(host, "agent-model-picker")
                check(models?.accessibilityPerformPress?() == true, "\(key) model picker opens")
                await settle(0.4)
                check(popover("agent-skill-search") == nil && popover("creative-model-search") != nil,
                      "\(key) model and skill popovers are mutually exclusive")
                if let panel = popover("creative-model-search") {
                    capture(panel, "creative-models-" + key)
                    let choice = find(panel, "creative-model-deepseek-chat")
                    check(choice?.accessibilityPerformPress?() == true, "\(key) model row selects")
                } else { check(false, "\(key) model panel reachable") }
                await settle()
                check(UserDefaults.standard.string(forKey: AgentPreferences.modelKey) == "deepseek-chat",
                      "\(key) choice updates actual model preference")
                check(model.draft == "未发送的中文🙂" && model.messages.isEmpty, "\(key) popover selection preserves draft and never sends")
                if mode == .agent {
                    window.setContentSize(.init(width: 420, height: 700))
                    model.draft = ""
                    await settle(1.1)
                    capture(host, "creative-compact-" + key)
                    check(host.bounds.width <= 420 && host.bounds.height <= 700, "\(key) compact viewport remains bounded")
                }
                window.close()
            }
        }
        if haloOnly {
            let report: [String: Any] = ["passed": passed, "failures": failures,
                "scope": "Native AppKit deterministic compositing; no performance or desktop-input claim"]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            exit(0)
        }
        // Timeline and lifecycle tests can be exercised under a locked desktop by
        // explicitly installing layers, without calling that visible-frame evidence.
        let mark = CreativeLoadingMark.Host(frame: .init(x: 0, y: 0, width: 64, height: 64))
        mark.synchronize(); mark.startAnimations()
        let morph = mark.shape.animation(forKey: "morph") as? CAKeyframeAnimation
        check(morph?.duration == 3.44 && morph?.values?.count == 87, "white morph spans 86 forty-ms intervals")
        check(mark.shape.animation(forKey: "breath")?.duration == 2, "white breath uses two-second period")
        mark.reduceMotion = true; mark.synchronize()
        check(mark.shape.animationKeys()?.isEmpty != false, "reduce motion stops white animation")
        mark.reduceMotion = false; mark.startAnimations(); mark.removeFromSuperview(); mark.synchronize()
        check(mark.shape.animationKeys()?.isEmpty != false, "detached loading mark stops all animations")
        let glow = ComposerEntranceGlow.Host(frame: .init(x: 0, y: 0, width: 480, height: 140))
        glow.synchronize()
        await settle(0.6)
        glow.startEntrance()
        check(glow.sweep.animation(forKey: "sweep")?.duration == 2.5, "blue sweep is one 2.5-second entrance")
        check(glow.sweep.animation(forKey: "sweep")?.repeatCount == 0, "blue sweep never loops")
        let insetPath = glow.inset.sublayers?.first?.shadowPath
        check(insetPath?.contains(CGPoint(x: glow.inset.bounds.midX, y: glow.inset.bounds.midY)) == false
              && insetPath?.contains(CGPoint(x: -8, y: -8)) == true,
              "inset shadow has a hollow center and exterior caster")
        glow.reduceMotion = true; glow.synchronize()
        check(glow.sweep.animationKeys()?.isEmpty != false, "reduce motion clears entrance layers")
        check(glow.inset.animationKeys()?.isEmpty != false, "reduce motion clears inset light")
        mark.startAnimations()
        mark.setFrameSize(.zero); mark.synchronize()
        check(mark.shape.animationKeys()?.isEmpty != false, "collapsed loading mark stops work")
        mark.setFrameSize(.init(width: 96, height: 96)); mark.synchronize()
        check((mark.shape.path?.boundingBox.width ?? 0) < 96 && mark.shape.bounds.width == 96,
              "loading mark rebuilds geometry after resizing")
        mark.setFrameSize(.init(width: 64, height: 64)); mark.synchronize()
        glow.reduceMotion = false; glow.hasPlayed = false; glow.startEntrance()
        glow.setFrameSize(.zero); glow.synchronize()
        check(glow.sweep.animationKeys()?.isEmpty != false, "collapsed composer stops glow")
        for width in [464.0, 640, 320, 464] {
            glow.setFrameSize(.init(width: width, height: 121)); glow.synchronize()
        }
        await settle(0.7)
        let texturePixels = glow.sweep.contents.map { ($0 as! CGImage).width }
        check(texturePixels == Int(ceil((464 * 1.66 + 144) * 2)),
              "rapid resize finishes with latest width texture")
        check(glow.inset.frame == glow.bounds.insetBy(dx: -1, dy: -1)
              && glow.inset.sublayers?.allSatisfy({ $0.bounds == glow.inset.bounds }) == true,
              "resized inset shadow remains aligned to composer boundary")
        if let image = CreativeMotion.gradientTexture(width: 400, sweep: false) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            let upper = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 160)?.alphaComponent ?? 0
            let lower = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 316)?.alphaComponent ?? 0
            check(lower > upper * 2, "bottom wash concentrates light at lower edge")
        } else { check(false, "bottom wash texture available") }

        let hoverSurface = NSView(frame: .init(x: 0, y: 0, width: 240, height: 160))
        let highlight = CreativeCardHighlight.Host(frame: hoverSurface.bounds)
        let hoverWindow = NSWindow(contentRect: hoverSurface.bounds, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        hoverWindow.isReleasedWhenClosed = false; hoverWindow.contentView = hoverSurface
        hoverSurface.addSubview(highlight)
        highlight.updateTrackingAreas()
        var hoverChanges: [Bool] = []
        highlight.onHoverChanged = { hoverChanges.append($0) }
        for i in 0..<240 { highlight.move(to: .init(x: i, y: 80)) }
        check(hoverChanges == [true], "240 pointer moves publish only one entry")
        check(highlight.spot.position == .init(x: 239, y: 80), "spot follows pointer in local coordinates")
        check(highlight.hitTest(.init(x: 20, y: 20)) == nil, "highlight leaves click routing to card")
        highlight.reduceMotion = true
        check(highlight.spot.animationKeys()?.isEmpty != false, "reduce motion clears running hover fade")
        highlight.isHidden = true
        check(hoverChanges == [true, false] && highlight.spot.opacity == 0,
              "hidden card clears hover state")
        highlight.isHidden = false; highlight.reduceMotion = false
        highlight.move(to: .init(x: 100, y: 60)); highlight.removeFromSuperview()
        check(hoverChanges == [true, false, true, false] && highlight.spot.animationKeys()?.isEmpty != false,
              "detached card clears state and animations")
        hoverWindow.close()
        let motionSurface = NSView(frame: .init(x: 0, y: 0, width: 560, height: 300))
        motionSurface.wantsLayer = true
        motionSurface.layer?.backgroundColor = NSColor.black.cgColor
        let motionWindow = NSWindow(contentRect: motionSurface.bounds, styleMask: [.titled],
                                    backing: .buffered, defer: false)
        motionWindow.isReleasedWhenClosed = false
        motionWindow.contentView = motionSurface
        mark.frame.origin = .init(x: 248, y: 180)
        glow.frame.origin = .init(x: 40, y: 20)
        motionSurface.addSubview(mark); motionSurface.addSubview(glow)
        motionWindow.orderFront(nil)
        await settle()
        mark.shape.fillColor = NSColor.white.cgColor
        mark.reduceMotion = false; glow.reduceMotion = false; glow.hasPlayed = false
        mark.startAnimations(); glow.startEntrance()
        let sampler = CreativeFrameSampler()
        let captureFrames = CreativePresentedFrames()
        var captureError: String?
        if displayUsable && CGPreflightScreenCaptureAccess() {
            do { try await captureFrames.start(windowID: CGWindowID(motionWindow.windowNumber)) }
            catch { captureError = String(describing: error) }
        } else { captureError = displayUsable ? "Screen capture permission is not available; no permission was requested." :
            "Desktop locked or display asleep/inactive; presented-frame acceptance blocked." }
        let started = sampler.start()
        await settle(longSampling ? 20 : 4.2)
        timing.merge(sampler.stop()) { _, new in new }
        timing["presented_frames"] = await captureFrames.stop()
        if let captureError { timing["capture_error"] = captureError }
        timing["display_link_started"] = started
        timing["loading_animation_attached_at_end"] = mark.shape.animation(forKey: "morph") != nil
        timing["screen_max_fps"] = NSScreen.main?.maximumFramesPerSecond ?? 0
        // A trivial compositor-only control distinguishes capture/desktop
        // throttling from the cost of our morph and glow geometry.
        mark.removeFromSuperview(); glow.removeFromSuperview()
        if displayUsable && CGPreflightScreenCaptureAccess() {
            let control = CALayer()
            control.frame = CGRect(x: 20, y: 100, width: 64, height: 64)
            control.backgroundColor = NSColor.white.cgColor
            motionSurface.layer?.addSublayer(control)
            let movement = CABasicAnimation(keyPath: "transform.translation.x")
            movement.fromValue = 0; movement.toValue = 440; movement.duration = 2
            movement.autoreverses = true; movement.repeatCount = .infinity
            movement.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            control.add(movement, forKey: "capture-control")
            let controlFrames = CreativePresentedFrames()
            do {
                try await controlFrames.start(windowID: CGWindowID(motionWindow.windowNumber))
                await settle(longSampling ? 20 : 3.2)
                timing["simple_layer_control"] = await controlFrames.stop()
                try await controlFrames.start(windowID: CGWindowID(motionWindow.windowNumber), scale: 1)
                await settle(3.2)
                timing["simple_layer_control_1x"] = await controlFrames.stop()
            } catch { timing["control_capture_error"] = String(describing: error) }
            control.removeFromSuperlayer()
        }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        timing["session_locked"] = locked
        timing["low_power_mode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        timing["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
        timing["main_display_active"] = CGDisplayIsActive(CGMainDisplayID()) != 0
        timing["main_display_asleep"] = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        timing["note"] = locked ? "Desktop locked; capture is not an interactive desktop acceptance test." :
            "WindowServer capture measures only this animation surface, not all product interactions."
        // #region debug-point A-B-C:measured-cadence
        if let endpoint = ProcessInfo.processInfo.environment["CLIPSLOTS_CREATIVE_DEBUG_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "creative-frame-cadence", "runId": ProcessInfo.processInfo.environment["CANVAS_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "A-B-C", "msg": "[DEBUG] measured native cadence and card invalidations", "data": timing]); _ = try? await URLSession.shared.data(for: request) }
        // #endregion
        try? JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("creative-timing.json"))
        motionWindow.close()
        // Render original vector key poses as a reviewable artifact.
        let contact = NSImage(size: .init(width: 600, height: 160))
        contact.lockFocus()
        NSColor.black.setFill(); NSBezierPath(rect: .init(x: 0, y: 0, width: 600, height: 160)).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(NSColor.white.cgColor)
            for i in 0..<10 {
                context.saveGState(); context.translateBy(x: CGFloat(i % 5) * 120 + 28, y: CGFloat(i / 5) * 80 + 8)
                context.addPath(CreativeMotion.loadingPath(phase: Double(i) / 10, size: 64)); context.fillPath()
                context.restoreGState()
            }
        }
        contact.unlockFocus()
        if let data = contact.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("creative-white-poses.png"))
        }
        let report: [String: Any] = ["passed": passed, "failures": failures, "sessionLocked": locked]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        exit(0)
    }
}
#endif
