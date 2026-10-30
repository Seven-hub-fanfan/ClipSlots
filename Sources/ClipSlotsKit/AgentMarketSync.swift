import Foundation
import CryptoKit

public struct AgentMarketItem: Identifiable, Equatable, Sendable {
    public var raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var kind: String { raw["kind"]?.stringValue ?? "skill" }
    public var name: String { raw["name"]?.stringValue ?? "" }
    public var id: String { kind + ":" + name }
    public var title: String { raw["display_name"]?.stringValue ?? name }
    public var summary: String { raw["marketing_line"]?.stringValue ?? raw["description"]?.stringValue ?? "" }
    public var activationSkill: String { raw["activation_skill"]?.stringValue ?? name }
    public var iconURL: String? { raw["icon_url"]?.stringValue }
    public var coverURL: String? { raw["cover_url"]?.stringValue }
    public var iconStyle: String? { raw["icon_style"]?.stringValue }
    public var form: JSONValue? { raw["try_form"] }
    public var fields: [JSONValue] { form?["fields"]?.arrayValue ?? [] }
    public var starter: String { raw["starter_prompt"]?.stringValue ?? "" }
    public var iconInitials: String {
        let words = title.split(whereSeparator: \.isWhitespace)
        if words.count >= 2 { return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased() }
        return String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
    }
    public var iconColor: UInt32 {
        let palette: [UInt32] = [0x4385BE, 0x3AA99F, 0x879A39, 0xD0A215, 0xDA702C, 0xD14D41, 0x8B7EC8, 0xCE5D97]
        // Match JavaScript's signed shift while preserving the outer numeric sum.
        let hash = name.lowercased().utf16.reduce(Int64(0)) {
            Int64($1) + Int64(Int32(truncatingIfNeeded:$0) &<< 5) - $0
        }
        return palette[Int(abs(hash)) % palette.count]
    }

    public func prompt(values: [String: String], text: String, referenceCount: Int) throws -> String {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let maximum = form?["prompt"]?["max_length"]?.intValue ?? 20_000
        guard text.count <= maximum else { throw AgentMarketSyncError.invalidForm("补充要求最多 \(maximum) 字") }
        let minimumReferences = form?["references"]?["min"]?.intValue ?? 0
        let maximumReferences = form?["references"]?["max"]?.intValue ?? 100
        guard referenceCount >= minimumReferences, referenceCount <= maximumReferences else {
            throw AgentMarketSyncError.invalidForm("需提供 \(minimumReferences)–\(maximumReferences) 个参考素材")
        }
        var lines: [String] = []
        for field in fields {
            let id = field["id"]?.stringValue ?? "", value = trim(values[id] ?? "")
            let label = field["label"]?.stringValue ?? id
            if field["required"]?.boolValue == true && value.isEmpty {
                throw AgentMarketSyncError.invalidForm("请填写\(label)")
            }
            if let limit = field["max_length"]?.intValue, value.count > limit {
                throw AgentMarketSyncError.invalidForm("\(label)最多 \(limit) 字")
            }
            if !value.isEmpty { lines.append(label + "：" + value) }
        }
        if !trim(text).isEmpty { lines.append(text) }
        guard !trim(text).isEmpty || !starter.isEmpty || fields.contains(where: { !trim(values[$0["id"]?.stringValue ?? ""] ?? "").isEmpty }) else {
            throw AgentMarketSyncError.invalidForm("请填写创作需求")
        }
        if lines.isEmpty { lines.append(starter) }
        return lines.joined(separator: "\n")
    }
}

public struct AgentMarketInstallation: Codable, Equatable, Sendable {
    public var item: JSONValue
    public var skillSlug: String?
    public var installedAt: Date
    public var connection: AgentMCPBinding?
    public var enabled: Bool? = true
    public var isEnabled: Bool { enabled != false }
    public var isReady: Bool { skillSlug != nil || connection?.isValid == true }
}

public struct AgentMarketSnapshot: Codable, Equatable, Sendable {
    public var scope: String
    public var catalog: JSONValue
    public var details: [String: JSONValue]
    public var skills: [String: JSONValue]
    public var fetchedAt: Date
    public var detailsAt: Date
    public var accountStatus: String
    public var managerCatalog: [JSONValue]?
    public var connectors: [JSONValue]?
    public var managerItems: [AgentMarketItem] {
        guard let managerCatalog else { return items }
        let apps = managerCatalog.map { AgentMarketItem($0) }
        let personal = skills.values.map { raw -> AgentMarketItem in
            var fields = raw.objectValue ?? [:]
            fields["kind"] = "skill"; fields["display_name"] = raw["name"]
            fields["activation_skill"] = raw["name"]
            return AgentMarketItem(.object(fields))
        }.sorted { $0.name < $1.name }
        return apps + personal
    }
    public var items: [AgentMarketItem] {
        let catalogItems = (catalog["items"]?.arrayValue ?? []).map { raw -> AgentMarketItem in
            let item = AgentMarketItem(raw)
            return AgentMarketItem(details[item.id] ?? raw)
        }
        let represented = Set(catalogItems.map(\.activationSkill))
        let personal = skills.values.filter {
            !represented.contains($0["name"]?.stringValue ?? "")
        }.map { raw -> AgentMarketItem in
            var fields = raw.objectValue ?? [:]; fields["kind"] = "skill"
            fields["display_name"] = raw["name"]; fields["activation_skill"] = raw["name"]
            fields["category"] = "账号技能"
            return AgentMarketItem(.object(fields))
        }.sorted { $0.name < $1.name }
        return catalogItems + personal
    }
    public var version: String { catalog["content_version"]?.stringValue ?? "" }
    public init(scope: String = "public", catalog: JSONValue, details: [String: JSONValue] = [:],
                skills: [String: JSONValue] = [:], fetchedAt: Date = .distantPast,
                detailsAt: Date = .distantPast, accountStatus: String = "未连接登录会话") {
        self.scope = scope; self.catalog = catalog; self.details = details; self.skills = skills
        self.fetchedAt = fetchedAt; self.detailsAt = detailsAt; self.accountStatus = accountStatus
    }
    public func item(_ id: String) -> AgentMarketItem? {
        if let detail = details[id] { return AgentMarketItem(detail) }
        if let item = managerItems.first(where: { $0.id == id }) { return item }
        return items.first { $0.id == id }
    }
    public func markdown(for item: AgentMarketItem) -> String? {
        if let content = details[item.id]?["public_content"]?.stringValue, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content }
        if let skill = skills[item.activationSkill] ?? skills[item.name],
           let instructions = skill["instructions"]?.stringValue, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if instructions.hasPrefix("---\n") { return instructions }
            // An official instruction-only response has no SKILL.md wrapper.
            // Preserve instructions verbatim; add only the actual API metadata.
            let encodedName = (try? JSONValue.string(item.activationSkill).encodedText()) ?? "\"skill\""
            let description = (try? JSONValue.string(skill["description"]?.stringValue ?? item.summary).encodedText()) ?? "\"\""
            return "---\nname: \(encodedName)\ndescription: \(description)\n---\n\n" + instructions
        }
        return nil
    }
}

public enum AgentMarketSyncError: LocalizedError {
    case invalidResponse, requiresLogin, invalidURL, invalidForm(String), unavailableSkill
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "目录响应不完整，已保留上次完整配置"
        case .requiresLogin: return "登录会话不可用，请在参考应用登录后刷新"
        case .invalidURL: return "资源地址无效"
        case .invalidForm(let message): return message
        case .unavailableSkill: return "尚未取得此 Skill 的完整正文"
        }
    }
}

public protocol AgentMarketHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
private final class MarketRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Authentication never follows a redirect. Asset redirects must remain HTTPS.
        guard task.originalRequest?.value(forHTTPHeaderField: "Authorization") == nil,
              request.url?.scheme == "https" else { completionHandler(nil); return }
        completionHandler(request)
    }
}
public struct AgentMarketURLSessionHTTP: AgentMarketHTTP {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: MarketRedirectPolicy(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard data.count <= 16 * 1024 * 1024 else { throw AgentMarketSyncError.invalidResponse }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public actor AgentMarketSyncService {
    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["CLIPSLOTS_MARKET_SYNC_ROOT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClipSlots/market-sync")
    }
    public let root: URL
    private let http: any AgentMarketHTTP
    private let base: URL
    private var imageTasks: [String: Task<Data, Error>] = [:]
    public init(root: URL = defaultRoot, base: URL = URL(string: "https://app.tapnow.media")!,
                http: any AgentMarketHTTP = AgentMarketURLSessionHTTP()) {
        self.root = root; self.base = base; self.http = http
    }
    public static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func snapshotURL(_ scope: String) -> URL { root.appendingPathComponent("scopes/" + Self.hash(scope) + "/snapshot.json") }
    func installationsURL(_ scope: String) -> URL {
        snapshotURL(scope).deletingLastPathComponent().appendingPathComponent("installed.json")
    }
    public func installations(scope: String) throws -> [String: AgentMarketInstallation] {
        let file = installationsURL(scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: AgentMarketInstallation].self, from: Data(contentsOf: file))
    }
    /// Only an actual skill document or verified, explicitly bound tools count
    /// as an installation. Old catalog-only records remain readable but pending.
    public func install(_ item: AgentMarketItem, snapshot: AgentMarketSnapshot) throws -> AgentMarketInstallation {
        var records = try installations(scope: snapshot.scope)
        let resolved = snapshot.item(item.id) ?? item
        let skill: AgentSkill?
        if snapshot.markdown(for: resolved) != nil { skill = try materialize(resolved, snapshot: snapshot) }
        else if resolved.kind == "app", let existing = records[item.id]?.connection,
                existing.isValid, existing.scope == snapshot.scope, existing.applicationID == item.id { skill = nil }
        else if resolved.kind == "app" { throw AgentMCPError.authorization }
        else { throw AgentMarketSyncError.unavailableSkill }
        let record = AgentMarketInstallation(item: resolved.raw, skillSlug: skill?.slug,
            installedAt: records[item.id]?.installedAt ?? Date(), connection: records[item.id]?.connection)
        records[item.id] = record
        let file = installationsURL(snapshot.scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        return record
    }
    public func bind(_ item: AgentMarketItem, snapshot: AgentMarketSnapshot,
                     client: AgentMCPClient, selectedNames: Set<String>) async throws -> AgentMarketInstallation {
        guard !selectedNames.isEmpty, item.kind == "app" else { throw AgentMCPError.unavailable }
        let tools = try await client.listTools().filter { selectedNames.contains($0.name) }
        guard tools.count == selectedNames.count else { throw AgentMCPError.invalidBinding }
        let binding = AgentMCPBinding(scope: snapshot.scope, applicationID: item.id, endpoint: client.endpoint, tools: tools)
        guard binding.isValid else { throw AgentMCPError.invalidBinding }
        var records = try installations(scope: snapshot.scope)
        let record = AgentMarketInstallation(item: item.raw, skillSlug: records[item.id]?.skillSlug,
            installedAt: records[item.id]?.installedAt ?? Date(), connection: binding)
        records[item.id] = record
        let file = installationsURL(snapshot.scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        return record
    }
    public func reference(_ item: AgentMarketItem, snapshot: AgentMarketSnapshot) throws -> AgentSkillReference {
        if snapshot.markdown(for: item) != nil {
            let skill = try materialize(item, snapshot: snapshot)
            return try AgentSkillReference.load(name: item.title, path: skill.markdownPath)
        }
        guard item.kind == "app" else { throw AgentMarketSyncError.unavailableSkill }
        guard let binding = try installations(scope: snapshot.scope)[item.id]?.connection,
              binding.isValid, binding.scope == snapshot.scope, binding.applicationID == item.id else {
            throw AgentMCPError.authorization
        }
        let content = try JSONValue.object(["application": item.raw, "bound_tools": .array(binding.tools.map {
            .object(["name": .string(binding.toolName($0)), "description": .string($0.description)])
        })]).encodedText(pretty: true)
        guard content.utf8.count <= AgentSkillReference.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return AgentSkillReference(name: item.title,
            path: "market-app:" + Self.hash(snapshot.scope) + ":" + item.id,
            markdown: content, applicationID: item.id)
    }
    public func activate(scope: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(["scope": scope]).write(to: root.appendingPathComponent("active.json"), options: .atomic)
    }
    public func load(scope: String = "public") -> AgentMarketSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(scope)) else { return scope == "public" ? seed() : nil }
        return try? JSONDecoder().decode(AgentMarketSnapshot.self, from: data)
    }
    private func seed() -> AgentMarketSnapshot? {
        let resources = Bundle.module.url(forResource: "Resources", withExtension: nil)?.appendingPathComponent("Market")
        guard let resources, let data = try? Data(contentsOf: resources.appendingPathComponent("catalog.json")),
              let catalog = try? JSONDecoder().decode(JSONValue.self, from: data),
              let detailData = try? Data(contentsOf: resources.appendingPathComponent("details.json")),
              let details = try? JSONDecoder().decode([String: JSONValue].self, from: detailData) else { return nil }
        return AgentMarketSnapshot(catalog: catalog, details: details, accountStatus: "公开目录 · 待刷新")
    }
    func request(_ path: String, session: AgentMarketDesktopSession?,
                         method: String = "GET", body: JSONValue? = nil, payload: Data? = nil, contentType: String? = nil) async throws -> JSONValue {
        guard ["app.tapnow.media", "app.tapnow.ai"].contains(base.host ?? ""), base.scheme == "https",
              path.hasPrefix("/api/bff/app-store/") || path.hasPrefix("/api/agent-gateway/v1/skills")
                    || path.hasPrefix("/api/agent-gateway/v1/plugins")
                    || path.hasPrefix("/api/agent-gateway/v1/connectors"),
              !path.contains(".."), !path.contains("#"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.scheme == base.scheme else { throw AgentMarketSyncError.invalidURL }
        var request = URLRequest(url: url)
        let segments = url.path.split(separator: "/").map(String.init)
        let resource = segments.count > 3 ? segments[3] : ""
        let allowedMutation =
            (resource == "plugins" && segments.count == 6 && segments.last == "installation" && ["PUT","PATCH","DELETE"].contains(method))
            || (resource == "skills" && ((segments.count == 4 && method == "POST")
                || (segments.count == 5 && segments.last == "import-folder" && method == "POST")
                || (segments.count == 5 && ["PATCH","DELETE"].contains(method))
                || (segments.count == 6 && segments.last == "status" && method == "PATCH")))
            || (resource == "connectors" && ((segments.count == 5 && method == "DELETE")
                || (segments.count == 6 && segments.last == "auth-sessions" && method == "POST")
                || (segments.count == 8 && segments.last == "submit" && method == "POST")))
        guard method == "GET" || (session != nil && allowedMutation) else {
            throw AgentMarketSyncError.invalidURL
        }
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let payload, let contentType {
            request.httpBody = payload; request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("explicit", forHTTPHeaderField: "X-Tap-App-Store-Layout")
        request.setValue("agent", forHTTPHeaderField: "X-Tap-Preset-Runners")
        if let session {
            request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization")
            if let organization = session.organization { request.setValue(organization, forHTTPHeaderField: "X-Org-ID") }
        }
        let (data, status) = try await http.send(request)
        try Task.checkCancellation()
        if status == 401 || status == 403 { throw AgentMarketSyncError.requiresLogin }
        if status == 204 && method != "GET" { return [:] }
        guard (200...299).contains(status), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value["code"]?.intValue == 200 || value["code"]?.intValue == 0 || value["code"] == nil,
              let result = value["data"], result.objectValue != nil || result.arrayValue != nil else { throw AgentMarketSyncError.invalidResponse }
        return result
    }
    /// Match the source's explicit Add action. Cloud installation is verified
    /// separately and never treated as proof that local tools are connected.
    public func ensureRemoteInstallation(_ item: AgentMarketItem, session: AgentMarketDesktopSession) async throws {
        guard item.kind == "app" else { throw AgentMarketSyncError.invalidResponse }
        var detail = try await fetchDetail(item, session: session)
        let path = "/api/agent-gateway/v1/plugins/" + item.name + "/installation"
        if detail["installed"] != .bool(true) && detail["install_mode"] != "system" {
            guard detail["install_mode"] == "user" else { throw AgentMCPError.unavailable }
            _ = try await request(path, session: session, method: "PUT", body: [:])
            detail = try await fetchDetail(item, session: session)
        }
        if detail["installed"] == .bool(true) && detail["enabled"] != .bool(true) {
            _ = try await request(path, session: session, method: "PATCH", body: ["status":"enabled"])
            detail = try await fetchDetail(item, session: session)
        }
        guard detail["enabled"] == .bool(true),
              detail["installed"] == .bool(true) || detail["install_mode"] == "system" else {
            throw AgentMCPError.unavailable
        }
    }
    public func refresh(session: AgentMarketDesktopSession? = nil, force: Bool = false) async throws -> AgentMarketSnapshot {
        let scope = session?.scope ?? "public"
        let cached = load(scope: scope)
        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < 60 { return cached }
        let catalog: JSONValue
        do { catalog = try await request("/api/bff/app-store/catalog", session: session) }
        catch AgentMarketSyncError.requiresLogin where session != nil {
            activate(scope: "public")
            return try await refresh(session: nil, force: true)
        }
        guard let rawItems = catalog["items"]?.arrayValue, !rawItems.isEmpty,
              catalog["content_version"]?.stringValue?.isEmpty == false,
              rawItems.allSatisfy({ $0["name"]?.stringValue?.isEmpty == false && ["app", "skill"].contains($0["kind"]?.stringValue ?? "") }),
              Set(rawItems.map { AgentMarketItem($0).id }).count == rawItems.count else { throw AgentMarketSyncError.invalidResponse }
        let publicSeed = load()
        var next = AgentMarketSnapshot(scope: scope, catalog: catalog,
            details: cached?.details ?? publicSeed?.details ?? [:], skills: cached?.skills ?? [:],
            detailsAt: cached?.detailsAt ?? .distantPast)
        // Catalog version, rather than a fixed list, determines when details change.
        if force || next.version != (cached?.version ?? publicSeed?.version) || next.details.count != rawItems.count
            || Date().timeIntervalSince(next.detailsAt) > 1800 {
            var complete: [String: JSONValue] = [:]
            for batchStart in stride(from: 0, to: rawItems.count, by: 4) {
                let batch = Array(rawItems[batchStart..<min(batchStart + 4, rawItems.count)]).map(AgentMarketItem.init)
                let baseService = self
                let values = try await withThrowingTaskGroup(of: (String, JSONValue).self) { group in
                    for item in batch { group.addTask { (item.id, try await baseService.fetchDetail(item, session: session)) } }
                    var output: [(String, JSONValue)] = []
                    for try await value in group { output.append(value) }; return output
                }
                for (id, detail) in values { complete[id] = detail }
            }
            next.details = complete; next.detailsAt = Date()
        }
        if let session {
            do {
                let response = try await request("/api/agent-gateway/v1/skills", session: session)
                guard let skills = response["skills"]?.arrayValue else { throw AgentMarketSyncError.invalidResponse }
                let retained = Set(["name", "description", "instructions", "provider", "version", "status", "skipped_file_count"])
                next.skills = Dictionary(skills.filter { $0["deleted_at"] == nil || $0["deleted_at"] == .null }
                    .compactMap { skill in skill["name"]?.stringValue.map {
                        ($0, JSONValue.object((skill.objectValue ?? [:]).filter { retained.contains($0.key) }))
                    } }, uniquingKeysWith: { _, last in last })
                next.accountStatus = "已连接本机登录会话"
            } catch AgentMarketSyncError.requiresLogin {
                // Do not expose the previous account's private documents as current.
                next.skills = [:]; next.accountStatus = "登录已失效 · 公开目录"
            }
        } else { next.accountStatus = "公开目录 · 登录后同步个人技能" }
        next.fetchedAt = Date()
        try commit(next)
        return next
    }
    public func fetchDetail(_ item: AgentMarketItem, session: AgentMarketDesktopSession? = nil) async throws -> JSONValue {
        guard item.name.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
              ["app", "skill"].contains(item.kind) else { throw AgentMarketSyncError.invalidURL }
        let detail = try await request("/api/bff/app-store/items/" + item.kind + "/" + item.name, session: session)
        guard detail["name"]?.stringValue == item.name, detail["kind"]?.stringValue == item.kind else {
            throw AgentMarketSyncError.invalidResponse
        }
        return detail
    }
    public func commit(_ snapshot: AgentMarketSnapshot) throws {
        let file = snapshotURL(snapshot.scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        let active = root.appendingPathComponent("active.json")
        try JSONEncoder().encode(["scope": snapshot.scope]).write(to: active, options: .atomic)
        // Refresh only previously materialized skill documents. No automatic script authorization.
        for item in snapshot.items where FileManager.default.fileExists(atPath: skillURL(item, scope: snapshot.scope).path) {
            if snapshot.markdown(for: item) != nil { _ = try materialize(item, snapshot: snapshot) }
        }
    }
    public func materialize(_ item: AgentMarketItem, snapshot: AgentMarketSnapshot) throws -> AgentSkill {
        guard let markdown = snapshot.markdown(for: item), markdown.utf8.count <= 1_048_576 else { throw AgentMarketSyncError.unavailableSkill }
        let directory = skillURL(item, scope: snapshot.scope), file = directory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: file, options: .atomic)
        let parsed = AgentSkillCatalog.parse(markdown: markdown, fallbackName: item.title)
        return AgentSkill(slug: "market_" + String(Self.hash(snapshot.scope + "|" + item.activationSkill).prefix(24)),
            name: item.title, description: item.summary, version: snapshot.version, directory: directory.path,
            markdownPath: file.path, source: .market, declaredTools: parsed.tools, scripts: [])
    }
    func skillURL(_ item: AgentMarketItem, scope: String) -> URL {
        root.appendingPathComponent("scopes/" + Self.hash(scope) + "/skills/" + Self.hash(item.activationSkill))
    }
    public static func discover(root: URL = defaultRoot) -> [AgentSkill] {
        guard let active = try? Data(contentsOf: root.appendingPathComponent("active.json")),
              let scope = (try? JSONDecoder().decode([String:String].self,from:active))?["scope"] else { return [] }
        return discover(root:root,session:scope == "public" ? nil : AgentMarketDesktopSession.read())
    }
    public static func discover(root: URL, session: AgentMarketDesktopSession?) -> [AgentSkill] {
        guard let active = try? Data(contentsOf: root.appendingPathComponent("active.json")),
              let scope = (try? JSONDecoder().decode([String: String].self, from: active))?["scope"],
              scope == "public" || session?.scope == scope,
              let data = try? Data(contentsOf: root.appendingPathComponent("scopes/" + hash(scope) + "/snapshot.json")),
              let snapshot = try? JSONDecoder().decode(AgentMarketSnapshot.self, from: data) else { return [] }
        var seen = Set<String>()
        let installedData = try? Data(contentsOf: root.appendingPathComponent("scopes/" + hash(scope) + "/installed.json"))
        let installed = installedData.flatMap { try? JSONDecoder().decode([String: AgentMarketInstallation].self, from: $0) } ?? [:]
        return snapshot.items.compactMap { item in
            guard seen.insert(item.activationSkill).inserted, installed[item.id]?.isEnabled != false else { return nil }
            let directory = root.appendingPathComponent("scopes/" + hash(scope) + "/skills/" + hash(item.activationSkill))
            let file = directory.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path), snapshot.markdown(for: item) != nil else { return nil }
            return AgentSkill(slug: "market_" + String(hash(scope + "|" + item.activationSkill).prefix(24)),
                name: item.title, description: item.summary, version: snapshot.version,
                directory: directory.path, markdownPath: file.path, source: .market,
                declaredTools: AgentSkillCatalog.parse(markdown: (try? String(contentsOf: file)) ?? "").tools, scripts: [])
        }
    }
    public func image(_ address: String) async throws -> Data {
        let resolved: URL?
        if address.hasPrefix("/app-store/") || address.hasPrefix("/assets/") {
            resolved = URL(string: address, relativeTo: base)?.absoluteURL
        } else { resolved = URL(string: address) }
        guard let url = resolved, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, !["localhost", "127.0.0.1", "::1"].contains(host) else { throw AgentMarketSyncError.invalidURL }
        let key = url.absoluteString
        let file = root.appendingPathComponent("images/" + Self.hash(key))
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < 86400, let data = try? Data(contentsOf: file) { return data }
        if let task = imageTasks[key] { return try await task.value }
        let transport = http
        let task = Task<Data, Error> {
            let (data, status) = try await transport.send(URLRequest(url: url))
            guard status == 200, !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw AgentMarketSyncError.invalidResponse }
            return data
        }
        imageTasks[key] = task
        defer { imageTasks[key] = nil }
        let data = try await task.value
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
    }
}
