#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentPanelResizeProbe(check: (Bool, String) -> Void) async {
    func settle() async { try? await Task.sleep(for: .milliseconds(90)) }
    func elements(_ object: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = object.accessibilityChildren?() ?? []
        return [object] + (children.isEmpty ? (object as? NSView)?.subviews ?? [] : children)
            .flatMap { elements($0 as AnyObject, depth: depth + 1) }
    }
    func editors(_ view: NSView) -> [AgentDraftEditor.Editor] {
        (view as? AgentDraftEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    let defaults = UserDefaults.standard, key = "agent.panel.requestedWidth", previous = defaults.object(forKey: "agent.panel.requestedWidth")
    defer {
        if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    defaults.set(440.0, forKey: key)
    AgentSidebarView.debugWidthWrites = 0; AgentSidebarView.debugLiveWidth = nil
    let model = AgentChatModel(displayName: "resize fixture",
        service: AgentService(transport: AgentScriptedTransport(steps: []), secretStore: AgentInMemorySecretStore(key: "fixture")))
    model.draft = "保持输入身份🙂"
    let host = NSHostingView(rootView: HStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity)
        AgentSidebarView(model: model, isVisible: .constant(true))
    })
    let window = NSWindow(contentRect: NSRect(x: 30, y: 60, width: 1440, height: 800),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
    await settle(); await settle()
    guard let editor = editors(host).first else {
        check(false, "resize native editor exists"); window.close(); return
    }
    let editorID = ObjectIdentifier(editor)
    window.makeFirstResponder(editor)
    let start = host.convert(CGPoint(x: host.bounds.width - 440 + 4, y: host.bounds.height / 2), to: nil)
    func mouse(_ type: NSEvent.EventType, dx: CGFloat) {
        if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x + dx, y: start.y),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { window.sendEvent(event) }
    }
    mouse(.leftMouseDown, dx: 0)
    for i in 1...12 { mouse(.leftMouseDragged, dx: -CGFloat(i) * 8); await settle() }
    check(AgentSidebarView.debugLiveWidth.map { abs($0 - 536) < 3 } == true,
          "native drag changes visual width by pointer displacement")
    check(AgentSidebarView.debugWidthWrites == 0 && defaults.double(forKey: key) == 440,
          "twelve drag callbacks write no persistent width")
    check(editors(host).first.map(ObjectIdentifier.init) == editorID && model.draft == "保持输入身份🙂",
          "resize preserves native editor and draft identity")
    mouse(.leftMouseUp, dx: -96); await settle()
    check(AgentSidebarView.debugWidthWrites == 1 && abs(defaults.double(forKey: key) - 536) < 3,
          "mouse release persists final width exactly once")
    window.close()
}
#endif
