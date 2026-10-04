import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor
final class CodexAccountModel: ObservableObject {
    static let shared = CodexAccountModel()
    struct ModelOption: Identifiable {
        var id: String
        var title: String
        var efforts: [String]
    }
    @Published var accountLabel = "尚未检查登录状态"
    @Published var isAuthenticated = false
    @Published var isBusy = false
    @Published var isLoggingIn = false
    @Published var errorText: String?
    @Published var models: [ModelOption] = []
    @Published var loginURL: URL?
    private var loginID: String?
    private var server: CodexAppServer?
    private var serverPath: String?
    private var serverStamp: String?
    private var eventTask: Task<Void, Never>?

    private func connect() async throws -> CodexAppServer {
        let configuration = AgentBackendCoordinator.codexConfiguration()
        let stamp = String(describing: try? FileManager.default.attributesOfItem(atPath: configuration.executable)[.modificationDate])
        if let server, serverPath == configuration.executable, serverStamp == stamp { return server }
        if let server { await server.close() }
        eventTask?.cancel()
        let opened = try await CodexConnection.open(configuration)
        let connection = opened.server
        server = connection
        serverPath = configuration.executable
        serverStamp = stamp
        eventTask = Task { [weak self] in
            do {
                for try await event in connection.events {
                    guard let self else { return }
                    let method = event["method"]?.stringValue ?? ""
                    let params = event["params"] ?? [:]
                    if method == "account/login/completed",
                       params["loginId"]?.stringValue == self.loginID {
                        self.isLoggingIn = false
                        self.loginURL = nil
                        self.loginID = nil
                        if params["success"]?.boolValue == true {
                            try await self.readAccount(connection)
                        } else {
                            self.errorText = params["error"]?.stringValue ?? "登录未完成，请重试。"
                        }
                    } else if let id = event["id"] {
                        try await connection.reject(id: id)
                    }
                }
            } catch {
                guard let self else { return }
                self.errorText = error.localizedDescription
            }
            guard let self, self.server === connection else { return }
            self.server = nil
            self.isLoggingIn = false
        }
        return connection
    }

    private func readAccount(_ connection: CodexAppServer) async throws {
        let result = try await connection.request("account/read", params: ["refreshToken": false])
        let account = result["account"]
        let settings = CodexWorkspaceSettings(try await connection.request("config/read", params: ["includeLayers": false]))
        isAuthenticated = account != nil && account != .null
        if !settings.requiresOpenAIAuth {
            accountLabel = "\(settings.provider) · 使用本机配置"
        } else if account?["type"]?.stringValue == "chatgpt" {
            accountLabel = "ChatGPT · " + (account?["planType"]?.stringValue ?? "已登录")
        } else {
            accountLabel = isAuthenticated ? "OpenAI API Key · 已登录" : "尚未登录 Codex"
        }
        var choices: [ModelOption] = []
        var cursor: String?
        for _ in 0..<10 {
            var parameters: [String: JSONValue] = ["limit": 100]
            if let cursor { parameters["cursor"] = .string(cursor) }
            let catalog = try await connection.request("model/list", params: .object(parameters))
            choices += (catalog["data"]?.arrayValue ?? []).filter { $0["hidden"]?.boolValue != true }.compactMap { item in
                guard let id = item["model"]?.stringValue else { return nil }
                return ModelOption(id: id, title: item["displayName"]?.stringValue ?? id,
                    efforts: (item["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue })
            }
            cursor = catalog["nextCursor"]?.stringValue
            if cursor == nil { break }
        }
        if !settings.model.isEmpty, !choices.contains(where: { $0.id == settings.model }) {
            choices.insert(.init(id: settings.model, title: settings.model, efforts: ["low", "medium", "high"]), at: 0)
        }
        models = choices
    }

    func refresh() {
        perform { connection in try await self.readAccount(connection) }
    }

    func login(apiKey: String? = nil) {
        guard !isLoggingIn else { return }
        perform { connection in
            let params: JSONValue = apiKey.map { ["type": "apiKey", "apiKey": .string($0)] } ?? ["type": "chatgpt"]
            let result = try await connection.request("account/login/start", params: params)
            if apiKey != nil {
                try await self.readAccount(connection)
            } else {
                guard let raw = result["authUrl"]?.stringValue, let url = URL(string: raw),
                      url.scheme == "https", let id = result["loginId"]?.stringValue else {
                    throw CodexServerError("Codex 没有返回有效的登录地址。")
                }
                self.loginID = id
                self.loginURL = url
                self.isLoggingIn = true
                NSWorkspace.shared.open(url)
            }
        }
    }

    func cancelLogin() {
        guard let loginID else { return }
        perform { connection in
            _ = try await connection.request("account/login/cancel", params: ["loginId": .string(loginID)])
            self.loginID = nil
            self.loginURL = nil
            self.isLoggingIn = false
        }
    }

    private func perform(_ action: @escaping (CodexAppServer) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            defer { isBusy = false }
            do { try await action(connect()) }
            catch {
                errorText = error.localizedDescription
                if let server { await server.close() }
                server = nil
                isLoggingIn = false
            }
        }
    }
}

struct CodexAccountView: View {
    @ObservedObject private var account = CodexAccountModel.shared
    @AppStorage(CodexPreferences.cliPathKey) private var path = ""
    @AppStorage(CodexPreferences.modelKey) private var model = ""
    @AppStorage(CodexPreferences.effortKey) private var effort = ""
    @State private var keyDraft = ""
    @State private var showAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接 Codex").font(.system(size: 16, weight: .semibold))
            Text("跟随本机 Codex 的模型服务配置，也可连接 ChatGPT 或 OpenAI API。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Image(systemName: account.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundColor(account.isAuthenticated ? .green : .secondary)
                Text(account.accountLabel).font(.system(size: 12))
                Spacer()
                if account.isBusy { ProgressView().controlSize(.small) }
                Button("刷新") { account.refresh() }.controlSize(.small).disabled(account.isBusy)
            }
            HStack {
                Button(account.isAuthenticated ? "重新登录 ChatGPT" : "登录 ChatGPT") { account.login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy || account.isLoggingIn)
                if account.isLoggingIn {
                    Button("取消") { account.cancelLogin() }.disabled(account.isBusy)
                }
            }
            if let url = account.loginURL {
                Link("继续在浏览器完成登录", destination: url).font(.system(size: 12))
            }
            DisclosureGroup("使用 OpenAI API Key", isExpanded: $showAPIKey) {
                HStack {
                    SecureField("输入 API Key", text: $keyDraft).textFieldStyle(.roundedBorder)
                    Button("连接") {
                        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyDraft = ""
                        account.login(apiKey: key)
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isBusy || account.isLoggingIn)
                }.padding(.top, 8)
            }.font(.system(size: 12))
            Divider()
            Text("模型").font(.system(size: 12, weight: .semibold))
            HStack {
                TextField("自动 · Codex 默认模型", text: $model).textFieldStyle(.roundedBorder)
                Menu("选择") {
                    Button("自动") { model = ""; effort = "" }
                    ForEach(account.models) { option in
                        Button(option.title) { model = option.id; effort = "" }
                    }
                }.frame(width: 76)
            }
            Picker("推理强度", selection: $effort) {
                Text("默认").tag("")
                ForEach(account.models.first(where: { $0.id == model })?.efforts ?? ["low", "medium", "high"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            DisclosureGroup("运行程序") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("留空跟随桌面 Codex，不可用时回退内置版本", text: $path).textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Text(CodexPreferences.executable(customPath: path) ?? "未找到 Codex，请指定程序路径。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }.padding(.top, 8)
            }.font(.system(size: 12))
            if let error = account.errorText {
                Text(error).font(.system(size: 11)).foregroundColor(.orange).textSelection(.enabled)
            }
            Text("认证由官方 Codex 按本机配置管理。槽位操作使用 ClipSlots 工具；终端权限可在输入框下方选择。桌面引擎更新在下一次连接生效，界面功能由 ClipSlots 更新提供。")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { account.refresh() }
        .onChange(of: path) { _ in AgentBackendCoordinator.broadcastChange() }
    }
}
