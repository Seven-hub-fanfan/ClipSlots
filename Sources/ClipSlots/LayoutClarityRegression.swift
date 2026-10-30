#if DEBUG
import AppKit
import SwiftUI
import Vision
import ClipSlotsKit

@MainActor enum LayoutClarityRegression {
    static func run(store: SlotStoreObservable, root: URL) async {
        var passed = [String](), failures = [String]()
        func check(_ value: Bool, _ name: String) {
            if value { passed.append(name) } else { failures.append(name) }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
        func find(_ root: AnyObject, _ id: String) -> AnyObject? {
            NativeAccessibilityProbe.elements(root).first { $0.accessibilityIdentifier?() == id }
        }
        func visible(_ node: AnyObject?, in host: NSView) -> Bool {
            guard let window = host.window, let rect = node?.accessibilityFrame?(),
                  rect.width > 4, rect.height > 4 else { return false }
            return window.convertToScreen(host.convert(host.bounds, to: nil))
                .insetBy(dx: -2, dy: -2).contains(rect)
        }
        func capture(_ host: NSView, _ name: String) throws -> String {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw ModelWorkspaceError.response
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
            guard let cg = bitmap.cgImage else { throw ModelWorkspaceError.response }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: cg).perform([request])
            return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined()
        }
        let originalAppearance = NSApp.appearance
        let originalMode = UserDefaults.standard.object(forKey: AppearanceDefaults.key)
        defer {
            NSApp.appearance = originalAppearance
            if let originalMode { UserDefaults.standard.set(originalMode, forKey: AppearanceDefaults.key) }
            else { UserDefaults.standard.removeObject(forKey: AppearanceDefaults.key) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NativeAccessibilityProbe.enable()
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            var saves = 0, cancellations = 0
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                UserDefaults.standard.set(dark ? "dark" : "light", forKey: AppearanceDefaults.key)
                for width in [760, 1080] {
                    let suffix = "\(dark ? "dark" : "light")-\(width)"
                    let host = NSHostingView(rootView: SettingsView(config: AppConfig(),
                        onSave: { _ in saves += 1 }, onClose: { cancellations += 1 }))
                    window.contentView = host; window.setContentSize(NSSize(width: width, height: 700))
                    window.makeKeyAndOrderFront(nil)
                    await settle()
                    for category in SettingsCategory.allCases {
                        check(find(host, "settings-category-\(category.rawValue)")?.accessibilityPerformPress?() == true,
                              "\(suffix)/\(category.rawValue) category opens")
                        await settle()
                        let text = try capture(host, "settings-\(category.rawValue)-\(suffix)")
                        check(text.contains(category.title), "\(suffix)/\(category.rawValue) native category rendered")
                        check(visible(find(host, "settings-save"), in: host) && visible(find(host, "settings-cancel"), in: host),
                              "\(suffix)/\(category.rawValue) footer actions remain inside window")
                        if category == .appearance {
                            check(["浅色", "深色", "跟随系统"].allSatisfy { text.contains($0) },
                                  "\(suffix) three appearance choices readable")
                        }
                        if category == .notification {
                            check(text.contains("保存成功后显示提示") && text.contains("复制成功后显示提示"),
                                  "\(suffix) toast toggles retain distinct actions")
                        }
                    }
                    check(find(host, "settings-cancel")?.accessibilityPerformPress?() == true,
                          "\(suffix) cancel remains actionable")
                }
            }
            check(saves == 0 && cancellations == 4, "browsing settings never writes configuration")
            let canvasRoot = root.appendingPathComponent("canvas-fixture")
            let storage = CanvasStorage(rootOverride: canvasRoot)
            let projects = CanvasProjectStorage(rootOverride: canvasRoot)
            let initial = CanvasStore(storage: storage, projectStorage: projects)
            let nodes = [CanvasNodeKind.audio, .threeD, .timeline, .stage].enumerated().map {
                CanvasNode(pageId: "fixture", groupId: "fixture", slot: $0.offset + 1,
                           kind: $0.element, x: 100, y: 100)
            }
            check(storage.save(CanvasDocument(nodes: nodes), projectId: initial.activeProjectId), "isolated tool fixtures saved")
            let canvas = CanvasStore(storage: storage, projectStorage: projects)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for width in [800, 1080] {
                    window.setContentSize(NSSize(width: width, height: 660))
                    for node in nodes {
                        let session = CanvasToolSession(canvas: canvas, store: store, node: node, attachments: [])
                        let before = session.configuration
                        let host = NSHostingView(rootView: CanvasToolEditor(session: session, canvas: canvas))
                        window.contentView = host; window.makeKeyAndOrderFront(nil)
                        await settle()
                        let suffix = "\(node.kind.rawValue)-\(dark ? "dark" : "light")-\(width)"
                        check(visible(find(host, "tool-export"), in: host) && visible(find(host, "tool-apply"), in: host),
                              "\(suffix) tool actions stay visible")
                        check(visible(find(host, "tool-editor-help"), in: host), "\(suffix) contextual help stays visible")
                        _ = try capture(host, "tool-\(suffix)")
                        check(find(host, "tool-editor-help")?.accessibilityPerformPress?() == true,
                              "\(suffix) help opens")
                        await settle()
                        let close = NSApp.windows.flatMap { NativeAccessibilityProbe.elements($0) }
                            .first { $0.accessibilityLabel?() == "关闭说明" }
                        check(close?.accessibilityPerformPress?() == true, "\(suffix) help closes accessibly")
                        check(session.configuration == before && !session.busy,
                              "\(suffix) inspecting help never mutates or generates")
                    }
                }
            }
            for width in [140, 240] {
                let host = NSHostingView(rootView: EmptySlotThumbnailView())
                window.contentView = host; window.setContentSize(NSSize(width: width, height: 100))
                window.makeKeyAndOrderFront(nil); await settle()
                check(NativeAccessibilityProbe.elements(host).contains { $0.accessibilityLabel?() == "空槽位" },
                      "\(width) empty preview has accessible state")
                _ = try capture(host, "empty-\(width)")
            }
        } catch { failures.append(error.localizedDescription) }
        let report: [String: Any] = ["complete": true, "passed": passed, "failures": failures,
                                    "paid_generation_requests": 0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
