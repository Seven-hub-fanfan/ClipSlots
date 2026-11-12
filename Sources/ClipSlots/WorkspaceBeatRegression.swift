#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runWorkspaceBeatProbe(directory: URL, includeWelcomeCards: Bool = true, check: (Bool, String) -> Void) async {
    final class Selection: ObservableObject {
        @Published var mode = WorkspaceMode.canvas
        @Published var reduceMotion = false
        var deferCommit = false
        let navigation = WorkspaceNavigationState()
    }
    struct Fixture: View {
        @ObservedObject var state: Selection
        var body: some View {
            WorkspaceNavigationBar(selection: Binding(get: { state.mode }, set: { mode in
                if state.deferCommit {
                    state.navigation.requestedMode = mode
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { state.mode = mode }
            }), navigation: state.navigation, animationsEnabled: !state.reduceMotion)
            .padding(20).background(Color(white: 0.90))
        }
    }
    func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 20 else { return [] }
        let children = node.accessibilityChildren?() ?? []
        let fallback = (node as? NSView)?.subviews ?? []
        return [node] + (children + fallback).flatMap {
            elements($0 as AnyObject, depth: depth + 1)
        }
    }
    let state = Selection()
    let host = NSHostingView(rootView: Fixture(state: state))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 284, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try? await Task.sleep(for: .milliseconds(500))
    host.layoutSubtreeIfNeeded()
    // Ask through an external AX client, enabling SwiftUI's accessibility tree
    // before inspecting it in-process.
    _ = await AgentProcessRunner.run(executable: "/usr/bin/swift",
        arguments: ["-e", """
            import ApplicationServices
            let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            """,
                    String(ProcessInfo.processInfo.processIdentifier)], timeout: 15)
    let nodes = elements(window)
    let description = nodes.map { [
        "id": $0.accessibilityIdentifier?() ?? "", "role": $0.accessibilityRole?()?.rawValue ?? "",
        "label": $0.accessibilityLabel?() ?? "", "enabled": $0.isAccessibilityEnabled?() ?? false
    ] as [String: Any] }
    try? JSONSerialization.data(withJSONObject: description, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("workspace-models-ax.json"))
    let models = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "workspace-models" }
    check(models != nil && models?.accessibilityLabel?() == "模型", "native top bar shows 模型")
    check(!nodes.contains { ($0.accessibilityLabel?() ?? "").contains("Beat") }, "native top bar removes Beat label")
    check(models?.isAccessibilityEnabled?() == true, "models workspace is available")
    _ = models?.accessibilityPerformPress?()
    try? await Task.sleep(for: .milliseconds(80))
    check(state.mode == .agent, "native models button opens the model workspace")
    check(WorkspaceMode.agent.isSelectable, "model route is selectable")
    state.mode = .canvas
    check(WorkspaceBrandResources.markURL.flatMap { NSImage(contentsOf: $0) } != nil,
          "original app-center artwork loads from bundled transparent resource")
    let edit = elements(window).first { ($0.accessibilityIdentifier?() ?? "") == "workspace-edit"
        || ($0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "编辑") }
    let canvas = elements(window).first { ($0.accessibilityIdentifier?() ?? "") == "workspace-canvas" }
    if let a = edit?.accessibilityFrame?(), let b = canvas?.accessibilityFrame?(), let c = models?.accessibilityFrame?() {
        check(abs(a.width-b.width)<0.5 && abs(b.width-c.width)<0.5
            && abs(a.midY-b.midY)<0.5 && abs(b.midY-c.midY)<0.5, "all three native segments have equal width and baseline")
    } else { check(false, "native segment frames available") }
    @discardableResult func capture(_ name: String) -> Double {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
            let x = Int((host.bounds.midX + WorkspaceModeSwitcher.preferredWidth / 2 - 10)
                * CGFloat(bitmap.pixelsWide) / host.bounds.width)
            if let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) {
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
        }
        return -1
    }
    let originalSkin = AppSkinCenter.current
    var paletteSamples = [[String: Any]]()
    for skin in AppSkin.allCases {
        AppSkinCenter.apply(skin)
        for dark in [false, true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(180))
            let name = "workspace-\(skin.rawValue)-\(dark ? "dark" : "light")"
            let brightness = capture(name)
            check(dark ? brightness >= 0 && brightness < 0.25 : brightness > 0.92,
                "\(name) live appearance renders \(dark ? "black" : "white") base")
            paletteSamples.append(["theme": name, "baseBrightness": brightness])
        }
    }
    AppSkinCenter.apply(originalSkin)
    try? JSONSerialization.data(withJSONObject: paletteSamples, options: [.prettyPrinted])
        .write(to: directory.appendingPathComponent("workspace-palette.json"))
    let buttons = nodes.filter { $0.accessibilityRole?() == .button }
    check(Set(buttons.compactMap { $0.accessibilityIdentifier?() }).count == 3,
          "decorative brand mark adds no accessible button or selection")
    let decorationPoint = CGPoint(x: host.bounds.midX - WorkspaceModeSwitcher.preferredWidth / 2 + 29,
                                  y: host.bounds.midY)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: host.convert(decorationPoint, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            window.sendEvent(event)
        }
    }
    try? await Task.sleep(for: .milliseconds(100))
    check(state.mode == .canvas, "native click on decorative brand mark leaves selection unchanged")
    var motion: OwnWindowCompositorProbe?
    if #available(macOS 14.4, *) {
        do {
            motion = try await OwnWindowCompositorProbe.start(window: window)
            motion?.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
            try? await Task.sleep(for: .milliseconds(180))
        } catch { check(false, "own-window animation capture starts: \(error.localizedDescription)") }
    }
    capture("workspace-contour-before")
    let started = motion?.now ?? 0
    _ = edit?.accessibilityPerformPress?()
    for index in 0..<18 {
        try? await Task.sleep(for: .milliseconds(25))
        capture(String(format: "workspace-motion-%02d", index))
    }
    if edit == nil {
        let point = CGPoint(x: host.bounds.midX - 41, y: host.bounds.midY)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
        }
        try? await Task.sleep(for: .milliseconds(150))
    }
    check(state.mode == .edit, "edit workspace still opens through its native control")
    if let motion {
        let ended = motion.now
        let report = await motion.report(since: started, until: ended, expectedText: nil,
                                        directory: directory, name: "workspace-contour")
        check((report["changedPixelSamples"] as? Int ?? 0) >= 4,
              "adaptive contour animates through distinct compositor frames with parent animations disabled")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("workspace-motion.json"))
        _ = await motion.exportAnimation(since: started, until: ended,
            directory: directory.appendingPathComponent("workspace-compositor-animation"))
        let surface = elements(host).compactMap { $0 as? WorkspaceContourSurface.Host }.first
        check(surface != nil, "native compositor surface is present behind SwiftUI buttons")
        let rim = elements(host).compactMap { $0 as? WorkspaceOuterRim.Host }.first
        check(rim != nil && rim?.bounds.size == CGSize(width: 244, height: 40)
              && rim?.hitTest(CGPoint(x: 100, y: 20)) == nil,
              "outer capsule light covers the complete navigation without intercepting input")
        let metalArt = elements(host).compactMap { $0 as? WorkspaceMetalArtwork.Host }
        check(Set(metalArt.map(\.debugKind)) == [.edit],
              "only the selected navigation symbol uses a B metal playback layer")
        let brand = elements(host).compactMap { $0 as? WorkspaceBrandMark.Host }.first
        check(brand != nil && brand?.bounds.size == CGSize(width: 22, height: 25),
              "brand restores the original artwork view and 22 by 25 point size")
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(180))
            check(surface?.debugLightHasOrbit == true,
                  "\(dark ? "dark" : "light") selected navigation runs its native light orbit")
            check(rim?.debugRunning == true && rim?.debugFrameCount == 150,
                  "\(dark ? "dark" : "light") outer capsule plays the complete reference palette")
            motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
            let orbitStarted = motion.now
            try? await Task.sleep(for: .seconds(2.6))
            let name = "workspace-light-\(dark ? "dark" : "light")"
            let orbitReport = await motion.report(since: orbitStarted, until: motion.now,
                expectedText: nil, directory: directory, name: name)
            check((orbitReport["changedPixelSamples"] as? Int ?? 0) >= 6,
                  "\(name) has moving compositor pixels while selection is stationary")
            _ = await motion.exportAnimation(since: orbitStarted, until: motion.now,
                directory: directory.appendingPathComponent(name))
            let art = elements(host).compactMap { $0 as? WorkspaceMetalArtwork.Host }
            check(art.count == 1 && art.allSatisfy { $0.debugFrameCount == 150 && $0.debugRunning },
                  "\(name) selected symbol plays the complete sampled reflection cycle")
            if let brand, let bitmap = brand.bitmapImageRepForCachingDisplay(in: brand.bounds) {
                brand.cacheDisplay(in: brand.bounds, to: bitmap)
                var colored = 0, opaque = 0
                var totalBrightness: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.5 else { continue }
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        opaque += 1
                        totalBrightness += channels.reduce(0, +) / 3
                        if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.08 { colored += 1 }
                    }
                }
                let brightness = totalBrightness / CGFloat(max(1, opaque))
                check(opaque > 12 && colored == 0 && (dark ? brightness > 0.55 : brightness < 0.45),
                      "\(name) original brand has monochrome artwork and the correct theme inversion")
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("original-brand-\(dark ? "dark" : "light").png"))
            } else { check(false, "\(name) original brand raster is available") }
        }
        motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
        state.deferCommit = true
        let deferredStarted = motion.now
        _ = canvas?.accessibilityPerformPress?()
        check(state.mode == .edit && state.navigation.requestedMode == .canvas,
              "requested navigation responds before deferred workspace commit")
        check(surface?.debugHasAnimation == true,
              "native contour starts synchronously inside the click action")
        try? await Task.sleep(for: .milliseconds(50))
        let stalledAt = motion.now
        // Reproduce the main-thread work encountered during page mounting.
        func simulateMountWork() { Thread.sleep(forTimeInterval: 0.12) }
        simulateMountWork()
        let resumedAt = motion.now
        try? await Task.sleep(for: .milliseconds(250))
        let deferredEnded = motion.now
        _ = await motion.exportAnimation(since: deferredStarted, until: deferredEnded,
            directory: directory.appendingPathComponent("workspace-deferred-animation"))
        try? JSONSerialization.data(withJSONObject: [
            "clickedAt": deferredStarted, "mainBlockedAt": stalledAt,
            "mainResumedAt": resumedAt, "endedAt": deferredEnded
        ], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("workspace-deferred-timing.json"))
        capture("workspace-pending-canvas")
        state.navigation.requestedMode = nil
        try? await Task.sleep(for: .milliseconds(450))
        check(state.mode == .edit && abs((surface?.debugVisibleCenter ?? 0) - 81) < 0.5,
              "abandoned deferred request restores the committed edit selection")
        capture("workspace-restored-edit")
        state.deferCommit = false
        motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
        let reversalStarted = motion.now
        _ = canvas?.accessibilityPerformPress?()
        try? await Task.sleep(for: .milliseconds(70))
        let beforeReverse = surface?.debugVisibleCenter ?? 0
        let lightBeforeReverse = surface?.debugLightVisibleCenter ?? 0
        _ = edit?.accessibilityPerformPress?()
        let afterReverse = surface?.debugVisibleCenter ?? 0
        let lightAfterReverse = surface?.debugLightVisibleCenter ?? 0
        check(abs(beforeReverse - afterReverse) < 1,
              "rapid reversal continues from the presented position without a jump")
        check(abs(lightBeforeReverse - lightAfterReverse) < 1
              && abs(afterReverse - lightAfterReverse) < 1,
              "moving prism remains attached to the selected arch during rapid reversal")
        try? await Task.sleep(for: .milliseconds(450))
        check(abs((surface?.debugVisibleCenter ?? 0) - 81) < 0.5,
              "rapid reversal settles at the latest requested workspace")
        _ = await motion.exportAnimation(since: reversalStarted, until: motion.now,
            directory: directory.appendingPathComponent("workspace-reversal-animation"))
        let transition = WorkspaceTransition()
        var erroneouslyCommitted = false
        transition.switchTo(.canvas, prepare: {
            try? await Task.sleep(for: .milliseconds(60))
            return false
        }, commit: { erroneouslyCommitted = true })
        check(transition.navigation.requestedMode == .canvas,
              "real workspace preparation publishes its requested selection immediately")
        for _ in 0..<40 where transition.isSwitching {
            try? await Task.sleep(for: .milliseconds(25))
        }
        check(!transition.isSwitching && transition.navigation.requestedMode == nil && !erroneouslyCommitted,
              "real failed workspace preparation rolls navigation back")
        transition.switchTo(.canvas, prepare: {
            try? await Task.sleep(for: .seconds(1))
            return true
        }, commit: { erroneouslyCommitted = true })
        transition.cancel()
        check(transition.navigation.requestedMode == nil && !transition.isSwitching,
              "real cancelled workspace request restores navigation immediately")
        motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
        state.reduceMotion = true
        try? await Task.sleep(for: .milliseconds(160))
        _ = canvas?.accessibilityPerformPress?()
        try? await Task.sleep(for: .milliseconds(400))
        check(state.mode == .canvas, "reduced-motion native switch still changes workspace")
        check(surface?.debugHasAnimation == false,
              "reduced-motion switch updates both native layers without animation")
        check(surface?.debugLightHasOrbit == false,
              "reduced-motion preference stops continuous light motion")
        check(rim?.debugRunning == false, "reduced motion stops the outer capsule light")
        check(elements(host).compactMap { $0 as? WorkspaceMetalArtwork.Host }.allSatisfy { !$0.debugRunning },
              "reduced motion also stops selected-symbol reflections")
        capture("workspace-reduced-motion")
        state.reduceMotion = false
        try? await Task.sleep(for: .milliseconds(160))
        check(surface?.debugLightHasOrbit == true, "restoring motion resumes the selected light")
        check(rim?.debugRunning == true, "restoring motion resumes the outer capsule light")
        rim?.isHidden = true
        check(rim?.debugRunning == false, "hidden outer capsule suspends its light")
        rim?.isHidden = false
        surface?.isHidden = true
        check(surface?.debugLightHasOrbit == false, "hidden navigation stops the light orbit")
        surface?.isHidden = false
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(160))
        check(surface?.debugLightHasOrbit == false, "offscreen window stops the light orbit")
        check(rim?.debugRunning == false, "offscreen window suspends the outer capsule light")
        check(elements(host).compactMap { $0 as? WorkspaceMetalArtwork.Host }.allSatisfy { !$0.debugRunning },
              "offscreen window suspends every B reflection layer")
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(160))
        check(surface?.debugLightHasOrbit == true, "visible window resumes the light orbit")
        check(rim?.debugRunning == true, "visible window resumes the outer capsule light")
        if let rim {
            rim.configure(animated: true, highContrast: true)
            check(!rim.debugRunning && rim.debugHiddenForContrast,
                  "increased contrast removes colored outer light and preserves the base outline")
        }
        if let surface {
            surface.configure(center: WorkspaceModeSwitcher.center(for: .canvas),
                halfWidth: WorkspaceModeSwitcher.contourHalfWidth, animated: true, highContrast: true)
            check(!surface.debugLightHasOrbit && surface.debugLightIsHidden,
                  "increased contrast preserves a clear monochrome contour without moving bloom")
        }
        await motion.stop()
    }
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("workspace-models.png"))
    }
    await runWorkspaceArchRasterProbe(directory: directory, check: check)
    await runWorkspaceOuterRimProbe(directory: directory, check: check)
    runWorkspaceMetalOpticalProbe(directory: directory, check: check)
    if includeWelcomeCards {
        await WelcomeCardInteractionRegression.run(directory: directory, check: check)
    }
}

/// Capture the outer capsule alone, so selected icons and the inner arch cannot
/// make a stationary or missing outer light appear to pass.
@MainActor
private func runWorkspaceOuterRimProbe(directory: URL, check: (Bool, String) -> Void) async {
    for dark in [false, true] {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 284, height: 80))
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1)
                                           : NSColor(white: 0.98, alpha: 1)).cgColor
        let surface = WorkspaceOuterRim.Host(frame: NSRect(x: 20, y: 20, width: 244, height: 40))
        container.addSubview(surface)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 284, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        surface.configure(animated: false, highContrast: false)
        window.makeKeyAndOrderFront(nil)
        surface.layoutSubtreeIfNeeded()
        let name = "outer-rim-\(dark ? "dark" : "light")"
        if let layer = surface.layer,
           let context = CGContext(data: nil, width: 488, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.scaleBy(x: 2, y: 2)
            layer.render(in: context)
            if let image = context.makeImage() {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name + "-poster.png"))
                let patches = [CGRect(x: 180, y: 0, width: 128, height: 5),
                               CGRect(x: 180, y: 75, width: 128, height: 5),
                               CGRect(x: 0, y: 32, width: 5, height: 16),
                               CGRect(x: 483, y: 32, width: 5, height: 16)]
                let coverage = patches.map { rect in
                    (Int(rect.minY)..<Int(rect.maxY)).flatMap { y in
                        (Int(rect.minX)..<Int(rect.maxX)).compactMap { x in
                            bitmap.colorAt(x: x, y: y)?.alphaComponent
                        }
                    }.max() ?? 0
                }
                if dark {
                    check(coverage.allSatisfy { $0 > 0.45 },
                          "\(name) has a continuous outline at the top, bottom and both rounded ends")
                } else {
                    check(coverage.filter { $0 > 0.1 }.count >= 2,
                          "\(name) has local refracted glints; the navigation base supplies the continuous silver outline")
                }
                var colored = 0, interior = 0
                for y in 0..<80 {
                    for x in 0..<488 {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.1 else { continue }
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.16 { colored += 1 }
                        if (100..<388).contains(x) && (12..<68).contains(y) { interior += 1 }
                    }
                }
                check(colored > 12 && interior == 0,
                      "\(name) contains prism pixels only around the outside of the capsule")
            } else { check(false, "\(name) has a raster image") }
        } else { check(false, "\(name) has a raster context") }
        surface.configure(animated: true, highContrast: false)
        try? await Task.sleep(for: .milliseconds(220))
        if #available(macOS 14.4, *) {
            do {
                let motion = try await OwnWindowCompositorProbe.start(window: window)
                motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
                let started = motion.now
                try? await Task.sleep(for: .seconds(1.6))
                let ended = motion.now
                let report = await motion.report(since: started, until: ended, expectedText: nil,
                                                directory: directory, name: name)
                check((report["changedPixelSamples"] as? Int ?? 0) >= 12,
                      "\(name) alone changes actual compositor pixels while navigation is stationary")
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                    .write(to: directory.appendingPathComponent(name + "-motion.json"))
                _ = await motion.exportAnimation(since: started, until: ended,
                                                directory: directory.appendingPathComponent(name))
                motion.begin(region: CGRect(origin: .zero, size: window.frame.size), retainImages: true)
                let blockedStarted = motion.now
                // Deliberately block this isolated fixture's main thread.
                usleep(300_000)
                let blockedEnded = motion.now
                let blocked = await motion.report(since: blockedStarted, until: blockedEnded,
                    expectedText: nil, directory: directory, name: name + "-main-thread-blocked")
                check((blocked["changedPixelSamples"] as? Int ?? 0) >= 3,
                      "\(name) compositor keeps moving during main-thread workspace preparation")
                await motion.stop()
            } catch { check(false, "\(name) compositor starts: \(error.localizedDescription)") }
        }
        window.close()
    }
}

@MainActor
private func runWorkspaceMetalOpticalProbe(directory: URL, check: (Bool, String) -> Void) {
    var samples = [[String: Any]]()
    for dark in [false, true] {
        for kind in [WorkspaceMetalMaterial.Kind.edit, .canvas, .model] {
            guard let image = WorkspaceMetalMaterial.poster(kind, dark: dark) else {
                check(false, "B \(kind.rawValue) reflection resource is available"); continue
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var luminance = [CGFloat]()
            var neutral = 0, opaque = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          c.alphaComponent > 0.85 else { continue }
                    let channels = [c.redComponent, c.greenComponent, c.blueComponent]
                    luminance.append(channels.reduce(0, +) / 3)
                    opaque += 1
                    if (channels.max() ?? 0) - (channels.min() ?? 0) < 0.16 { neutral += 1 }
                }
            }
            let range = (luminance.max() ?? 0) - (luminance.min() ?? 0)
            check(opaque > 12 && range > 0.28 && Double(neutral) / Double(max(1, opaque)) > 0.80,
                  "B \(kind.rawValue) \(dark ? "dark" : "light") retains bright and dark silver faces")
            samples.append(["kind": kind.rawValue, "dark": dark, "opaquePixels": opaque,
                            "neutralPixels": neutral, "silverLuminanceRange": range])
        }
    }
    try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("workspace-metal-optics.json"))
}

/// This verifies production Core Animation pixels offscreen. It deliberately
/// makes no claim about desktop focus, compositor timing or physical input.
@MainActor
func runWorkspaceArchRasterProbe(directory: URL, check: (Bool, String) -> Void) async {
    var crownSamples = [[String: Any]]()
    for dark in [false, true] {
        for highContrast in [false, true] {
          for mode in WorkspaceMode.allCases {
            let surface = WorkspaceContourSurface.Host(frame: NSRect(x: 0, y: 0,
                width: WorkspaceModeSwitcher.preferredWidth, height: WorkspaceModeSwitcher.preferredHeight))
            surface.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let center = WorkspaceModeSwitcher.center(for: mode)
            surface.configure(center: center, halfWidth: WorkspaceModeSwitcher.contourHalfWidth,
                              animated: false, highContrast: highContrast)
            surface.layoutSubtreeIfNeeded()
            guard let layer = surface.layer,
                  let context = CGContext(data: nil, width: Int(surface.bounds.width * 2),
                    height: Int(surface.bounds.height * 2), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                check(false, "native arch raster is available"); continue
            }
            context.scaleBy(x: 2, y: 2)
            layer.render(in: context)
            guard let image = context.makeImage() else {
                check(false, "native arch raster has pixels"); continue
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            let name = "workspace-arch-\(mode.rawValue)-\(dark ? "dark" : "light")-\(highContrast ? "contrast" : "normal")"
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
            func crownAlpha(_ offset: CGFloat) -> CGFloat {
                let x = Int((center + offset) * 2)
                let rows = Array(0..<12) + Array((bitmap.pixelsHigh - 12)..<bitmap.pixelsHigh)
                return rows.compactMap { bitmap.colorAt(x: x, y: $0)?.alphaComponent }.max() ?? 0
            }
            let left = crownAlpha(-6), right = crownAlpha(6)
            check(min(left, right) > 0.45 && (!highContrast || abs(left - right) < 0.04),
                  "\(name) crown remains readable on both sides")
            var coloredPixels = 0, colorOutsideSelection = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.1 else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.16 {
                        coloredPixels += 1
                        if abs(CGFloat(x) / 2 - center) > WorkspaceModeSwitcher.contourHalfWidth + 6 {
                            colorOutsideSelection += 1
                        }
                    }
                }
            }
            check(highContrast ? coloredPixels == 0 : coloredPixels > 12,
                  "\(name) renders the expected prism or increased-contrast fallback")
            check(colorOutsideSelection == 0, "\(name) light stays inside the selected region")
            crownSamples.append(["theme": name, "leftAlpha": left, "rightAlpha": right])
          }
        }
    }
    try? JSONSerialization.data(withJSONObject: crownSamples, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("workspace-arch-pixels.json"))
}
/// Exercise the same loading/navigation modifier used by ContentView, with a
/// delayed preparation and admission queue so the covered phases are observable.
@MainActor
func runWorkspaceNavigationLoadingProbe(directory: URL, check: (Bool, String) -> Void) async {
    @MainActor final class Selection: ObservableObject {
        @Published var mode = WorkspaceMode.edit
        let transition = WorkspaceTransition()
        var preparationAllowed = false
        func select(_ mode: WorkspaceMode) {
            if mode == self.mode { transition.cancel(); return }
            transition.switchTo(mode, prepare: { [self] in
                while !preparationAllowed && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(15))
                }
                return !Task.isCancelled
            }, commit: { [self] in
                self.mode = mode
                transition.sections.enroll((0..<12).map { "cover-fixture-\($0)" })
            })
        }
    }
    struct Fixture: View {
        @ObservedObject var state: Selection
        var body: some View {
            Color.red
                .modifier(WorkspaceLoadingOverlay(transition: state.transition,
                    navigation: WorkspaceNavigationBar(
                        selection: Binding(get: { state.mode }, set: { state.select($0) }),
                        navigation: state.transition.navigation)
                        .padding(.top, WorkspaceModeSwitcher.pinnedTopInset)))
        }
    }
    let state = Selection()
    let host = NSHostingView(rootView: Fixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 480, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { state.transition.cancel(); window.close() }
    // A new hosting window may still be admitted by SwiftUI after the first
    // run-loop turn, especially after the preceding compositor fixtures close.
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if state.transition.surface != nil
            && NativeAccessibilityProbe.elements(host).contains(where: { $0 is WorkspaceContourSurface.Host }) { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    let surface = NativeAccessibilityProbe.elements(host).compactMap { $0 as? WorkspaceContourSurface.Host }.first
    guard let surface, let loading = state.transition.surface else {
        check(false, "loading fixture mounts the production navigation and cover"); return
    }
    var samples = [[String: Any]]()
    func sample(_ label: String, dark: Bool, bodyCovered: Bool) -> Bool {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
        let rect = surface.convert(surface.bounds, to: nil)
        let raster = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        var colored = 0
        for y in Int(raster.minY)..<Int(raster.maxY) {
            for x in Int(raster.minX)..<Int(raster.maxX) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.12 { colored += 1 }
            }
        }
        let center = WorkspaceModeSwitcher.center(for: state.transition.navigation.requestedMode ?? state.mode)
        let text = CGRect(x: raster.minX + (center - 13) * scale,
                          y: raster.minY + 22 * scale, width: 26 * scale, height: 13 * scale).integral
        var luminance = [CGFloat]()
        for y in Int(text.minY)..<Int(text.maxY) {
            for x in Int(text.minX)..<Int(text.maxX) {
                if let color = bitmap.colorAt(x: x, y: y) {
                    luminance.append((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                }
            }
        }
        let textContrast = (luminance.max() ?? 0) - (luminance.min() ?? 0)
        let point = loading.convert(CGPoint(x: 12, y: 140), to: nil)
        let color = bitmap.colorAt(x: Int(point.x * scale),
                                  y: Int((window.frame.height - point.y) * scale))
        let background = dark ? 0 : 236
        let covered = color.map { color in
            [color.redComponent, color.greenComponent, color.blueComponent]
                .allSatisfy { abs(Int(($0 * 255).rounded()) - background) <= 1 }
        } ?? false
        samples.append(["phase": label, "coloredNavigationPixels": colored, "bodyCovered": covered,
                        "selectedLabelContrast": textContrast, "rootContentsScale": host.layer?.contentsScale ?? 0,
                        "rootGeometryFlipped": host.layer?.isGeometryFlipped ?? false])
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("navigation-cover-\(label).png"))
        return colored > 12 && textContrast > 0.56 && (!bodyCovered || covered)
    }
    for dark in [false, true] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try? await Task.sleep(for: .milliseconds(160))
        let theme = dark ? "dark" : "light"
        for mode in [WorkspaceMode.canvas, .agent, .edit] {
            state.preparationAllowed = false
            state.select(mode)
            try? await Task.sleep(for: .milliseconds(80))
            check(state.transition.isSwitching
                  && sample("\(theme)-\(mode.rawValue)-prepare", dark: dark, bodyCovered: true),
                  "\(theme) \(mode.rawValue): navigation and prism remain visible over the opaque preparation cover")
            check(loading.layer?.opacity == 1 && loading.frames?.images.count == 86
                  && loading.symbol.contents != nil,
                  "\(theme) \(mode.rawValue): the original loading animation still covers the unready workspace")
            check(loading.frames?.images.allSatisfy { $0.width == 200 && $0.height == 200 } == true
                  && loading.frames?.lightImages.allSatisfy { $0.width == 200 && $0.height == 200 } == true
                  && abs((loading.frames?.duration ?? 0) - 3.44) < 0.001,
                  "\(theme) \(mode.rawValue): loading retains original resolution and frame timing during the Retina pulse")
            let navigationPoint = CGPoint(x: loading.bounds.midX,
                y: WorkspaceModeSwitcher.pinnedTopInset + WorkspaceModeSwitcher.preferredHeight / 2)
            check(loading.hitTest(navigationPoint) == nil
                  && loading.hitTest(CGPoint(x: 12, y: 140)) === loading,
                  "\(theme) \(mode.rawValue): loading intercepts content input and passes navigation input")
            state.preparationAllowed = true
            var observedMount = false, visibleDuringMount = true
            for _ in 0..<100 where state.transition.isSwitching {
                try? await Task.sleep(for: .milliseconds(15))
                if state.mode == mode && state.transition.isSwitching {
                    observedMount = true
                    visibleDuringMount = visibleDuringMount && sample(
                        "\(theme)-\(mode.rawValue)-mount", dark: dark, bodyCovered: true)
                }
            }
            check(observedMount && visibleDuringMount && state.mode == mode && !state.transition.isSwitching,
                  "\(theme) \(mode.rawValue): navigation stays visible while the destination mounts and becomes ready")
            check(sample("\(theme)-\(mode.rawValue)-reveal", dark: dark, bodyCovered: false),
                  "\(theme) \(mode.rawValue): navigation stays clear and readable during the ready fade")
            check(host.layer?.animation(forKey: "workspace-ready-blur") == nil
                  && (host.layer?.filters ?? []).isEmpty,
                  "\(theme) \(mode.rawValue): ready fade does not blur the loading glyph or destination controls")
            try? await Task.sleep(for: .milliseconds(320))
            check(NativeAccessibilityProbe.elements(host).compactMap { $0 as? WorkspaceContourSurface.Host }.first === surface,
                  "\(theme) \(mode.rawValue): switching preserves the single native navigation instance")
        }
    }
    state.preparationAllowed = false
    state.select(.canvas)
    try? await Task.sleep(for: .milliseconds(100))
    let rect = surface.convert(surface.bounds, to: nil)
    let location = CGPoint(x: rect.minX + WorkspaceModeSwitcher.center(for: .edit), y: rect.midY)
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
    }
    try? await Task.sleep(for: .milliseconds(80))
    check(state.mode == .edit && !state.transition.isSwitching && state.transition.navigation.requestedMode == nil,
          "clicking the current navigation button cancels a pending switch through the active loading cover")
    try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("navigation-cover-pixels.json"))
}
#endif
