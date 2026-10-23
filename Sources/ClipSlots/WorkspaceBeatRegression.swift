#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runWorkspaceBeatProbe(directory: URL, check: (Bool, String) -> Void) async {
    final class Selection: ObservableObject {
        @Published var mode = WorkspaceMode.canvas
    }
    struct Fixture: View {
        @ObservedObject var state: Selection
        var body: some View { WorkspaceModeSwitcher(selection: $state.mode).padding(20) }
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
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 310, height: 90),
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
        .write(to: directory.appendingPathComponent("workspace-beat-ax.json"))
    let beat = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "workspace-beat"
        || ($0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "测评（Beat）") }
    check(beat != nil && beat?.accessibilityLabel?() == "测评（Beat）", "native top bar names the placeholder 测评（Beat）")
    check(beat?.isAccessibilityEnabled?() == false, "Beat is disabled in the native accessibility tree")
    _ = beat?.accessibilityPerformPress?()
    try? await Task.sleep(for: .milliseconds(80))
    check(state.mode == .canvas, "native Beat press cannot leave the canvas")
    check(!WorkspaceMode.agent.isSelectable, "legacy agent route is not a selectable workspace")
    let edit = elements(window).first { ($0.accessibilityIdentifier?() ?? "") == "workspace-edit"
        || ($0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "编辑") }
    _ = edit?.accessibilityPerformPress?()
    try? await Task.sleep(for: .milliseconds(100))
    if edit == nil {
        let point = CGPoint(x: host.bounds.midX - 78, y: host.bounds.midY)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
        }
        try? await Task.sleep(for: .milliseconds(150))
    }
    check(state.mode == .edit, "edit workspace still opens through its native control")
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("workspace-beat.png"))
    }
}
#endif
