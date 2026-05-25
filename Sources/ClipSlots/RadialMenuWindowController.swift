import AppKit
import SwiftUI

final class RadialMenuWindowController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RadialMenuView>?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var clickGesture: NSClickGestureRecognizer?

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

        let radialView = RadialMenuView(
            slots: slots,
            labels: labels,
            slotCount: slotCount,
            onSelect: { _ in },  // handled by AppKit gesture below
            onDismiss: { onDismiss() }
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

        // AppKit click gesture — reliable on non-activating panels
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        hosting.addGestureRecognizer(gesture)
        self.clickGesture = gesture

        // Store click-handling state in the gesture recognizer's associated storage
        objc_setAssociatedObject(gesture, "center", NSValue(point: center), .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(gesture, "outerRadius", NSNumber(value: Float(outerRadius)), .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(gesture, "deadZoneRadius", NSNumber(value: Float(deadZoneRadius)), .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(gesture, "slotCount", NSNumber(value: slotCount), .OBJC_ASSOCIATION_RETAIN)

        // Use a closure wrapper to store the callbacks
        let callbacks = RadialCallbacks(onSelect: onSelect, onDismiss: onDismiss)
        objc_setAssociatedObject(gesture, "callbacks", callbacks, .OBJC_ASSOCIATION_RETAIN)

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

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view,
              let centerVal = objc_getAssociatedObject(gesture, "center") as? NSValue,
              let deadZoneNum = objc_getAssociatedObject(gesture, "deadZoneRadius") as? NSNumber,
              let slotCountNum = objc_getAssociatedObject(gesture, "slotCount") as? NSNumber,
              let callbacks = objc_getAssociatedObject(gesture, "callbacks") as? RadialCallbacks else {
            return
        }

        let center = centerVal.pointValue
        let deadZoneRadius = CGFloat(deadZoneNum.floatValue)
        let slotCount = slotCountNum.intValue

        let clickPoint = gesture.location(in: view)
        let dx = clickPoint.x - center.x
        let dy = clickPoint.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        if distance < deadZoneRadius {
            callbacks.onDismiss()
            return
        }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let segmentAngle = 360.0 / Double(slotCount)
        let index = Int(angle / segmentAngle)
        let slot = min(index + 1, slotCount)

        callbacks.onSelect(slot)
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
        if let gesture = clickGesture, let view = hostingView {
            view.removeGestureRecognizer(gesture)
            clickGesture = nil
        }
        panel?.close()
        panel = nil
        hostingView = nil
    }
}

/// Helper to store callbacks with ObjC associated objects
private final class RadialCallbacks: NSObject {
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    init(onSelect: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }
}
