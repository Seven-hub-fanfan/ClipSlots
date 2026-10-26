#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runWorkspaceBeatProbe(directory: URL, check: (Bool, String) -> Void) async {
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
    check(models?.isAccessibilityEnabled?() == false, "models placeholder retains its unavailable state")
    _ = models?.accessibilityPerformPress?()
    try? await Task.sleep(for: .milliseconds(80))
    check(state.mode == .canvas, "native models placeholder cannot leave the canvas")
    check(!WorkspaceMode.agent.isSelectable, "legacy agent route is not a selectable workspace")
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
    for colorful in [false, true] {
        AppSkinCenter.apply(colorful ? .colorful : .minimal)
        for dark in [false, true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(180))
            let name = "workspace-\(colorful ? "colorful" : "minimal")-\(dark ? "dark" : "light")"
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
        _ = edit?.accessibilityPerformPress?()
        let afterReverse = surface?.debugVisibleCenter ?? 0
        check(abs(beforeReverse - afterReverse) < 1,
              "rapid reversal continues from the presented position without a jump")
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
        capture("workspace-reduced-motion")
        await motion.stop()
    }
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("workspace-models.png"))
    }
    await WelcomeCardInteractionRegression.run(directory: directory, check: check)
}
#endif
