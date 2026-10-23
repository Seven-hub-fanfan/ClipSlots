#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runLibraryDesignProbe(directory: URL, store: SlotStoreObservable, canvas: CanvasStore) async {
    var passed = 0, failures: [String] = []
    func check(_ value: Bool, _ title: String) {
        if value { passed += 1 } else { failures.append(title) }
    }
    do {
        let group = try store.specialStorage.createSpecialSlot(name: "镜头参考")
        check(store.specialStorage.set(1, content: SlotContent(text: "海风中的旧码头"), in: group.id), "isolated content fixture stored")
        store.reloadAll()
        canvas.isLibraryExpanded = true
        let host = NSHostingView(rootView: CanvasSlotLibraryPanel(store: store, canvas: canvas,
            onDragChanged: { _, _ in }, onDropSlot: { _, _ in }, archiveDrag: nil, onReorder: { _, _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 240, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NativeAccessibilityProbe.enable()
        try? await Task.sleep(for: .seconds(1))
        func capture(_ name: String) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        func find(_ id: String) -> AnyObject? {
            NativeAccessibilityProbe.elements(host).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(220))
            check(host.bounds.width == 240, "\(label) library preserves 240pt width")
            check(find("slot-group-drag-\(group.id)") != nil, "\(label) quiet group drag target remains accessible")
            check(find("slot-group-toggle-\(group.id)")?.accessibilityPerformPress?() == true,
                  "\(label) group expands through native action")
            try? await Task.sleep(for: .milliseconds(220))
            capture("library-\(label)-expanded")
            check(find("slot-group-toggle-\(group.id)")?.accessibilityPerformPress?() == true,
                  "\(label) group collapses through native action")
            try? await Task.sleep(for: .milliseconds(220))
            capture("library-\(label)-collapsed")
        }
        canvas.isLibraryExpanded = false
        try? await Task.sleep(for: .milliseconds(220))
        check(find("canvas-library-expand")?.accessibilityPerformPress?() == true,
              "collapsed floating control expands library")
        try? await Task.sleep(for: .milliseconds(220))
        check(canvas.isLibraryExpanded, "native floating control restores expanded state")
        window.close()
    } catch { failures.append(error.localizedDescription) }
    let report: [String: Any] = [
        "passed": passed, "failures": failures,
        "scope": "isolated native library render and accessible expand/collapse; does not certify desktop focus",
        "sessionLocked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    ]
    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("report.json"))
    NSApp.terminate(nil)
}
#endif
