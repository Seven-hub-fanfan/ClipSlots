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

    // v2.7.0: Slot connection preference
    @State private var enableSlotConnection: Bool

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
        _enableSlotConnection = State(initialValue: UserDefaults.standard.object(forKey: UserPreferenceKeys.enableSlotConnection) == nil
            ? true : UserDefaults.standard.bool(forKey: UserPreferenceKeys.enableSlotConnection))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 20) {
                    appearanceSection
                    slotSection
                    shortcutSection
                    advancedSection
                    notificationPreferencesSection
                    connectionSection
                    helpSection
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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

                shortcutRecorder(title: "保存快捷键", subtitle: "按下组合键，支持槽位编号占位 {n}", text: $saveKey, preview: saveKey.replacingOccurrences(of: "{n}", with: "1"), allowsSlotPlaceholder: true)
                shortcutRecorder(title: "粘贴快捷键", subtitle: "按下组合键，支持槽位编号占位 {n}", text: $pasteKey, preview: pasteKey.replacingOccurrences(of: "{n}", with: "1"), allowsSlotPlaceholder: true)
                shortcutRecorder(title: "圆盘菜单快捷键", subtitle: "默认 Ctrl+Space；按组合键即可修改", text: $radialKey, preview: radialKey, allowsSlotPlaceholder: false)
            }
        }
    }

    private var advancedSection: some View {
        settingsSection(title: "高级", icon: "slider.horizontal.3") {
            settingsToggleRow(
                title: "输出详细日志",
                subtitle: "用于调试保存、粘贴、快捷键注册等问题。",
                isOn: $verbose
            )
        }
    }

    private var notificationPreferencesSection: some View {
        settingsSection(title: "提示与确认", icon: "bell.fill") {
            VStack(spacing: 12) {
                settingsToggleRow(
                    title: "覆盖槽位前询问",
                    subtitle: "保存时若目标槽位已有内容，弹窗确认是否覆盖。",
                    isOn: Binding(
                        get: { !skipOverwriteConfirmation },
                        set: { skipOverwriteConfirmation = !$0 }
                    )
                )

                settingsToggleRow(
                    title: "批量保存前询问",
                    subtitle: "批量保存文件时，弹窗确认保存计划。",
                    isOn: Binding(
                        get: { !skipBatchSaveConfirmation },
                        set: { skipBatchSaveConfirmation = !$0 }
                    )
                )

                settingsToggleRow(title: "保存成功后显示提示", subtitle: "保存 / 覆盖槽位后显示轻提示。", isOn: $showSaveToast)

                settingsToggleRow(title: "复制成功后显示提示", subtitle: "复制槽位内容后显示轻提示。", isOn: $showCopyToast)

                Button("重置提示偏好") {
                    resetNotificationPreferences()
                }
                .controlSize(.small)
            }
        }
    }

    // v2.7.0: Slot connection toggle
    private var connectionSection: some View {
        settingsSection(title: "槽位连接", icon: "point.3.connected.trianglepath.dotted") {
            settingsToggleRow(title: "启用槽位连接", subtitle: "关闭后隐藏连接编辑与串联粘贴；连接数据保留。", isOn: $enableSlotConnection)
        }
    }

    private var helpSection: some View {
        settingsSection(title: "快捷键格式", icon: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                helpRow("修饰键", "cmd, option, ctrl, shift")
                helpRow("普通键", "0-9, a-z, f1-f12, space, tab, 方向键")
                helpRow("槽位占位符", "{n} 代表槽位编号，例如 cmd+{n}。录入保存/粘贴快捷键时按数字键会自动转成 {n}。")
                helpRow("槽位组切换", "Cmd+← → 在当前页面内的槽位组间循环切换")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("恢复默认") { showingResetConfirm = true }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.escape)
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(height: 72)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.elevatedBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.subtleBorder(colorScheme), lineWidth: 1)
        )
    }

    private func shortcutInput(title: String, subtitle: String, placeholder: String, text: Binding<String>, preview: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        HStack(alignment: .top, spacing: 12) {
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

    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 24)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 64, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetDefaults() {
        slots = 9
        saveKey = "cmd+option+{n}"
        pasteKey = "cmd+{n}"
        radialKey = "ctrl+space"
        verbose = true
    }

    private func save() {
        var newConfig = config
        newConfig.slots = Int(slots)
        newConfig.saveKey = HotkeyTemplateNormalizer.normalizedShortcut(saveKey, allowsSlotPlaceholder: true)
        newConfig.pasteKey = HotkeyTemplateNormalizer.normalizedShortcut(pasteKey, allowsSlotPlaceholder: true)
        newConfig.radialKey = HotkeyTemplateNormalizer.normalizedShortcut(radialKey, allowsSlotPlaceholder: false)
        newConfig.verbose = verbose
        newConfig.hotkeyTemplate.kind = hotkeyTemplateKind
        newConfig.save()

        // v2.6.0: persist notification preferences
        UserDefaults.standard.set(skipOverwriteConfirmation, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
        UserDefaults.standard.set(skipBatchSaveConfirmation, forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
        UserDefaults.standard.set(showSaveToast, forKey: UserPreferenceKeys.showSaveToast)
        UserDefaults.standard.set(showCopyToast, forKey: UserPreferenceKeys.showCopyToast)
        UserDefaults.standard.set(enableSlotConnection, forKey: UserPreferenceKeys.enableSlotConnection)

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

// MARK: - v2.7.9 Settings Section Card

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            content
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - v2.7.25 Shortcut Recorder

private func shortcutRecorder(title: String, subtitle: String, text: Binding<String>, preview: String, allowsSlotPlaceholder: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 12) {
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
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        }

        ShortcutCaptureField(shortcut: text, allowsSlotPlaceholder: allowsSlotPlaceholder)
            .frame(height: 38)
    }
}

private struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var shortcut: String
    let allowsSlotPlaceholder: Bool

    func makeNSView(context: Context) -> ShortcutCaptureTextField {
        let field = ShortcutCaptureTextField()
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.backgroundColor = .controlBackgroundColor
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        field.alignment = .left
        field.onShortcut = { value in
            // Only mutate local SettingsView draft binding. This does NOT affect live config.
            shortcut = value
        }
        field.allowsSlotPlaceholder = allowsSlotPlaceholder
        field.stringValue = shortcut
        field.placeholderString = "点击后直接按组合键"
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = true
        return field
    }

    func updateNSView(_ nsView: ShortcutCaptureTextField, context: Context) {
        nsView.allowsSlotPlaceholder = allowsSlotPlaceholder
        if nsView.stringValue != shortcut { nsView.stringValue = shortcut }
    }
}

private final class ShortcutCaptureTextField: NSTextField {
    var onShortcut: ((String) -> Void)?
    var allowsSlotPlaceholder = false
    private var isRecording = false
    private var pendingShortcut: String?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        isRecording = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 7
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        layer?.borderWidth = 0
        return super.resignFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "按下组合键…"
    }
    override func keyDown(with event: NSEvent) {
        let value = Self.shortcutString(from: event, allowsSlotPlaceholder: allowsSlotPlaceholder)
        guard !value.isEmpty else { return }
        stringValue = value
        pendingShortcut = value
        // Important: only update visual text here. Do not call onShortcut yet.
        // Mutating SwiftUI state during keyDown can re-render settings and leak draft
        // shortcuts into active handlers before the user clicks Save.
    }

    override func keyUp(with event: NSEvent) {
        guard let value = pendingShortcut else { return }
        pendingShortcut = nil
        stringValue = value
        onShortcut?(value)
    }

    override func flagsChanged(with event: NSEvent) {
        // Give immediate feedback when user only presses modifiers first.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if !parts.isEmpty { stringValue = parts.joined(separator: "+") + "+…" }
    }

    private static func shortcutString(from event: NSEvent, allowsSlotPlaceholder: Bool) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }

        let key = normalizedKey(event)
        guard !key.isEmpty else { return "" }
        // v2.7.26: for save/paste shortcuts, any letter or number means slot placeholder.
        // Users press cmd+1 or cmd+a to express the slot token; registering a literal
        // number/letter would create one shortcut only and fail for other slots.
        if allowsSlotPlaceholder, key.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil {
            parts.append("{n}")
        } else {
            parts.append(key)
        }
        return parts.joined(separator: "+")
    }

    private static func normalizedKey(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 49: return "space"
        case 48: return "tab"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            return (event.charactersIgnoringModifiers ?? "").lowercased()
        }
    }
}

// MARK: - v2.7.30 Hotkey Normalizer

enum HotkeyTemplateNormalizer {
    static func normalizedShortcut(_ raw: String, allowsSlotPlaceholder: Bool) -> String {
        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        var modifiers: [String] = []
        var key: String?
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": if !modifiers.contains("cmd") { modifiers.append("cmd") }
            case "ctrl", "control", "⌃": if !modifiers.contains("ctrl") { modifiers.append("ctrl") }
            case "option", "opt", "alt", "⌥": if !modifiers.contains("option") { modifiers.append("option") }
            case "shift", "⇧": if !modifiers.contains("shift") { modifiers.append("shift") }
            case "{n}", "n", "数字": key = allowsSlotPlaceholder ? "{n}" : "n"
            default:
                if allowsSlotPlaceholder, p.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil { key = "{n}" } else { key = p }
            }
        }
        let ordered = ["cmd", "ctrl", "option", "shift"].filter { modifiers.contains($0) }
        return (ordered + [key ?? ""]).filter { !$0.isEmpty }.joined(separator: "+")
    }
}
