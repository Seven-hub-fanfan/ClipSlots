#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor enum WelcomeCardInteractionRegression {
    static var retainedWindow: NSWindow?

    static func run(directory: URL, check: (Bool, String) -> Void) async {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func highlights(_ host: NSView) -> [CreativeCardHighlight.Host] {
            views(host).compactMap { $0 as? CreativeCardHighlight.Host }
        }
        let originalSkin = AppSkinCenter.current
        defer { AppSkinCenter.apply(originalSkin) }
        for colorful in [false, true] {
            AppSkinCenter.apply(colorful ? .colorful : .minimal)
            for dark in [false, true] {
                for expanded in [false, true] {
                    let name = "\(colorful ? "colorful" : "minimal")-\(dark ? "dark" : "light")-\(expanded ? "wide" : "sidebar")"
                    let model = AgentChatModel(displayName: "欢迎卡片验收", service: AgentService(
                        transport: AgentScriptedTransport(steps: []),
                        secretStore: AgentInMemorySecretStore(key: "fixture")),
                        persistenceURL: directory.appendingPathComponent("welcome-\(name).json"))
                    let host = NSHostingView(rootView: AgentSidebarView(
                        model: model, isVisible: .constant(true), workspaceMode: .edit, isExpanded: expanded))
                    let window = NSWindow(contentRect: NSRect(x: 100, y: 100,
                        width: expanded ? 940 : 430, height: 900),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.title = "欢迎卡片交互验收"
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .milliseconds(900))
                    host.layoutSubtreeIfNeeded()
                    let cards = highlights(host)
                    check(cards.count == 2, "\(name) original interactive highlights mount on both suggestion cards")
                    func capture(_ stage: String) {
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent("welcome-\(name)-\(stage).png"))
                    }
                    capture("idle")
                    if let card = cards.first {
                        // Keep this local event-injection check independent of the
                        // desktop cursor. Restore tracking for the later system check.
                        let tracking = card.trackingAreas
                        tracking.forEach { card.removeTrackingArea($0) }
                        card.setInside(false)
                        try? await Task.sleep(for: .milliseconds(750))
                        var transitions: [Bool] = []
                        let publish = card.onHoverChanged
                        card.onHoverChanged = { transitions.append($0); publish?($0) }
                        for i in 0..<120 {
                            let point = CGPoint(x: card.bounds.width * (0.2 + 0.6 * CGFloat(i) / 119),
                                                y: card.bounds.midY)
                            let location = card.convert(point, to: nil)
                            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location,
                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, eventNumber: i,
                                clickCount: 0, pressure: 0) {
                                card.mouseMoved(with: event)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(800))
                        check(card.spot.opacity == 1 && abs(card.spot.position.x - card.bounds.width * 0.8) < 1,
                              "\(name) blue spot follows native pointer coordinates")
                        check(transitions == [true], "\(name) pointer movement publishes one hover entry")
                        check(card.hitTest(CGPoint(x: card.bounds.midX, y: card.bounds.midY)) == nil,
                              "\(name) glow remains passive for card clicks")
                        capture("hover")
                        let exitPublish = card.onHoverChanged
                        card.onHoverChanged = { transitions.append($0); exitPublish?($0) }
                        card.setInside(false)
                        try? await Task.sleep(for: .milliseconds(800))
                        check(card.spot.opacity == 0 && transitions == [true, false],
                              "\(name) pointer exit clears hover and glow")
                        capture("exit")
                        card.reduceMotion = true
                        card.move(to: CGPoint(x: card.bounds.midX, y: card.bounds.midY))
                        check(card.spot.animationKeys()?.isEmpty != false,
                              "\(name) reduced motion keeps static hover without a fade")
                        card.setInside(false)
                        card.reduceMotion = false
                        card.onHoverChanged = exitPublish
                        tracking.forEach { card.addTrackingArea($0) }
                        if colorful && dark && expanded
                            && ProcessInfo.processInfo.environment["CLIPSLOTS_WELCOME_SYSTEM_MOUSE"] == "1" {
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
                            try? await Task.sleep(for: .milliseconds(400))
                            var requests = ""
                            func moveSystemPointer(to point: CGPoint) async {
                                let screen = window.convertPoint(toScreen: card.convert(point, to: nil))
                                let event: [String: Any] = [
                                    "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                                    "type": CGEventType.mouseMoved.rawValue, "x": screen.x,
                                    "y": CGDisplayBounds(CGMainDisplayID()).height - screen.y
                                ]
                                if let data = try? JSONSerialization.data(withJSONObject: event) {
                                    requests += String(decoding: data, as: UTF8.self) + "\n"
                                    try? requests.write(to: directory.appendingPathComponent("agent-sidebar-mouse-events.jsonl"),
                                                        atomically: true, encoding: .utf8)
                                }
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                            await moveSystemPointer(to: CGPoint(x: card.bounds.midX, y: -35))
                            let initialBodies = CreativeSuggestionCard.debugBodyCount
                            for i in 0..<8 {
                                await moveSystemPointer(to: CGPoint(x: card.bounds.width * (0.2 + 0.08 * CGFloat(i)),
                                                                   y: card.bounds.midY))
                            }
                            try? await Task.sleep(for: .milliseconds(800))
                            check(card.spot.opacity == 1, "system mouse enters restored card blue highlight")
                            check(abs(card.spot.position.x - card.bounds.width * 0.76) < 12,
                                  "system mouse moves blue highlight within restored card")
                            check(CreativeSuggestionCard.debugBodyCount - initialBodies <= 6,
                                  "system pointer motion does not rebuild card text every frame")
                            capture("system-hover")
                            await moveSystemPointer(to: CGPoint(x: card.bounds.midX, y: -35))
                            try? await Task.sleep(for: .milliseconds(800))
                            check(card.spot.opacity == 0, "system mouse exits restored card and clears blue highlight")
                            capture("system-exit")
                        }
                    }
                    let buttons = NativeAccessibilityProbe.elements(window).filter {
                        $0.accessibilityRole?() == .button
                            && ($0.accessibilityIdentifier?() ?? "").hasPrefix("agent-suggestion-")
                    }
                    check(Set(buttons.compactMap { $0.accessibilityIdentifier?() }).count == 2,
                          "\(name) restored cards preserve both accessible click targets")
                    _ = buttons.first?.accessibilityPerformPress?()
                    try? await Task.sleep(for: .milliseconds(180))
                    check(!model.draft.isEmpty && model.messages.isEmpty && !model.isRunning,
                          "\(name) suggestion click fills draft without submitting")
                    model.draft = ""
                    if colorful && dark && expanded
                        && ProcessInfo.processInfo.environment["CLIPSLOTS_WELCOME_KEEP_OPEN"] == "1" {
                        retainedWindow = window
                    } else {
                        window.close()
                    }
                }
            }
        }
    }
}
#endif
