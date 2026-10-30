#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor enum CanvasToolUIRegression {
    static func run(sessions: [CanvasNodeKind: CanvasToolSession], canvas: CanvasStore,
                    directory: URL, check: (Bool, String) -> Void) async throws {
        NativeAccessibilityProbe.enable()
        await runWorkspaceBeatProbe(directory: directory, check: check)
        for skin in AppSkin.allCases {
            AppSkinCenter.apply(skin)
            for dark in [false, true] {
                for size in [NSSize(width: 800, height: 558), NSSize(width: 1080, height: 740)] {
                    for kind in [CanvasNodeKind.audio, .threeD, .timeline, .stage] {
                        guard let session = sessions[kind] else { continue }
                        let host = NSHostingView(rootView: CanvasToolEditor(session: session, canvas: canvas))
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = host; window.makeKeyAndOrderFront(nil)
                        try await Task.sleep(for: .milliseconds(300))
                        host.layoutSubtreeIfNeeded()
                        let name = "\(kind.rawValue)-\(skin.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))"
                        func element(_ id: String) -> AnyObject? {
                            NativeAccessibilityProbe.elements(window).first { $0.accessibilityIdentifier?() == id }
                        }
                        let export = element("tool-export"), apply = element("tool-apply")
                        let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
                        func visible(_ node: AnyObject?) -> Bool {
                            guard let node, let rect = node.accessibilityFrame?() else { return false }
                            return rect.width > 5 && rect.height > 5 && contentFrame.insetBy(dx: -2, dy: -2).contains(rect)
                        }
                        check(visible(export) && (export?.accessibilityFrame?().width ?? 1000) < 110, "\(name) export is compact and inside window")
                        check(visible(apply), "\(name) apply remains visible outside inspector scroll")
                        if kind == .audio || kind == .threeD {
                            let generate = element("tool-generate")
                            check(visible(generate) && (generate?.accessibilityFrame?().maxX ?? 10000) < contentFrame.minX + size.width * 0.75,
                                "\(name) prompt composer action remains under preview")
                        }
                        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?
                                .write(to: directory.appendingPathComponent("ui-\(name).png"))
                        }
                        if kind == .threeD && size.width == 800 && !dark {
                            let before = session.configuration
                            _ = element("tool-cloud-settings")?.accessibilityPerformPress?()
                            try await Task.sleep(for: .milliseconds(250))
                            let nodes = NSApp.windows.flatMap { NativeAccessibilityProbe.elements($0) }
                            let key = nodes.first { $0.accessibilityIdentifier?() == "tool-service-key" }
                            check(key != nil, "native advanced popover exposes service-key field")
                            let close = nodes.first { $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "关闭参数" }
                            _ = close?.accessibilityPerformPress?()
                            try await Task.sleep(for: .milliseconds(100))
                            check(session.configuration == before && !session.busy,
                                "opening and closing generation parameters does not submit a cloud task")
                        }
                        if kind == .stage && size.width == 800 && !dark,
                           let entity = session.configuration.stage.entities.first,
                           let shot = session.configuration.stage.shots.first {
                            _ = element("tool-entity-\(entity.id)")?.accessibilityPerformPress?()
                            try await Task.sleep(for: .milliseconds(200))
                            func dump(_ name: String) throws {
                                let nodes = NativeAccessibilityProbe.elements(window).map {
                                    ["id": $0.accessibilityIdentifier?() ?? "",
                                     "label": $0.accessibilityLabel?() ?? "",
                                     "role": $0.accessibilityRole?()?.rawValue ?? ""]
                                }
                                try JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted])
                                    .write(to: directory.appendingPathComponent("inspector-\(name)-ax.json"))
                            }
                            try dump("entity")
                            check(element("tool-section-对象参数") != nil,
                                "native entity selection opens object inspector")
                            _ = element("tool-shot-\(shot.id)")?.accessibilityPerformPress?()
                            try await Task.sleep(for: .milliseconds(200))
                            try dump("shot")
                            check(element("tool-section-镜头参数") != nil && element("tool-section-对象参数") == nil,
                                "native shot selection replaces object inspector without stacking panels")
                        }
                        window.close()
                    }
                }
            }
        }
        if let session = sessions[.stage], let node = session.node,
           let fixture = ProcessInfo.processInfo.environment["CLIPSLOTS_TOOL_FIXTURES"] {
            let before = session.configuration, attachments = session.attachments
            let host = NSHostingView(rootView: CanvasToolEditor(session: session, canvas: canvas))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 558),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            try await session.ingest(URL(fileURLWithPath: fixture).appendingPathComponent("triangle.glb"))
            try await Task.sleep(for: .milliseconds(150))
            let stored = session.store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
            check(session.attachments == stored && session.attachments.count == attachments.count + 1
                && Set(session.attachments.map(\.id)).count == session.attachments.count,
                "import with mounted editor keeps one attachment per ID after synchronous storage notification")
            _ = canvas.undo()
            try await Task.sleep(for: .milliseconds(150))
            check(session.configuration == before
                && session.store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot) == attachments,
                "mounted-editor import undo restores exact configuration and attachments")
            window.close()
        }
    }
}
#endif
