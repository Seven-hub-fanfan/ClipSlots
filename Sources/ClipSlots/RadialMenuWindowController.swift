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
    private var previewPanel: NSPanel?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var onDismissCallback: (() -> Void)?

    // v2.7.10: synced from SwiftUI wrapper so AppKit dismiss paths can respect pin
    private var isPreviewPinned = false

    func show(
        at screenPoint: NSPoint,
        store: SlotStoreObservable,
        onSelectSlot: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        dismiss()

        // v2.7.11: radial window only contains the radial menu again.
        // Its center must equal the mouse point used by ctrl+space.
        let menuWidth: CGFloat = 460
        let menuHeight: CGFloat = 500
        self.onDismissCallback = onDismiss
        self.isPreviewPinned = false

        // Read theme mode so radial menu matches main window appearance
        let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ThemeMode.system.rawValue
        let themeMode = ThemeMode(rawValue: modeRaw) ?? .system

        let radialView = RadialMenuView(
            store: store,
            onSelectSlot: { [weak self] slot in
                onSelectSlot(slot)
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() }
                onDismiss()
            },
            onDismiss: { [weak self] in
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() }
                onDismiss()
            },
            connectionMap: store.currentConnectionMap
        )
        .preferredColorScheme(themeMode.preferredColorScheme)

        let hosting = NSHostingView(rootView: radialView)
        hosting.frame = NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = 0
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

        showPreviewPanel(store: store, near: screenPoint, themeMode: themeMode)

        // Escape key dismiss
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() }
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
                self.dismissRadialOnly()
                if !self.isPreviewPinned { self.dismissPreviewPanel() }
                onDismiss()
            }
        }
    }

    private func showPreviewPanel(store: SlotStoreObservable, near screenPoint: NSPoint, themeMode: ThemeMode) {
        dismissPreviewPanel()

        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultSize = NSSize(width: 360, height: 420)
        let origin = NSPoint(
            x: screenFrame.maxX - defaultSize.width - 24,
            y: screenFrame.maxY - defaultSize.height - 24
        )

        let preview = RadialPreviewPanel(
            title: store.currentSpecialSlot?.name ?? "默认槽位组",
            subtitle: "悬停圆盘槽位实时预览",
            content: AnyView(RadialLivePreviewContent(store: store)),
            isPinned: Binding<Bool>(
                get: { self.isPreviewPinned },
                set: { self.isPreviewPinned = $0 }
            )
        )
        .preferredColorScheme(themeMode.preferredColorScheme)

        let hosting = NSHostingView(rootView: preview)
        hosting.frame = NSRect(origin: .zero, size: defaultSize)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.masksToBounds = false

        let previewPanel = NSPanel(
            contentRect: NSRect(origin: origin, size: defaultSize),
            // v2.7.13: borderless preview. The SwiftUI toolbar is the only top bar.
            // Remove native titlebar / traffic lights to avoid duplicated bars and broken corners.
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewPanel.isOpaque = false
        previewPanel.backgroundColor = .clear
        // v2.7.13: no AppKit shadow. The preview should look like a clean image surface.
        previewPanel.hasShadow = false
        previewPanel.level = .floating
        previewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        previewPanel.isMovableByWindowBackground = true
        previewPanel.minSize = NSSize(width: 260, height: 220)
        previewPanel.maxSize = NSSize(width: min(900, screenFrame.width - 80), height: min(900, screenFrame.height - 80))
        previewPanel.contentView = hosting
        previewPanel.contentView?.wantsLayer = true
        previewPanel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        previewPanel.contentView?.layer?.cornerRadius = 0
        previewPanel.contentView?.layer?.masksToBounds = false
        previewPanel.orderFrontRegardless()
        self.previewPanel = previewPanel
    }

    private func dismissRadialOnly() {
        panel?._dismissed = true
        panel?.onMouseDown = nil
        panel?.close()
        panel = nil
    }

    private func dismissPreviewPanel() {
        previewPanel?.close()
        previewPanel = nil
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
        dismissRadialOnly()
        if !isPreviewPinned { dismissPreviewPanel() }
    }
}
