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

    // Geometry for hit-testing
    private var center: CGPoint = .zero
    private var deadZoneRadius: CGFloat = 0
    private var slotCount: Int = 9
    private var onSelectCallback: ((Int) -> Void)?
    private var onDismissCallback: (() -> Void)?

    func show(
        at screenPoint: NSPoint,
        slots: [Int: SlotContent],
        labels: [Int: String],
        slotCount: Int,
        onSelect: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        dismiss()

        let menuSize: CGFloat = 340
        let outerRadius = menuSize / 2
        let deadZoneRadius = outerRadius * 0.22
        let center = CGPoint(x: menuSize / 2, y: menuSize / 2)

        self.center = center
        self.deadZoneRadius = deadZoneRadius
        self.slotCount = slotCount
        self.onSelectCallback = onSelect
        self.onDismissCallback = onDismiss

        // Read theme mode so radial menu matches main window appearance
        let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ThemeMode.system.rawValue
        let themeMode = ThemeMode(rawValue: modeRaw) ?? .system

        let radialView = RadialMenuView(
            slots: slots,
            labels: labels,
            slotCount: slotCount,
            onSelect: { _ in },
            onDismiss: { onDismiss() }
        )
        .preferredColorScheme(themeMode.preferredColorScheme)

        let hosting = NSHostingView(rootView: radialView)
        hosting.frame = NSRect(x: 0, y: 0, width: menuSize, height: menuSize)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = menuSize / 2
        hosting.layer?.masksToBounds = true

        let windowOrigin = NSRect(
            x: screenPoint.x - menuSize / 2,
            y: screenPoint.y - menuSize / 2,
            width: menuSize,
            height: menuSize
        )

        let p = RadialPanel(
            contentRect: windowOrigin,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.contentView = hosting

        // Handle clicks at window level
        p.onMouseDown = { [weak self] localPoint in
            self?.handleMenuClick(at: localPoint)
        }

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

    private func handleMenuClick(at point: NSPoint) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        if distance < deadZoneRadius {
            onDismissCallback?()
            return
        }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let segmentAngle = 360.0 / Double(slotCount)
        let index = Int(angle / segmentAngle)
        let slot = min(index + 1, slotCount)

        onSelectCallback?(slot)
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
        onSelectCallback = nil
        onDismissCallback = nil
        panel?._dismissed = true
        panel?.onMouseDown = nil
        panel?.close()
        panel = nil
    }
}
