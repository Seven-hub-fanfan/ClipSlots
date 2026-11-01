import Foundation
import ClipSlotsKit

extension AgentMarketSyncStore {
    var managementItems: [AgentMarketItem] { snapshot?.managerItems ?? items }
    func sourceAdded(_ item: AgentMarketItem) -> Bool {
        if let raw = snapshot?.managerCatalog?.first(where: { AgentMarketItem($0).id == item.id }) {
            return AgentMarketItem(raw).sourceAdded
        }
        return item.sourceAdded || isInstalled(item)
    }
    func sourceEnabled(_ item: AgentMarketItem) -> Bool {
        item.sourceEnabled && installed[item.id]?.isEnabled != false
    }
    func connectorStatus(_ id: String) -> String? {
        snapshot?.connectors?.first { $0["id"]?.stringValue == id }?["status"]?.stringValue
    }
    func applicationAuthorizationReady(_ item: AgentMarketItem) -> Bool {
        guard item.kind == "app" else { return true }
        let current = snapshot?.managerCatalog?.first(where: { AgentMarketItem($0).id == item.id })
            .map(AgentMarketItem.init) ?? snapshot?.item(item.id) ?? item
        return current.connectorIDs.allSatisfy { connectorStatus($0) == "authenticated" }
    }
    func connectorStatusText(_ id: String) -> String {
        switch connectorStatus(id) {
        case "authenticated": return "已连接"
        case "pending_approval": return "待批准"
        case "pending", "authorizing": return "授权中"
        case "error": return "连接失败"
        case "expired": return "授权已过期"
        case "cancelled": return "已取消"
        case "disconnected": return "未连接"
        default: return "状态未知"
        }
    }
    func refreshManagement() async {
        guard !isRefreshing else { return }
        if readsDesktop || session == nil { await loadCached() }
        guard let session else {
            if snapshot == nil { await loadCached() }
            return
        }
        isRefreshing = true; defer { isRefreshing = false }
        let scope = snapshot?.scope, token = revision
        let operation = beginCatalogOperation()
        defer { finishCatalogOperation(operation) }
        do {
            let next = try await service.refreshManager(session: session, previous: snapshot)
            guard catalogIsCurrent(operation, scope: scope, token: token) else { return }
            try await service.commit(next, operation: operation)
            guard catalogIsCurrent(operation, scope: scope, token: token) else { return }
            snapshot = next
        } catch {
            if catalogIsCurrent(operation, scope: scope, token: token) { self.error = error.localizedDescription }
        }
    }
    func managementDetail(_ item: AgentMarketItem) async throws {
        guard let session else { return }
        let token = revision, scope = snapshot?.scope
        let operation = beginCatalogOperation()
        defer { finishCatalogOperation(operation) }
        let detail = try await service.managementDetail(item, session: session)
        guard catalogIsCurrent(operation, scope: scope, token: token), var next = snapshot else { throw CancellationError() }
        next.details[item.id] = detail
        if item.kind == "skill" { next.skills[item.name] = detail }
        else if let index = next.managerCatalog?.firstIndex(where: { AgentMarketItem($0).id == item.id }) {
            next.managerCatalog?[index] = detail
        }
        try await service.commit(next, operation: operation)
        guard catalogIsCurrent(operation, scope: scope, token: token) else { throw CancellationError() }
        snapshot = next
    }
    func requireSession() async throws -> AgentMarketDesktopSession {
        guard let session, session.scope == snapshot?.scope else { throw AgentMarketSyncError.requiresLogin }
        if readsDesktop {
            let live = await Task.detached { AgentMarketDesktopSession.read() }.value
            guard let live, live.scope == session.scope else { throw AgentMarketSyncError.requiresLogin }
            self.session = live; return live
        }
        return session
    }
    func importManagedSkill(_ url: URL, folder: Bool) async throws {
        if !folder {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 1_048_576, let text = String(data: bytes, encoding: .utf8) else { throw AgentMarketSyncError.unavailableSkill }
            let parsed = AgentSkillCatalog.parse(markdown: text, fallbackName: url.deletingPathExtension().lastPathComponent)
            _ = try await saveManagedSkill(original: nil, name: parsed.name, description: parsed.description, instructions: text)
            return
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path),
              let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else {
            throw AgentMarketSyncError.unavailableSkill
        }
        var bytes = 0
        for case let file as URL in files {
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard info.isSymbolicLink != true else { throw AgentMarketSyncError.invalidForm("技能文件夹不可包含符号链接") }
            bytes += info.fileSize ?? 0
            guard bytes < 16 * 1024 * 1024 else { throw AgentMarketSyncError.invalidForm("技能文件夹最多 16 MB") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skill-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("skill.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", url.path, archive.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentMarketSyncError.unavailableSkill }
        let session = try await requireSession(), token = revision
        _ = try await service.importSkillArchive(Data(contentsOf: archive), session: session)
        guard token == revision, snapshot?.scope == session.scope else { throw CancellationError() }
        await refreshManagement()
    }
    func changeInstallation(_ item: AgentMarketItem, action: String) async throws {
        guard !pending.contains(item.id) else { return }
        let scope = snapshot?.scope, token = revision
        if session == nil && action == "add" { try await add(item); return }
        pending.insert(item.id); defer { pending.remove(item.id) }
        if session != nil {
            let session = try await requireSession()
            guard session.scope == scope else { throw AgentMarketSyncError.requiresLogin }
            if action == "remove" {
                for id in item.connectorIDs where connectorStatus(id) != "disconnected" {
                    try await service.disconnectConnector(id, session: session)
                }
            }
            if item.kind == "app" { try await service.setInstallation(item, action: action, session: session) }
            else { try await service.mutateSkill(item, status: action == "remove" ? nil : action, session: session) }
        }
        guard scope == snapshot?.scope, token == revision else { throw CancellationError() }
        if let scope {
            if action == "remove" { try await service.removeLocal(item, scope: scope); installed[item.id] = nil }
            else if action == "enabled" || action == "disabled" {
                try await service.setLocalEnabled(item, scope: scope, enabled: action == "enabled")
                installed[item.id]?.enabled = action == "enabled"
                if let slug = installed[item.id]?.skillSlug {
                    var enabled = AgentPreferences.decodeEnabledSlugs(UserDefaults.standard.string(forKey: AgentPreferences.enabledSkillsKey) ?? "")
                    if action == "enabled" { enabled.insert(slug) } else { enabled.remove(slug) }
                    UserDefaults.standard.set(AgentPreferences.encodeEnabledSlugs(enabled), forKey: AgentPreferences.enabledSkillsKey)
                    AgentSkillLibrary.shared.refresh()
                }
            }
        }
        if session != nil { await refreshManagement() }
    }
    func saveManagedSkill(original: AgentMarketItem?, name: String, description: String, instructions: String) async throws -> AgentMarketItem {
        let operation = beginCatalogOperation()
        defer { finishCatalogOperation(operation) }
        let session = try await requireSession(), token = revision
        let value = try await service.saveSkill(original: original?.name, name: name, description: description,
                                                instructions: instructions, session: session)
        guard catalogIsCurrent(operation, scope: session.scope, token: token) else { throw CancellationError() }
        var fields = value.objectValue ?? [:]
        fields["kind"] = "skill"; fields["name"] = .string(name)
        fields["display_name"] = .string(name); fields["activation_skill"] = .string(name)
        fields["description"] = .string(description); fields["instructions"] = .string(instructions)
        fields["source"] = "personal"; fields["status"] = value["status"] ?? "enabled"
        let item = AgentMarketItem(.object(fields))
        if var next = snapshot {
            if let original { next.skills[original.name] = nil; next.details[original.id] = nil }
            next.skills[name] = item.raw
            try await service.commit(next, operation: operation)
            guard catalogIsCurrent(operation, scope: session.scope, token: token) else { throw CancellationError() }
            snapshot = next
        }
        return item
    }
    func startSourceConnection(_ item: AgentMarketItem, fresh: Bool = false) async throws {
        let key = "auth:" + item.id
        // A fresh retry supersedes a still-held earlier request instead of waiting on it.
        guard fresh || !pending.contains(key) else { return }
        if !fresh, sourceConnection?.id == item.id, sourceAuth?.terminal == false { return }
        let attempt = UUID(); authAttempt = attempt; authAttemptKey = key
        pending.insert(key)
        // Keep the marker only while a newer attempt for the same connector is in flight.
        defer { if authAttempt == attempt || authAttemptKey != key { pending.remove(key) } }
        let session = try await requireSession(), token = revision
        guard let id = item.connectorIDs.first else { throw AgentMCPError.unavailable }
        guard authAttempt == attempt else { throw CancellationError() }
        let connector = snapshot?.connectors?.first { $0["id"]?.stringValue == id }
        if !fresh, let pendingID = connector?["pending_session_id"]?.stringValue {
            sourceConnection = item
            sourceAuth = AgentConnectorSession(["session_id": .string(pendingID), "status":"pending",
                "challenge_kind": connector?["status"] == "pending_approval" ? "external_approval" : "none"])
            return
        }
        let capabilities = (connector?["capabilities"]?.arrayValue ?? [])
            .filter { $0["enabled"]?.boolValue == true }.compactMap { $0["id"]?.stringValue }
        let auth = try await service.startConnector(id, capabilityIDs: capabilities, session: session)
        try Task.checkCancellation()
        guard token == revision, authAttempt == attempt, snapshot?.scope == session.scope else { throw CancellationError() }
        sourceConnection = item; sourceAuth = auth
    }
    func pollSourceConnection() async throws {
        let session = try await requireSession(), token = revision, attempt = authAttempt
        guard let item = sourceConnection, let auth = sourceAuth, !auth.terminal, let id = item.connectorIDs.first else { return }
        let next = try await service.pollConnector(id, auth: auth, session: session)
        guard token == revision, authAttempt == attempt, sourceConnection?.id == item.id, sourceAuth?.id == auth.id,
              sourceAuth?.terminal == false, snapshot?.scope == session.scope else { return }
        sourceAuth = next
    }
    func submitSourceConnection(_ values: [String: String]) async throws {
        let session = try await requireSession(), token = revision, attempt = authAttempt
        guard let item = sourceConnection, let auth = sourceAuth, let id = item.connectorIDs.first else { throw AgentMCPError.unavailable }
        let next = try await service.submitConnector(id, auth: auth, values: values, session: session)
        guard token == revision, authAttempt == attempt, sourceAuth?.id == auth.id,
              snapshot?.scope == session.scope else { throw CancellationError() }
        // A terminal state observed by polling meanwhile wins over a late pending reply.
        if sourceAuth?.terminal == true && !next.terminal { return }
        sourceAuth = next
    }
    func cancelSourceConnection(reset: Bool) async throws {
        let item = sourceConnection
        // Invalidate first: no in-flight start/poll/submit may publish after cancel.
        authAttempt = UUID(); authAttemptKey = nil; sourceAuth = nil; sourceConnection = nil
        pending = pending.filter { !$0.hasPrefix("auth:") }
        if reset, let item, let id = item.connectorIDs.first {
            let session = try await requireSession()
            try await service.disconnectConnector(id, reset: true, session: session)
        }
    }
}
