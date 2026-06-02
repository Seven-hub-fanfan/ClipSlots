import SwiftUI

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

    // v2.6.0: Notification preferences
    @State private var skipOverwriteConfirmation: Bool
    @State private var skipBatchSaveConfirmation: Bool
    @State private var showSaveToast: Bool
    @State private var showCopyToast: Bool

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
        _skipOverwriteConfirmation = State(initialValue: UserDefaults.standard.skipOverwriteConfirmation)
        _skipBatchSaveConfirmation = State(initialValue: UserDefaults.standard.skipBatchSaveConfirmation)
        _showSaveToast = State(initialValue: UserDefaults.standard.showSaveToast)
        _showCopyToast = State(initialValue: UserDefaults.standard.showCopyToast)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 18) {
                    appearanceSection
                    slotSection
                    shortcutSection
                    advancedSection
                    notificationPreferencesSection
                    helpSection
                }
                .padding(20)
            }

            footer
        }
        .background(AppTheme.windowBackground(colorScheme))
        .confirmationDialog("恢复默认设置？", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { resetDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("槽位数量、快捷键和日志设置将恢复为默认值。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.brandGradient(colorScheme))
                    .frame(width: 38, height: 38)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ClipSlots 设置")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("配置外观、槽位和全局快捷键")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var appearanceSection: some View {
        settingsSection(title: "外观", icon: "paintbrush.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("外观", selection: appearanceModeBinding) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("默认跟随系统设置，也可以强制使用浅色或深色模式。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var slotSection: some View {
        settingsSection(title: "槽位", icon: "rectangle.stack.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("槽位数量")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(slots))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
                }
                Slider(value: $slots, in: 1...10, step: 1)
                Text("建议设置为 5～9 个槽位。槽位越多，圆盘菜单可读性越低。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var shortcutSection: some View {
        settingsSection(title: "快捷键", icon: "keyboard.fill") {
            VStack(spacing: 14) {
                // Template picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("快捷键模板").font(.subheadline)
                    Picker("模板", selection: $hotkeyTemplateKind) {
                        ForEach(HotkeyTemplateKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                shortcutInput(title: "保存快捷键", subtitle: "将当前剪贴板内容保存到指定槽位", placeholder: "ctrl+option+{n}", text: $saveKey, preview: saveKey.replacingOccurrences(of: "{n}", with: "1"))
                shortcutInput(title: "粘贴快捷键", subtitle: "从指定槽位粘贴内容", placeholder: "ctrl+{n}", text: $pasteKey, preview: pasteKey.replacingOccurrences(of: "{n}", with: "1"))
                shortcutInput(title: "圆盘菜单快捷键", subtitle: "在鼠标位置弹出圆盘选择器", placeholder: "ctrl+space", text: $radialKey, preview: radialKey)
            }
        }
    }

    private var advancedSection: some View {
        settingsSection(title: "高级", icon: "slider.horizontal.3") {
            Toggle(isOn: $verbose) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("输出详细日志")
                        .font(.subheadline)
                    Text("用于调试保存、粘贴、快捷键注册等问题。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var notificationPreferencesSection: some View {
        settingsSection(title: "提示与确认", icon: "bell.fill") {
            VStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { !skipOverwriteConfirmation },
                    set: { skipOverwriteConfirmation = !$0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("覆盖槽位前询问")
                            .font(.subheadline)
                        Text("保存时若目标槽位已有内容，弹窗确认是否覆盖。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { !skipBatchSaveConfirmation },
                    set: { skipBatchSaveConfirmation = !$0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("批量保存前询问")
                            .font(.subheadline)
                        Text("批量保存文件时，弹窗确认保存计划。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $showSaveToast) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保存成功后显示提示")
                            .font(.subheadline)
                        Text("保存/覆盖槽位后显示轻提示。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $showCopyToast) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("复制成功后显示提示")
                            .font(.subheadline)
                        Text("复制槽位内容后显示轻提示。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Button("重置提示偏好") {
                    resetNotificationPreferences()
                }
                .controlSize(.small)
            }
        }
    }

    private var helpSection: some View {
        settingsSection(title: "快捷键格式", icon: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                helpRow("修饰键", "ctrl, option, cmd, shift")
                helpRow("普通键", "0-9, a-z, f1-f12, space, tab, 方向键")
                helpRow("槽位占位符", "{n} 代表槽位编号，例如 ctrl+{n}")
                helpRow("槽位组切换", "Cmd+← → 在当前页面内的槽位组间循环切换")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("恢复默认") { showingResetConfirm = true }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.escape)
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.elevatedBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.subtleBorder(colorScheme), lineWidth: 1)
        )
    }

    private func shortcutInput(title: String, subtitle: String, placeholder: String, text: Binding<String>, preview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(preview.isEmpty ? "未设置" : preview)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func helpRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
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

        // v2.6.0: persist notification preferences
        UserDefaults.standard.set(skipOverwriteConfirmation, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
        UserDefaults.standard.set(skipBatchSaveConfirmation, forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
        UserDefaults.standard.set(showSaveToast, forKey: UserPreferenceKeys.showSaveToast)
        UserDefaults.standard.set(showCopyToast, forKey: UserPreferenceKeys.showCopyToast)

        onSave(newConfig)
        dismiss()
    }

    private func resetNotificationPreferences() {
        UserDefaults.standard.removeObject(forKey: UserPreferenceKeys.skipOverwriteConfirmation)
        UserDefaults.standard.removeObject(forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
        UserDefaults.standard.removeObject(forKey: UserPreferenceKeys.showSaveToast)
        UserDefaults.standard.removeObject(forKey: UserPreferenceKeys.showCopyToast)
        skipOverwriteConfirmation = false
        skipBatchSaveConfirmation = false
        showSaveToast = true
        showCopyToast = true
    }
}
