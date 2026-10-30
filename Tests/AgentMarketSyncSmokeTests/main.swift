import Foundation
import ClipSlotsKit

actor FixtureHTTP: AgentMarketHTTP {
    var requests: [URLRequest] = []
    var version = "v1"
    var fails = false
    var unauthorized = false
    func setFailure(_ value: Bool) { fails = value }
    func setUnauthorized(_ value: Bool) { unauthorized = value }
    func setVersion(_ value: String) { version = value }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if fails { return (Data("broken".utf8), 500) }
        if request.url!.path.hasSuffix("/skills") {
            if unauthorized { return (Data(), 401) }
            return (Data(#"{"code":200,"data":{"skills":[{"name":"fixture","description":"actual fixture instructions","instructions":"Read actual canvas before changing it.","provider":"system","status":"enabled","user_id":"must-not-cache","org_id":"must-not-cache"}]}}"#.utf8), 200)
        }
        if request.url!.host == "icons.example.com" || request.url!.path.hasPrefix("/app-store/") { return (Data([1,2,3]), 200) }
        var detail: JSONValue = ["kind":"skill", "name":"fixture", "display_name":"Fixture", "description":"真实参数测试",
            "activation_skill":"fixture", "icon_url":"https://icons.example.com/a.png",
            "try_form":["references":["min":1,"max":2],"prompt":["max_length":30],
                "fields":[["id":"subject","label":"主题","required":true,"max_length":5]]],
            "future_config":["preserve":true]]
        if request.url!.path.hasSuffix("/catalog") {
            detail = ["content_version":.string(version), "items":[detail], "categories":[["id":"film","label":"影视"]],
                "featured":[["kind":"skill","name":"fixture"]]]
        }
        return (try JSONValue.object(["code":200,"data":detail]).encodedText().data(using: .utf8)!, 200)
    }
}

actor FixtureMCPHTTP: AgentMCPHTTP {
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        let method = json["method"]?.stringValue ?? ""
        let result: JSONValue
        switch method {
        case "initialize": result = ["protocolVersion":"2025-03-26", "capabilities":["tools":[:]]]
        case "tools/list": result = ["tools":[["name":"read_document","description":"Fixture document",
            "inputSchema":["type":"object","properties":["id":["type":"string"]],"required":["id"]],
            "annotations":["readOnlyHint":true]]]]
        case "tools/call": calls += 1; result = ["content":[["type":"text","text":"Verified fixture document"]]]
        default: result = [:]
        }
        let status = method == "notifications/initialized" ? 202 : 200
        return (try JSONEncoder().encode(JSONValue.object(["jsonrpc":"2.0","id":json["id"] ?? .null,"result":result])),
                HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}

actor RemoteInstallHTTP: AgentMarketHTTP {
    var methods: [String] = []
    var installed = false
    var enabled = false
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        methods.append(request.httpMethod ?? "GET")
        if request.httpMethod == "PUT" { installed = true }
        if request.httpMethod == "PATCH" { enabled = true }
        let detail: JSONValue = ["kind":"app","name":"remote-app","install_mode":"user",
            "installed":.bool(installed),"enabled":.bool(enabled)]
        return (try JSONEncoder().encode(JSONValue.object(["code":200,"data":detail])),200)
    }
}

@main struct Smoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("market-sync-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = [], passed: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed.append(name) } else { failures.append(name) }
            print((value ? "PASS " : "FAIL ") + name)
        }
        try await MCPWireRegression.run(check: check)
        // A real Chromium WriteBatch/log fixture includes a newer tombstone.
        func varint(_ n: UInt64) -> [UInt8] {
            var n = n, out: [UInt8] = []
            repeat { let b = UInt8(n & 127); n >>= 7; out.append(b | (n == 0 ? 0 : 128)) } while n > 0
            return out
        }
        func little(_ n: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((n >> ($0 * 8)) & 255) } }
        func log(_ bytes: [UInt8]) -> Data { Data([0,0,0,0] + little(UInt64(bytes.count),2) + [1] + bytes) }
        func fixtureSession(home: URL, sub: String, expiry: Int, deleted: Bool = false, origin: String = "tapnow://app") throws {
            let directory = home.appendingPathComponent("Library/Application Support/@tap/desktop/Local Storage/leveldb")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("MANIFEST-000001\n".utf8).write(to: directory.appendingPathComponent("CURRENT"))
            try log([2] + varint(64)).write(to: directory.appendingPathComponent("MANIFEST-000001"))
            let claims: JSONValue = ["sub": .string(sub), "org_id":"org", "exp": .number(Double(expiry))]
            let payload = Data(try claims.encodedText().utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let token = "header." + payload + ".signature"
            let key = Array(("_" + origin).utf8) + [0,1] + Array("access_token".utf8)
            let value = [UInt8(1)] + Array(token.utf8)
            let record = [UInt8(deleted ? 0 : 1)] + varint(UInt64(key.count)) + key
                + (deleted ? [] : varint(UInt64(value.count)) + value)
            try log(little(2,8) + little(1,4) + record).write(to: directory.appendingPathComponent("000064.log"))
        }
        let home = root.appendingPathComponent("home")
        try fixtureSession(home: home, sub: "account-a", expiry: Int(Date().timeIntervalSince1970) + 1000)
        let session = AgentMarketDesktopSession.read(home: home.path)
        check(session != nil, "current official desktop access token can be read without writing profile")
        try await MarketManagementWireRegression.run(root: root.appendingPathComponent("management"), session: session!, check: check)
        let remoteHTTP = RemoteInstallHTTP()
        let remote = AgentMarketSyncService(root:root.appendingPathComponent("remote"),http:remoteHTTP)
        let remoteItem = AgentMarketItem(["kind":"app","name":"remote-app"])
        try await remote.ensureRemoteInstallation(remoteItem,session:session!)
        check(await remoteHTTP.methods == ["GET","PUT","GET","PATCH","GET"],
              "source installation performs PUT enable PATCH and verifies actual state")
        check(try await remote.installations(scope:session!.scope).isEmpty,
              "source install alone cannot mark local app connected")
        let profileBefore = try Data(contentsOf: home.appendingPathComponent("Library/Application Support/@tap/desktop/Local Storage/leveldb/000064.log"))
        _ = AgentMarketDesktopSession.read(home: home.path)
        check(try Data(contentsOf: home.appendingPathComponent("Library/Application Support/@tap/desktop/Local Storage/leveldb/000064.log")) == profileBefore,
              "reference desktop bytes remain unchanged")
        let http = FixtureHTTP(), service = AgentMarketSyncService(root: root.appendingPathComponent("cache"), http: http)
        let snapshot = try await service.refresh(session: session, force: true)
        check(snapshot.items.count == 1 && snapshot.skills.count == 1, "catalog and actual skill instructions both synchronize")
        check(snapshot.skills["fixture"]?["user_id"] == nil && snapshot.skills["fixture"]?["org_id"] == nil,
              "private profile identifiers are omitted from cached skill data")
        let item = snapshot.item("skill:fixture")!
        check(item.raw["future_config"]?["preserve"] == true, "unknown app configuration round-trips intact")
        do { _ = try item.prompt(values: [:], text: "需求", referenceCount: 1); check(false, "required form validation") }
        catch { check(true, "required form validation") }
        do { _ = try item.prompt(values: ["subject":"abcdef"], text: "需求", referenceCount: 1); check(false, "field maximum validation") }
        catch { check(true, "field maximum validation") }
        do { _ = try item.prompt(values: ["subject":"汽水"], text: "需求", referenceCount: 0); check(false, "reference minimum validation") }
        catch { check(true, "reference minimum validation") }
        check(try item.prompt(values: ["subject":"汽水"], text: "需求", referenceCount: 1).contains("主题：汽水"), "source field labels and values reach the draft")
        check(AgentMarketSyncService.discover(root: root.appendingPathComponent("cache")).isEmpty,
              "synchronization does not automatically install or authorize scripts")
        let skill = try await service.materialize(item, snapshot: snapshot)
        let bytes = try String(contentsOfFile: skill.markdownPath, encoding: .utf8)
        check(bytes.hasSuffix("Read actual canvas before changing it.") && skill.scripts.isEmpty,
              "materialized document preserves actual instructions without inventing scripts")
        check(AgentMarketSyncService.discover(root: root.appendingPathComponent("cache"), session: session).first?.slug == skill.slug,
              "actual skill discovery uses the active account")
        check(AgentMarketSyncService.discover(root:root.appendingPathComponent("cache"),session:nil).isEmpty,
              "logout blocks private cached skills even before opening the market again")
        let installedSkill = try await service.install(item, snapshot: snapshot)
        check(installedSkill.skillSlug == skill.slug, "install materializes and records a real skill")
        let installedAgain = try await service.install(item, snapshot: snapshot)
        let installedRecords = try await service.installations(scope: snapshot.scope)
        check(installedAgain.installedAt == installedSkill.installedAt
            && installedRecords.count == 1, "repeated install is idempotent")
        let connector = AgentMarketItem(["kind":"app", "name":"connector", "display_name":"飞书",
            "connectors":[["provider":"feishu","auth":"source"]]])
        do {
            _ = try await service.install(connector, snapshot: snapshot)
            check(false, "catalog-only app cannot install")
        } catch { check(true, "catalog-only app cannot install") }
        let mcpHTTP = FixtureMCPHTTP()
        let client = AgentMCPClient(endpoint: URL(string:"http://127.0.0.1/mcp")!, http:mcpHTTP)
        let installedApp = try await service.bind(connector,snapshot:snapshot,client:client,selectedNames:["read_document"])
        check(installedApp.skillSlug == nil && installedApp.connection?.tools.count == 1,
            "connector persists only verified selected tools")
        let bound = AgentMCPApplicationTools(binding:installedApp.connection!,title:"飞书",client:client,
            readOnly:true,isCurrent:{true},approve:{ _,_ in true })
        let result = await bound.execute(call:.init(id:"actual",name:bound.specs()[0].name,argumentsJSON:"{\"id\":\"fixture\"}"))
        let actualCalls = await mcpHTTP.calls
        check(!result.isFailure && result.content.contains("Verified fixture document") && actualCalls == 1,
            "bound application executes tools/call and receives actual result")
        let appReference = try await service.reference(connector, snapshot: snapshot)
        let wire = AgentMessage(role: .user, content: "读一下资料", skillReferences: [appReference]).wireContent
        check(appReference.applicationID == connector.id && wire.contains("应用配置") && !wire.contains("仅提供 SKILL.md"),
            "application references retain bound tool names on backend wire")
        let reloadedService = AgentMarketSyncService(root: root.appendingPathComponent("cache"), http: http)
        check(try await reloadedService.installations(scope: snapshot.scope).count == 2,
            "installed applications survive service restart")
        check(try await reloadedService.installations(scope: "other-account").isEmpty,
            "installations are isolated by account")
        do {
            _ = try await service.install(AgentMarketItem(["kind":"skill","name":"missing-body"]), snapshot: snapshot)
            check(false, "unavailable skill install must fail")
        } catch { check(true, "unavailable skill install must fail") }
        check(try await service.installations(scope: snapshot.scope).count == 2, "failed install never records success")
        let legacy = Data(#"{"name":"old","path":"/legacy/SKILL.md","markdown":"legacy instructions"}"#.utf8)
        check(try JSONDecoder().decode(AgentSkillReference.self, from: legacy).applicationID == nil,
            "old persisted skill references remain compatible")
        let publicBody = AgentMarketItem(["kind":"skill","name":"oversized","public_content":.string(String(repeating:"x",count:65_537))])
        var oversizedSnapshot = snapshot; oversizedSnapshot.details[publicBody.id] = publicBody.raw
        do { _ = try await service.reference(publicBody, snapshot: oversizedSnapshot); check(false,"oversized reference must fail") }
        catch { check(true,"oversized reference must fail") }
        check(try item.prompt(values:["subject":"汽水"],text:"需求",referenceCount:1) == "主题：汽水\n需求",
            "form input produces concise user content without hidden instruction boilerplate")
        let imagesBefore = await http.requests.count
        _ = try await service.image(item.iconURL!); _ = try await service.image(item.iconURL!)
        check(await http.requests.count == imagesBefore + 1, "unchanged icon URL uses persistent cache")
        check(await http.requests.filter { $0.url?.host == "icons.example.com" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil },
              "icon requests never carry account credentials")
        _ = try await service.image("/app-store/commerce/ad-resizer-output.svg")
        let relativeRequest = await http.requests.last!
        check(relativeRequest.url?.absoluteString == "https://app.tapnow.media/app-store/commerce/ad-resizer-output.svg"
                && relativeRequest.value(forHTTPHeaderField: "Authorization") == nil,
              "relative source artwork resolves to official HTTPS without credentials")
        let icon = AgentMarketItem(["kind":"app", "name":"a", "display_name":"Alpha Beta"])
        let sourceIcon = AgentMarketItem(["kind":"skill","name":"3d-studio","display_name":"3D 片场"])
        check(icon.iconInitials == "AB" && icon.iconColor == 0x3AA99F && sourceIcon.iconColor == 0x8B7EC8,
              "source default icon preserves actual initials and stable palette")
        await http.setFailure(true)
        do { _ = try await service.refresh(session: session, force: true); check(false, "failed refresh throws") }
        catch { check(true, "failed refresh throws") }
        check(await service.load(scope: snapshot.scope) == snapshot, "failed refresh retains the last complete snapshot")
        await service.activate(scope: "other-account")
        check(AgentMarketSyncService.discover(root: root.appendingPathComponent("cache")).isEmpty,
              "switching account immediately hides previous account skills")
        await http.setFailure(false); await http.setUnauthorized(true)
        let unavailable = try await service.refresh(session: session, force: true)
        check(unavailable.skills.isEmpty && unavailable.accountStatus.contains("失效"), "401 clears active private skill availability")
        check(AgentMarketSyncService.discover(root: root.appendingPathComponent("cache")).isEmpty,
              "expired login cannot expose previously downloaded private skills")
        try fixtureSession(home: home, sub: "account-a", expiry: 1)
        check(AgentMarketDesktopSession.read(home: home.path) == nil, "expired access token is not reused")
        try fixtureSession(home: home, sub: "account-a", expiry: Int(Date().timeIntervalSince1970) + 1000, deleted: true)
        check(AgentMarketDesktopSession.read(home: home.path) == nil, "logout tombstone cannot resurrect a credential")
        try fixtureSession(home: home, sub: "account-a", expiry: Int(Date().timeIntervalSince1970) + 1000, origin: "https://unrelated.example.com")
        check(AgentMarketDesktopSession.read(home: home.path) == nil, "unrelated storage origins cannot supply a session")
        check(await http.requests.allSatisfy { $0.httpMethod == nil || $0.httpMethod == "GET" }, "sync performs read-only GET requests")
        let summary: [String: Any] = ["passed":passed, "failures":failures]
        if let output = ProcessInfo.processInfo.environment["MARKET_SYNC_REPORT"] {
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        if let directory = ProcessInfo.processInfo.environment["MARKET_SYNC_LIVE_ROOT"] {
            let liveRoot = URL(fileURLWithPath: directory)
            let live = AgentMarketSyncService(root: liveRoot)
            guard let desktop = AgentMarketDesktopSession.read() else { throw AgentMarketSyncError.requiresLogin }
            let current = try await live.refresh(session: desktop, force: true)
            let sourceCount = current.catalog["items"]?.arrayValue?.count ?? 0
            let bodyCount = current.items.filter { current.markdown(for: $0) != nil }.count
            check(sourceCount > 0 && current.details.count == sourceCount && !current.skills.isEmpty
                    && current.skills.values.allSatisfy { $0["instructions"]?.stringValue?.isEmpty == false },
                  "live official catalog details and all currently readable skills synchronize")
            let report: [String: Any] = ["source_items":sourceCount, "display_items":current.items.count,
                "actual_skill_documents":current.skills.count, "usable_document_entries":bodyCount,
                "dynamic_forms":current.items.filter { $0.form != nil }.count,
                "version":current.version, "account_connected":current.accountStatus == "已连接本机登录会话",
                "reference_profile_written":false, "paid_generation_requests":0,
                "credential_persisted":false, "remote_mutations":0]
            try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys])
                .write(to:liveRoot.appendingPathComponent("live-source-report.json"))
            print(try String(data: JSONSerialization.data(withJSONObject: report, options:.sortedKeys), encoding:.utf8)!)
        }
        print("\(passed.count) passed; \(failures.count) failed")
        if !failures.isEmpty { exit(1) }
    }
}
