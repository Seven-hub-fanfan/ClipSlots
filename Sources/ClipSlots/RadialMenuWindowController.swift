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

    // v2.9.25 hotfix4: 已彻底移除折叠/展开/悬停 resize 逻辑（previewHoverObserver /
    // previewExpandedHeight / previewCollapsedHeight）。预览窗为固定尺寸，不再有任何高度变化。

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
        // v2.9.25 hotfix4: 预览窗固定放大为原来的两倍（360×420 → 720×840），不折叠、不 resize。
        let defaultSize = NSSize(width: 720, height: 840)
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
        // v2.9.25 hotfix4: 窗口锁定为固定尺寸（min == max），完全禁止 resize，杜绝悬停时窗口撑大/状态栏上跳。
        previewPanel.minSize = size
        previewPanel.maxSize = size
        previewPanel.contentView = hosting
        previewPanel.contentView?.wantsLayer = true
        previewPanel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        previewPanel.contentView?.layer?.cornerRadius = 0
        previewPanel.contentView?.layer?.masksToBounds = false
        previewPanel.orderFrontRegardless()
        self.previewPanel = previewPanel
        // v2.9.25 hotfix4: 无任何折叠/展开/resize 逻辑，窗口始终固定 720×840，工具栏固定在顶部，内容区在下方。
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
        // v2.9.25 hotfix4: 窗口尺寸恒定，直接持久化当前 frame（仅记录位置）。
        UserDefaults.standard.set(NSStringFromRect(previewPanel.frame), forKey: "radialPreviewFrame")
    }

    private func restoredPreviewFrame(defaultSize: NSSize, screenFrame: NSRect) -> NSRect {
        // v2.9.25 hotfix4: 尺寸恒为 defaultSize（720×840），只从持久化里恢复位置，避免旧的小尺寸帧被复用。
        if isPreviewPinned,
           let raw = UserDefaults.standard.string(forKey: "radialPreviewFrame") {
            let rect = NSRectFromString(raw)
            let candidate = NSRect(x: rect.origin.x, y: rect.maxY - defaultSize.height,
                                   width: defaultSize.width, height: defaultSize.height)
            if screenFrame.intersects(candidate) { return candidate }
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

    // v2.9.25 hotfix4: installPreviewHoverObserver / applyPreviewCollapsed 已删除（不再折叠/展开/resize）。

    private func dismissPreviewPanel() {
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
