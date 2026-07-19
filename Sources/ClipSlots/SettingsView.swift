import SwiftUI
import ClipSlotsKit

// v2.9.12: in-app settings categories for the Obsidian-style two-pane layout.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, slot, shortcut, notification, connection, advanced, cli

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .slot: return "槽位"
        case .shortcut: return "快捷键"
        case .notification: return "提示与确认"
        case .connection: return "槽位连接"
        case .advanced: return "高级"
        case .cli: return "命令行工具"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .slot: return "rectangle.stack.fill"
        case .shortcut: return "keyboard.fill"
        case .notification: return "bell.fill"
        case .connection: return "point.3.connected.trianglepath.dotted"
        case .advanced: return "slider.horizontal.3"
        case .cli: return "terminal.fill"
        }
    }
}

struct SettingsView: View {
    @State var config: AppConfig
    var onSave: (AppConfig) -> Void
    // v2.9.12: optional close handler used by the in-app overlay presentation.
    // Falls back to the SwiftUI dismiss action when nil (legacy window path).
    var onClose: (() -> Void)? = nil
    // v2.9.17: open the independent plugin marketplace popover from the sidebar.
    // The marketplace stays a separate floating layer (not embedded here).
    var onOpenPlugins: (() -> Void)? = nil
    @State private var selectedCategory: SettingsCategory = .appearance

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

    // v2.9.6: CLI install management
    @StateObject private var cliManager = CLIInstallManager()

    // v2.9.46: Agent Skill 安装管理 + 卸载 App
    @StateObject private var skillManager = AgentSkillInstallManager()
    @StateObject private var appUninstaller = AppUninstaller()
    @State private var showUninstallSheet = false
    @State private var uninstallDeleteData = true
    @State private var uninstallRemoveCLI = true
    @State private var uninstallRemoveSkills = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    // v2.7.47: align Settings with first-launch default dark mode.
    // Existing persisted appearanceMode remains unchanged.
    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.dark.rawValue

    private var appearanceModeBinding: Binding<ThemeMode> {
        Binding(
            get: { ThemeMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void, onClose: (() -> Void)? = nil, onOpenPlugins: (() -> Void)? = nil) {
        AppearanceDefaults.ensureDefaultDarkIfNeeded()
        self.config = config
        self.onSave = onSave
        self.onClose = onClose
        self.onOpenPlugins = onOpenPlugins
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
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                overlayHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sectionContent(for: selectedCategory)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.windowBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.subtleBorder(colorScheme), lineWidth: 1)
        )
        .onAppear {
            cliManager.refreshState()
            skillManager.refresh()
        }
        .sheet(isPresented: $showUninstallSheet) {
            uninstallConfirmSheet
        }
        .confirmationDialog("恢复默认设置？", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { resetDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("槽位数量、快捷键和日志设置将恢复为默认值。")
        }
    }

    // v2.9.12: left category navigation sidebar (Obsidian-style).
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.brandGradient(colorScheme))
                        .frame(width: 32, height: 32)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClipSlots")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("设置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(SettingsCategory.allCases) { category in
                sidebarRow(category)
            }

            // v2.9.17: plugin marketplace entry — placed after 高级/命令行工具.
            // Clicking it opens the independent marketplace popover; it does NOT
            // embed into the settings window.
            Divider()
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            pluginMarketRow

            Spacer()
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(AppTheme.elevatedBackground(colorScheme))
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            // v2.9.13: make the entire row (incl. blank area right of the text)
            // clickable, not just the text/icon glyphs.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // v2.9.17: special sidebar entry that launches the plugin marketplace popover.
    private var pluginMarketRow: some View {
        Button {
            onOpenPlugins?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text("插件市场")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help("打开插件市场（独立弹窗）")
    }

    // v2.9.12: content header with the × close button (no window titlebar).
    private var overlayHeader: some View {
        HStack {
            Text(selectedCategory.title)
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button { closeAction() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(AppTheme.chipBackground(colorScheme))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func sectionContent(for category: SettingsCategory) -> some View {
        switch category {
        case .appearance: appearanceSection
        case .slot: slotSection
        case .shortcut:
            shortcutSection
            helpSection
        case .notification: notificationPreferencesSection
        case .connection: connectionSection
        case .advanced: advancedSection
        case .cli:
            cliSection
            agentSkillSection
            uninstallAppSection
        }
    }

    // v2.9.12: unified close that prefers the in-app overlay handler.
    private func closeAction() {
        if let onClose {
            onClose()
        } else {
            dismiss()
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
                Text("首次安装默认使用深色模式；也可以改为浅色或跟随系统。")
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

    // v2.9.6: CLI install management
    private var cliSection: some View {
        settingsSection(title: "命令行工具 (CLI)", icon: "terminal.fill") {
            VStack(alignment: .leading, spacing: 12) {
                // Status row
                HStack(spacing: 10) {
                    Circle()
                        .fill(cliStatusColor)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cliStatusTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(cliStatusSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }

                Text("安装后可在终端或智能体中直接调用 `clipslots` 命令，路径为 \(CLIInstallManager.targetPath)。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Action buttons
                HStack(spacing: 10) {
                    Button(action: { cliManager.install() }) {
                        Label(cliPrimaryButtonTitle, systemImage: cliPrimaryButtonIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cliManager.isBusy)

                    if cliIsInstalled {
                        Button(role: .destructive, action: { cliManager.uninstall() }) {
                            Label("卸载 CLI", systemImage: "trash")
                        }
                        .disabled(cliManager.isBusy)
                    }

                    if cliManager.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if let message = cliManager.lastMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(cliManager.lastMessageIsError ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cliIsInstalled: Bool {
        switch cliManager.state {
        case .notInstalled: return false
        case .installed, .outdated: return true
        }
    }

    private var cliStatusColor: Color {
        switch cliManager.state {
        case .notInstalled: return .secondary
        case .installed: return .green
        case .outdated: return .orange
        }
    }

    private var cliStatusTitle: String {
        switch cliManager.state {
        case .notInstalled: return "未安装"
        case .installed(let version): return "已安装 · v\(version)"
        case .outdated(let installed, _): return "已安装（旧版本 v\(installed)）"
        }
    }

    private var cliStatusSubtitle: String {
        switch cliManager.state {
        case .notInstalled:
            return "尚未安装命令行工具。"
        case .installed:
            return CLIInstallManager.targetPath
        case .outdated(_, let bundled):
            return "可更新至 v\(bundled)"
        }
    }

    private var cliPrimaryButtonTitle: String {
        switch cliManager.state {
        case .notInstalled: return "安装 CLI"
        case .installed: return "重新安装 CLI"
        case .outdated: return "更新 CLI"
        }
    }

    private var cliPrimaryButtonIcon: String {
        switch cliManager.state {
        case .notInstalled: return "arrow.down.circle"
        case .installed: return "arrow.clockwise"
        case .outdated: return "arrow.up.circle"
        }
    }

    // MARK: - v2.9.46 Agent Skill 卡片

    private var agentSkillSection: some View {
        settingsSection(title: "Agent Skill", icon: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 12) {
                let installed = skillManager.agentsWithSkillInstalled

                // 状态行（绿点 + 安装数量 + 版本）
                HStack(spacing: 10) {
                    Circle()
                        .fill(installed.isEmpty ? Color.secondary : Color.green)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installed.isEmpty ? "未安装" : "已安装 · \(installed.count) 个 Agent")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(skillManager.bundledSkillVersionInfo.map { "当前 Skill 版本：\($0)" } ?? "未能读取内置 Skill 版本")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }

                // 已安装 Agent 列表（绿点 + 路径）
                if !installed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(installed) { agent in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(agent.displayName)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(agent.skillTargetPath)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.leading, 2)
                }

                Text("把 ClipSlots 使用说明（SKILL.md）安装到本机 Agent，供智能体理解 `clipslots` CLI 的用法。重新安装会用 App 内最新内容覆盖各 Agent 的 skill 目录。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 操作按钮
                HStack(spacing: 10) {
                    Button(action: { skillManager.reinstallSkillByOverwrite() }) {
                        Label("重新安装 Skill", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(skillManager.busyAgentID != nil)

                    if !installed.isEmpty {
                        Button(role: .destructive, action: { skillManager.uninstallSkillFromAllAgents() }) {
                            Label("卸载 Skill", systemImage: "trash")
                        }
                        .disabled(skillManager.busyAgentID != nil)
                    }
                    Spacer()
                }

                if let message = skillManager.lastMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(skillManager.lastMessageIsError ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - v2.9.46 卸载 App（危险区域）

    private var uninstallAppSection: some View {
        settingsSection(title: "卸载 ClipSlots", icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("卸载会把 ClipSlots 移入废纸篓，并可选清理槽位数据、CLI 与 Agent Skill。此操作不可恢复。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(role: .destructive) {
                        showUninstallSheet = true
                    } label: {
                        Label("卸载 ClipSlots", systemImage: "trash.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(appUninstaller.isBusy)

                    if appUninstaller.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
        }
    }

    // v2.9.46: 卸载确认弹窗
    private var uninstallConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("确认卸载 ClipSlots？")
                    .font(.system(size: 17, weight: .bold))
                Text("此操作不可恢复，请谨慎选择。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("同时删除所有槽位数据（删除 App 数据目录）", isOn: $uninstallDeleteData)
                Toggle("同时卸载 CLI（删除 \(CLIInstallManager.targetPath)）", isOn: $uninstallRemoveCLI)
                Toggle("同时卸载所有 Agent Skill（删除各 Agent skill 目录）", isOn: $uninstallRemoveSkills)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("取消") { showUninstallSheet = false }
                    .keyboardShortcut(.escape)
                Button(role: .destructive) {
                    showUninstallSheet = false
                    appUninstaller.performUninstall(
                        deleteData: uninstallDeleteData,
                        uninstallCLI: uninstallRemoveCLI,
                        uninstallSkills: uninstallRemoveSkills,
                        skillManager: skillManager
                    )
                } label: {
                    Text("确认卸载")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 440)
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
            Button("取消") { closeAction() }
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
                    // v2.9.18: 快捷键预览由 11pt 提升到 12pt（保留 monospaced 以对齐键位显示），改善可读。
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
        slots = 10
        saveKey = "option+{n}"
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
        closeAction()
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
                // v2.9.18: 快捷键预览由 11pt 提升到 12pt（保留 monospaced 以对齐键位显示），改善可读。
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        }

        ShortcutCaptureField(shortcut: text, allowsSlotPlaceholder: allowsSlotPlaceholder)
            .frame(height: 38)
            .overlay(alignment: .trailing) {
                Text("录入后需点击右下角「保存」才生效")
                    // v2.9.18: 9pt 提示字上调到 AppTheme.Fonts.footnote（12pt），提升到可读范围。
                    .font(AppTheme.Fonts.footnote)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                    .allowsHitTesting(false)
            }
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
        // v2.7.33: Do not overwrite the recorder display while it is focused.
        // SwiftUI updateNSView was resetting "ctrl+option+{n}" back to the old
        // binding during modifier/key transitions, making it look unsaved.
        guard !nsView.isRecording else { return }
        if nsView.stringValue != shortcut { nsView.stringValue = shortcut }
    }
}

private final class ShortcutCaptureTextField: NSTextField {
    var onShortcut: ((String) -> Void)?
    var allowsSlotPlaceholder = false
    var isRecording = false
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
        pendingShortcut = nil
        onShortcut?(value)
    }

    override func keyUp(with event: NSEvent) {
        // v2.7.31: no-op. Some key combinations never deliver keyUp to NSTextField
        // reliably while modifiers are involved, which made shortcut saving impossible.
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
