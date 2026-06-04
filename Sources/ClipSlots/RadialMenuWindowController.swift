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

    // v2.7.10: synced from SwiftUI wrapper so AppKit dismiss paths can respect pin
    private var isPreviewPinned = false

    func show(
        at screenPoint: NSPoint,
        store: SlotStoreObservable,
        onSelectSlot: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        dismiss()

        // v2.4.2: taller window to accommodate page selector + group switcher
        // v2.7.10: wider window for preview panel
        let menuWidth: CGFloat = 440
        let menuHeight: CGFloat = 480
        self.onDismissCallback = onDismiss
        self.isPreviewPinned = false

        // Read theme mode so radial menu matches main window appearance
        let modeRaw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ThemeMode.system.rawValue
        let themeMode = ThemeMode(rawValue: modeRaw) ?? .system

        // v2.7.10: wrapper that includes preview panel alongside radial menu
        let wrapper = RadialMenuWithPreview(
            store: store,
            onSelectSlot: { [weak self] slot in
                onSelectSlot(slot)
                if self?.isPreviewPinned != true {
                    self?.dismiss()
                    onDismiss()
                }
            },
            onDismiss: { [weak self] in
                if self?.isPreviewPinned == true {
                    // Don't call the real dismiss — just let SwiftUI hide radial menu
                } else {
                    self?.dismiss()
                    onDismiss()
                }
            },
            connectionMap: store.currentConnectionMap,
            isPinned: Binding<Bool>(
                get: { self.isPreviewPinned },
                set: { self.isPreviewPinned = $0 }
            )
        )
        .preferredColorScheme(themeMode.preferredColorScheme)

        let hosting = NSHostingView(rootView: wrapper)
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

        // Escape key dismiss
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                if self?.isPreviewPinned == true {
                    return nil  // ignore escape when preview is pinned
                }
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
                if self.isPreviewPinned {
                    return  // don't dismiss when preview is pinned
                }
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

// MARK: - v2.7.10 Radial Menu + Preview Wrapper

private struct RadialMenuWithPreview: View {
    @ObservedObject var store: SlotStoreObservable
    var onSelectSlot: (Int) -> Void
    var onDismiss: () -> Void
    var connectionMap: SlotConnectionMap
    @Binding var isPinned: Bool

    @State private var showRadialMenu = true

    var body: some View {
        ZStack {
            // v2.7.10: Preview panel on the left alongside radial menu
            HStack(spacing: 0) {
                RadialPreviewPanel(
                    title: store.currentSpecialSlot?.name ?? "预览",
                    subtitle: "槽位内容预览",
                    content: AnyView(
                        VStack(spacing: 6) {
                            Image(systemName: "eye")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("悬停槽位查看预览")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ),
                    isPinned: $isPinned
                )
                .opacity(showRadialMenu || isPinned ? 1 : 0)

                if showRadialMenu {
                    RadialMenuView(
                        store: store,
                        onSelectSlot: { slot in
                            onSelectSlot(slot)
                            if !isPinned { onDismiss() }
                        },
                        onDismiss: {
                            if isPinned {
                                showRadialMenu = false
                            } else {
                                onDismiss()
                            }
                        },
                        connectionMap: connectionMap
                    )
                }
            }
        }
    }
}
