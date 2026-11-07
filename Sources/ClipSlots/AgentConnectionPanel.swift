import SwiftUI
import ClipSlotsKit

@MainActor
final class AgentConnectionController: ObservableObject {
    @Published var provider: AgentAPIProvider?
    @Published var baseURL = ""
    @Published var modelID = ""
    @Published var keyDraft = ""
    @Published var busy = false
    @Published var error: String?
    let scope: AgentBackendScope
    let defaults: UserDefaults
    private let verify: (ModelProfile, String) async throws -> Void
    private let saveKey: (ModelProfile, String) async throws -> Void
    private var task: Task<Void, Never>?

    init(scope: AgentBackendScope, defaults: UserDefaults = .standard,
         verify: @escaping (ModelProfile, String) async throws -> Void = {
             try await AgentProviderTransport(profile: $0).verify(apiKey: $1)
         },
         saveKey: @escaping (ModelProfile, String) async throws -> Void = { profile, key in
             try await Task.detached {
                 try AgentKeychain(service: profile.keyService, account: profile.keyAccount).writeAPIKey(key)
             }.value
         }) {
        self.scope = scope; self.defaults = defaults
        self.verify = verify; self.saveKey = saveKey
    }
    func select(_ provider: AgentAPIProvider) {
        guard !busy else { return }
        self.provider = provider; error = nil; keyDraft = ""
        let saved = AgentConnectionPreferences.profile(scope: scope.rawValue, defaults: defaults)
        if AgentConnectionPreferences.provider(saved) == provider, let saved {
            baseURL = saved.endpoint
            if provider == .gemini { baseURL = baseURL.replacingOccurrences(of: "/models/{model}:generateContent", with: "") }
            modelID = saved.model
        } else {
            baseURL = provider.baseURL
            modelID = provider == .deepseek ? defaults.string(forKey: AgentPreferences.modelKey) ?? AgentConfig.defaultModel : provider.defaultModel
            if provider == .deepseek { baseURL = defaults.string(forKey: AgentPreferences.endpointKey) ?? provider.baseURL }
        }
    }
    func back() { guard !busy else { return }; provider = nil; keyDraft = ""; error = nil }
    func connect(onConnected: @escaping () -> Void) {
        guard let provider, !busy else { return }
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let profile = try provider.profile(baseURL: baseURL, model: modelID)
                var key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    key = try await AgentCredentialAccess.readAPIKey(
                        from: AgentKeychain(service: profile.keyService, account: profile.keyAccount)) ?? ""
                }
                guard !key.isEmpty else { throw ModelWorkspaceError.credential }
                try await verify(profile, key)
                try Task.checkCancellation()
                try await saveKey(profile, key)
                try Task.checkCancellation()
                try AgentConnectionPreferences.save(profile, scope: scope.rawValue, defaults: defaults)
                AgentBackendCoordinator.setKind(.deepseek, for: scope, defaults: defaults)
                keyDraft = ""
                onConnected()
            } catch is CancellationError {
                // View dismissal cancels verification before preferences change.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    func cancel() { task?.cancel(); keyDraft = "" }
}

struct AgentConnectionPanel: View {
    @ObservedObject var connection: AgentConnectionController
    var onConnected: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let provider = connection.provider {
                Button { connection.back() } label: { Label("选择其他 API", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                    .disabled(connection.busy).accessibilityIdentifier("agent-api-back")
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("连接 \(provider.name)").font(.system(size: 24, weight: .medium))
                        Text("填写 API 信息，开始与你的 Agent 对话。")
                            .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if provider != .custom {
                        AgentLineArtwork(mode: provider.rawValue, light: scheme == .light)
                            .frame(width: 138, height: 145).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }.frame(minHeight: provider == .custom ? 72 : 145)
                field("API 地址") {
                    TextField(provider.baseURL.isEmpty ? "https://…" : provider.baseURL, text: $connection.baseURL)
                        .accessibilityIdentifier("agent-api-url")
                }
                field("API Key") {
                    SecureField("填写 API Key；已保存时可留空", text: $connection.keyDraft)
                        .accessibilityIdentifier("agent-api-key")
                }
                field("模型") {
                    TextField("填写模型 ID", text: $connection.modelID)
                        .accessibilityIdentifier("agent-api-model")
                }
                if let error = connection.error {
                    Text(error).font(.system(size: 11)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("agent-api-error")
                }
                Button { connection.connect(onConnected: onConnected) } label: {
                    HStack(spacing: 8) {
                        if connection.busy { ProgressView().controlSize(.small) }
                        Text(connection.busy ? "正在验证连接…" : "连接并开始对话")
                        if !connection.busy { Image(systemName: "arrow.right") }
                    }.font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(TapSkin.ink).foregroundColor(TapSkin.tone(0xfafafa, 0x111111))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(connection.busy)
                    .accessibilityIdentifier("agent-api-connect")
                Text("密钥保存在本机钥匙串。连接时会发送一条简短测试消息。")
                    .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
            } else {
                Text("选择你的 AI").font(.system(size: 26, weight: .medium))
                Text("接入 API，让 Agent 帮你完成创作。")
                    .font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk)
                AgentLineArtwork(mode: "picker", light: scheme == .light) { connection.select($0) }
                    .frame(height: 540)
                    .accessibilityIdentifier("agent-api-brands")
                Button { connection.select(.custom) } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自定义 API").font(.system(size: 12))
                            Text("接入 OpenAI 兼容服务").font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(12).background(TapSkin.tone(0xf9f9f8, 0x191919))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.subtleBorder, lineWidth: 1))
                }.buttonStyle(.plain).accessibilityIdentifier("agent-api-custom")
            }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
            .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
            .onDisappear { connection.cancel() }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk)
            content().textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 12).frame(height: 43)
                .background(TapSkin.tone(0xffffff, 0x191919))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.subtleBorder, lineWidth: 1))
                .disabled(connection.busy)
        }
    }
}

struct AgentConnectionPanelHost: View {
    @StateObject private var connection: AgentConnectionController
    var onConnected: () -> Void
    var editSaved = false
    init(scope: AgentBackendScope, controller: AgentConnectionController? = nil,
         editSaved: Bool = false, onConnected: @escaping () -> Void) {
        _connection = StateObject(wrappedValue: controller ?? AgentConnectionController(scope: scope))
        self.editSaved = editSaved; self.onConnected = onConnected
    }
    var body: some View {
        AgentConnectionPanel(connection: connection, onConnected: onConnected)
            .onAppear {
                if editSaved, connection.provider == nil,
                   let provider = AgentConnectionPreferences.provider(
                    AgentConnectionPreferences.profile(scope: connection.scope.rawValue, defaults: connection.defaults)) {
                    connection.select(provider)
                }
            }
    }
}
