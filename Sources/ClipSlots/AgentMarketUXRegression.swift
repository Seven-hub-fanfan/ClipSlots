#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor MarketUXBackend: AgentBackend {
    var received: [AgentMessage] = []
    var toolResult: AgentToolResult?
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        received = history
        if let spec = tools?.specs().first(where: { $0.name.hasPrefix("app_") }) {
            toolResult = await tools?.execute(call: .init(id: "wire-proof", name: spec.name, argumentsJSON: "{\"id\":\"doc-42\"}"))
        }
        return [AgentMessage(role: .assistant, content: "已收到实际引用")]
    }
}
private actor MarketUXMCPHTTP: AgentMCPHTTP {
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let input = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        let method = input["method"]?.stringValue
        let result: JSONValue
        switch method {
        case "initialize": result = ["protocolVersion":"2025-03-26","capabilities":["tools":[:]]]
        case "tools/list": result = ["tools":[["name":"feishu_read_document","description":"读取飞书文档",
            "inputSchema":["type":"object","properties":["id":["type":"string"]],"required":["id"]],
            "annotations":["readOnlyHint":true]]]]
        case "tools/call":
            calls += 1
            result = ["content":[["type":"text","text":"真实传输返回 doc-42"]]]
        default: result = [:]
        }
        return (try JSONEncoder().encode(JSONValue.object(["jsonrpc":"2.0","id":input["id"] ?? .null,"result":result])),
                HTTPURLResponse(url:request.url!,statusCode:method == "notifications/initialized" ? 202 : 200,
                    httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
private actor MarketUXHTTP: AgentMarketHTTP {
    let snapshot: AgentMarketSnapshot
    init(_ snapshot: AgentMarketSnapshot) { self.snapshot = snapshot }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let value = request.url?.path.hasSuffix("/catalog") == true ? snapshot.catalog :
            snapshot.details.values.first { request.url?.path.hasSuffix("/" + ($0["name"]?.stringValue ?? "")) == true } ?? .null
        return (try JSONEncoder().encode(JSONValue.object(["code":200,"data":value])),200)
    }
}

@MainActor enum AgentMarketNativeInput {
    static func click(frame: CGRect, window: NSWindow, root: URL, text: String? = nil, hover: Bool = false) async -> Bool {
        guard window.isVisible, !frame.isEmpty else { return false }
        let nonce = UUID().uuidString
        let receipt = "input-receipt-" + nonce + ".json"
        var request: [String: Any] = ["pid":ProcessInfo.processInfo.processIdentifier,
            "window":window.windowNumber,"x":frame.midX,
            "y":(NSScreen.screens.first?.frame.maxY ?? 0) - frame.midY,"receipt":receipt]
        if let text { request["kind"] = "keyboard"; request["text"] = text }
        if hover { request["kind"] = "hover" }
        do {
            try JSONSerialization.data(withJSONObject:request)
                .write(to:root.appendingPathComponent("input-request.json"),options:.atomic)
            for _ in 0..<100 {
                if let data = try? Data(contentsOf:root.appendingPathComponent(receipt)),
                   let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                    try? await Task.sleep(for:.milliseconds(100))
                    return value["success"] as? Bool == true
                }
                try? await Task.sleep(for:.milliseconds(50))
            }
        } catch {}
        return false
    }
}

@MainActor enum AgentMarketUXRegression {
    static func run(root: URL) async {
        var passed: [String] = [], failures: [String] = []
        func check(_ value: Bool, _ label: String) { if value { passed.append(label) } else { failures.append(label) } }
        var mouseEvents: [[String: String]] = []
        var deliveredEvents: [[String: String]] = []
        let eventMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp]) { event in
            deliveredEvents.append(["type":String(event.type.rawValue),"window":String(event.windowNumber),
                "point":NSStringFromPoint(event.locationInWindow),"timestamp":String(event.timestamp)])
            return event
        }
        defer {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(320)) }
        func find(_ view: NSView, _ id: String) -> AnyObject? {
            NativeAccessibilityProbe.elements(view).first { $0.accessibilityIdentifier?() == id }
        }
        func press(_ view: NSView, _ id: String) async -> Bool {
            guard let element = find(view, id),
                  let window = (element.accessibilityWindow?() as? NSWindow) ?? view.window,
                  window.isVisible, let frame = element.accessibilityFrame?(), !frame.isEmpty else { return false }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let hit = view.hitTest(view.convert(point, from: nil))
            mouseEvents.append(["id":id,"frame":NSStringFromRect(frame),"point":NSStringFromPoint(point),
                                "hit":String(describing: type(of: hit)),"window":String(window.windowNumber)])
            if id == "agent-add-apps" || id == "agent-add-skills" {
                guard await AgentMarketNativeInput.click(frame:frame,window:window,root:root,hover:true),
                      let current = find(view,id), let updated = current.accessibilityFrame?() else { return false }
                check(abs(updated.midX - frame.midX) < 1 && abs(updated.midY - frame.midY) < 1,
                      id + " hover expands left while root control stays anchored")
                return await AgentMarketNativeInput.click(frame:updated,window:window,root:root)
            }
            return await AgentMarketNativeInput.click(frame: frame, window: window, root: root)
        }
        func capture(_ view: NSView, _ name: String) -> NSBitmapImageRep? {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return nil }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent(name + ".png"))
            return bitmap
        }
        func enterText(_ view: NSView, _ id: String, _ text: String) async -> Bool {
            guard await press(view, id), let window = view.window,
                  let frame = find(view,id)?.accessibilityFrame?() else { return false }
            return await AgentMarketNativeInput.click(frame:frame, window:window, root:root, text:text)
        }
        let enabledBefore = UserDefaults.standard.object(forKey: AgentPreferences.enabledSkillsKey)
        defer {
            if let enabledBefore { UserDefaults.standard.set(enabledBefore, forKey: AgentPreferences.enabledSkillsKey) }
            else { UserDefaults.standard.removeObject(forKey: AgentPreferences.enabledSkillsKey) }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            NativeAccessibilityProbe.enable()
            // A newly signed, isolated bundle has its own permission identity.
            // Close the normal launch guide through its observed control; this
            // does not grant, repair, reset or suppress any system permission.
            for _ in 0..<60 {
                if let guide = PermissionCenter.panel, guide.isVisible, let content = guide.contentView {
                    check(await press(content, "permission-close"), "isolated launch guide closes through actual mouse input")
                    await settle()
                    check(PermissionCenter.panel == nil, "launch guide is dismissed without changing permissions")
                    break
                }
                if PermissionCenter.model.authorized.contains(.accessibility) { break }
                try? await Task.sleep(for:.milliseconds(100))
            }
            let app = AgentMarketItem(["kind":"app","name":"feishu","display_name":"飞书","description":"文档与团队资料",
                "connectors":[["name":"feishu","requires_authorization":true]]])
            let skill = AgentMarketItem(["kind":"skill","name":"film","display_name":"分镜创作","public_content":"# 分镜\n保持原始媒体比例。"])
            let missing = AgentMarketItem(["kind":"skill","name":"missing","display_name":"未取得正文"])
            let fixture = AgentMarketSnapshot(catalog:["content_version":"ux-v1","items":.array([app.raw,skill.raw,missing.raw])],
                details:[app.id:app.raw,skill.id:skill.raw,missing.id:missing.raw],fetchedAt:Date(),detailsAt:Date())
            let service = AgentMarketSyncService(root:root.appendingPathComponent("market-cache"),http:MarketUXHTTP(fixture))
            try await service.commit(fixture)
            let sync = AgentMarketSyncStore(service:service,fixture:fixture,readsDesktop:false)
            await sync.refresh()
            let backend = MarketUXBackend()
            let model = AgentChatModel(displayName:"回归",backend:backend,persistenceURL:root.appendingPathComponent("conversation.json"))
            let mcp = MarketUXMCPHTTP()
            sync.clientFactory = { endpoint, _ in AgentMCPClient(endpoint: endpoint, http: mcp) }
            model.applicationStore = sync
            model.selectAutomaticApproval(true)
            model.draft = "保留草稿🙂"
            let reference = AgentSkillReference(name:"分镜",path:"/fixture/SKILL.md",markdown:"# 真实规范")
            do {
                _ = try await model.prepareReference(prompt:"不应写入") { throw CocoaError(.fileNoSuchFile) }
                check(false,"failed read throws")
            } catch { check(true,"failed read throws") }
            check(model.draft == "保留草稿🙂" && model.draftSkillReferences.isEmpty && !model.isAddingSkill,
                "failed read is atomic and releases busy state")
            let slow = Task { try await model.prepareReference {
                try await Task.sleep(for:.milliseconds(150)); return reference
            } }
            await Task.yield()
            let duplicate = try await model.prepareReference { reference }
            check(!duplicate && model.isAddingSkill,"rapid duplicate reference cannot enter a second operation")
            check(!model.send(text:model.draft,config:AgentConfig(),enabledSkills:[]),"send is blocked until reference commits")
            _ = try await slow.value
            check(model.draftSkillReferences.count == 1 && model.draft == "保留草稿🙂","slow reference adds once without altering draft")
            model.draftSkillReferences += (1...3).map { AgentSkillReference(name:"\($0)",path:"/\($0)",markdown:"body") }
            let repeated = try await model.prepareReference { reference }
            check(repeated && model.draftSkillReferences.count == 4,"existing reference succeeds at four-item limit")
            do {
                _ = try await model.prepareReference(prompt:"不应写入") { AgentSkillReference(name:"第五项",path:"/5",markdown:"body") }
                check(false,"fifth distinct reference rejected")
            } catch { check(model.draft == "保留草稿🙂" && model.draftSkillReferences.count == 4,"fifth reference preserves draft and existing references") }
            model.draftSkillReferences = []
            let stale = Task { try await model.prepareReference(prompt:"旧会话") {
                try await Task.sleep(for:.milliseconds(160)); return reference
            } }
            await Task.yield(); model.clearHistory(); model.draft = "新会话草稿"
            check(try await stale.value == false && model.draftSkillReferences.isEmpty && model.draft == "新会话草稿",
                "switching conversation discards late reference and prompt")
            let cancelled = Task { try await model.prepareReference(prompt:"已取消") {
                try await Task.sleep(for:.milliseconds(160)); return reference
            } }
            await Task.yield(); cancelled.cancel()
            _ = try? await cancelled.value
            check(!model.isAddingSkill && model.draftSkillReferences.isEmpty && model.draft == "新会话草稿",
                "dismissal cancellation cannot mutate composer")
            do { try await sync.install(missing); check(false,"missing skill must fail") }
            catch { check(!sync.isInstalled(missing) && sync.itemErrors[missing.id] != nil,"failed install shows retryable error without checkmark") }
            var recovered = fixture
            recovered.details[missing.id] = ["kind":"skill","name":"missing","public_content":"# 已取得真实正文"]
            sync.snapshot = recovered
            try await sync.install(missing)
            check(sync.isInstalled(missing) && sync.itemErrors[missing.id] == nil,"retry installs after real skill becomes available")
            // Fail a real disk write; success must not leak into the visible manifest.
            let blockedRoot = root.appendingPathComponent("blocked")
            try Data("file blocks directory".utf8).write(to:blockedRoot)
            let blockedStore = AgentMarketSyncStore(service:.init(root:blockedRoot),fixture:fixture,readsDesktop:false)
            do { try await blockedStore.install(app); check(false,"disk write failure must throw") }
            catch { check(!blockedStore.isInstalled(app) && blockedStore.pending.isEmpty,"disk write failure never presents installed state") }

            let window = NSWindow(contentRect:CGRect(x:100,y:100,width:412,height:560),
                styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            defer { window.close(); model.stop() }
            var used = 0
            let manager = NSHostingView(rootView:AgentApplicationManager(model:model,sync:sync,onClose:{}))
            window.contentView = manager; window.setContentSize(CGSize(width:720,height:640))
            window.makeKeyAndOrderFront(nil); await settle()
            check(await press(manager,"market-add-feishu"),"manager exposes direct plus")
            await settle()
            check(!sync.isInstalled(app) && sync.connectingItem?.id == app.id,
                "unconnected app opens real authorization and never shows false success")
            sync.connectingItem = nil; await settle()
            try await sync.bind(app,client:sync.clientFactory(AgentMCPClient.officialEndpoint,"public"),
                                selectedNames:["feishu_read_document"])
            check(sync.isInstalled(app) && used == 0 && model.draftSkillReferences.isEmpty,
                "verified tool binding installs without changing composer")
            _ = capture(manager,"manager-added-light")
            check(await press(manager, "market-card-feishu"), "actual card click opens detail")
            await settle()
            check(find(manager, "market-manager-detail") != nil && find(manager, "market-manager-back") != nil,
                  "card detail replaces list within same manager")
            check(await press(manager, "market-manager-enabled"), "actual enable switch accepts mouse events")
            await settle()
            check(sync.installed[app.id]?.isEnabled == false, "disabled application loses local execution permission")
            _ = capture(manager, "detail-after-disable-light")
            check(sync.applicationTools(readOnly: false, automaticApproval: true, isCurrent: { true }, onInteraction: { _ in }).isEmpty,
                  "disabled application is excluded from Agent tool inventory")
            check(await press(manager, "market-manager-enabled"), "switch can re-enable installed application")
            await settle()
            check(sync.installed[app.id]?.isEnabled == true, "enable state persists in installation manifest")
            check(await press(manager, "market-manager-back"), "actual back returns from detail")
            await settle()
            check(find(manager, "market-manager-search") != nil, "return restores list controls")
            let picker = NSHostingView(rootView:AgentInstalledApplicationList(model:model,sync:sync,localItems:[],
                localPick:{ _ in false },onUse:{ used += 1 },onManage:{}))
            window.contentView = picker; window.makeKeyAndOrderFront(nil); await settle()
            _ = capture(picker,"picker-added-light")
            check(await press(picker,"market-installed-feishu"),"installed application row accepts reference")
            await settle()
            check(used == 1 && model.draftSkillReferences.first?.applicationID == app.id && model.draft == "新会话草稿",
                "installed application becomes an actual composer reference without boilerplate")
            model.flushSession()
            let restored = AgentChatModel(displayName:"恢复",backend:backend,persistenceURL:root.appendingPathComponent("conversation.json"))
            check(restored.draftSkillReferences == model.draftSkillReferences,"application reference survives conversation reload")
            restored.stop()
            model.selectAutomaticApproval(true)
            check(model.send(text:model.draft,config:AgentConfig(),enabledSkills:[]),"application reference submits through real model send")
            for _ in 0..<50 {
                if !(await backend.received).isEmpty && !model.isRunning { break }
                try? await Task.sleep(for:.milliseconds(20))
            }
            let message = await backend.received.last { $0.role == .user }
            check(message?.skillReferences?.first?.applicationID == app.id
                && message?.wireContent.contains("应用配置") == true
                && message?.wireContent.contains("bound_tools") == true,
                "backend receives actual bound tool names")
            let executed = await backend.toolResult
            let callCount = await mcp.calls
            check(executed?.isFailure == false && executed?.content.contains("真实传输返回 doc-42") == true && callCount == 1,
                  "actual model send invokes application tools and receives service result")
            model.draft = "使用技能"
            _ = try await model.prepareReference { try await sync.reference(skill) }
            check(model.send(text:model.draft,config:AgentConfig(),enabledSkills:[]),"installed skill submits through same send path")
            for _ in 0..<50 {
                if !model.isRunning { break }; try? await Task.sleep(for:.milliseconds(20))
            }
            let skillMessage = await backend.received.last { $0.role == .user }
            check(skillMessage?.skillReferences?.first?.markdown == "# 分镜\n保持原始媒体比例。"
                && skillMessage?.wireContent.contains("仅提供 SKILL.md") == true,
                "backend receives exact skill body")
            let reloaded = AgentMarketSyncStore(service:service,fixture:fixture,readsDesktop:false)
            await reloaded.refresh()
            check(reloaded.isInstalled(app) && reloaded.isInstalled(skill),"picker install state survives reopening")
            reloaded.snapshot = AgentMarketSnapshot(scope:"other",catalog:fixture.catalog)
            await reloaded.refresh()
            check(!reloaded.isInstalled(app),"account change hides previous account installations")
            let form = NSHostingView(rootView: AgentApplicationManager(model: model, sync: sync,
                initialTab: "创建技能", onClose: {}))
            window.contentView = form; window.setContentSize(CGSize(width: 720, height: 640))
            window.makeKeyAndOrderFront(nil); await settle()
            check(find(form, "market-skill-name") != nil && find(form, "market-skill-description") != nil
                && find(form, "market-skill-instructions") != nil, "create skill opens complete three-field form")
            check(await enterText(form, "market-skill-name", "native-skill"), "skill name accepts actual keyboard events")
            check(await enterText(form, "market-skill-description", "完整描述"), "skill description accepts actual keyboard events")
            check(await enterText(form, "market-skill-instructions", "完整指令正文"), "skill instructions accept actual keyboard events")
            _ = capture(form, "skill-create-light")
            check(await press(form, "market-skill-save"), "create skill save receives actual mouse click")
            await settle()
            check(find(form, "market-manager-error") != nil && find(form, "market-skill-instructions") != nil,
                  "failed authentication preserves all skill fields and shows recoverable error")
            check(await press(form, "market-manager-back"), "dirty form back receives actual mouse click")
            await settle()
            let discard = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first {
                NativeAccessibilityProbe.elements($0).contains { $0.accessibilityLabel?() == "放弃" || $0.accessibilityTitle?() == "放弃" }
            }
            check(discard != nil, "dirty skill back opens discard confirmation")
            if let discard {
                let cancel = NativeAccessibilityProbe.elements(discard).first { $0.accessibilityLabel?() == "取消" || $0.accessibilityTitle?() == "取消" }
                if let frame = cancel?.accessibilityFrame?(), let sheet = discard.window {
                    check(await AgentMarketNativeInput.click(frame:frame,window:sheet,root:root), "discard cancel receives system mouse events")
                } else { check(false, "discard confirmation cancel is clickable") }
                await settle()
                check(find(form, "market-skill-name") != nil, "cancel discard retains editor")
            }
            try await AgentMarketDepthRegression.run(root: root, window: window, press: press,
                enterText: enterText, capture: capture, check: check)

            for dark in [false,true] {
                window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
                for width in [360,440,960] {
                    model.draftSkillReferences = []; model.draft = "保留输入与焦点"
                    let sidebar = NSHostingView(rootView:HStack(spacing: 0) {
                        Rectangle().fill(TapSkin.tone(0xefeff0, 0x101010)).frame(width: 500)
                            .overlay(Text("画布").foregroundStyle(TapSkin.secondaryInk))
                        AgentSidebarView(model:model,isVisible:.constant(true), workspaceMode:.agent,marketSync:sync)
                            .frame(width: CGFloat(width))
                    })
                    window.contentView = sidebar; window.setContentSize(CGSize(width:width + 500,height:780))
                    window.center()
                    window.makeKeyAndOrderFront(nil); await settle()
                    let label = "\(dark ? "dark" : "light")-\(width)"
                    check(await press(sidebar,"agent-composer-add"),label + " actual composer plus opens")
                    await settle()
                    let popover = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first {
                        find($0,"agent-composer-add-menu") != nil
                    }
                    if let popover {
                        _ = capture(popover,"composer-plus-" + label)
                        check(find(popover,"market-add-feishu") == nil
                            && find(popover,"agent-add-apps") != nil,label + " plus opens compact root without app grid")
                        check(await press(popover,"agent-add-apps"),label + " all applications submenu opens")
                        await settle()
                        let submenu = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first { find($0,"agent-installed-applications") != nil }
                        check(submenu != nil,label + " installed applications list is visible")
                        if let submenu {
                            _ = capture(submenu,"composer-submenu-" + label)
                            check(await press(submenu,"market-installed-feishu"),label + " installed application row references")
                        } else { check(false, label + " installed application submenu must exist before reference") }
                        await settle()
                        check(model.draftSkillReferences.first?.applicationID == app.id && model.draft == "保留输入与焦点",
                            label + " plus reference preserves composer text")
                        check(window.firstResponder is AgentDraftEditor.Editor,label + " reference returns keyboard focus to native editor")
                        _ = capture(sidebar,"composer-reference-" + label)
                        _ = await press(sidebar,"agent-composer-add"); await settle()
                        if let rootMenu = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first(where: { find($0,"agent-composer-add-menu") != nil }) {
                            _ = await press(rootMenu,"agent-add-apps"); await settle()
                            if let submenu = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first(where: { find($0,"agent-installed-applications") != nil }) {
                                check(await press(submenu,"market-installed-manage"), label + " management footer receives actual click"); await settle()
                                if let managerWindow = NSApp.windows.first(where: { $0.contentView.map { find($0,"agent-application-manager") != nil } == true && $0.isVisible }) {
                                    let expected = window.convertToScreen(sidebar.convert(sidebar.bounds,to:nil))
                                    check(abs(managerWindow.frame.midX - expected.midX) < 2
                                        && abs(managerWindow.frame.midY - expected.midY) < 2,
                                        label + " application manager is centered over owner window")
                                    check(managerWindow.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua])
                                        == (dark ? .darkAqua : .aqua),label + " manager inherits owner appearance")
                                    try? JSONSerialization.data(withJSONObject:[
                                        "expected":NSStringFromRect(expected),"actual":NSStringFromRect(managerWindow.frame)])
                                        .write(to:root.appendingPathComponent("manager-geometry-" + label + ".json"))
                                    _ = capture(managerWindow.contentView!,"composer-manager-" + label)
                                    let screenshot = root.appendingPathComponent("screenshot-request.json")
                                    let receipt = root.appendingPathComponent("screenshot-receipt-" + label + ".json")
                                    try? JSONSerialization.data(withJSONObject: ["label":label,"window":window.windowNumber])
                                        .write(to: screenshot, options: .atomic)
                                    for _ in 0..<100 {
                                        if FileManager.default.fileExists(atPath: receipt.path) { break }
                                        try? await Task.sleep(for: .milliseconds(50))
                                    }
                                    let captured = (try? Data(contentsOf: receipt)).flatMap {
                                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                                    }?["success"] as? Bool
                                    check(captured == true, label + " complete owner window screenshot is captured")
                                    _ = await press(managerWindow.contentView!,"market-manager-close"); await settle()
                                } else { check(false,label + " centered manager opens") }
                            } else { check(false, label + " management submenu must exist before click") }
                        } else { check(false, label + " root menu must reopen before management") }
                    } else { check(false,label + " composer picker is visible") }
                }
            }

            // Deliberately huge portrait and landscape source images exercise intrinsic image sizing.
            for dimensions in [(1200,2400),(2400,600)] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:dimensions.0,pixelsHigh:dimensions.1,
                    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
                    bytesPerRow:dimensions.0 * 4,bitsPerPixel:32)!
                for offset in stride(from:0,to:bitmap.bytesPerRow * bitmap.pixelsHigh,by:4) {
                    bitmap.bitmapData![offset] = 240; bitmap.bitmapData![offset+1] = 10
                    bitmap.bitmapData![offset+2] = 190; bitmap.bitmapData![offset+3] = 255
                }
                let iconURL = root.appendingPathComponent("portrait-\(dimensions.0).png")
                try bitmap.representation(using:.png,properties:[:])!.write(to:iconURL)
                let imported = try await sync.importIcon(iconURL)
                var presentation = MarketPresentation()
                presentation.followsSource = false; presentation.icon = imported
                try await sync.save(presentation,for:app.id)
                for dark in [false,true] {
                    window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
                    for width in [320,360,440,960] {
                        let name = "\(dimensions.0)-\(dark ? "dark" : "light")-\(width)"
                        let host = NSHostingView(rootView:VStack(spacing:0) {
                            MarketArtwork(item:app,sync:sync,isCover:true).frame(height:148)
                            Text("飞书 · 标题与正文必须完整可见").frame(height:80)
                        }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                            .background(Color.white))
                        window.contentView = host; window.setContentSize(CGSize(width:width,height:280)); await settle()
                        if let rendered = capture(host,"contain-" + name), let image = rendered.cgImage {
                            let imageWidth = image.width, imageHeight = image.height
                            var rgba = [UInt8](repeating:0,count:imageWidth * imageHeight * 4)
                            rgba.withUnsafeMutableBytes { buffer in
                                let context = CGContext(data:buffer.baseAddress,width:imageWidth,height:imageHeight,
                                    bitsPerComponent:8,bytesPerRow:imageWidth * 4,space:CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                                context.draw(image,in:CGRect(x:0,y:0,width:imageWidth,height:imageHeight))
                            }
                            var pixels = 0, minX = imageWidth, maxX = 0, minY = imageHeight, maxY = 0
                            for y in 0..<imageHeight {
                                for x in 0..<imageWidth {
                                    let offset = (y * imageWidth + x) * 4
                                    if rgba[offset] > 204 && rgba[offset+1] < 51 && rgba[offset+2] > 128 {
                                        pixels += 1; minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
                                    }
                                }
                            }
                            let scale = CGFloat(imageWidth) / CGFloat(width)
                            check(pixels > 20 && CGFloat(maxX-minX) <= 65 * scale && CGFloat(maxY-minY) <= 65 * scale,
                                name + " icon pixels stay within 64-point fallback bounds")
                        } else { check(false,name + " rendered bitmap exists") }
                    }
                }
            }
        } catch { failures.append(error.localizedDescription) }
        let report: [String:Any] = ["passed":passed,"failures":failures,"paid_generation_requests":0,
            "backend":"deterministic local fixture through AgentChatModel.send",
            "ui_events":"CoreGraphics mouse down/up through the OS event channel, scoped to the observed isolated app PID and window; native keyboard events"]
        try? JSONSerialization.data(withJSONObject: mouseEvents, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("mouse-events.json"))
        try? JSONSerialization.data(withJSONObject: deliveredEvents, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("delivered-mouse-events.json"))
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
