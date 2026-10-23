import SwiftUI
import AppKit
import ClipSlotsKit

/// The transparent top edge has native window gestures in both workspaces.
/// The workspace switcher and traffic lights retain their own pointer handling.
struct MainWindowDragRegion: NSViewRepresentable {
    var leadingControlsWidth: CGFloat = 90
    @MainActor private static weak var zoomWindow: NSWindow?
    @MainActor private static var restoreFrame: NSRect?

    @MainActor static func toggleZoom(_ window: NSWindow) {
        if zoomWindow === window, let frame = restoreFrame {
            restoreFrame = nil
            zoomWindow = nil
            window.setFrame(frame, display: true)
        } else {
            zoomWindow = window
            restoreFrame = window.frame
            window.performZoom(nil)
        }
    }

    final class Host: NSView {
        var leadingControlsWidth: CGFloat = 90
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), let window,
                  !window.styleMask.contains(.fullScreen),
                  local.x > max(90, leadingControlsWidth),
                  abs(local.x - bounds.midX) > WindowLayoutMetrics.workspaceSwitcherWidth / 2 + 8
            else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                MainWindowDragRegion.toggleZoom(window)
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.leadingControlsWidth = leadingControlsWidth
        return view
    }
    func updateNSView(_ view: Host, context: Context) {
        view.leadingControlsWidth = leadingControlsWidth
    }
}
