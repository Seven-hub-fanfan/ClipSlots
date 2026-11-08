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
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(180))
            check(surface?.debugLightHasOrbit == true,
                  "\(dark ? "dark" : "light") selected navigation runs its native light orbit")
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
        capture("workspace-reduced-motion")
        state.reduceMotion = false
        try? await Task.sleep(for: .milliseconds(160))
        check(surface?.debugLightHasOrbit == true, "restoring motion resumes the selected light")
        surface?.isHidden = true
        check(surface?.debugLightHasOrbit == false, "hidden navigation stops the light orbit")
        surface?.isHidden = false
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(160))
        check(surface?.debugLightHasOrbit == false, "offscreen window stops the light orbit")
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(160))
        check(surface?.debugLightHasOrbit == true, "visible window resumes the light orbit")
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
    if includeWelcomeCards {
        await WelcomeCardInteractionRegression.run(directory: directory, check: check)
    }
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
    try? await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
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
        let point = loading.convert(CGPoint(x: 12, y: 140), to: nil)
        let color = bitmap.colorAt(x: Int(point.x * scale),
                                  y: Int((window.frame.height - point.y) * scale))
        let background = dark ? 0 : 236
        let covered = color.map { color in
            [color.redComponent, color.greenComponent, color.blueComponent]
                .allSatisfy { abs(Int(($0 * 255).rounded()) - background) <= 1 }
        } ?? false
        samples.append(["phase": label, "coloredNavigationPixels": colored, "bodyCovered": covered])
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("navigation-cover-\(label).png"))
        return colored > 12 && (!bodyCovered || covered)
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
                  "\(theme) \(mode.rawValue): navigation remains visible during the ready fade and blur")
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
