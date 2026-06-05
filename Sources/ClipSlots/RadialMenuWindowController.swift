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
    private var previewStore: SlotStoreObservable?
    private var previewThemeMode: ThemeMode = .system
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var onDismissCallback: (() -> Void)?

    // v2.7.14: pinned state and frame persist across radial menu sessions.
    private var isPreviewPinned: Bool {
        get { UserDefaults.standard.bool(forKey: "radialPreviewPinned") }
        set { UserDefaults.standard.set(newValue, forKey: "radialPreviewPinned") }
    }

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
        // Do not reset pin state here. Pinned preview must survive radial menu sessions.

        // Read theme mode so radial menu matches main window appearance
        let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ThemeMode.system.rawValue
        let themeMode = ThemeMode(rawValue: modeRaw) ?? .system

        let radialView = RadialMenuView(
            store: store,
            onSelectSlot: { [weak self] slot in
                onSelectSlot(slot)
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() } else { self?.persistPreviewFrame() }
                onDismiss()
            },
            onPasteAll: { [weak self] in
                // v2.7.21: fast path for radial paste-all. Toolbar paste-all keeps
                // its confirmation behavior; radial action should feel immediate.
                store.pasteAllSlotsFastFromRadialMenu()
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() }
                onDismiss()
            },
            onDismiss: { [weak self] in
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() } else { self?.persistPreviewFrame() }
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
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() } else { self?.persistPreviewFrame() }
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
                if !self.isPreviewPinned { self.dismissPreviewPanel() } else { self.persistPreviewFrame() }
                onDismiss()
            }
        }
    }

    private func showPreviewPanel(store: SlotStoreObservable, near screenPoint: NSPoint, themeMode: ThemeMode) {
        previewStore = store
        previewThemeMode = themeMode

        // If preview is pinned and already visible, keep its position/size and only refresh content.
        if isPreviewPinned, let previewPanel {
            previewPanel.contentView = makePreviewHostingView(store: store, themeMode: themeMode, size: previewPanel.frame.size)
            previewPanel.orderFrontRegardless()
            return
        }

        if !isPreviewPinned { dismissPreviewPanel() }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultSize = NSSize(width: 360, height: 420)
        let savedFrame = restoredPreviewFrame(defaultSize: defaultSize, screenFrame: screenFrame)
        let origin = savedFrame.origin
        let size = savedFrame.size

        let hosting = makePreviewHostingView(store: store, themeMode: themeMode, size: size)

        let previewPanel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            // v2.7.13: borderless preview. The SwiftUI toolbar is the only top bar.
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

    private func makePreviewHostingView(store: SlotStoreObservable, themeMode: ThemeMode, size: NSSize) -> NSView {
        let preview = RadialPreviewPanel(
            title: store.currentSpecialSlot?.name ?? "默认槽位组",
            subtitle: "悬停圆盘槽位实时预览",
            content: AnyView(RadialLivePreviewContent(store: store)),
            isPinned: Binding<Bool>(
                get: { self.isPreviewPinned },
                set: { [weak self] newValue in
                    guard let self else { return }
                    self.isPreviewPinned = newValue
                    if newValue {
                        self.persistPreviewFrame()
                    } else {
                        UserDefaults.standard.removeObject(forKey: "radialPreviewFrame")
                    }
                    if let store = self.previewStore {
                        self.previewPanel?.contentView = self.makePreviewHostingView(store: store, themeMode: self.previewThemeMode, size: self.previewPanel?.frame.size ?? size)
                    }
                }
            )
        )
        .preferredColorScheme(themeMode.preferredColorScheme)

        let hosting = NSHostingView(rootView: preview)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.masksToBounds = false
        return hosting
    }

    private func persistPreviewFrame() {
        guard let frame = previewPanel?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "radialPreviewFrame")
    }

    private func restoredPreviewFrame(defaultSize: NSSize, screenFrame: NSRect) -> NSRect {
        if isPreviewPinned,
           let raw = UserDefaults.standard.string(forKey: "radialPreviewFrame") {
            let rect = NSRectFromString(raw)
            if rect.width >= 120, rect.height >= 120, screenFrame.intersects(rect) { return rect }
        }
        return NSRect(
            x: screenFrame.maxX - defaultSize.width - 24,
            y: screenFrame.maxY - defaultSize.height - 24,
            width: defaultSize.width,
            height: defaultSize.height
        )
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
        if !isPreviewPinned { dismissPreviewPanel() } else { persistPreviewFrame() }
    }
}
