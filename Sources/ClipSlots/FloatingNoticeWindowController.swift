import SwiftUI
import AppKit

// MARK: - Global HUD Window Controller (v2.6.3)

/// Displays an auto-dismissing non-activating HUD window that is visible
/// across all apps/spaces, regardless of whether the ClipSlots main window
/// is visible. Used for save/copy/batch feedback from hotkey operations.
final class FloatingNoticeWindowController {
    static let shared = FloatingNoticeWindowController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(notice: FloatingNotice, duration: TimeInterval = 2.0) {
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()

            let hostingView = NSHostingView(
                rootView: FloatingNoticeView(notice: notice)
                    .padding(1)
            )

            let panel = self.panel ?? self.makePanel()
            panel.contentView = hostingView

            // Size: use fittingSize with a fallback
            let fitting = hostingView.fittingSize
            let fallbackSize = NSSize(
                width: 420,
                height: notice.subtitle.isEmpty ? 78 : 104
            )
            let size = fitting.width > 0 && fitting.height > 0 ? fitting : fallbackSize
            panel.setContentSize(size)

            self.position(panel)
            panel.orderFrontRegardless()

            self.panel = panel

            let workItem = DispatchWorkItem { [weak self] in
                self?.panel?.orderOut(nil)
            }
            self.dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + duration,
                execute: workItem
            )
        }
    }

    /// Immediately hide the HUD.
    func dismiss() {
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil
            self.panel?.orderOut(nil)
        }
    }

    // MARK: - Private

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // v2.6.5: ensure no shadow
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .transient,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        // Ensure it never becomes key
        panel.becomesKeyOnlyIfNeeded = false

        return panel
    }

    /// Position the panel at the top-center of the screen containing the mouse.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        guard let screen = targetScreen else { return }

        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size

        let x = visibleFrame.midX - size.width / 2
        // ~120px from the top of the visible area
        let y = visibleFrame.maxY - 120 - size.height

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Non-Activating Panel

/// A panel that can NEVER become key or main. This prevents the HUD
/// from stealing focus from the current app (Finder, browser, etc.).
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
