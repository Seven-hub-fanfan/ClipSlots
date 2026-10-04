import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor
final class CodexWorkspaceModel: ObservableObject {
    static let shared = CodexWorkspaceModel()
    struct ModelOption: Identifiable {
        let id: String
        let title: String
        let efforts: [String]
    }
    struct Skill: Identifiable {
        var id: String
        var name: String
        var description: String
        var enabled: Bool
    }
    struct MCP: Identifiable {
        var id: String
        var auth: String
        var toolCount: Int
        var status: String
    }
    @Published private(set) var threads: [CodexThreadSummary] = []
    @Published private(set) var projects: [CodexProject] = []
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var skills: [Skill] = []
    @Published private(set) var skillsCwd: String?
    private var requestedToolsCwd: String?
    @Published private(set) var servers: [MCP] = []
    @Published private(set) var settings = CodexWorkspaceSettings([:])
    @Published private(set) var engineLabel = "正在连接本机 Codex"
    @Published private(set) var enginePath = ""
    @Published private(set) var accountLabel = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingThread = false
    @Published private(set) var toolsBusy = false
    @Published private(set) var lastRefresh: Date?
    @Published var errorText: String?
    @Published var toolsError: String?
    @Published private(set) var projectsBusy = false
    @Published var projectsError: String?
    private var connection: CodexConnection?
    private var fingerprint = ""
    private var connecting: Task<CodexConnection, Error>?
    private var events: Task<Void, Never>?
    private var selectionGeneration = 0

    private var isFixture: Bool {
        ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1"
    }

    private func connect() async throws -> CodexConnection {
        let config = AgentBackendCoordinator.codexConfiguration()
        let attrs = try? FileManager.default.attributesOfItem(atPath: config.executable)
        let key = config.executable + String(describing: attrs?[.modificationDate])
            + String(describing: attrs?[.systemFileNumber])
        if let connection, fingerprint == key { return connection }
        if let connecting { return try await connecting.value }
        if let connection { await connection.server.close() }
        let task = Task { try await CodexConnection.open(config) }
        connecting = task
        defer { connecting = nil }
        let opened = try await task.value
        connection = opened
        fingerprint = key
        enginePath = opened.executable
        events?.cancel()
        events = Task { [weak self] in
            do {
                for try await event in opened.server.events {
                    if let id = event["id"] { try await opened.server.reject(id: id) }
                }
            } catch { }
            if self?.connection?.server === opened.server { self?.connection = nil }
        }
        let version = await AgentProcessRunner.run(executable: opened.executable,
            arguments: ["--version"], timeout: 5, maxOutputBytes: 1000)
        let value = version.succeeded ? version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "版本未知"
        engineLabel = opened.fallbackReason ?? (opened.executable.contains("codex-runtime") ? "内置 · " : "本机 · ") + value
        return opened
    }

    func refresh(chat: AgentChatModel) {
        guard !isFixture, chat.isCodex, !isRefreshing else { return }
        isRefreshing = true
        errorText = nil
        let generation = selectionGeneration
        let conversation = chat.selectedConversationID
        Task {
            defer { isRefreshing = false }
            do {
                let connection = try await connect()
                let server = connection.server
                settings = CodexWorkspaceSettings(try await server.request("config/read", params: ["includeLayers": false]))
                let account = try await server.request("account/read", params: ["refreshToken": false])
                accountLabel = settings.requiresOpenAIAuth
                    ? (account["account"] == .null ? "未登录 · 打开设置连接" : "Codex 已连接")
                    : "\(settings.provider) · 本机配置"
                let latest = try await CodexWorkspaceAPI.threads(server)
                threads = latest
                projects = try await CodexWorkspaceAPI.projects(server, threads: latest)
                let options = try await CodexWorkspaceAPI.pages(server, method: "model/list")
                var choices = options.filter { $0["hidden"]?.boolValue != true }.compactMap { row -> ModelOption? in
                    guard let id = row["model"]?.stringValue else { return nil }
                    return .init(id: id, title: row["displayName"]?.stringValue ?? id,
                        efforts: (row["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue })
                }
                let configured = [settings.model] + latest.filter { $0.provider == settings.provider }.compactMap(\.model)
                for id in configured.reversed() where !id.isEmpty && !choices.contains(where: { $0.id == id }) {
                    choices.insert(.init(id: id, title: id, efforts: ["low", "medium", "high"]), at: 0)
                }
                var seen = Set<String>()
                models = choices.filter { seen.insert($0.id).inserted }
                lastRefresh = Date()
                if let id = chat.codexThreadID, !chat.isRunning,
                   generation == selectionGeneration, conversation == chat.selectedConversationID {
                    loadThread(id, chat: chat)
                }
            } catch {
                errorText = error.localizedDescription
                if let connection { await connection.server.close() }
                connection = nil
            }
        }
    }

    func cancelSelection() {
        selectionGeneration += 1
        isLoadingThread = false
    }

    func loadThread(_ id: String, chat: AgentChatModel) {
        guard !chat.isRunning, !isFixture else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        let conversation = chat.selectedConversationID
        isLoadingThread = true
        errorText = nil
        Task {
            defer { if generation == selectionGeneration { isLoadingThread = false } }
            do {
                let connection = try await connect()
                let (thread, messages) = try await CodexWorkspaceAPI.history(connection.server, id: id)
                guard generation == selectionGeneration, conversation == chat.selectedConversationID, !chat.isRunning else { return }
                chat.openCodexThread(thread, messages: messages)
            } catch {
                if generation == selectionGeneration { errorText = error.localizedDescription }
            }
        }
    }

    func refreshTools(cwd: String) {
        guard !isFixture else { return }
        requestedToolsCwd = cwd
        guard !toolsBusy else { return }
        toolsBusy = true
        toolsError = nil
        Task {
            defer {
                toolsBusy = false
                if let next = requestedToolsCwd, next != cwd { refreshTools(cwd: next) }
            }
            do {
                let connection = try await connect()
                let response = try await connection.server.request("skills/list",
                    params: ["cwds": [.string(cwd)], "forceReload": true])
                guard requestedToolsCwd == cwd else { return }
                var seen = Set<String>()
                skills = (response["data"]?.arrayValue ?? []).flatMap { $0["skills"]?.arrayValue ?? [] }.compactMap {
                    guard let path = $0["path"]?.stringValue, seen.insert(path).inserted else { return nil }
                    return .init(id: path, name: $0["name"]?.stringValue ?? path,
                                 description: $0["description"]?.stringValue ?? "", enabled: $0["enabled"]?.boolValue ?? false)
                }
                skillsCwd = cwd
                let rows = try await CodexWorkspaceAPI.pages(connection.server, method: "mcpServerStatus/list")
                servers = rows.compactMap { row in
                    guard let name = row["name"]?.stringValue else { return nil }
                    let count: Int
                    if case .object(let tools) = row["tools"] { count = tools.count } else { count = 0 }
                    return .init(id: name, auth: row["authStatus"]?.stringValue ?? "unsupported",
                                 toolCount: count, status: row["runtimeStatus"]?["state"]?.stringValue ?? "已配置")
                }
            } catch { toolsError = error.localizedDescription }
        }
    }

    func setSkill(_ skill: Skill, enabled: Bool, cwd: String) {
        guard !toolsBusy else { return }
        toolsBusy = true
        Task {
            do {
                let connection = try await connect()
                _ = try await connection.server.request("skills/config/write", params: ["path": .string(skill.id), "enabled": .bool(enabled)])
                toolsBusy = false
                refreshTools(cwd: cwd)
            } catch { toolsError = error.localizedDescription; toolsBusy = false }
        }
    }

    func authorize(_ server: MCP) {
        guard !toolsBusy else { return }
        toolsBusy = true
        Task {
            defer { toolsBusy = false }
            do {
                let connection = try await connect()
                let result = try await connection.server.request("mcpServer/oauth/login", params: ["name": .string(server.id)])
                guard let raw = result["authorizationUrl"]?.stringValue, let url = URL(string: raw), url.scheme == "https" else {
                    throw CodexServerError("此服务没有提供授权地址，请检查本机 Codex 配置。")
                }
                NSWorkspace.shared.open(url)
            } catch { toolsError = error.localizedDescription }
        }
    }

    func chooseProject(chat: AgentChatModel) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.prompt = "使用此文件夹"
        picker.begin { result in
            guard result == .OK, let url = picker.url else { return }
            self.cancelSelection()
            chat.selectProject(.init(id: url.path, name: url.lastPathComponent, path: url.path, isOfficial: false))
        }
    }

    func reloadProjects() {
        mutateProject { _ in }
    }

    func addProject(name: String, path: String, key: String, completion: @escaping () -> Void) {
        mutateProject { server in
            try await CodexWorkspaceAPI.createProject(server, name: name, path: path, key: key)
            completion()
        }
    }

    func renameProject(_ project: CodexProject, name: String, completion: @escaping () -> Void) {
        mutateProject { server in
            try await CodexWorkspaceAPI.renameProject(server, id: project.id, name: name)
            completion()
        }
    }

    func deleteProject(_ project: CodexProject) {
        mutateProject { server in
            try await CodexWorkspaceAPI.deleteProject(server, id: project.id)
        }
    }

    private func mutateProject(_ action: @escaping (CodexAppServer) async throws -> Void) {
        guard !projectsBusy, !isFixture else { return }
        projectsBusy = true; projectsError = nil
        Task {
            defer { projectsBusy = false }
            do {
                let connection = try await connect()
                try await action(connection.server)
                projects = try await CodexWorkspaceAPI.projects(connection.server, threads: threads)
            } catch {
                projectsError = (error as? CodexServerError)?.isUnsupported == true
                    ? "当前 Codex 引擎未开放项目管理；仍可使用文件夹开始对话。" : error.localizedDescription
            }
        }
    }
}
