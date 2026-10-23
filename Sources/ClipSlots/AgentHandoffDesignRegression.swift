#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runAgentHandoffDesignProbe(directory: URL, check: (Bool, String) -> Void) async {
    final class LocalOpener: AgentExternalHandoffOpening {
        var copied: String?
        var opens = 0
        var allowsHarness = false
        var openedURLs: [URL] = []
        func applicationAvailable(bundleID: String) -> Bool { allowsHarness && bundleID == "com.deepseek.dsh" }
        func openApplication(bundleID: String) async -> AgentExternalOpenOutcome { opens += 1; return .unsupported }
        func openURL(_ url: URL) async -> AgentExternalOpenOutcome {
            opens += 1; openedURLs.append(url)
            return allowsHarness && url.absoluteString == "dsh://open" ? .opened : .unsupported
        }
        func copyPrompt(_ prompt: String) -> Bool { copied = prompt; return true }
    }
    NativeAccessibilityProbe.enable()
    let scope = try! AgentArtifactScope(projectID: "handoff-design-fixture", canvasID: "handoff-design-fixture")
    let context = AgentExternalProjectContext(scope: scope, projectTitle: "连接窗口设计验收",
        cliPath: "/usr/local/bin/clipslots", mcpReadiness: .ready, region: "CN", language: "zh-CN",
        snapshotID: UUID())
    let defaults = UserDefaults(suiteName: "clipslots.handoff.design-fixture")!
    let preferences = AgentExternalHandoffPreferences(defaults: defaults)
    let opener = LocalOpener()
    for identifier in AgentBrandResources.identifiers {
        let image = AgentBrandResources.iconURL(for: identifier).flatMap(NSImage.init(contentsOf:))
        check(image != nil && image!.size.width >= 128, "\(identifier) resolves actual bundled brand artwork")
    }
    check(AgentBrandResources.iconURL(for: "../claude") == nil, "brand lookup rejects non-catalog paths")
    for available in [CGSize(width: 1280, height: 720), CGSize(width: 740, height: 520)] {
        let layout = AgentHandoffLayout(available: available)
        let host = NSHostingView(rootView: AgentExternalHandoffView(context: context,
            preferences: preferences, opener: opener, availableSize: available, onClose: {}))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: layout.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() async { try? await Task.sleep(for: .milliseconds(220)) }
        func element(_ id: String) -> AnyObject? {
            NativeAccessibilityProbe.elements(host).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        func textValue(_ id: String) -> String? {
            guard let object = element(id) as? NSObject else { return nil }
            let selector = NSSelectorFromString("accessibilityValue")
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? String
        }
        func capture(_ name: String) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        await settle()
        let label = layout.compact ? "compact" : "wide"
        check(host.bounds.size == layout.size && layout.size.width <= available.width
            && layout.size.height <= available.height, "\(label) native dialog fits available workspace")
        let harnessNameWidth = ("DeepSeek Harness" as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        check(harnessNameWidth <= layout.providerNameWidth
            && !layout.fitsPreviousSelectionBadge(name: "DeepSeek Harness"),
              "\(label) full Harness name fits without last-selection badge compression")
        for identifier in AgentBrandResources.identifiers {
            check(element("agent-external-provider-\(identifier)")?.accessibilityPerformPress?() == true,
                  "\(label) \(identifier) responds through native provider row")
            await settle()
            check(defaults.string(forKey: "clipslots.agent.external.last-used") == identifier,
                  "\(label) \(identifier) native selection updates persisted preference")
            guard let button = element("agent-external-open"),
                  let copy = element("agent-external-copy") else {
                check(false, "\(label) footer mounted"); continue
            }
            let frame = button.accessibilityFrame?() ?? .zero
            let copyFrame = copy.accessibilityFrame?() ?? .zero
            let windowFrame = window.frame
            check(frame.height >= 35 && copyFrame.height >= 35
                && windowFrame.contains(frame) && windowFrame.contains(copyFrame)
                && copyFrame.maxX <= frame.minX + 1, "\(label) \(identifier) footer buttons visible without overlap")
            capture("handoff-\(label)-\(identifier)")
            if identifier == "deepseek" {
                // SwiftUI combines the row's Text into its accessible Button.
                // Measure the mounted row, then remove its exact padding/icon/gap.
                let rowFrame = element("agent-external-provider-deepseek")?.accessibilityFrame?() ?? .zero
                check(rowFrame.width - 24 - 18 - 10 + 1 >= harnessNameWidth,
                      "\(label) actual Harness row holds its complete name")
                let title = textValue("agent-external-title")
                check(title == "在 DeepSeek Harness 里继续这个项目",
                      "\(label) native title uses complete Harness identity")
                opener.allowsHarness = true
                check(button.accessibilityPerformPress?() == true, "\(label) Harness open button responds")
                await settle()
                check(opener.openedURLs.map(\.absoluteString) == ["dsh://open"]
                    && opener.copied?.contains(scope.projectID) == true
                    && opener.copied?.contains(context.snapshotID!.uuidString) == true,
                      "\(label) mocked Harness open uses verified URI and current snapshot")
                let result = textValue("agent-external-result")
                check(result == "已打开客户端并复制提示词，尚未发送。",
                      "\(label) Harness launch status distinguishes copied from sent")
                opener.allowsHarness = false; opener.opens = 0; opener.openedURLs = []
            }
        }
        check(element("agent-external-copy")?.accessibilityPerformPress?() == true,
              "\(label) prompt copy responds")
        await settle()
        check(opener.copied?.contains(scope.projectID) == true && opener.opens == 0,
              "\(label) copy uses current project without opening client")
        check(element("agent-external-more")?.accessibilityPerformPress?() == true,
              "\(label) more Agent opens MCP configuration")
        await settle()
        check(element("agent-external-copy-mcp")?.accessibilityPerformPress?() == true,
              "\(label) configuration copy is reachable in fixed footer")
        await settle()
        let value = opener.copied.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(value?["mcpServers"] != nil && opener.copied?.contains(context.snapshotID!.uuidString) == true,
              "\(label) copied configuration preserves snapshot and project scope")
        capture("handoff-\(label)-mcp")
        check(opener.opens == 0, "\(label) design validation never opens external client")
        window.close()
        await settle()
    }
    final class Presentation: ObservableObject {
        @Published var visible = false
    }
    struct SheetRoot: View {
        @ObservedObject var presentation: Presentation
        let content: AgentExternalHandoffView
        var body: some View {
            Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity)
                .sheet(isPresented: $presentation.visible) { content }
        }
    }
    for available in [CGSize(width: 1280, height: 720), CGSize(width: 740, height: 520)] {
        defaults.set("deepseek", forKey: "clipslots.agent.external.last-used")
        let presentation = Presentation()
        let layout = AgentHandoffLayout(available: available)
        let host = NSHostingView(rootView: SheetRoot(presentation: presentation,
            content: AgentExternalHandoffView(context: context, preferences: preferences,
                opener: opener, availableSize: available, onClose: { presentation.visible = false })))
        let parent = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: available),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = host
        parent.makeKeyAndOrderFront(nil)
        presentation.visible = true
        for _ in 0..<60 {
            if parent.attachedSheet != nil { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(350))
        let label = layout.compact ? "compact" : "wide"
        guard let sheet = parent.attachedSheet, let root = sheet.contentView else {
            check(false, "\(label) actual SwiftUI sheet mounted"); parent.close(); continue
        }
        check(sheet.sheetParent === parent, "\(label) retains native modal sheet relationship")
        check(sheet.styleMask == [.borderless] && !sheet.isOpaque
            && sheet.backgroundColor.alphaComponent == 0,
            "\(label) native host has no second rounded frame or opaque corner background")
        check(abs(root.bounds.width - layout.size.width) < 1
            && abs(root.bounds.height - layout.size.height) < 1,
            "\(label) actual sheet content fits without an outer inset")
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(sheet.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("handoff-sheet-\(label).png"))
            let scale = CGFloat(rep.pixelsWide) / layout.size.width
            let corners = [(0, 0), (rep.pixelsWide - 1, 0),
                           (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1)]
            check(corners.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.05 },
                  "\(label) actual sheet four outer corners are transparent")
            var profiles: [[CGFloat]] = []
            for (x, y) in corners {
                let sx = x == 0 ? 1 : -1, sy = y == 0 ? 1 : -1
                let samples = (0..<Int(16 * scale)).map {
                    rep.colorAt(x: x + sx * $0, y: y + sy * $0)?.alphaComponent ?? 0
                }
                profiles.append(samples)
                check(zip(samples, samples.dropFirst()).allSatisfy { $0.0 <= $0.1 + 0.02 }
                    && samples.last! > 0.99,
                    "\(label) corner \(x),\(y) has one monotonic silhouette into the panel")
            }
            check(profiles.dropFirst().allSatisfy { profile in
                // Mirrored raster edges may have different subpixel coverage.
                // Their opaque/transparent boundaries must still occupy identical pixels.
                profile.firstIndex(where: { $0 > 0.01 }) == profiles[0].firstIndex(where: { $0 > 0.01 })
                    && profile.firstIndex(where: { $0 > 0.99 }) == profiles[0].firstIndex(where: { $0 > 0.99 })
                    && zip(profiles[0], profile).reduce(CGFloat(0)) { $0 + abs($1.0 - $1.1) } < 0.5
            }, "\(label) actual sheet four continuous corners share curvature within half a raster pixel")
        } else { check(false, "\(label) actual sheet pixels captured") }
        let close = NativeAccessibilityProbe.elements(root).first {
            ($0.accessibilityIdentifier?() ?? "") == "agent-external-close"
        }
        check(close?.accessibilityPerformPress?() == true, "\(label) actual sheet close responds")
        for _ in 0..<60 {
            if parent.attachedSheet == nil { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        check(parent.attachedSheet == nil && !presentation.visible,
              "\(label) native sheet dismisses and releases modal presentation")
        check(opener.opens == 0, "\(label) actual sheet validation never opens a client")
        parent.close()
        try? await Task.sleep(for: .milliseconds(200))
    }
    defaults.removePersistentDomain(forName: "clipslots.handoff.design-fixture")
}
#endif
