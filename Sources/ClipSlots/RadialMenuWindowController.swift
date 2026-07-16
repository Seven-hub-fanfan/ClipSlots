import AppKit
import ClipSlotsKit
import SwiftUI
import QuartzCore

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
    private var globalKeyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var onDismissCallback: (() -> Void)?

    // v2.9.23: 悬停展开 / 默认折叠。实时预览面板默认只显示顶部工具栏（约 60pt），
    // 悬停圆盘槽位后才展开内容区，鼠标离开重新折叠，带高度动画，保持顶边固定。
    private var previewHoverObserver: Any?
    private var previewExpandedHeight: CGFloat = 420
    private let previewCollapsedHeight: CGFloat = 60

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
                // v2.7.71: when pinned, keep the preview window on screen but reset
                // it to the blank default state (clear the big preview) so it no
                // longer obscures the screen; the next slot hover re-populates it.
                // When unpinned, keep the original behavior (dismiss after paste).
                if self?.isPreviewPinned != true {
                    self?.dismissPreviewPanel()
                } else {
                    self?.clearPreviewContent()
                    self?.persistPreviewFrame()
                }
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
            // v2.7.26: bind to store directly. Passing a copied connectionMap freezes
            // connection colors for the whole radial-menu session. Switching slot group inside
            // the radial menu must refresh colors immediately.
            connectionMap: .empty
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

        // Escape key dismiss: 同时监听本地和全局 ESC 事件
        let dismissOnEscape: (NSEvent) -> NSEvent? = { [weak self] event in
            if event.keyCode == 53 {
                self?.dismissRadialOnly()
                if self?.isPreviewPinned != true { self?.dismissPreviewPanel() } else { self?.persistPreviewFrame() }
                onDismiss()
                return nil
            }
            return event
        }
        
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: dismissOnEscape)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = dismissOnEscape($0) })

        // Click outside dismiss: 同时监听全局和本地点击，解决在 App 自身窗口点击不关闭的问题
        let dismissIfOutside: (NSPoint) -> Void = { [weak self] clickLocation in
            guard let self = self, let panel = self.panel else { return }
            
            // 点击预览窗不关闭圆盘菜单，否则置顶/缩放按钮会被外部点击监听提前吞掉
            if let previewPanel = self.previewPanel, previewPanel.frame.contains(clickLocation) {
                return
            }
            
            if !panel.frame.contains(clickLocation) {
                self.dismissRadialOnly()
                if !self.isPreviewPinned { self.dismissPreviewPanel() } else { self.persistPreviewFrame() }
                onDismiss()
            }
        }
        
        // 全局点击：其他应用窗口
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            dismissIfOutside(NSEvent.mouseLocation)
        }
        
        // 本地点击：本 App 自身窗口
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            dismissIfOutside(NSEvent.mouseLocation)
            return event
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
        previewPanel.minSize = NSSize(width: 260, height: previewCollapsedHeight)
        previewPanel.maxSize = NSSize(width: min(900, screenFrame.width - 80), height: min(900, screenFrame.height - 80))
        previewPanel.contentView = hosting
        previewPanel.contentView?.wantsLayer = true
        previewPanel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        previewPanel.contentView?.layer?.cornerRadius = 0
        previewPanel.contentView?.layer?.masksToBounds = false
        previewPanel.orderFrontRegardless()
        self.previewPanel = previewPanel

        // v2.9.23: 记录展开高度，默认折叠为仅工具栏，随后按悬停状态展开/折叠。
        previewExpandedHeight = max(size.height, previewCollapsedHeight)
        applyPreviewCollapsed(true, animated: false)
        installPreviewHoverObserver()
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

    // v2.7.71: reset the live preview back to its blank default state (narrow
    // title bar + empty area) without closing the window. Posting the hover
    // notification with no payload and a nil object clears RadialLivePreviewContent's
    // previewPayload/hoveredSlot; the next real slot hover repopulates it.
    private func clearPreviewContent() {
        NotificationCenter.default.post(
            name: .radialMenuHoveredSlotChanged,
            object: nil,
            userInfo: nil
        )
    }

    private func persistPreviewFrame() {
        guard let previewPanel else { return }
        // v2.9.23: 始终以展开高度持久化，避免下次恢复时停留在折叠态。
        var frame = previewPanel.frame
        if frame.height > previewCollapsedHeight + 1 { previewExpandedHeight = frame.height }
        let top = frame.maxY
        frame.size.height = max(previewExpandedHeight, previewCollapsedHeight)
        frame.origin.y = top - frame.size.height
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

    // v2.9.23: 监听悬停槽位变化，展开/折叠实时预览面板。
    private func installPreviewHoverObserver() {
        if let obs = previewHoverObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        previewHoverObserver = NotificationCenter.default.addObserver(
            forName: .radialMenuHoveredSlotChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let hovering = (note.userInfo?["preview"] != nil) || (note.object is Int)
            self.applyPreviewCollapsed(!hovering, animated: true)
        }
    }

    // v2.9.23: 折叠 = 仅工具栏高度；展开 = 完整高度。保持顶边固定，向下折叠/展开。
    private func applyPreviewCollapsed(_ collapsed: Bool, animated: Bool) {
        guard let previewPanel else { return }
        let targetHeight = collapsed ? previewCollapsedHeight : max(previewExpandedHeight, previewCollapsedHeight)
        var frame = previewPanel.frame
        if abs(frame.height - targetHeight) < 0.5 { return }
        let top = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                previewPanel.animator().setFrame(frame, display: true)
            }
        } else {
            previewPanel.setFrame(frame, display: false)
        }
    }

    private func dismissPreviewPanel() {
        if let obs = previewHoverObserver {
            NotificationCenter.default.removeObserver(obs)
            previewHoverObserver = nil
        }
        previewPanel?.close()
        previewPanel = nil
    }

    func dismiss() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
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
