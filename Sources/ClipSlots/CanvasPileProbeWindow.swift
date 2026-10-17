#if DEBUG
import AppKit
import SwiftUI

/// A dedicated native host for the canvas probe when SwiftUI's application
/// scene cannot open a window in the current desktop Space. This is not a
/// product-launch test, and cannot run in the installed application.
@MainActor enum CanvasPileProbeWindow {
    private static var window: NSWindow?
    private(set) static var usedFallback = false

    static func schedule(store: SlotStoreObservable) {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPSLOTS_PILE_ISOLATED_HOST"] == "1", env["CLIPSLOTS_PILE_PROBE"] == "1",
              Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test",
              env["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/clipslots-v2174-") == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard NSApp.windows.isEmpty else { return }
            let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            host.title = "ClipSlots · Isolated Pile Canvas"
            host.isReleasedWhenClosed = false
            host.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            host.contentView = NSHostingView(rootView: ContentView(store: store))
            host.center()
            window = host
            usedFallback = true
            host.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSLog("[PileProbe] Isolated AppKit host opened; product scene launch is outside this probe.")
        }
    }
}
#endif
