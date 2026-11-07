#if DEBUG
import AppKit
import SwiftUI
import WebKit
import CryptoKit
import CoreImage
import ClipSlotsKit

private actor FollowupConnectorHTTP: AgentMarketHTTP {
    var requests: [(String, String)] = []
    var delayStart = false
    var sequence = 0
    func delay() { delayStart = true }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        requests.append((method, path))
        let result: JSONValue
        if path.hasSuffix("/auth-sessions") {
            sequence += 1
            if delayStart { try await Task.sleep(for: .milliseconds(150)) }
            result = ["session_id": .string("fixture-\(sequence)"), "status": "pending",
                      "authorization_url": "https://example.com/authorize"]
        } else if path.contains("/auth-sessions/") {
            result = ["status": "authenticated"]
        } else if path.contains("/plugins/") {
            result = ["plugin_name": .string(String(path.split(separator: "/").last!)),
                      "connectors": [["connector_id": "notion"]]]
        } else {
            result = ["id": .string(String(path.split(separator: "/").last!)), "status": "disconnected"]
        }
        return (try JSONEncoder().encode(JSONValue.object(["code": 200, "data": result])), 200)
    }
}

@MainActor enum AgentFollowupRegression {
    static func run(root: URL, check: (Bool, String) -> Void) async throws {
        // Minimal LevelDB fixture; no live account or provider credentials.
        func varint(_ input: UInt64) -> [UInt8] {
            var value = input, out: [UInt8] = []
            repeat { let b = UInt8(value & 127); value >>= 7; out.append(b | (value == 0 ? 0 : 128)) } while value > 0
            return out
        }
        func little(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> ($0 * 8)) & 255) } }
        func log(_ bytes: [UInt8]) -> Data { Data([0,0,0,0] + little(UInt64(bytes.count), 2) + [1] + bytes) }
        let home = root.appendingPathComponent("connector-fixture-home")
        let database = home.appendingPathComponent("Library/Application Support/@tap/desktop/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: database.appendingPathComponent("CURRENT"))
        try log([2] + varint(64)).write(to: database.appendingPathComponent("MANIFEST-000001"))
        let claims: JSONValue = ["sub": "followup-fixture", "exp": .number(Double(Int(Date().timeIntervalSince1970) + 3600))]
        let payload = try JSONEncoder().encode(claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let key = Array("_tapnow://app".utf8) + [UInt8(0),1] + Array("access_token".utf8)
        let value = [UInt8(1)] + Array(("header." + payload + ".signature").utf8)
        var batch = little(2,8) + little(1,4)
        batch += [1] + varint(UInt64(key.count)) + key
        batch += varint(UInt64(value.count)) + value
        try log(batch).write(to: database.appendingPathComponent("000064.log"))
        guard let session = AgentMarketDesktopSession.read(home: home.path) else { throw AgentMarketSyncError.requiresLogin }
        let http = FollowupConnectorHTTP()
        let service = AgentMarketSyncService(root: root.appendingPathComponent("connector-cache"), http: http)
        let names = ["unsplash", "frameio", "vimeo", "feishu", "lark", "notion", "slack",
                     "linear", "asana", "descript", "atlassian", "baidupan", "airtable", "hubspot"]
        let apps = names.map { name in
            AgentMarketItem(["kind": "app", "name": .string(name), "connectors": [["connector_id": .string(name)]]])
        }
        var fixture = AgentMarketSnapshot(scope: session.scope, catalog: ["items": .array(apps.map(\.raw))])
        fixture.managerCatalog = apps.map(\.raw)
        fixture.connectors = names.filter { $0 != "vimeo" }.map { ["id": .string($0), "status": "disconnected"] }
        let store = AgentMarketSyncStore(service: service, fixture: fixture, readsDesktop: false)
        store.session = session
        for app in apps {
            try await store.startSourceConnection(app, fresh: true)
            check(store.sourceConnectorID == app.name && store.sourceAuth?.externalURL != nil,
                  "\(app.name): real connector_id shape reaches authorization")
            try await store.pollSourceConnection()
            check(store.sourceAuth?.status == "authenticated", "\(app.name): session polling completes")
            check(try await store.finishSourceConnection(), "\(app.name): completed consent admits local grant")
            try await store.cancelSourceConnection(reset: false)
        }
        check(await http.requests.contains { $0 == ("GET", "/api/agent-gateway/v1/connectors/vimeo") },
              "connector missing from inventory is resolved from provider endpoint")
        let before = await http.requests.count
        try await store.startSourceConnection(apps[0])
        check(await http.requests.count == before && store.connectingItem?.id == apps[0].id,
              "already authorized application does not restart consent")
        try await store.cancelSourceConnection(reset: false)
        let invalid = AgentMarketItem(["kind":"app", "name":"invalid", "connectors":[["display_name":"Unknown"]]])
        check(!store.applicationAuthorizationReady(invalid), "invalid connector never becomes authorized through empty allSatisfy")
        do { try await store.startSourceConnection(invalid); check(false, "invalid declaration rejected") }
        catch { check(await http.requests.count == before, "invalid declaration fails before network") }
        let native = AgentMarketItem(["kind":"app", "name":"creative", "connectors":[]])
        try await store.startSourceConnection(native)
        check(store.sourceAuth == nil && store.connectingItem?.id == native.id,
              "app without external connector goes directly to local tools")
        try await store.cancelSourceConnection(reset: false)
        store.snapshot?.connectors = []
        let multiple = AgentMarketItem(["kind":"app", "name":"multiple",
            "connectors":[["connector_id":"slack"],["connector_id":"notion"]]])
        try await store.startSourceConnection(multiple)
        try await store.pollSourceConnection()
        check(try await !store.finishSourceConnection() && store.sourceConnectorID == "notion",
              "second connector starts after first consent")
        try await store.pollSourceConnection()
        check(try await store.finishSourceConnection() && store.applicationAuthorizationReady(multiple),
              "multi-connector app waits for every consent")
        try await store.cancelSourceConnection(reset: false)
        let stale = AgentMarketItem(["kind":"app", "name":"slack", "connectors":[]])
        try await store.startSourceConnection(stale)
        check(store.sourceConnection?.connectorIDs == ["slack"], "manager catalog replaces stale detail connector list")
        try await store.cancelSourceConnection(reset: false)
        let unresolved = AgentMarketItem(["kind":"app", "name":"unresolved"])
        try await store.startSourceConnection(unresolved)
        check(store.sourceConnection?.connectorIDs == ["notion"], "missing connector declaration resolves fresh plugin detail")
        try await store.cancelSourceConnection(reset: false)
        store.snapshot?.connectors = []
        await http.delay()
        let pending = Task { try await store.startSourceConnection(apps[0], fresh: true) }
        try await Task.sleep(for: .milliseconds(40))
        check(store.sourceAuth == nil, "new authorization cannot reuse completed challenge from previous connector")
        try await store.cancelSourceConnection(reset: false)
        _ = try? await pending.value
        check(store.sourceAuth == nil && store.sourceConnection == nil, "cancel discards late authorization response")
        for (model, backend, icon) in [("deepseek-reasoner", AgentBackendKind.deepseek, "deepseek"),
                                      ("DEEPSEEK-v4", .gateway, "deepseek"),
                                      ("gpt-5", .deepseek, "circle.hexagongrid"),
                                      ("gpt-5", .gateway, "cpu"), ("Tika Agent", .tika, "circle.hexagongrid")] {
            check(AgentModelPresentation(name: model, backend: backend).icon == icon,
                  "\(model): editor and sidebar share model artwork rule")
        }
        try await editorPresentation(check: check)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let loading = WorkspaceLoadingView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        window.contentView = loading; window.makeKeyAndOrderFront(nil)
        loading.show(title: "冷启动图案")
        check(loading.frames?.images.count == 86 && loading.symbol.contents != nil,
              "cold loading cover has the complete animation immediately")
        let coldFrames = loading.frames
        check(coldFrames?.images.allSatisfy { $0.width <= 128 && $0.height <= 128 } == true,
              "shared animation frames are limited to the 64pt Retina display size")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check((loading.symbol.animation(forKey: "morph") as? CAKeyframeAnimation)?.values?.count == 87,
                  "cold show starts the real morph before any asynchronous wait")
        }
        try transitionPoster(loading: loading, root: root, name: "cold", check: check)
        let firstPulseStart = loading.symbol.animation(forKey: "pulse")?.beginTime
        await loading.prepareAnimation()
        await CanvasDisplayClock.shared.nextFrame()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(loading.symbol.animation(forKey: "pulse")?.beginTime == firstPulseStart
                  && loading.symbol.animation(forKey: "morph")?.beginTime == firstPulseStart,
                  "morph and pulse start together without a later decoding handoff")
        }
        loading.layoutSubtreeIfNeeded(); loading.show(title: "正在准备画布")
        check(loading.symbol.bounds.size == CGSize(width: 64, height: 64)
              && loading.envelope.position == CGPoint(x: 240, y: 180), "canvas loader centered at exact TapNow size")
        check(loading.frames?.images.count == 86 && abs((loading.frames?.duration ?? 0) - 3.44) < 0.001,
              "all 86 original WebP frames retain 40ms timing")
        try transitionThemeFrames(loading: loading, check: check)
        if let url = AgentBackgroundResources.pageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TapNowMotion/workspace-loading.webp") {
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            check(digest == "e90e059cd2c39b8c739a2e00f25fbed5f3e322a69dfe26be4b17d5ea93c798e0",
                  "dark canvas loader uses byte-identical TapNow artwork including luminance gradients")
        } else { check(false, "original loading asset exists") }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check((loading.symbol.animation(forKey: "morph") as? CAKeyframeAnimation)?.values?.count == 87
                  && (loading.symbol.animation(forKey: "pulse") as? CAKeyframeAnimation)?.duration == 2,
                  "morph frames loop with the original two-second scale pulse")
            check(loading.layer?.opacity == 1 && loading.layer?.animation(forKey: "visibility") == nil
                  && loading.envelope.animationKeys()?.isEmpty != false,
                  "loading cover is immediately opaque without an entering fade or reveal")
        }
        if ProcessInfo.processInfo.environment["CLIPSLOTS_FOLLOWUP_STATIC_ONLY"] != "1" {
            try await transitionRuntime(window: window, loading: loading, root: root, check: check)
            try await transitionReadiness(window: window, loading: loading, root: root, check: check)
        }
        loading.hide(); loading.show(title: "再次切换")
        try await Task.sleep(for: .milliseconds(250))
        check(loading.layer?.opacity == 1, "late hide does not remove restarted transition")
        loading.hide()
        check(loading.hitTest(.zero) == nil, "fade-out immediately releases input interception")
        try await Task.sleep(for: .milliseconds(250))
        check(loading.symbol.animationKeys()?.isEmpty != false && loading.frames == nil,
              "hidden transition releases animation and input interception")
        loading.show(title: "释放帧后再次加载")
        check(loading.frames?.images.first === coldFrames?.images.first && loading.symbol.contents != nil,
              "repeated loading reuses already decoded original animation frames")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check((loading.symbol.animation(forKey: "morph") as? CAKeyframeAnimation)?.values?.count == 87,
                  "repeated show starts the complete morph immediately")
        }
        try transitionPoster(loading: loading, root: root, name: "repeat", check: check)
        loading.hide()
        try await Task.sleep(for: .milliseconds(250))
        window.close()
        try await readyBlurLifecycle(check: check)
    }

    private static func readyBlurLifecycle(check: (Bool, String) -> Void) async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 360),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let base = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
            let loading = WorkspaceLoadingView(frame: base.bounds)
            base.wantsLayer = true
            base.layerUsesCoreImageFilters = false
            let foreign = CIFilter(name: "CIColorControls")!
            base.layer?.filters = [foreign]
            base.addSubview(loading); window.contentView = base
            window.makeKeyAndOrderFront(nil)
            loading.show(title: "Loading")
            check(base.layer?.animation(forKey: "workspace-ready-blur") == nil
                  && !base.layerUsesCoreImageFilters,
                  "\(appearance.rawValue): loading never blurs an incomplete destination")
            loading.hide()
            let blur = base.layer?.animation(forKey: "workspace-ready-blur") as? CAKeyframeAnimation
            check(blur?.duration == 0.28 && blur?.values as? [Int] == [0, 6, 0]
                  && base.layerUsesCoreImageFilters && base.layer?.filters?.count == 2,
                  "\(appearance.rawValue): ready reveal adds a short native blur beside existing filters")
            try await Task.sleep(for: .milliseconds(45))
            loading.show(title: "Restart")
            check(base.layer?.animation(forKey: "workspace-ready-blur") == nil
                  && base.layer?.filters?.count == 1
                  && (base.layer?.filters?.first as AnyObject?) === foreign
                  && !base.layerUsesCoreImageFilters && loading.layer?.opacity == 1,
                  "\(appearance.rawValue): restarting restores the root and opaque loading cover immediately")
            try await Task.sleep(for: .milliseconds(300))
            check(loading.symbol.contents != nil && loading.layer?.opacity == 1,
                  "\(appearance.rawValue): previous blur cleanup cannot remove a restarted animation")
            loading.hide()
            try await Task.sleep(for: .milliseconds(350))
            check(base.layer?.animation(forKey: "workspace-ready-blur") == nil
                  && base.layer?.filters?.count == 1
                  && (base.layer?.filters?.first as AnyObject?) === foreign
                  && !base.layerUsesCoreImageFilters && base.wantsLayer,
                  "\(appearance.rawValue): ready completion restores the original native filter state")
            loading.show(title: "Detach"); loading.hide()
            loading.removeFromSuperview()
            check(base.layer?.animation(forKey: "workspace-ready-blur") == nil
                  && base.layer?.filters?.count == 1 && !base.layerUsesCoreImageFilters,
                  "\(appearance.rawValue): detaching the loader removes its transient blur")
            window.close()
        }
    }

    private static func transitionPoster(loading: WorkspaceLoadingView, root: URL, name: String,
                                         check: (Bool, String) -> Void) throws {
        let width = Int(loading.bounds.width), height = Int(loading.bounds.height)
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let layer = loading.layer else {
            check(false, "\(name): initial glyph raster exists"); return
        }
        context.interpolationQuality = .low
        layer.render(in: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let background = Int(bytes[0])
        var glyphPixels = 0
        for y in (height / 2 - 32)..<(height / 2 + 32) {
            for x in (width / 2 - 32)..<(width / 2 + 32) {
                if abs(Int(bytes[(y * width + x) * 4]) - background) > 20 { glyphPixels += 1 }
            }
        }
        check(glyphPixels > 100, "\(name): visible central reference glyph exists before any async frame wait")
        if let image = context.makeImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: root.appendingPathComponent("initial-glyph-\(name).png"))
        }
    }

    private static func transitionReadiness(window: NSWindow, loading: WorkspaceLoadingView, root: URL,
                                           check: (Bool, String) -> Void) async throws {
        let base = NSView(frame: window.contentView!.bounds)
        base.wantsLayer = true
        base.layer?.backgroundColor = NSColor.systemRed.cgColor
        loading.removeFromSuperview()
        loading.frame = base.bounds
        loading.autoresizingMask = [.width, .height]
        base.addSubview(loading)
        window.contentView = base
        let transition = WorkspaceTransition()
        transition.surface = loading
        var observations: [[String: Any]] = []
        for mode in [WorkspaceMode.canvas, .edit] {
            await loading.prepareAnimation()
            var preparing = false, prepared = false, committed = false
            transition.switchTo(mode, prepare: {
                preparing = true
                // Keep preparation pending while the covered destination changes.
                for index in 0..<10 {
                    base.layer?.backgroundColor = (index.isMultiple(of: 2) ? NSColor.systemRed : .systemBlue).cgColor
                    try? await Task.sleep(for: .milliseconds(35))
                }
                prepared = true
                return true
            }, commit: {
                committed = true
                base.layer?.backgroundColor = NSColor.systemGreen.cgColor
                transition.sidebarMounts.enroll((0..<12).map { "sidebar-\($0)" })
                if mode == .edit { transition.editorMounts.enroll((0..<12).map { "editor-\($0)" }) }
            })
            check(loading.layer?.opacity == 1 && loading.hitTest(.zero) === loading,
                  "\(mode.rawValue): opaque input cover precedes destination preparation")
            let start = CACurrentMediaTime()
            var coverSamples = 0, opaque = true, pixelsCovered = true
            var preparationSamples = 0, mountSamples = 0
            while transition.isSwitching && CACurrentMediaTime() - start < 4 {
                try await Task.sleep(for: .milliseconds(35))
                guard transition.isSwitching else { break }
                coverSamples += 1
                if preparing && !prepared { preparationSamples += 1 }
                if committed { mountSamples += 1 }
                let opacity = loading.layer?.presentation()?.opacity ?? 0
                opaque = opaque && opacity > 0.999 && loading.layer?.animation(forKey: "visibility") == nil
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                    CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let scale = Double(bitmap.pixelsWide) / Double(base.bounds.width)
                    let titleHeight = Double(bitmap.pixelsHigh) / scale - Double(base.bounds.height)
                    let points = [(16.0, titleHeight + 16.0),
                                  (16.0, titleHeight + Double(base.bounds.height) - 16)]
                    var colors: [[Int]] = []
                    for (x, y) in points {
                        // Compare the stored screenshot channels. colorAt reports
                        // calibrated RGB; converting it again alters raw #ececec.
                        if let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)) {
                            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                                .map { Int(($0 * 255).rounded()) }
                            colors.append(channels)
                            pixelsCovered = pixelsCovered && channels.allSatisfy { abs($0 - 236) <= 1 }
                        } else { pixelsCovered = false }
                    }
                    observations.append(["mode": mode.rawValue, "preparing": !prepared, "mounted": committed,
                                         "opacity": opacity, "colors": colors])
                    if coverSamples == 4 || (committed && mountSamples == 1) {
                        try bitmap.representation(using: .png, properties: [:])?.write(
                            to: root.appendingPathComponent("ready-cover-\(mode.rawValue)-\(committed ? "mount" : "prepare").png"))
                    }
                } else { pixelsCovered = false }
            }
            check(preparationSamples >= 4 && mountSamples >= 2 && opaque && pixelsCovered,
                  "\(mode.rawValue): actual window hides changing destination throughout preparation and mounting")
            check(prepared && committed && !transition.isSwitching
                  && transition.sections.pendingIDs.isEmpty && transition.sidebarMounts.pendingIDs.isEmpty
                  && transition.editorMounts.pendingIDs.isEmpty,
                  "\(mode.rawValue): destination commits and all admission queues drain before reveal")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check((loading.layer?.animation(forKey: "visibility") as? CABasicAnimation)?.duration == 0.18
                      && loading.envelope.opacity == 1,
                      "\(mode.rawValue): only the ready workspace triggers a single short exit fade")
            }
            try await Task.sleep(for: .milliseconds(250))
            check(loading.layer?.opacity == 0 && loading.frames == nil,
                  "\(mode.rawValue): ready exit releases the cover and decoded frames")
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("ready-cover-runtime.json"))
        loading.show(title: "再次切换")
    }

    private static func transitionRuntime(window: NSWindow, loading: WorkspaceLoadingView, root: URL,
                                          check: (Bool, String) -> Void) async throws {
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<75 {
            if window.occlusionState.contains(.visible) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(window.occlusionState.contains(.visible), "transition runtime window is visible")
        var samples: [[String: Double]] = []
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let start = CACurrentMediaTime()
            var uniqueFrames = Set<Int>()
            while CACurrentMediaTime() - start < 2.1 {
                await CanvasDisplayClock.shared.nextFrame()
                guard let presentation = loading.symbol.presentation() else { continue }
                if let image = presentation.contents {
                    uniqueFrames.insert(ObjectIdentifier(image as AnyObject).hashValue)
                }
                samples.append(["time": CACurrentMediaTime() - start, "scale": presentation.transform.m11,
                                "opacity": Double(loading.layer?.presentation()?.opacity ?? 0)])
            }
            let duration = (samples.last?["time"] ?? 0) - (samples.first?["time"] ?? 0)
            let scales = samples.compactMap { $0["scale"] }
            check(samples.count >= 60 && duration > 2, "visible compositor yields sustained transition samples")
            check(uniqueFrames.count >= 35, "visible native compositor advances through original morph frames")
            check((scales.min() ?? 0) >= 0.949 && (scales.max() ?? 2) <= 1.051
                  && (scales.max() ?? 0) - (scales.min() ?? 0) > 0.09,
                  "runtime scale pulse spans the original 0.95–1.05 range")
            check(samples.allSatisfy { ($0["opacity"] ?? 0) > 0.999 },
                  "loading backdrop stays fully opaque throughout compositor sampling")
        }
        let morphStart = loading.symbol.animation(forKey: "morph")?.beginTime
        let pulseStart = loading.symbol.animation(forKey: "pulse")?.beginTime
        var raster: [NSAppearance.Name: [UInt8]] = [:]
        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            let light = appearance == .aqua
            let backdrop = light
                ? NSColor(srgbRed: 236.0 / 255, green: 236.0 / 255, blue: 236.0 / 255, alpha: 1)
                : NSColor.black
            check(loading.layer?.backgroundColor == backdrop.cgColor,
                  "\(appearance.rawValue): existing loader backdrop follows window theme")
            let expected = light ? loading.frames?.lightImages.first : loading.frames?.images.first
            check((loading.symbol.contents as AnyObject?) === expected,
                  "\(appearance.rawValue): existing loader selects the matching morph colors")
            check(loading.symbol.animation(forKey: "morph")?.beginTime == morphStart
                  && loading.symbol.animation(forKey: "pulse")?.beginTime == pulseStart,
                  "\(appearance.rawValue): theme switch preserves morph and pulse clocks")
            if let layer = loading.layer,
               let context = CGContext(data: nil, width: 480, height: 360, bitsPerComponent: 8,
                   bytesPerRow: 480 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // Match CALayer's linear sampling. The default CGContext
                // downsampling introduces ringing outside the palette range.
                context.interpolationQuality = .low
                layer.render(in: context)
                if let data = context.data {
                    raster[appearance] = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                                                  count: 480 * 360 * 4))
                }
                if let image = context.makeImage() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: root.appendingPathComponent("transition-raster-\(appearance.rawValue).png"))
                }
            }
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: root.appendingPathComponent("transition-\(appearance.rawValue).png"))
            }
        }
        if let light = raster[.aqua], let dark = raster[.darkAqua] {
            check(light[0] == 236 && dark[0] == 0,
                  "rendered light backdrop matches reference #ececec and dark backdrop is black")
            let outsideSymbol = (180 * 480 + 209) * 4
            check(light[outsideSymbol] == 236 && dark[outsideSymbol] == 0,
                  "rendered frame backdrop matches the surrounding theme without a rectangular seam")
            var gradientError = 0
            var lightMin = 255, darkMax = 0
            for y in 148..<212 {
                for x in 208..<272 {
                    let index = (y * 480 + x) * 4
                    lightMin = min(lightMin, Int(light[index]))
                    darkMax = max(darkMax, Int(dark[index]))
                    let expected = 236.0 - 168.0 * Double(dark[index]) / 255
                    gradientError = max(gradientError, abs(Int(light[index]) - Int(expected.rounded())))
                }
            }
            check(abs(lightMin - 68) <= 2 && darkMax > 247,
                  "rendered light glyph matches reference #444444 and dark glyph remains white")
            check(gradientError <= 2, "rendered light morph retains the original gradients in the reference palette")
        } else { check(false, "both theme rasters are available") }
        window.setContentSize(NSSize(width: 620, height: 400))
        loading.layoutSubtreeIfNeeded()
        check(loading.envelope.position == CGPoint(x: 310, y: 200)
              && loading.symbol.bounds.size == CGSize(width: 64, height: 64),
              "resizing keeps the 64px morph animation centered")
        try JSONSerialization.data(withJSONObject: ["samples": samples,
            "reference": "TapNow loading-overlay-CfKK9qM2.js / loading-BWU_g4Wm.webp",
            "scope": "Native presentation-layer timing; not a recording of TapNow's live transition"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("transition-runtime.json"))
    }

    private static func transitionThemeFrames(loading: WorkspaceLoadingView, check: (Bool, String) -> Void) throws {
        guard let frames = loading.frames, frames.lightImages.count == frames.images.count else {
            check(false, "both themes contain every original animation frame"); return
        }
        func pixels(_ image: CGImage) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                             count: image.width * image.height * 4))
        }
        var maximumError = 0, alphaChanged = false, gradientPixels = 0
        var referenceBackdropPixels = 0, referenceGlyphPixels = 0
        var uniqueDarkFrames = Set<Data>()
        for (dark, light) in zip(frames.images, frames.lightImages) {
            guard let original = pixels(dark), let adapted = pixels(light), original.count == adapted.count else {
                check(false, "theme frames decode to matching pixel dimensions"); return
            }
            uniqueDarkFrames.insert(Data(SHA256.hash(data: Data(original))))
            for index in stride(from: 0, to: original.count, by: 4) {
                let alpha = Int(original[index + 3])
                alphaChanged = alphaChanged || original[index + 3] != adapted[index + 3]
                for channel in 0..<3 {
                    let expected = (236.0 * Double(alpha) - 168.0 * Double(original[index + channel])) / 255
                    maximumError = max(maximumError, abs(Int(adapted[index + channel]) - Int(expected.rounded())))
                }
                if original[index] > 2 && Int(original[index]) < alpha - 2 { gradientPixels += 1 }
                if alpha == 255 && original[index] == 0 && adapted[index] == 236 { referenceBackdropPixels += 1 }
                if alpha == 255 && original[index] == 255 && adapted[index] == 68 { referenceGlyphPixels += 1 }
            }
        }
        check(!alphaChanged, "all 86 light frames preserve the original alpha values")
        check(uniqueDarkFrames.count >= 70, "complete cached animation contains distinct original morph shapes")
        let cachedBytes = (frames.images + frames.lightImages).reduce(0) {
            $0 + $1.bytesPerRow * $1.height
        }
        check(cachedBytes <= 12 * 1024 * 1024, "both themes share a bounded display-size animation cache")
        check(maximumError <= 2 && gradientPixels > 1000,
              "all 86 light frames retain full luminance gradients in the reference gray palette")
        check(referenceBackdropPixels > 1000 && referenceGlyphPixels > 1000,
              "all 86 adapted frames reach the screenshot's #ececec backdrop and #444444 glyph")
    }

    private static func editorPresentation(check: (Bool, String) -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [AgentBackendScope.sidebar.preferenceKey, AgentGatewayPreferences.modelKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let group = SpecialSlot(id: "icon-fixture", name: "Fixture", sourceType: .manual,
                                createdAt: Date(), updatedAt: Date())
        let model = try SlotEditorModel(snapshot: .init(slot: 1, group: group, pageName: "Fixture",
            content: SlotContent(items: [[PasteboardItem(type: "public.utf8-plain-text", data: Data("Fixture".utf8))]])))
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SlotTextEditorSheet(model: model,
            onFullScreen: {}, onSave: {}, onCancel: {}))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        for (name, icon) in [("deepseek-v4-pro", "deepseek"), ("gpt-5", "cpu")] {
            defaults.set(name, forKey: AgentGatewayPreferences.modelKey)
            AgentBackendCoordinator.setKind(.gateway, for: .sidebar)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try await Task.sleep(for: .milliseconds(150))
            check(model.modelName == name && model.modelPresentation.icon == icon,
                  "open editor reacts to \(name) preference notifications without reopening")
            let indicator = NativeAccessibilityProbe.elements(host).first { $0.accessibilityIdentifier?() == "slot-editor-model" }
            check(indicator?.accessibilityLabel?() == "当前模型：" + name,
                  "\(name): mounted editor indicator and accessible model name update together")
        }
        window.close()
    }

    static func settings(window: NSWindow, web: AgentLineHostWebView, root: URL,
                         check: (Bool, String) -> Void) async {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        var delivered = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.window === window { delivered += 1 }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        for name in ["claude", "gemini", "gpt", "deepseek", "grok", "kimi"] {
          var nativeGestureTravel: CGFloat = 0
          // Quartz-injected momentum is ignored inconsistently by NSScrollView
          // itself. Exercise AppKit's actual deceleration from ended gestures.
          for kind in ["native-gesture", "wheel", "gesture"] {
            let raw = try? await web.evaluateJavaScript("(()=>{const r=document.querySelector('#picker .\(name)').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()")
            guard let point = raw as? [String: Double], let x = point["x"], let y = point["y"] else {
                check(false, name + ": card DOM located"); continue
            }
            var ancestor = web.superview
            while ancestor != nil && !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
            guard let scroll = ancestor as? NSScrollView else {
                check(false, name + ": outer settings scroll exists"); continue
            }
            // Leave a margin above the fixed footer. scrollToVisible on the
            // nested WebView alone can put a bottom card behind that footer.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let pointInClip = scroll.contentView.convert(NSPoint(x: x, y: y), from: web)
            let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let revealY = min(maxY, max(0, pointInClip.y - scroll.contentView.bounds.height + 100))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: revealY))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(120))
            let control = kind.hasPrefix("native-")
            let location = control
                ? scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.minX + 4,
                                                     y: scroll.contentView.bounds.midY), to: nil)
                : web.convert(NSPoint(x: x, y: y), to: nil)
            let hit = window.contentView?.hitTest(window.contentView!.convert(location, from: nil))
            let hitsWeb = hit === web || hit?.isDescendant(of: web) == true
            check(control ? (!hitsWeb && hit?.isDescendant(of: scroll) == true) : hitsWeb,
                  name + "/" + kind + ": input location hits the intended visible surface")
            let screen = window.convertPoint(toScreen: location)
            let before = scroll.contentView.bounds.origin.y
            let receipt = "scroll-receipt-\(UUID().uuidString).json"
            let request: [String: Any] = ["pid": getpid(), "window": window.windowNumber,
                "x": screen.x, "y": (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y,
                "receipt": receipt, "delta": -48, "kind": kind]
            try? JSONSerialization.data(withJSONObject: request)
                .write(to: root.appendingPathComponent("scroll-request.json"), options: .atomic)
            var acknowledged = false
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: root.appendingPathComponent(receipt)),
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    acknowledged = result["success"] as? Bool == true
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // AppKit synthesizes deceleration after a phase-ended event. Let
            // it finish before resetting the next fixture's clip origin.
            var stable = 0, previous = scroll.contentView.bounds.origin.y
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                let current = scroll.contentView.bounds.origin.y
                stable = abs(current - previous) < 0.01 ? stable + 1 : 0
                previous = current
                if stable >= 4 { break }
            }
            let delta = scroll.contentView.bounds.origin.y - before
            check(acknowledged, name + "/" + kind + ": external input targets the correct native window")
            check(stable >= 4, name + "/" + kind + ": native deceleration settles before next input")
            if kind == "native-gesture" { nativeGestureTravel = delta }
            let correctTravel: Bool
            switch kind {
            case "wheel": correctTravel = abs(delta - 48) < 1
            case "gesture":
                // More travel than the 48px input proves actual deceleration.
                // Compare to native padding, allowing scheduler-dependent speed.
                correctTravel = delta > 72 && nativeGestureTravel > 72
                    && abs(delta - nativeGestureTravel) / nativeGestureTravel < 0.35
            default: correctTravel = delta > 0
            }
            check(correctTravel, name + "/" + kind + ": travel matches native control and input semantics")
            print("SCROLL \(name)/\(kind) before=\(before) after=\(scroll.contentView.bounds.origin.y) delivered=\(delivered) location=\(location)")
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
          }
        }
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: root.appendingPathComponent("agent-settings-followup.png"))
        }
    }
}
#endif
