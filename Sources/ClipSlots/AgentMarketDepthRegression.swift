#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor DepthManagementHTTP: AgentMarketHTTP {
    var added = false
    var enabled = false
    var skills: [String: JSONValue] = [
        "personal": ["name":"personal","description":"个人描述","instructions":"个人完整正文","provider":"user","status":"enabled"],
        "system": ["name":"system","description":"系统描述","instructions":"系统完整正文","provider":"system","status":"enabled"]
    ]
    var requests: [(String, String)] = []
    var authCount = 0
    var detailHasConnector = false
    func includeDetailConnector() { detailHasConnector = true }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        requests.append((method, path))
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? [:]
        var result: JSONValue = [:]
        if path.contains("/plugins") {
            if method == "PUT" { added = true; enabled = true; try await Task.sleep(for: .milliseconds(800)) }
            if method == "PATCH" { enabled = body["status"] == "enabled" }
            if method == "DELETE" { added = false }
            let app: JSONValue = ["plugin_name":"creative","display_name":"Design Room (Ecom)","description":"完整产品视觉工作室",
                "install_mode":"user","status":"published","connectors":detailHasConnector ? [["name":"lark"]] : [],
                "installation":added ? ["installed":true,"status":.string(enabled ? "enabled" : "disabled")] : .null,
                "skills":[["name":"embedded","display_name":"内嵌技能","description":"实际应用 Skill"]],
                "marketing_slots":[
                    ["url":"https://fe-assets.tapnow.media/plugin-marketing-slots/design-room/39d7336932040297745d20628f97d97e905157611f0c84d563a1f4dfdbbd3384.png","media_type":"image"],
                    ["url":"https://fe-assets.tapnow.media/plugin-marketing-slots/design-room/4ed9714a9d0eca8fd5fad04d70329c607381eaea1a0da4d2946e54cd0d40474a.png","media_type":"image"],
                    ["url":"https://fe-assets.tapnow.media/plugin-marketing-slots/design-room/c4a00cc680f52b274bce2f301c03b180dd21c8ec585b6fe0e4a7744e236558a7.mp4","media_type":"video"]]]
            if path.hasSuffix("/skills/embedded") {
                result = ["name":"embedded","description":"实际应用 Skill","instructions":"内嵌的完整正文"]
            } else if path.hasSuffix("/plugins") {
                result = ["plugins": .array(request.url!.query == nil || added ? [app] : [])]
            } else { result = app }
        } else if path.contains("/auth-sessions") {
            if method == "POST", path.hasSuffix("/auth-sessions") { authCount += 1 }
            result = ["session_id":.string("depth-\(authCount)"),"status":"pending","stage":"create_app","challenge_kind":"redirect",
                "redirect_url":"https://connector.example.com/create","poll_interval_ms":30000]
        } else if path.hasSuffix("/connectors") {
            result = ["connectors":[["id":"lark","status":"disconnected"]]]
        } else if path.contains("/skills") {
            let key = path.split(separator: "/").last.map(String.init) ?? ""
            if method == "POST" {
                var fields = body.objectValue ?? [:]; fields["provider"] = "user"; fields["status"] = "enabled"
                skills[body["name"]?.stringValue ?? ""] = .object(fields)
                result = .object(fields)
            } else if method == "PATCH" {
                if key == "status" {
                    let name = String(path.split(separator: "/").dropLast().last!)
                    var fields = skills[name]?.objectValue ?? [:]; fields["status"] = body["status"]
                    skills[name] = .object(fields); result = .object(fields)
                } else {
                    skills[key] = nil
                    var fields = body.objectValue ?? [:]; fields["provider"] = "user"; fields["status"] = "enabled"
                    skills[body["name"]?.stringValue ?? ""] = .object(fields); result = .object(fields)
                }
            } else if method == "DELETE" { skills[key] = nil }
            else { result = key == "skills" ? ["skills":.array(Array(skills.values))] : skills[key] ?? [:] }
        }
        return (try JSONEncoder().encode(JSONValue.object(["code":200,"data":result])), 200)
    }
}

private struct DepthConnectorPresenterProbe: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var sync: AgentMarketSyncStore
    @State private var presented = false
    var body: some View {
        Button("连接") { presented = true }
            .accessibilityIdentifier("depth-open-connector")
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(AgentApplicationManagerPresenter(isPresented:$presented,model:model,sync:sync,
                isReadOnly:false,initialTab:"连接",onClose:{}))
    }
}

@MainActor enum AgentMarketDepthRegression {
    static func run(root: URL, window: NSWindow,
                    press: (NSView, String) async -> Bool,
                    enterText: (NSView, String, String) async -> Bool,
                    capture: (NSView, String) -> NSBitmapImageRep?,
                    check: (Bool, String) -> Void) async throws {
        func settle() async { try? await Task.sleep(for: .milliseconds(320)) }
        func has(_ view: NSView, _ id: String) -> Bool {
            NativeAccessibilityProbe.elements(view).contains { $0.accessibilityIdentifier?() == id }
        }
        func dialog(_ label: String) async -> Bool {
            for candidate in NSApp.windows.filter(\.isVisible).sorted(by: { $0.isSheet && !$1.isSheet }) {
                guard let content = candidate.contentView,
                      let button = NativeAccessibilityProbe.elements(content).first(where: {
                          $0.accessibilityRole?() == .button && ($0.accessibilityTitle?() == label || $0.accessibilityLabel?() == label)
                      }), let frame = button.accessibilityFrame?() else { continue }
                let result = await AgentMarketNativeInput.click(frame:frame,window:candidate,root:root)
                await settle(); return result
            }
            return false
        }
        // A scoped Chromium fixture exercises the production decoder without reading user credentials.
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value, result: [UInt8] = []
            repeat { let byte = UInt8(value & 127); value >>= 7; result.append(byte | (value == 0 ? 0 : 128)) } while value > 0
            return result
        }
        func little(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> ($0 * 8)) & 255) } }
        func log(_ value: [UInt8]) -> Data { Data([0,0,0,0] + little(UInt64(value.count), 2) + [1] + value) }
        let home = root.appendingPathComponent("depth-home")
        let database = home.appendingPathComponent("Library/Application Support/@tap/desktop/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: database.appendingPathComponent("CURRENT"))
        try log([2] + varint(64)).write(to: database.appendingPathComponent("MANIFEST-000001"))
        let claims: JSONValue = ["sub":"native-depth-fixture","exp":.number(Double(Int(Date().timeIntervalSince1970) + 3600))]
        let payload = try JSONEncoder().encode(claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let key = Array("_tapnow://app".utf8) + [UInt8(0),1] + Array("access_token".utf8)
        let value = [UInt8(1)] + Array(("header." + payload + ".signature").utf8)
        var batch = little(2,8) + little(1,4)
        batch += [1] + varint(UInt64(key.count)) + key
        batch += varint(UInt64(value.count)) + value
        try log(batch).write(to: database.appendingPathComponent("000064.log"))
        guard let session = AgentMarketDesktopSession.read(home: home.path) else { throw AgentMarketSyncError.requiresLogin }
        let http = DepthManagementHTTP()
        let service = AgentMarketSyncService(root: root.appendingPathComponent("depth-cache"), http: http)
        let fixture = try await service.refreshManager(session: session, previous: nil)
        let sync = AgentMarketSyncStore(service: service, fixture: fixture, readsDesktop: false)
        sync.session = session
        func checkpoint(_ name: String) async {
            let windows: [[String: Any]] = NSApp.windows.map { window in
                let elements: [[String: String]] = window.contentView.map {
                    NativeAccessibilityProbe.elements($0).compactMap { element in
                        guard let id = element.accessibilityIdentifier?(), id.hasPrefix("market-") || id == "agent-composer-add-menu" else { return nil }
                        return ["id":id, "frame":NSStringFromRect(element.accessibilityFrame?() ?? .zero),
                            "title":element.accessibilityTitle?() ?? element.accessibilityLabel?() ?? ""]
                    }
                } ?? []
                return ["window":window.windowNumber,"visible":window.isVisible,"sheet":window.isSheet,"elements":elements,
                    "class":String(describing:type(of:window)), "frame":NSStringFromRect(window.frame),
                    "content_frame":NSStringFromRect(window.contentView?.frame ?? .zero),
                    "content_bounds":NSStringFromRect(window.contentView?.bounds ?? .zero),
                    "key":window.isKeyWindow,"parent":window.parent?.windowNumber ?? 0,
                    "ignores_mouse":window.ignoresMouseEvents,
                    "works_when_modal":(window as? NSPanel)?.worksWhenModal ?? false,
                    "modal_window":NSApp.modalWindow?.windowNumber ?? 0]
            }
            try? JSONSerialization.data(withJSONObject: ["windows":windows,"error":sync.error ?? "",
                "has_session":sync.session != nil,"items":sync.managementItems.map { ["name":$0.name,"added":$0.sourceAdded,"enabled":$0.sourceEnabled] }],
                options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("depth-checkpoint-" + name + ".json"))
            for candidate in NSApp.windows.filter(\.isVisible) {
                let label = "checkpoint-" + name + "-" + String(candidate.windowNumber)
                let request: [String:Any] = ["label":label,"window":candidate.windowNumber]
                try? JSONSerialization.data(withJSONObject:request).write(to:root.appendingPathComponent("screenshot-request.json"),options:.atomic)
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath:root.appendingPathComponent("screenshot-receipt-" + label + ".json").path) { break }
                    try? await Task.sleep(for:.milliseconds(50))
                }
            }
        }
        let model = AgentChatModel(displayName: "完整层级验证", persistenceURL: root.appendingPathComponent("depth-conversation.json"))
        defer { model.stop() }
        let manager = NSHostingView(rootView: AgentApplicationManager(model: model, sync: sync, onClose: {}))
        window.contentView = manager; window.setContentSize(CGSize(width:720,height:640)); window.makeKeyAndOrderFront(nil)
        await settle()
        check(await enterText(manager, "market-manager-search", "Design Room"), "manager search receives actual text")
        check(await press(manager, "market-card-creative"), "search result opens application detail")
        await settle()
        check(await press(manager, "market-media-image"), "detail image receives actual preview click")
        await settle()
        await checkpoint("image")
        if let preview = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first(where: { has($0, "market-media-preview") }) {
            check(await press(preview, "market-media-preview-close"), "image preview closes and returns to same detail")
        } else { check(false, "image preview opens") }
        await settle()
        check(!NSApp.windows.contains { $0.isVisible && $0.contentView.map { has($0, "market-media-preview") } == true },
              "image preview is actually dismissed before video interaction")
        check(await press(manager, "market-media-video"), "detail video receives actual preview click")
        await settle()
        await checkpoint("video")
        if let preview = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).first(where: { has($0, "market-media-preview") }) {
            check(await press(preview, "market-media-preview-close"), "video preview closes and stops playback")
        } else { check(false, "video preview opens") }
        await settle()
        check(!NSApp.windows.contains { $0.isVisible && $0.contentView.map { has($0, "market-media-preview") } == true },
              "video preview is actually dismissed before returning to detail")
        check(await press(manager, "market-manager-plugin-skill-0"), "embedded Skill opens from application detail")
        await settle()
        check(!has(manager, "market-manager-edit"), "application Skill is read-only")
        check(await press(manager, "market-manager-back"), "embedded Skill returns to parent application")
        await settle()
        check(await press(manager, "market-manager-install"), "application detail starts actual installation")
        check(has(manager, "market-manager-progress"), "installation presents progress overlay")
        for _ in 0..<10 {
            if sync.managementItems.first?.sourceAdded == true && has(manager, "market-manager-uninstall") { break }
            await settle()
        }
        check(sync.managementItems.first?.sourceAdded == true && has(manager, "market-manager-uninstall"),
              "successful installation stays on detail with authoritative installed state")
        await checkpoint("installed-detail")
        _ = capture(manager, "depth-installed-detail")
        check(await press(manager, "market-manager-uninstall"), "application uninstall opens confirmation")
        await settle()
        check(await dialog("取消"), "uninstall cancel receives actual mouse events")
        check(sync.managementItems.first?.sourceAdded == true, "cancel uninstall preserves installation")
        check(await press(manager, "market-manager-uninstall"), "application uninstall confirmation reopens")
        await settle()
        check(await dialog("卸载"), "uninstall confirmation commits removal")
        await settle()
        _ = capture(manager, "depth-after-uninstall")
        await checkpoint("uninstall")
        check(sync.managementItems.first?.sourceAdded == false && has(manager, "market-manager-search"),
              "uninstall removes state and returns to searched list")
        await http.includeDetailConnector()
        check(await press(manager, "market-card-creative"), "application detail reopens for connector entry")
        await settle()
        check(await press(manager, "market-manager-connector-lark"), "detail connector receives actual mouse click")
        await settle()
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.parent === window
            && !$0.isSheet && $0.contentView.map { has($0,"market-connector-wizard") } == true }), let content = panel.contentView {
            check(abs(panel.frame.midX - window.frame.midX) < 1, "detail connection opens independent centered panel")
            check(await press(content,"market-connector-close"), "detail connection closes through actual mouse click")
            await settle()
            check(!panel.isVisible && has(manager,"market-manager-detail"), "closing detail connection restores same application")
        } else { check(false,"detail connection opens independent centered panel") }
        check(await press(manager, "market-manager-back"), "application returns after detail connection")
        await settle()
        check(await press(manager, "market-manager-tab-技能"), "Skill tab opens from manager")
        await settle()
        check(await enterText(manager, "market-manager-search", ""), "manager search can be cleared")
        await settle()
        await checkpoint("skill-catalog")
        let searchValue: String? = NativeAccessibilityProbe.elements(manager).first(where: {
            $0.accessibilityIdentifier?() == "market-manager-search"
        })?.accessibilityValue?()
        check(searchValue == "", "cleared search exposes unfiltered Skill catalog")
        check(await press(manager, "market-card-system"), "system Skill detail opens")
        await settle()
        check(!has(manager, "market-manager-edit") && !has(manager, "market-manager-uninstall"),
              "system Skill has no edit or uninstall controls")
        check(await press(manager, "market-manager-back"), "system Skill returns to catalog")
        await settle()
        check(await press(manager, "market-card-personal"), "personal Skill detail opens")
        await settle()
        check(await press(manager, "market-manager-edit"), "personal Skill enters complete editor")
        await settle()
        check(await enterText(manager, "market-skill-name", "renamed"), "Skill rename edits name")
        check(await enterText(manager, "market-skill-description", "更新后的描述"), "Skill edit updates description")
        check(await enterText(manager, "market-skill-instructions", "更新后的完整指令"), "Skill edit updates full instructions")
        check(await press(manager, "market-skill-save"), "Skill save executes PATCH")
        await settle()
        check(sync.snapshot?.skills["personal"] == nil && sync.snapshot?.skills["renamed"]?["instructions"] == "更新后的完整指令"
            && has(manager, "market-manager-edit"), "rename commits all fields and returns to detail")
        check(await press(manager, "market-manager-enabled"), "Skill enabled switch accepts actual click")
        await settle()
        check(sync.snapshot?.skills["renamed"]?["status"] == "disabled"
            && sync.snapshot?.item("skill:renamed")?.sourceEnabled == false, "Skill disable updates detail and persists through server readback")
        check(await press(manager, "market-manager-uninstall"), "personal Skill uninstall opens confirmation")
        await settle()
        check(await dialog("卸载"), "personal Skill uninstall confirms")
        await settle()
        check(sync.snapshot?.skills["renamed"] == nil, "Skill removal survives refresh")
        let create = NSHostingView(rootView: AgentApplicationManager(model:model,sync:sync,initialTab:"创建技能",onClose:{}))
        window.contentView = create; await settle()
        check(await enterText(create, "market-skill-name", "created"), "create Skill name receives input")
        check(await enterText(create, "market-skill-description", "新技能描述"), "create Skill description receives input")
        check(await enterText(create, "market-skill-instructions", "新技能完整正文"), "create Skill instructions receive input")
        check(await press(create, "market-skill-save"), "create Skill executes POST")
        await settle()
        check(sync.snapshot?.skills["created"]?["instructions"] == "新技能完整正文" && has(create, "market-manager-search"),
              "Skill creation persists and returns to list")
        _ = capture(create, "depth-created-skill-list")
        let connector = AgentMarketItem(["kind":"app","name":"lark","display_name":"Lark","connectors":[["name":"lark"]]])
        sync.sourceConnection = connector
        var closed = 0
        func mount(_ auth: AgentConnectorSession) async -> NSHostingView<AgentSourceConnectorWizard> {
            sync.sourceAuth = auth
            let wizard = NSHostingView(rootView: AgentSourceConnectorWizard(item:connector,sync:sync,onClose:{ closed += 1 }))
            window.contentView = wizard; window.setContentSize(CGSize(width:680,height:640)); await settle()
            return wizard
        }
        let stageOne = await mount(.init(["session_id":"first","status":"pending","stage":"create_app",
            "challenge_kind":"redirect","redirect_url":"https://connector.example.com/create","poll_interval_ms":30000]))
        check(has(stageOne, "market-connector-continue"), "observed first step presents external continuation action")
        await checkpoint("create-app")
        _ = capture(stageOne, "depth-connector-step-one")
        check(await press(stageOne, "market-connector-cancel"), "first step cancel receives actual click")
        await settle()
        check(sync.sourceAuth == nil && closed == 1, "create-app cancel resets pending authorization")
        await checkpoint("cancel")
        check(await http.requests.contains(where: { $0.0 == "DELETE" && $0.1.hasSuffix("/connectors/lark") }),
              "create-app cancel performs connector reset")
        sync.sourceConnection = connector
        let second = await mount(.init(["session_id":"second","status":"pending","stage":"authorize","challenge_kind":"form",
            "poll_interval_ms":30000,"form_fields":[["name":"client_id","label":"Client ID","required":true],
                ["name":"secret","label":"Secret","required":true,"secret":true]]]))
        check(has(second, "market-connector-field-client_id") && has(second, "market-connector-field-secret"),
              "second step renders complete server field schema")
        check(await press(second, "market-connector-submit"), "empty connection form submits through validation")
        await settle()
        check(has(second, "market-connector-error"), "required fields display recoverable validation error")
        check(await enterText(second, "market-connector-field-client_id", "fixture-id"), "connector public field receives keyboard input")
        check(await enterText(second, "market-connector-field-secret", "fixture-secret"), "connector secret field receives secure keyboard input")
        _ = capture(second, "depth-connector-step-two")
        check(await press(second, "market-connector-submit"), "completed connection form executes submit")
        await settle()
        check(await http.requests.contains(where: { $0.0 == "POST" && $0.1.hasSuffix("/auth-sessions/second/submit") }),
              "complete form reaches session-scoped submit endpoint")
        let expired = await mount(.init(["session_id":"expired","status":"expired","stage":"authorize","challenge_kind":"none"]))
        check(await press(expired, "market-connector-retry"), "expired authorization exposes actual retry")
        await settle()
        check(sync.sourceAuth?.id.hasPrefix("depth-") == true && sync.sourceAuth?.id != "expired",
              "retry replaces expired authorization with a fresh session")
        check(await press(expired, "market-connector-close"), "wizard close receives actual click")
        check(sync.sourceAuth?.terminal == false, "closing wizard retains pending session for resume")
        let approval = await mount(.init(["session_id":"approval","status":"pending","challenge_kind":"external_approval","poll_interval_ms":30000]))
        _ = capture(approval, "depth-connector-admin-approval")
        check(await press(approval, "market-connector-cancel"), "administrator approval can be cancelled")
        await settle()
        check(sync.sourceAuth == nil, "cancel clears in-memory pending session")
        sync.sourceConnection = connector
        sync.sourceAuth = .init(["session_id":"presenter","status":"pending","stage":"create_app",
            "challenge_kind":"redirect","redirect_url":"https://connector.example.com/create","poll_interval_ms":30000])
        let presenter = NSHostingView(rootView:DepthConnectorPresenterProbe(model:model,sync:sync))
        window.contentView = presenter; window.setContentSize(CGSize(width:1000,height:800)); await settle()
        check(await press(presenter, "depth-open-connector"), "connector entry receives actual mouse click")
        await settle()
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.parent === window
            && $0.contentView.map { has($0,"market-connector-wizard") } == true }), let content = panel.contentView {
            await checkpoint("connector-presenter")
            check(abs(panel.frame.width - 680) < 1 && abs(panel.frame.midX - window.frame.midX) < 1
                && panel.frame.height < 480 && panel.frame.height > 360,
                "connector binding opens centered owner panel without unrelated state changes")
            _ = capture(content,"depth-connector-presenter")
            check(await press(content,"market-connector-close"), "centered connector panel closes through actual mouse click")
            await settle()
            check(!panel.isVisible && sync.sourceAuth?.id == "presenter", "connector close hides panel and preserves resumable session")
        } else { check(false,"connector binding opens centered owner panel") }
    }
}
#endif
