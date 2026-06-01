import SwiftUI

// MARK: - Settings Section Card (v2.4.3)

private struct SettingsSectionCard<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            content()
        }
        .padding(18)
        .background(AppTheme.settingsCardBackground(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.settingsCardStroke(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Settings Row (v2.4.3)

private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            control()
        }
    }
}

// MARK: - Hotkey Setting Row (v2.4.3)

private struct HotkeySettingRow: View {
    let title: String
    let subtitle: String
    @Binding var value: String
    let preview: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(preview.isEmpty ? "未设置" : preview)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppTheme.settingsBadgeBackground(colorScheme)))
            }

            TextField("", text: $value)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppTheme.settingsInputBackground(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.settingsInputStroke(colorScheme, isFocused: false), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Hotkey Badge (v2.4.3)

private struct HotkeyBadge: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(AppTheme.settingsBadgeBackground(colorScheme)))
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State var config: AppConfig
    var onSave: (AppConfig) -> Void

    @State private var slots: Double
    @State private var saveKey: String
    @State private var pasteKey: String
    @State private var radialKey: String
    @State private var verbose: Bool
    @State private var hotkeyTemplateKind: HotkeyTemplateKind
    @State private var showingResetConfirm = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.system.rawValue

    private var appearanceModeBinding: Binding<ThemeMode> {
        Binding(
            get: { ThemeMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _slots = State(initialValue: Double(config.slots))
        _saveKey = State(initialValue: config.saveKey)
        _pasteKey = State(initialValue: config.pasteKey)
        _radialKey = State(initialValue: config.radialKey)
        _verbose = State(initialValue: config.verbose)
        _hotkeyTemplateKind = State(initialValue: config.hotkeyTemplate.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    appearanceSection
                    slotSection
                    shortcutSection
                    advancedSection
                    hotkeyFormatSection
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }

            Divider()

            settingsFooter
        }
        .background(AppTheme.settingsWindowBackground(colorScheme))
        .frame(width: 680, height: 680)
        .confirmationDialog("恢复默认设置？", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { resetDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("槽位数量、快捷键和日志设置将恢复为默认值。")
        }
    }

    // MARK: - Header (v2.4.3: lighter)

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.brandGradient(colorScheme))
                    .frame(width: 40, height: 40)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("ClipSlots 设置")
                    .font(.system(size: 20, weight: .semibold))
                Text("外观、快捷键和高级选项")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(AppTheme.headerBackground(colorScheme))
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        SettingsSectionCard(icon: "paintbrush.fill", title: "外观") {
            SettingsRow(title: "主题模式", subtitle: "选择浅色、深色或跟随系统") {
                Picker("", selection: appearanceModeBinding) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
    }

    // MARK: - Slot Section

    private var slotSection: some View {
        SettingsSectionCard(icon: "rectangle.stack.fill", title: "槽位") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("槽位数量")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(slots))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppTheme.settingsBadgeBackground(colorScheme)))
                }
                Slider(value: $slots, in: 1...10, step: 1)
                Text("建议设置为 5～9 个槽位。槽位越多，圆盘菜单可读性越低。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Shortcut Section (v2.4.3: restructured)

    private var shortcutSection: some View {
        SettingsSectionCard(
            icon: "keyboard.fill",
            title: "快捷键",
            subtitle: "配置保存、粘贴和圆盘菜单"
        ) {
            VStack(spacing: 14) {
                // Template picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("快捷键模板")
                        .font(.system(size: 13, weight: .medium))
                    Picker("", selection: $hotkeyTemplateKind) {
                        ForEach(HotkeyTemplateKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().opacity(0.45)

                HotkeySettingRow(
                    title: "保存快捷键",
                    subtitle: "将当前剪贴板内容保存到指定槽位",
                    value: $saveKey,
                    preview: saveKey.replacingOccurrences(of: "{n}", with: "1")
                )

                Divider().opacity(0.45)

                HotkeySettingRow(
                    title: "粘贴快捷键",
                    subtitle: "从指定槽位粘贴内容",
                    value: $pasteKey,
                    preview: pasteKey.replacingOccurrences(of: "{n}", with: "1")
                )

                Divider().opacity(0.45)

                HotkeySettingRow(
                    title: "圆盘菜单快捷键",
                    subtitle: "在鼠标位置弹出圆盘选择器",
                    value: $radialKey,
                    preview: radialKey
                )

                Divider().opacity(0.45)

                SettingsRow(
                    title: "槽位组切换",
                    subtitle: "在当前页面内切换上一个 / 下一个槽位组"
                ) {
                    HStack(spacing: 8) {
                        HotkeyBadge("⌘←")
                        HotkeyBadge("⌘→")
                    }
                }
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        SettingsSectionCard(
            icon: "slider.horizontal.3",
            title: "高级",
            subtitle: "调试和诊断选项"
        ) {
            SettingsRow(
                title: "输出详细日志",
                subtitle: "用于调试保存、粘贴、快捷键注册等问题"
            ) {
                Toggle("", isOn: $verbose)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Hotkey Format Help Section

    private var hotkeyFormatSection: some View {
        SettingsSectionCard(
            icon: "info.circle.fill",
            title: "快捷键格式",
            subtitle: "输入快捷键时可使用以下格式"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                FormatRow(label: "修饰键", value: "ctrl, option, cmd, shift")
                FormatRow(label: "普通键", value: "0–9, a–z, f1–f12, space, tab, 方向键")
                FormatRow(label: "槽位占位符", value: "{n} 代表槽位编号，例如 ctrl+{n}")
                FormatRow(label: "槽位组切换", value: "⌘← / ⌘→ 在当前页面内循环切换")
            }
        }
    }

    // MARK: - Footer (v2.4.3: lighter)

    private var settingsFooter: some View {
        HStack {
            Button("恢复默认") { showingResetConfirm = true }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.escape)
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(AppTheme.settingsFooterBackground(colorScheme))
    }

    // MARK: - Helpers (v2.4.3)

    private struct FormatRow: View {
        let label: String
        let value: String

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 76, alignment: .leading)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func resetDefaults() {
        slots = 9
        saveKey = "ctrl+option+{n}"
        pasteKey = "ctrl+{n}"
        radialKey = "ctrl+space"
        verbose = true
    }

    private func save() {
        var newConfig = config
        newConfig.slots = Int(slots)
        newConfig.saveKey = saveKey.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.pasteKey = pasteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.radialKey = radialKey.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.verbose = verbose
        newConfig.hotkeyTemplate.kind = hotkeyTemplateKind
        newConfig.save()
        onSave(newConfig)
        dismiss()
    }
}
