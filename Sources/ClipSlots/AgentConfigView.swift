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
// v2.17.7：顶部加了"AI 后端"分段，可以在 DeepSeek 与 Tika 间切换。后端偏好写到
// `TikaBackendPreferences.backendKindKey`；保存后 `AgentBackendCoordinator.broadcastChange()`
// 让 `AgentSessionStore` 里的 model 立刻切走，不用重启 App。

struct AgentConfigView: View {
    @Environment(\.dismiss) private var dismiss

    // DeepSeek 相关
    @AppStorage(AgentPreferences.modelKey) private var model = AgentConfig.defaultModel
    @AppStorage(AgentPreferences.systemPromptKey) private var systemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentPreferences.thinkingModeKey) private var thinkingRaw = AgentThinkingMode.serverDefault.rawValue
    @AppStorage(AgentPreferences.reasoningEffortKey) private var reasoningEffort = ""
    @AppStorage(AgentPreferences.endpointKey) private var endpoint = AgentConfig.defaultEndpoint.absoluteString

    // v2.17.7：后端选择
    @AppStorage(TikaBackendPreferences.backendKindKey) private var backendKindRaw = AgentBackendKind.deepseek.rawValue
    @AppStorage(TikaBackendPreferences.tikaAgentIdKey) private var tikaAgentId = ""
    @AppStorage(TikaBackendPreferences.tikaCLIPathKey) private var tikaCLIPath = "tikacli"
    @AppStorage(TikaBackendPreferences.tikaSystemPromptKey) private var tikaSystemPrompt = ""

    /// 输入中的 API Key。只在本视图存活期间存在于内存，保存后立刻清空。
    @State private var keyDraft = ""
    @State private var storedKeySuffix: String?
    @State private var errorText: String?
    @State private var savedHint: String?

    private let keychain = AgentKeychain.shared

    private var currentBackend: AgentBackendKind {
        AgentBackendKind(rawValue: backendKindRaw) ?? .deepseek
    }

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
                    } else {
                        tikaSection
                        tikaSystemPromptSection
                    }
                }
                .padding(18)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 460, height: 640)
        .background(AppTheme.windowBackground)
        .onAppear(perform: reloadKeyState)
        .onChange(of: backendKindRaw) { _ in
            AgentBackendCoordinator.broadcastChange()
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
        section("AI 后端", note: "DeepSeek 走 HTTPS + API Key；Tika 走本机 tikacli 子进程（无需 API Key，先 `tikacli auth login`）。切换后立刻生效。") {
            Picker("", selection: $backendKindRaw) {
                ForEach(AgentBackendKind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var tikaSection: some View {
        section("Tika Agent", note: "在 Tika Space 里预先建好使用 ClipSlots XML 契约的 Agent（参考 docs/tika-agent-system-prompt.md），把它的 agent_id 填在这里。tikacli 用 `tikacli auth login` 完成登录。") {
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
        section("DeepSeek API Key", note: "只写入本机钥匙串（com.clipslots.agent），不进配置文件、不进导出包。") {
            HStack(spacing: 8) {
                SecureField(storedKeySuffix == nil ? "sk-…" : "输入新 Key 可替换", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("保存", action: saveKey)
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 10) {
                if let suffix = storedKeySuffix {
                    Label("已保存 · 末 4 位 \(suffix)", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Button("删除") { deleteKey() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                } else {
                    Label("未配置，无法发起对话", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                Spacer()
                Link("获取 API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    .font(.system(size: 11))
            }

            if let savedHint {
                Text(savedHint).font(.system(size: 11)).foregroundColor(.green)
            }
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundColor(.red)
            }
        }
    }

    private var modelSection: some View {
        section("模型", note: "DeepSeek 的模型名会随代际变化；填错时对话区会提示，可随时改成官方当前在售的名字。") {
            HStack(spacing: 8) {
                TextField("deepseek-reasoner", text: $model)
                    .textFieldStyle(.roundedBorder)
                Menu("预设") {
                    ForEach(AgentConfig.modelPresets) { preset in
                        Button("\(preset.id) — \(preset.note)") { model = preset.id }
                    }
                }
                .frame(width: 76)
            }
        }
    }

    private var thinkingSection: some View {
        section("思考模式", note: "默认「跟随服务端」时请求里完全不带 thinking 字段，兼容性最好；显式开关仅在新一代模型上有意义。") {
            Picker("", selection: $thinkingRaw) {
                ForEach(AgentThinkingMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("推理强度", selection: $reasoningEffort) {
                Text("不指定").tag("")
                Text("low").tag("low")
                Text("high").tag("high")
                Text("max").tag("max")
            }
            .pickerStyle(.segmented)
            .disabled(thinkingRaw == AgentThinkingMode.disabled.rawValue)
        }
    }

    private var systemPromptSection: some View {
        section("System Prompt", note: "决定 Agent 的身份与行为准则，每轮对话都会带上。") {
            TextEditor(text: $systemPrompt)
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
                Button("恢复默认") { systemPrompt = AgentConfig.defaultSystemPrompt }
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

    private func reloadKeyState() {
        // v2.17.6：只读一次钥匙串。旧写法在 else 分支又调了一次 readAPIKey()，
        // 每次刷新面板等于 2 次读取——在 ad-hoc 签名 + 授权 prompt 场景下会翻倍
        // 弹框机率。现在 AgentKeychain 有进程内缓存兑底也不该重复读。
        let key = keychain.readAPIKey()
        if let k = key, k.count >= 4 {
            storedKeySuffix = String(k.suffix(4))
        } else if key != nil {
            storedKeySuffix = "••••"
        } else {
            storedKeySuffix = nil
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.writeAPIKey(trimmed)
            keyDraft = ""
            errorText = nil
            savedHint = "已保存到钥匙串"
            reloadKeyState()
        } catch {
            savedHint = nil
            errorText = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try keychain.deleteAPIKey()
            savedHint = "已从钥匙串删除"
            errorText = nil
            reloadKeyState()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
