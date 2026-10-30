import Foundation

public extension AgentMarketItem {
    var sourceAdded: Bool {
        (kind == "skill" && raw["status"]?.stringValue != nil)
            || raw["installed"]?.boolValue == true || raw["is_installed"]?.boolValue == true
            || raw["install_mode"]?.stringValue == "system"
    }
    var sourceEnabled: Bool {
        raw["enabled"]?.boolValue ?? (raw["status"]?.stringValue != "disabled")
    }
    var isEditable: Bool {
        kind == "skill" && raw["is_editable"]?.boolValue != false
            && !["system", "tapnow"].contains(raw["source"]?.stringValue ?? "")
            && raw["provider"]?.stringValue != "system"
    }
    var connectorIDs: [String] {
        (raw["connectors"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue ?? $0["id"]?.stringValue }
    }
}

/// Keeps a cloud authorization challenge in memory; secret form values are never cached.
public struct AgentConnectorSession: Equatable, Sendable {
    public var raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { raw["session_id"]?.stringValue ?? "" }
    public var status: String { raw["status"]?.stringValue ?? "pending" }
    public var stage: String { raw["stage"]?.stringValue ?? "" }
    public var kind: String { raw["challenge_kind"]?.stringValue ?? "" }
    public var fields: [JSONValue] { raw["form_fields"]?.arrayValue ?? [] }
    public var terminal: Bool { ["authenticated", "error", "expired", "cancelled"].contains(status) }
    public var interval: Double {
        min(30, max(0.2, Double(raw["poll_interval_ms"]?.intValue ?? 2000) / 1000))
    }
    public var externalURL: URL? {
        guard let text = raw["redirect_url"]?.stringValue ?? raw["verification_url"]?.stringValue,
              let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }
    public func merging(_ update: JSONValue) -> Self {
        var fields = raw.objectValue ?? [:]
        for (key, value) in update.objectValue ?? [:] { fields[key] = value }
        return .init(.object(fields))
    }
}

extension AgentMarketSyncService {
    static func segment(_ name: String) throws -> String {
        guard !name.isEmpty, name.count <= 256, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let value = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_")))
        else { throw AgentMarketSyncError.invalidURL }
        return value
    }
    static func list(_ raw: JSONValue, key: String) throws -> [JSONValue] {
        guard let list = raw.arrayValue ?? raw[key]?.arrayValue ?? raw["items"]?.arrayValue else { throw AgentMarketSyncError.invalidResponse }
        return list
    }
    public static func normalizePlugin(_ plugin: JSONValue) -> JSONValue {
        var value = plugin.objectValue ?? [:]
        let name = plugin["plugin_name"] ?? plugin["name"] ?? plugin["id"] ?? ""
        value["name"] = name; value["kind"] = "app"
        value["display_name"] = plugin["display_name"] ?? plugin["title"] ?? name
        value["description"] = plugin["public_description"] ?? plugin["description"] ?? plugin["public_content"] ?? ""
        let status = [plugin["installation_status"], plugin["installation"]?["status"], plugin["status"]]
            .compactMap { $0?.stringValue }.first { ["enabled", "disabled"].contains($0) }
        let enabled = plugin["is_enabled"]?.boolValue ?? plugin["enabled"]?.boolValue ?? plugin["installation"]?["enabled"]?.boolValue
        value["installed"] = .bool(plugin["is_installed"]?.boolValue ?? plugin["installed"]?.boolValue
            ?? plugin["installation"]?["installed"]?.boolValue ?? (status != nil || enabled == true))
        value["enabled"] = .bool(status.map { $0 == "enabled" } ?? enabled ?? false)
        if let status { value["installation_status"] = .string(status) }
        return .object(value)
    }
    public func refreshManager(session: AgentMarketDesktopSession, previous: AgentMarketSnapshot?) async throws -> AgentMarketSnapshot {
        async let catalog = request("/api/agent-gateway/v1/plugins", session: session)
        async let added = request("/api/agent-gateway/v1/plugins?installed_only=true", session: session)
        async let skillResponse = request("/api/agent-gateway/v1/skills", session: session)
        async let connectorResponse = request("/api/agent-gateway/v1/connectors", session: session)
        let (all, installed, skills, connectors) = try await (catalog, added, skillResponse, connectorResponse)
        let installedList = try Self.list(installed, key: "plugins").map(Self.normalizePlugin)
        let addedByName = Dictionary(installedList.compactMap { value in
            value["name"]?.stringValue.map { ($0, value) }
        }, uniquingKeysWith: { _, last in last })
        var next = previous?.scope == session.scope ? previous! :
            AgentMarketSnapshot(scope: session.scope, catalog: load()?.catalog ?? ["items": []])
        next.managerCatalog = try Self.list(all, key: "plugins").map(Self.normalizePlugin).map { plugin in
            var value = next.details["app:" + (plugin["name"]?.stringValue ?? "")]?.objectValue ?? [:]
            for (key, field) in plugin.objectValue ?? [:] { value[key] = field }
            let name = plugin["name"]?.stringValue ?? ""
            value["kind"] = "app"
            value["display_name"] = plugin["display_name"] ?? plugin["name"]
            value["installed"] = .bool(addedByName[name] != nil || plugin["install_mode"] == "system")
            if let added = addedByName[name] {
                for key in ["installation_status", "enabled", "install_mode"] { if let field = added[key] { value[key] = field } }
            }
            return .object(value)
        }
        guard next.managerCatalog?.allSatisfy({ $0["name"]?.stringValue?.isEmpty == false }) == true else {
            throw AgentMarketSyncError.invalidResponse
        }
        let retained = Set(["name","description","instructions","provider","source","is_editable","is_system","version","status","skipped_file_count","files","support_files"])
        next.skills = Dictionary(try Self.list(skills, key: "skills").filter {
            $0["deleted_at"] == nil || $0["deleted_at"] == .null
        }.compactMap { value in value["name"]?.stringValue.map {
            ($0, .object((value.objectValue ?? [:]).filter { retained.contains($0.key) }))
        } }, uniquingKeysWith: { _, last in last })
        for key in next.details.keys.filter({ $0.hasPrefix("skill:") }) {
            let name = String(key.dropFirst("skill:".count))
            guard let skill = next.skills[name] else { next.details[key] = nil; continue }
            var fields = skill.objectValue ?? [:]
            fields["kind"] = "skill"; fields["display_name"] = .string(name)
            fields["activation_skill"] = .string(name)
            next.details[key] = .object(fields)
        }
        next.connectors = try Self.list(connectors, key: "connectors")
        // Details must not retain stale installation flags from the web store.
        for raw in next.managerCatalog ?? [] { next.details[AgentMarketItem(raw).id] = raw }
        next.accountStatus = "已连接本机登录会话"; next.fetchedAt = Date()
        return next
    }
    public func pluginSkill(_ item: AgentMarketItem, name: String, session: AgentMarketDesktopSession) async throws -> JSONValue {
        try await request("/api/agent-gateway/v1/plugins/" + Self.segment(item.name) + "/skills/" + Self.segment(name), session: session)
    }
    public func managementDetail(_ item: AgentMarketItem, session: AgentMarketDesktopSession) async throws -> JSONValue {
        let resource = item.kind == "app" ? "plugins" : "skills"
        let response = try await request("/api/agent-gateway/v1/" + resource + "/" + Self.segment(item.name), session: session)
        let retained = Set(["name","description","instructions","provider","source","is_editable","is_system","version","status","skipped_file_count","files","support_files"])
        let detail = item.kind == "app" ? Self.normalizePlugin(response) :
            .object((response.objectValue ?? [:]).filter { retained.contains($0.key) })
        guard detail["name"]?.stringValue == item.name else { throw AgentMarketSyncError.invalidResponse }
        var result = item.raw.objectValue ?? [:]
        for (key, value) in detail.objectValue ?? [:] { result[key] = value }
        result["kind"] = .string(item.kind)
        return .object(result)
    }
    public func setInstallation(_ item: AgentMarketItem, action: String, session: AgentMarketDesktopSession) async throws {
        guard item.kind == "app", ["add", "enabled", "disabled", "remove"].contains(action) else { throw AgentMarketSyncError.invalidForm("无效操作") }
        let method = action == "add" ? "PUT" : action == "remove" ? "DELETE" : "PATCH"
        _ = try await request("/api/agent-gateway/v1/plugins/" + Self.segment(item.name) + "/installation",
            session: session, method: method, body: method == "PATCH" ? ["status": .string(action)] : nil)
    }
    public func saveSkill(original: String?, name: String, description: String, instructions: String,
                          session: AgentMarketDesktopSession) async throws -> JSONValue {
        guard name.range(of: #"^[a-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.count <= 1024,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.count <= 20_000 else { throw AgentMarketSyncError.invalidForm("名称需为 1–64 位小写字母、数字或连字符；描述最多 1024 字，指令最多 20000 字") }
        let suffix = try original.map { "/" + (try Self.segment($0)) } ?? ""
        return try await request("/api/agent-gateway/v1/skills" + suffix, session: session,
            method: original == nil ? "POST" : "PATCH",
            body: ["name": .string(name), "description": .string(description), "instructions": .string(instructions)])
    }
    public func mutateSkill(_ item: AgentMarketItem, status: String?, session: AgentMarketDesktopSession) async throws {
        guard item.isEditable || status != nil else { throw AgentMarketSyncError.invalidForm("系统技能不可卸载") }
        if let status, !["enabled", "disabled"].contains(status) { throw AgentMarketSyncError.invalidResponse }
        _ = try await request("/api/agent-gateway/v1/skills/" + Self.segment(item.name) + (status == nil ? "" : "/status"),
            session: session, method: status == nil ? "DELETE" : "PATCH",
            body: status.map { ["status": .string($0)] })
    }
    public func importSkillArchive(_ bytes: Data, session: AgentMarketDesktopSession) async throws -> JSONValue {
        guard bytes.count < 16 * 1024 * 1024, bytes.starts(with: [0x50, 0x4b]) else { throw AgentMarketSyncError.invalidForm("技能文件夹需为 ZIP 包") }
        let boundary = "ClipSlots-" + UUID().uuidString
        var payload = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"skill.zip\"\r\nContent-Type: application/zip\r\n\r\n".utf8)
        payload.append(bytes); payload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await request("/api/agent-gateway/v1/skills/import-folder", session: session,
            method: "POST", payload: payload, contentType: "multipart/form-data; boundary=" + boundary)
    }
    public func startConnector(_ id: String, capabilityIDs: [String], session: AgentMarketDesktopSession) async throws -> AgentConnectorSession {
        let raw = try await request("/api/agent-gateway/v1/connectors/" + Self.segment(id) + "/auth-sessions",
            session: session, method: "POST", body: capabilityIDs.isEmpty ? [:] : ["capabilities": .array(capabilityIDs.map(JSONValue.string))])
        let result = AgentConnectorSession(raw)
        guard !result.id.isEmpty else { throw AgentMarketSyncError.invalidResponse }
        return result
    }
    public func pollConnector(_ id: String, auth: AgentConnectorSession, session: AgentMarketDesktopSession) async throws -> AgentConnectorSession {
        auth.merging(try await request("/api/agent-gateway/v1/connectors/" + Self.segment(id) + "/auth-sessions/" + Self.segment(auth.id), session: session))
    }
    public func submitConnector(_ id: String, auth: AgentConnectorSession, values: [String: String],
                                session: AgentMarketDesktopSession) async throws -> AgentConnectorSession {
        for field in auth.fields where field["required"]?.boolValue == true {
            guard let name = field["name"]?.stringValue, !(values[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentMarketSyncError.invalidForm("请填写" + (field["label"]?.stringValue ?? "必填字段"))
            }
        }
        let allowed = Set(auth.fields.compactMap { $0["name"]?.stringValue })
        guard Set(values.keys).isSubset(of: allowed) else { throw AgentMarketSyncError.invalidForm("授权字段已变化") }
        return auth.merging(try await request("/api/agent-gateway/v1/connectors/" + Self.segment(id) + "/auth-sessions/" + Self.segment(auth.id) + "/submit",
            session: session, method: "POST", body: ["values": .object(values.mapValues(JSONValue.string))]))
    }
    public func disconnectConnector(_ id: String, reset: Bool = false, session: AgentMarketDesktopSession) async throws {
        _ = try await request("/api/agent-gateway/v1/connectors/" + Self.segment(id) + (reset ? "?reset=true" : ""),
            session: session, method: "DELETE")
    }
    public func setLocalEnabled(_ item: AgentMarketItem, scope: String, enabled: Bool) throws {
        var records = try installations(scope: scope)
        if records[item.id] == nil { return }
        records[item.id]?.enabled = enabled
        try JSONEncoder().encode(records).write(to: installationsURL(scope), options: .atomic)
    }
    public func removeLocal(_ item: AgentMarketItem, scope: String) throws {
        var records = try installations(scope: scope)
        records[item.id] = nil
        let file = installationsURL(scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        let directory = skillURL(item, scope: scope)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
