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

struct AgentConfigView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AgentPreferences.modelKey) private var model = AgentConfig.defaultModel
    @AppStorage(AgentPreferences.systemPromptKey) private var systemPrompt = AgentConfig.defaultSystemPrompt
    @AppStorage(AgentPreferences.thinkingModeKey) private var thinkingRaw = AgentThinkingMode.serverDefault.rawValue
    @AppStorage(AgentPreferences.reasoningEffortKey) private var reasoningEffort = ""
    @AppStorage(AgentPreferences.endpointKey) private var endpoint = AgentConfig.defaultEndpoint.absoluteString

    /// 输入中的 API Key。只在本视图存活期间存在于内存，保存后立刻清空。
    @State private var keyDraft = ""
    @State private var storedKeySuffix: String?
    @State private var errorText: String?
    @State private var savedHint: String?

    private let keychain = AgentKeychain.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    apiKeySection
                    modelSection
                    thinkingSection
                    systemPromptSection
                    endpointSection
                }
                .padding(18)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 460, height: 620)
        .background(AppTheme.windowBackground)
        .onAppear(perform: reloadKeyState)
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
            // 预设 + 自由填写并存：预设覆盖常用情况，自由填写是模型改名时的自救出口。
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
            Text("API Key 仅保存在本机钥匙串；ad-hoc 签名下版本更新后首次读取会弹系统授权，点「始终允许」即可。")
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
        if let key = keychain.readAPIKey(), key.count >= 4 {
            storedKeySuffix = String(key.suffix(4))
        } else {
            storedKeySuffix = keychain.readAPIKey() == nil ? nil : "••••"
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.writeAPIKey(trimmed)
            keyDraft = ""            // 立刻清空明文，别在内存里多留一秒
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
