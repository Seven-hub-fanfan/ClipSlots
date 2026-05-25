import AppKit
import SwiftUI

final class RadialMenuWindowController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RadialMenuView>?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

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

        let radialView = RadialMenuView(
            slots: slots,
            labels: labels,
            slotCount: slotCount,
            onSelect: { slot in
                onSelect(slot)
            },
            onDismiss: {
                onDismiss()
            }
        )

        let hosting = NSHostingView(rootView: radialView)
        hosting.frame = NSRect(x: 0, y: 0, width: menuSize, height: menuSize)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = menuSize / 2
        hosting.layer?.masksToBounds = true
        self.hostingView = hosting

        let windowOrigin = NSRect(
            x: screenPoint.x - menuSize / 2,
            y: screenPoint.y - menuSize / 2,
            width: menuSize,
            height: menuSize
        )

        let p = NSPanel(
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
        p.orderFrontRegardless()

        self.panel = p

        // Escape key dismiss
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                onDismiss()
                return nil
            }
            return event
        }

        // Click outside dismiss
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let panel = self?.panel else { return }
            let clickLocation = NSEvent.mouseLocation
            let screenFrame = panel.frame
            if !screenFrame.contains(clickLocation) {
                self?.dismiss()
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
        panel?.close()
        panel = nil
        hostingView = nil
    }
}
