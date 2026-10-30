#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor SyncNativeHTTP: AgentMarketHTTP {
    let snapshot: AgentMarketSnapshot
    init(_ snapshot: AgentMarketSnapshot) { self.snapshot = snapshot }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data = request.url?.path.hasSuffix("/catalog") == true ? snapshot.catalog : snapshot.details["skill:sync-fixture"]!
        return (try JSONEncoder().encode(JSONValue.object(["code":200, "data":data])), 200)
    }
}
private final class SyncNativeBackend: AgentBackend, @unchecked Sendable {
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] { [] }
}

@MainActor enum AgentMarketSyncRegression {
    static func run(store: SlotStoreObservable, root: URL) async {
        var passed: [String] = [], failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed.append(name) } else { failures.append(name) }
        }
        func find(_ root: NSView, _ id: String) -> AnyObject? {
            NativeAccessibilityProbe.elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        func press(_ view: NSView, _ id: String) -> Bool { find(view, id)?.accessibilityPerformPress?() == true }
        func fill(_ view: NSView, _ id: String, _ text: String) -> Bool {
            guard let element = find(view, id),
                  let field = (element as? NSTextField) ?? ((element as? NSCell)?.controlView as? NSTextField),
                  let window = field.window else { return false }
            window.makeFirstResponder(field)
            guard let editor = window.fieldEditor(true, for: field) as? NSTextView else { return false }
            editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
            window.makeFirstResponder(nil)
            return field.stringValue == text
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
        func capture(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
            }
        }
        func customIconVisible(_ view: NSView) -> Bool {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return false }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let image = bitmap.cgImage else { return false }
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating:0,count:width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,
                    bitsPerComponent:8,bytesPerRow:width * 4,space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
                return true
            }
            guard drawn else { return false }
            var blue = 0, orange = 0
            for index in stride(from:0,to:pixels.count,by:24) {
                if pixels[index + 2] > 128 && pixels[index] < 77 { blue += 1 }
                if pixels[index] > 204 && pixels[index + 1] > 77 && pixels[index + 2] < 77 { orange += 1 }
            }
            return blue > 3 && orange > 3
        }
        let previous = UserDefaults.standard.object(forKey: AgentPreferences.enabledSkillsKey)
        let appearance = NSApp.appearance
        defer {
            NSApp.appearance = appearance
            if let previous { UserDefaults.standard.set(previous, forKey: AgentPreferences.enabledSkillsKey) }
            else { UserDefaults.standard.removeObject(forKey: AgentPreferences.enabledSkillsKey) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NativeAccessibilityProbe.enable()
            let item: JSONValue = ["kind":"skill", "name":"sync-fixture", "display_name":"角色创作工作室",
                "description":"使用来源的实际技能和参数", "activation_skill":"sync-fixture",
                "business_scenario":"film", "public_content":"# 同步技能\n\n保持角色和媒体比例。",
                "try_form":["prompt":["max_length":400],"references":["min":0,"max":4],
                    "fields":[["id":"subject","label":"主题","required":true,"max_length":20]]]]
            let catalog: JSONValue = ["content_version":"native-v1", "items":[item],
                "categories":[["id":"film","label":"影视创意"]], "featured":[["kind":"skill","name":"sync-fixture"]]]
            let fixture = AgentMarketSnapshot(catalog: catalog, details: ["skill:sync-fixture":item], accountStatus: "公开目录")
            let service = AgentMarketSyncService(root: root.appendingPathComponent("sync-cache"), http: SyncNativeHTTP(fixture))
            let sync = AgentMarketSyncStore(service: service, fixture: fixture, readsDesktop: false)
            let iconBitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:2, pixelsHigh:1,
                bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false,
                colorSpaceName:.deviceRGB, bytesPerRow:8, bitsPerPixel:32)!
            for (index,byte) in [UInt8(40),130,230,255,255,160,40,255].enumerated() {
                iconBitmap.bitmapData![index] = byte
            }
            let localIcon = root.appendingPathComponent("custom-test-icon.png")
            let iconBytes = iconBitmap.representation(using:.png,properties:[:])!
            try iconBytes.write(to:localIcon)
            let imported = try await sync.importIcon(localIcon)
            check(try Data(contentsOf:root.appendingPathComponent("sync-cache/custom-icons/" + String(imported.dropFirst(6)))) == iconBytes,
                "local icon import preserves the selected image bytes")
            let canvas = CanvasStore(storage: CanvasStorage(rootOverride: root.appendingPathComponent("canvas")),
                projectStorage: CanvasProjectStorage(rootOverride: root.appendingPathComponent("canvas")))
            let model = AgentSessionStore().canvasSession(canvas: canvas, store: store)
            model.setBackend(SyncNativeBackend())
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 440, height: 780),
                styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close(); model.stop() }
            for dark in [false,true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for width in [320,360,440,960] {
                    let name = "\(dark ? "dark" : "light")-\(width)"
                    UserDefaults.standard.set("", forKey: AgentPreferences.enabledSkillsKey)
                    model.draft = "保留草稿🙂"; model.draftSkillReferences = []
                    let graph = canvas.nodes, conversation = model.selectedConversationID
                    var used = 0
                    let host = NSHostingView(rootView: AgentSyncedAppMarketView(model: model,
                        onClose: {}, onUse: { used += 1 }, sync: sync))
                    window.contentView = host; window.setContentSize(CGSize(width: width,height:780))
                    window.makeKeyAndOrderFront(nil); await settle()
                    capture(host, "sync-home-" + name)
                    check(find(host,"market-sync-item-sync-fixture") != nil, name + " actual source-driven card exists")
                    check(press(host,"market-add-sync-fixture"),name + " direct add or reference action is present on the list")
                    await settle()
                    check(sync.isInstalled(AgentMarketItem(item)),name + " list installs without opening detail")
                    model.draftSkillReferences = []; used = 0
                    check(press(host,"market-sync-featured-sync-fixture"), name + " source featured item opens")
                    await settle()
                    _ = press(host,"market-sync-use"); await settle()
                    check(used == 1 && model.draft == "保留草稿🙂" && model.draftSkillReferences.count == 1,
                        name + " ordinary reference skips forms and preserves visible draft")
                    used = 0; model.draftSkillReferences = []
                    check(press(host,"market-sync-form"),name + " optional form expands")
                    await settle()
                    _ = press(host,"market-sync-use-form"); await settle()
                    check(used == 0 && model.draft == "保留草稿🙂" && model.draftSkillReferences.isEmpty,
                        name + " optional form validates before mutating reference or draft")
                    check(fill(host,"market-sync-field-subject","柠檬汽水"), name + " dynamic source field accepts native input")
                    await settle()
                    check(AgentPreferences.decodeEnabledSlugs(UserDefaults.standard.string(forKey:AgentPreferences.enabledSkillsKey) ?? "").count == 1,
                        name + " enabling changes actual authorization")
                    capture(host,"sync-detail-" + name)
                    check(press(host,"market-sync-use-form"),name + " source trial action responds")
                    for _ in 0..<40 {
                        if used == 1 && !model.isAddingSkill { break }
                        try? await Task.sleep(for:.milliseconds(30))
                    }
                    check(used == 1 && model.draft.hasPrefix("保留草稿🙂\n\n") && model.draft.contains("主题：柠檬汽水")
                        && model.draftSkillReferences.first?.markdown == "# 同步技能\n\n保持角色和媒体比例。"
                        && canvas.nodes == graph && model.selectedConversationID == conversation,
                        name + " actual markdown and params preserve draft graph and conversation")
                    check(press(host,"market-sync-presentation"),name + " icon configuration opens")
                    await settle()
                    if let sheet = window.sheets.first?.contentView {
                        check(find(sheet,"market-sync-follow-icon") != nil && find(sheet,"market-sync-icon-url") != nil,
                            name + " source following and URL icon configuration render")
                        capture(sheet,"sync-icon-settings-" + name)
                        _ = press(sheet,"market-sync-save-presentation")
                    } else { check(false,name + " configuration sheet exists") }
                    await settle()
                    check(sync.presentation["skill:sync-fixture"]?.followsSource == true,name + " source following persists")
                    _ = press(host,"market-sync-presentation"); await settle()
                    if let sheet = window.sheets.first?.contentView {
                        check(press(sheet,"market-sync-follow-icon"),name + " custom icon mode responds")
                        await settle()
                        check(fill(sheet,"market-sync-icon-url",imported),name + " imported local icon accepts native configuration")
                        check(press(sheet,"market-sync-save-presentation"),name + " custom icon save responds")
                        await settle()
                        check(sync.presentation["skill:sync-fixture"]?.icon == imported
                            && sync.presentation["skill:sync-fixture"]?.followsSource == false,
                            name + " actual custom icon selection persists")
                        _ = press(host,"market-sync-back"); await settle()
                        capture(host,"sync-custom-icon-" + name)
                        check(customIconVisible(host),name + " selected local icon pixels are visibly rendered")
                        _ = press(host,"market-sync-featured-sync-fixture"); await settle()
                        _ = press(host,"market-sync-presentation"); await settle()
                        if let restored = window.sheets.first?.contentView {
                            _ = press(restored,"market-sync-follow-icon")
                            _ = press(restored,"market-sync-save-presentation"); await settle()
                            check(sync.presentation["skill:sync-fixture"]?.followsSource == true,
                                name + " custom icon returns to source following")
                        } else { check(false,name + " custom icon can reopen settings") }
                    } else { check(false,name + " custom icon configuration sheet exists") }
                    _ = press(host,"market-sync-back"); await settle()
                    check(fill(host,"market-sync-search","not-found"),name + " native search input")
                    await settle(); check(find(host,"market-sync-empty") != nil,name + " no-result state renders")
                }
            }
            let readOnly = NSHostingView(rootView: AgentSyncedAppMarketView(model:model,isReadOnly:true,onClose:{},onUse:{},sync:sync))
            window.contentView = readOnly; await settle()
            _ = press(readOnly,"market-sync-item-sync-fixture"); await settle()
            let raw = UserDefaults.standard.string(forKey:AgentPreferences.enabledSkillsKey), draft = model.draft
            _ = press(readOnly,"market-add-sync-fixture"); _ = press(readOnly,"market-sync-use"); await settle()
            check(raw == UserDefaults.standard.string(forKey:AgentPreferences.enabledSkillsKey) && draft == model.draft,
                "read-only mode cannot enable skill or change draft")
            // Render the current verified public catalog with its real remote artwork.
            let liveService = AgentMarketSyncService(root:root.appendingPathComponent("source-preview"))
            if let source = await liveService.load() {
                let live = AgentMarketSyncStore(service:liveService,fixture:source,readsDesktop:false)
                let sourceHost = NSHostingView(rootView:AgentSyncedAppMarketView(model:model,onClose:{},onUse:{},sync:live))
                window.contentView = sourceHost; window.setContentSize(CGSize(width:440,height:880))
                for item in source.items.prefix(4) {
                    if let address = item.coverURL ?? item.iconURL { _ = try? await liveService.image(address) }
                }
                await settle()
                capture(sourceHost,"verified-source-catalog")
                check(source.items.count == 81 && source.details.count == 81,"verified bundled catalog preserves every actual app configuration")
                if let artwork = source.items.compactMap(\.coverURL).first(where:{$0.hasPrefix("/app-store/")}) {
                    let bytes = try await liveService.image(artwork)
                    check(NSImage(data:bytes) != nil,"actual relative SVG source artwork decodes natively")
                } else { check(false,"actual source SVG artwork exists") }
                if let feishu = source.items.first(where: { $0.name == "tapnow-feishu" }), let icon = feishu.iconURL {
                    let image = try await liveService.image(icon)
                    check(NSImage(data:image) != nil,"real Feishu icon can decode")
                    for dark in [false,true] {
                        NSApp.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
                        window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
                        for width in [320,440,960] {
                            let actual = NSHostingView(rootView:AgentSyncedAppMarketView(model:model,onClose:{},onUse:{},sync:live))
                            window.contentView = actual; window.setContentSize(CGSize(width:width,height:780)); await settle()
                            check(fill(actual,"market-sync-search","飞书"),"real Feishu search \(dark)-\(width)")
                            await settle()
                            check(press(actual,"market-sync-item-tapnow-feishu"),"real Feishu detail opens \(dark)-\(width)")
                            await settle()
                            capture(actual,"feishu-detail-\(dark ? "dark" : "light")-\(width)")
                            let cover = find(actual,"market-sync-cover-tapnow-feishu")?.accessibilityFrame?() ?? .zero
                            let button = find(actual,"market-sync-use")?.accessibilityFrame?() ?? .zero
                            check(cover.height <= 150 && button.height > 0 && !cover.intersects(button),
                                "real Feishu cover and reference controls remain bounded \(dark)-\(width)")
                        }
                    }
                } else { check(false,"verified source contains Feishu application") }
            } else { check(false,"verified source snapshot can be loaded") }
        } catch { check(false,error.localizedDescription) }
        let report: [String:Any] = ["passed":passed,"failures":failures,"paid_generation_requests":0,"themes":2,"widths":[320,360,440,960]]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
