import SwiftUI
import ClipSlotsKit

// MARK: - Agent 配置页
//
// 三类设置，存储位置刻意分开：
//   - **API Key → 仅 Keychain**（service com.clipslots.agent / account deepseek_api_key）。
//     这个视图从不把 key 写进 @AppStorage、不打印、不回显原文；已配置时只显示
//     "已保存 · 末 4 位"，因为末 4 位足够让用户确认"是不是我以为的那把"，
//     又不足以被截图泄露。
//   - **模型 / System Prompt / 思考模式 / Endpoint → @AppStorage**（可自定义，用户明确要求）。
//   - Skill 勾选状态在 AgentSkillPickerView 里，同样走 @AppStorage。
//
// 首次打开侧栏若无 key，由侧栏把 `isPresented` 置 true 弹出本页（用户要求的行为）。
//
// 后端选择只通过 AgentBackendCoordinator 读写，设置页和实际调用共享同一作用域。

struct AgentConfigView: View {
    @Environment(\.dismiss) private var dismiss
    var isWorkspace = false

    // DeepSeek 相关
    @AppStorage(AgentPreferences.modelKey) private var model = AgentConfig.defaultModel
    @AppStorage(AgentPreferences.systemPromptKey) private var systemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentPreferences.thinkingModeKey) private var thinkingRaw = AgentThinkingMode.serverDefault.rawValue
    @AppStorage(AgentPreferences.reasoningEffortKey) private var reasoningEffort = ""
    @AppStorage(AgentPreferences.endpointKey) private var endpoint = AgentConfig.defaultEndpoint.absoluteString

    @AppStorage(TikaBackendPreferences.tikaAgentIdKey) private var tikaAgentId = ""
    @AppStorage(TikaBackendPreferences.tikaCLIPathKey) private var tikaCLIPath = "tikacli"
    @AppStorage(TikaBackendPreferences.tikaSystemPromptKey) private var tikaSystemPrompt = ""

    @AppStorage(AgentGatewayPreferences.endpointKey) private var gatewayEndpoint = AgentGatewayPreferences.defaultEndpoint.absoluteString
    @AppStorage(AgentGatewayPreferences.modelKey) private var gatewayModel = AgentGatewayPreferences.defaultModel
    @AppStorage(AgentGatewayPreferences.systemPromptKey) private var gatewaySystemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentGatewayPreferences.thinkingModeKey) private var gatewayThinkingRaw = AgentThinkingMode.serverDefault.rawValue

    /// 输入中的 API Key。只在本视图存活期间存在于内存，保存后立刻清空。
    @State private var keyDraft = ""
    @State private var storedKeySuffix: String?
    @State private var errorText: String?
    @State private var savedHint: String?
    @State private var isKeyBusy = false
    @State private var keyReadFailed = false
    @State private var currentBackend = AgentBackendKind.deepseek
    @State private var showingEnvironment = false

    private var gatewayURL: URL? { AgentGatewayPreferences.endpoint() }
    private var keychain: AgentKeychain? {
        if currentBackend == .deepseek { return AgentKeychain.shared }
        if currentBackend == .gateway, let url = gatewayURL { return AgentGatewayPreferences.keychain(url: url) }
        return nil
    }
    private var credentialScopeID: String {
        currentBackend.rawValue + ":" + (currentBackend == .gateway
            ? gatewayURL.map(AgentGatewayPreferences.credentialAccount(url:)) ?? "invalid" : "")
    }
    private var backendScope: AgentBackendScope { isWorkspace ? .workspace : .sidebar }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    backendSection
                    Divider().opacity(0.3)

                    if currentBackend == .deepseek {
                        apiKeySection
                        modelSection
                        thinkingSection
                        systemPromptSection
                        endpointSection
                    } else if currentBackend == .tika {
                        tikaSection
                        tikaSystemPromptSection
                    } else {
                        gatewaySection
                        apiKeySection
                        modelSection
                        thinkingSection
                        systemPromptSection
                    }
                }
                .padding(18)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 460, height: 640)
        .background(AppTheme.windowBackground)
        .sheet(isPresented: $showingEnvironment) { EnvironmentSetupView() }
        .task(id: isWorkspace) {
            currentBackend = AgentBackendCoordinator.kind(for: backendScope)
        }
        .task(id: credentialScopeID) {
            keyDraft = ""
            savedHint = nil
            storedKeySuffix = nil
            errorText = nil
            keyReadFailed = false
            if currentBackend != .tika { await reloadKeyState() }
        }
        .onChange(of: currentBackend) { kind in
            guard AgentBackendCoordinator.kind(for: backendScope) != kind else { return }
            AgentBackendCoordinator.setKind(kind, for: backendScope)
        }
        .onChange(of: tikaAgentId) { _ in
            if currentBackend == .tika { AgentBackendCoordinator.broadcastChange() }
        }
        .onChange(of: tikaCLIPath) { _ in
            if currentBackend == .tika { AgentBackendCoordinator.broadcastChange() }
        }
        .onChange(of: tikaSystemPrompt) { _ in
            if currentBackend == .tika { AgentBackendCoordinator.broadcastChange() }
        }
        .onChange(of: gatewayEndpoint) { _ in
            if currentBackend == .gateway { AgentBackendCoordinator.broadcastChange() }
        }
        .onChange(of: gatewayModel) { _ in
            if currentBackend == .gateway { AgentBackendCoordinator.broadcastChange() }
        }
        .onChange(of: gatewaySystemPrompt) { _ in
            if currentBackend == .gateway { AgentBackendCoordinator.broadcastChange() }
        }
        .onChange(of: gatewayThinkingRaw) { _ in
            if currentBackend == .gateway { AgentBackendCoordinator.broadcastChange() }
        }
    }

    // MARK: 分段

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text("Agent 设置")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // v2.17.7 新增
    private var backendSection: some View {
        section("AI 后端", note: isWorkspace ? "独立 Agent 页的设置，切换后下一条消息生效。" : "编辑和画布助手的设置，切换后下一条消息生效。") {
            Picker("", selection: $currentBackend) {
                ForEach(AgentBackendKind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isKeyBusy)
        }
    }

    private var gatewaySection: some View {
        section("自建网关地址", note: "可选后端，仅连接你自行部署的 v1 运行网关，不连接 TapNow 私有接口。远程地址必须使用 HTTPS；本机开发允许回环 HTTP。凭据不要填写在地址中。") {
            HStack(spacing: 8) {
                TextField(AgentGatewayPreferences.defaultEndpoint.absoluteString, text: $gatewayEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("默认") { gatewayEndpoint = AgentGatewayPreferences.defaultEndpoint.absoluteString }
                    .controlSize(.small)
            }
            .disabled(isKeyBusy)
            if gatewayURL == nil {
                Label("地址无效，请去掉账号、密码、查询参数和片段", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundColor(.orange)
            }
            Text("支持断线续接、等待确认与远端取消。画布变更先作为提案展示，确认后才应用。")
                .font(.system(size: 11)).foregroundColor(AppTheme.canvasCardMetaInk)
        }
    }

    private var tikaSection: some View {
        section("Tika Agent", note: "在 Tika Space 中配置 Agent 后填入 ID。首次使用可点击「环境检测」自动安装，并通过浏览器登录。") {
            Button { showingEnvironment = true } label: {
                Label("环境检测 · 一键安装与登录", systemImage: "wrench.and.screwdriver")
            }.controlSize(.small)
            HStack(spacing: 8) {
                TextField("Agent ID（例：1509440157188）", text: $tikaAgentId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            HStack(spacing: 8) {
                Text("tikacli 路径")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.canvasCardMetaInk)
                TextField("tikacli", text: $tikaCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("默认") { tikaCLIPath = "tikacli" }
                    .controlSize(.small)
            }
            HStack(spacing: 10) {
                Label(tikaAgentId.isEmpty ? "未配置 Agent ID，将使用 tikacli 默认 Agent"
                                          : "将走 Agent \(tikaAgentId.prefix(16))…",
                      systemImage: tikaAgentId.isEmpty ? "exclamationmark.circle" : "checkmark.seal")
                    .font(.system(size: 11))
                    .foregroundColor(tikaAgentId.isEmpty ? .orange : .green)
                Spacer()
                Link("打开 Tika", destination: URL(string: "https://tika.byteintl.net/")!)
                    .font(.system(size: 11))
            }
        }
    }

    private var tikaSystemPromptSection: some View {
        section("补充系统提示词", note: "Tika Agent 的 instructions 在 Tika Web 里配置；这里仅填写本机额外要求，默认留空。") {
            TextEditor(text: $tikaSystemPrompt)
                .font(.system(size: 12))
                .frame(height: 110)
                .padding(6)
                .background(AppTheme.searchFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.subtleBorder, lineWidth: 1))
        }
    }

    private var apiKeySection: some View {
        section(currentBackend == .gateway ? "网关凭据（可选）" : "DeepSeek API Key",
                note: currentBackend == .gateway
                    ? "仅写入本机钥匙串，按协议、主机和端口独立保存；不会读取或复用 DeepSeek Key。是否需要凭据由你的网关决定。"
                    : "只写入本机钥匙串（com.clipslots.agent），不进配置文件、不进导出包。") {
            HStack(spacing: 8) {
                SecureField(storedKeySuffix == nil ? (currentBackend == .gateway ? "网关访问令牌" : "sk-…") : "输入新 Key 可替换", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("保存", action: saveKey)
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 10) {
                if isKeyBusy {
                    ProgressView().controlSize(.small)
                    Text("正在访问钥匙串…").font(.system(size: 11))
                } else if keyReadFailed {
                    Label("尚未获得钥匙串授权", systemImage: "lock")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Button("重新授权") {
                        Task { await reloadKeyState(retryAfterFailure: true) }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                } else if let suffix = storedKeySuffix {
                    Label(currentBackend == .gateway ? "此网关凭据已保存" : "已保存 · 末 4 位 \(suffix)", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Button("删除") { deleteKey() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                } else {
                    Label(currentBackend == .gateway ? "未保存凭据，可使用允许匿名访问的网关" : "未配置，无法发起对话", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                Spacer()
                if currentBackend == .deepseek {
                    Link("获取 API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                        .font(.system(size: 11))
                }
            }

            if let savedHint {
                Text(savedHint).font(.system(size: 11)).foregroundColor(.green)
            }
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundColor(.red)
            }
        }
        .disabled(isKeyBusy || keychain == nil)
    }

    private var modelSection: some View {
        section("模型", note: currentBackend == .gateway ? "填写自建网关支持的模型标识；default 表示由网关选择默认模型。" : "DeepSeek 的模型名会随代际变化；填错时对话区会提示，可随时改成官方当前在售的名字。") {
            HStack(spacing: 8) {
                TextField(currentBackend == .gateway ? "default" : "deepseek-reasoner",
                          text: currentBackend == .gateway ? $gatewayModel : $model)
                    .textFieldStyle(.roundedBorder)
                if currentBackend == .deepseek { Menu("预设") {
                    ForEach(AgentConfig.modelPresets) { preset in
                        Button("\(preset.id) — \(preset.note)") { model = preset.id }
                    }
                }
                .frame(width: 76) }
            }
        }
    }

    private var thinkingSection: some View {
        section("思考模式", note: currentBackend == .gateway ? "思考策略由网关实现；未支持时应由网关明确拒绝，不改变其他后端设置。" : "默认「跟随服务端」时请求里完全不带 thinking 字段，兼容性最好；显式开关仅在新一代模型上有意义。") {
            Picker("", selection: currentBackend == .gateway ? $gatewayThinkingRaw : $thinkingRaw) {
                ForEach(AgentThinkingMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if currentBackend == .deepseek { Picker("推理强度", selection: $reasoningEffort) {
                Text("不指定").tag("")
                Text("low").tag("low")
                Text("high").tag("high")
                Text("max").tag("max")
            }
            .pickerStyle(.segmented)
            .disabled(thinkingRaw == AgentThinkingMode.disabled.rawValue) }
        }
    }

    private var systemPromptSection: some View {
        section(currentBackend == .gateway ? "系统提示词" : "System Prompt", note: "决定 Agent 的身份与行为准则，每轮对话都会带上。") {
            TextEditor(text: currentBackend == .gateway ? $gatewaySystemPrompt : $systemPrompt)
                .font(.system(size: 12))
                .frame(height: 130)
                .padding(6)
                .background(AppTheme.searchFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.subtleBorder, lineWidth: 1))
            HStack {
                Spacer()
                Button("恢复默认") {
                    if currentBackend == .gateway { gatewaySystemPrompt = AgentConfig.defaultSystemPrompt }
                    else { systemPrompt = AgentConfig.defaultSystemPrompt }
                }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    private var endpointSection: some View {
        section("Endpoint", note: "OpenAI 兼容的 chat completions 地址，一般不用改。") {
            HStack(spacing: 8) {
                TextField(AgentConfig.defaultEndpoint.absoluteString, text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("默认") { endpoint = AgentConfig.defaultEndpoint.absoluteString }
                    .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10))
            Text(currentBackend == .tika
                 ? "Tika 走本机 tikacli，认证与云端调度由 tikacli 自己处理；本 App 不持有任何 Tika 凭据。"
                 : currentBackend == .gateway
                 ? "网关凭据按服务来源独立保存在钥匙串。停止仅在远端明确确认后视为已取消；结果未知时保留续接状态。"
                 : "API Key 仅保存在本机钥匙串；ad-hoc 签名下版本更新后首次读取会弹系统授权，点「始终允许」即可。")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: 构件

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        note: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
            Text(note)
                .font(.system(size: 10))
                .foregroundColor(AppTheme.canvasCardMetaInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Keychain 动作

    @MainActor
    private func reloadKeyState(retryAfterFailure: Bool = false) async {
        guard !isKeyBusy, let keychain else { return }
        let scope = credentialScopeID
        isKeyBusy = true
        defer { isKeyBusy = false }
        let state = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: keychain.keyState(retryAfterFailure: retryAfterFailure))
            }
        }
        guard scope == credentialScopeID else { return }
        applyKeyState(state)
    }

    private func applyKeyState(_ state: AgentKeychainState) {
        storedKeySuffix = state.suffix
        keyReadFailed = state.error != nil
        errorText = state.error?.localizedDescription
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isKeyBusy, let keychain else { return }
        changeKey(hint: "已保存到钥匙串", clearDraft: true) {
            try keychain.writeAPIKey(trimmed)
        }
    }

    private func deleteKey() {
        guard !isKeyBusy, let keychain else { return }
        changeKey(hint: "已从钥匙串删除", clearDraft: false) {
            try keychain.deleteAPIKey()
        }
    }

    private func changeKey(hint: String, clearDraft: Bool, operation: @escaping () throws -> Void) {
        guard let keychain else { return }
        let scope = credentialScopeID
        isKeyBusy = true
        savedHint = nil
        Task { @MainActor in
            let result: Result<AgentKeychainState, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result {
                        try operation()
                        return keychain.keyState()
                    })
                }
            }
            isKeyBusy = false
            guard scope == credentialScopeID else { return }
            switch result {
            case .success(let state):
                if clearDraft { keyDraft = "" }
                applyKeyState(state)
                savedHint = hint
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}
