import AppKit
import SwiftUI

// MARK: - Radial Panel (intercepts mouseDown at window level)

private final class RadialPanel: NSPanel {
    var onMouseDown: ((NSPoint) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let localPoint = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            onMouseDown?(localPoint)
            if _dismissed { return }
        }
        super.sendEvent(event)
    }

    // Set by the controller when panel is dismissed to avoid forwarding stale events
    var _dismissed = false
}

// MARK: - Window Controller

final class RadialMenuWindowController {
    private var panel: RadialPanel?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var onDismissCallback: (() -> Void)?

    func show(
        at screenPoint: NSPoint,
        store: SlotStoreObservable,
        onSelectSlot: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        dismiss()

        // v2.4.4: compact window, just enough to fit the disc + controls
        let menuWidth: CGFloat = 260
        let menuHeight: CGFloat = 310
        self.onDismissCallback = onDismiss

        // Read theme mode so radial menu matches main window appearance
        let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ThemeMode.system.rawValue
        let themeMode = ThemeMode(rawValue: modeRaw) ?? .system

        let radialView = RadialMenuView(
            store: store,
            onSelectSlot: onSelectSlot,
            onDismiss: { onDismiss() }
        )
        .preferredColorScheme(themeMode.preferredColorScheme)

        let hosting = NSHostingView(rootView: radialView)
        hosting.frame = NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.masksToBounds = false

        let windowOrigin = NSRect(
            x: screenPoint.x - menuWidth / 2,
            y: screenPoint.y - menuHeight / 2,
            width: menuWidth,
            height: menuHeight
        )

        let p = RadialPanel(
            contentRect: windowOrigin,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.contentView = hosting

        // Clicks are handled by SwiftUI .onTapGesture; window-level handler no longer needed
        p.orderFrontRegardless()
        self.panel = p

        // Escape key dismiss
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                onDismiss()
                return nil
            }
            return event
        }

        // Click outside dismiss
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                self.dismiss()
                onDismiss()
            }
        }
    }

    func dismiss() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        onDismissCallback = nil
        panel?._dismissed = true
        panel?.onMouseDown = nil
        panel?.close()
        panel = nil
    }
}
