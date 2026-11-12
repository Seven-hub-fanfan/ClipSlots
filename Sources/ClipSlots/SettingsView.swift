import SwiftUI
import ClipSlotsKit

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, slot, shortcut, permission, notification, connection, advanced, cli
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .slot: return "槽位"
        case .shortcut: return "快捷键"
        case .permission: return "系统权限"
        case .notification: return "提示与确认"
        case .connection: return "槽位连接"
        case .advanced: return "高级"
        case .cli: return "命令行工具"
        }
    }
    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .slot: return "square.stack"
        case .shortcut: return "keyboard"
        case .permission: return "lock.shield"
        case .notification: return "bell"
        case .connection: return "point.3.connected.trianglepath.dotted"
        case .advanced: return "slider.horizontal.3"
        case .cli: return "terminal"
        }
    }
}

/// All editable preferences are a draft. Appearance and language preview live,
/// then roll back on every dismissal path unless the user saves.
struct SettingsView: View {
    @State var config: AppConfig
    var onSave: (AppConfig) -> Void
    var onClose: (() -> Void)?
    var onOpenPlugins: (() -> Void)?
    @State private var selectedCategory: SettingsCategory
    @State private var slots: Int
    @State private var saveKey: String
    @State private var pasteKey: String
    @State private var radialKey: String
    @State private var verbose: Bool
    @State private var undoSteps: Int
    @State private var cacheBudgetMiB: Int
    @State private var attachmentWarningCount: Int
    @State private var undoDiskBytes: Int64?
    @State private var hotkeyTemplateKind: HotkeyTemplateKind
    @State private var skipOverwriteConfirmation: Bool
    @State private var skipBatchSaveConfirmation: Bool
    @State private var showSaveToast: Bool
    @State private var showCopyToast: Bool
    @State private var enableSlotConnection: Bool
    @State private var saved = false
    @State private var originalAppearance: String
    @State private var originalLanguage: String
    @StateObject private var cliManager = CLIInstallManager()
    @StateObject private var skillManager = AgentSkillInstallManager()
    @StateObject private var appUninstaller = AppUninstaller()
    @State private var showUninstallSheet = false
    @State private var uninstallDeleteData = false
    @State private var uninstallRemoveCLI = true
    @State private var uninstallRemoveSkills = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearanceMode") private var appearanceRaw = ThemeMode.light.rawValue
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void,
         onClose: (() -> Void)? = nil, onOpenPlugins: (() -> Void)? = nil,
         initialCategory: SettingsCategory = .appearance) {
        AppearanceDefaults.ensureDefaultLightIfNeeded()
        self.config = config
        self.onSave = onSave
        self.onClose = onClose
        self.onOpenPlugins = onOpenPlugins
        _selectedCategory = State(initialValue: initialCategory)
        _slots = State(initialValue: config.slots)
        _saveKey = State(initialValue: config.saveKey)
        _pasteKey = State(initialValue: config.pasteKey)
        _radialKey = State(initialValue: config.radialKey)
        _verbose = State(initialValue: config.verbose)
        _undoSteps = State(initialValue: SlotUndoStack.clampLimit(config.undoSteps))
        _cacheBudgetMiB = State(initialValue: config.cacheBudgetMiB)
        _attachmentWarningCount = State(initialValue: config.attachmentWarningCount)
        _hotkeyTemplateKind = State(initialValue: config.hotkeyTemplate.kind)
        let defaults = UserDefaults.standard
        _skipOverwriteConfirmation = State(initialValue: defaults.skipOverwriteConfirmation)
        _skipBatchSaveConfirmation = State(initialValue: defaults.skipBatchSaveConfirmation)
        _showSaveToast = State(initialValue: defaults.showSaveToast)
        _showCopyToast = State(initialValue: defaults.showCopyToast)
        _enableSlotConnection = State(initialValue: defaults.object(forKey: UserPreferenceKeys.enableSlotConnection) == nil
            || defaults.bool(forKey: UserPreferenceKeys.enableSlotConnection))
        _originalAppearance = State(initialValue: defaults.string(forKey: "appearanceMode") ?? ThemeMode.light.rawValue)
        _originalLanguage = State(initialValue: defaults.string(forKey: AppInterfaceLanguage.preferenceKey)
            ?? AppInterfaceLanguage.chinese.rawValue)
    }

    private var hasChanges: Bool {
        slots != config.slots || saveKey != config.saveKey || pasteKey != config.pasteKey
            || radialKey != config.radialKey || verbose != config.verbose
            || undoSteps != config.undoSteps || cacheBudgetMiB != config.cacheBudgetMiB
            || attachmentWarningCount != config.attachmentWarningCount
            || hotkeyTemplateKind != config.hotkeyTemplate.kind
            || appearanceRaw != originalAppearance || languageRaw != originalLanguage
            || skipOverwriteConfirmation != UserDefaults.standard.skipOverwriteConfirmation
            || skipBatchSaveConfirmation != UserDefaults.standard.skipBatchSaveConfirmation
            || showSaveToast != UserDefaults.standard.showSaveToast
            || showCopyToast != UserDefaults.standard.showCopyToast
            || enableSlotConnection != (UserDefaults.standard.object(forKey: UserPreferenceKeys.enableSlotConnection) == nil
                || UserDefaults.standard.bool(forKey: UserPreferenceKeys.enableSlotConnection))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    AppLocalizedText(selectedCategory.title).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button(action: closeAction) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .localizedAccessibilityLabel("关闭")
                    .accessibilityIdentifier("settings-close")
                }
                .padding(.horizontal, 28).frame(height: 76)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { sectionContent }
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 2)
                }
                .id(selectedCategory)
                Divider()
                footer
            }
        }
        .font(.system(size: 13))
        .buttonStyle(CompactActionStyle())
        .controlSize(.regular)
        .tint(scheme == .dark ? Color(white: 0.78) : Color(white: 0.28))
        .background(AppTheme.windowBackground(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(AppTheme.subtleBorder(scheme), lineWidth: 1))
        .onDisappear { restorePreview() }
        .sheet(isPresented: $showUninstallSheet) { uninstallConfirmSheet }
        .perfCount("SettingsView.body")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            AppLocalizedText("设置").font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 22)
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    selectedCategory = category
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.icon).font(.system(size: 14, weight: .medium)).frame(width: 20)
                        AppLocalizedText(category == .permission ? "权限" : category.title)
                            .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Color.primary.opacity(selectedCategory == category ? 0.07 : 0),
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 10)
                .accessibilityIdentifier("settings-category-\(category.rawValue)")
                .accessibilityAddTraits(selectedCategory == category ? [.isSelected] : [])
            }
            Divider().padding(.horizontal, 22).padding(.vertical, 12)
            Button { onOpenPlugins?() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").frame(width: 20)
                    AppLocalizedText("插件")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                .padding(.horizontal, 22).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary)
            Spacer()
            Text("ClipSlots  \(AppVersion.current)").font(.system(size: 12)).foregroundColor(.secondary).padding(22)
        }
        .frame(width: 188).frame(maxHeight: .infinity)
        .background(AppTheme.elevatedBackground(scheme))
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedCategory {
        case .appearance: appearanceSection
        case .slot: slotSection
        case .shortcut: shortcutSection
        case .permission: PermissionSettingsSection()
        case .notification: notificationSection
        case .connection: connectionSection
        case .advanced: advancedSection
        case .cli: cliSection
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "主题") {
                HStack(spacing: 12) {
                    ForEach(ThemeMode.allCases) { mode in appearanceChoice(mode) }
                }.padding(16)
            }
            SettingsGroup(title: "语言") {
                SettingsRow("界面语言") {
                    Picker(localized: "界面语言", selection: $languageRaw) {
                        ForEach(AppInterfaceLanguage.allCases) { language in
                            Text(verbatim: language.nativeTitle).tag(language.rawValue)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 208)
                        .accessibilityIdentifier("settings-interface-language")
                }
            }
        }
    }

    private func appearanceChoice(_ mode: ThemeMode) -> some View {
        let selected = appearanceRaw == mode.rawValue
        let dark = mode == .dark
        return Button { appearanceRaw = mode.rawValue } label: {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    VStack(spacing: 7) {
                        ForEach(0..<3) { _ in
                            Capsule().fill(Color(white: dark ? 0.34 : 0.77)).frame(height: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8).frame(width: 32).background(Color(white: dark ? 0.19 : 0.92))
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Color(white: dark ? 0.5 : 0.7)).frame(width: 32, height: 5)
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: dark ? 0.23 : 0.9))
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: dark ? 0.23 : 0.9))
                    }.padding(10)
                }
                .frame(height: 82)
                .background(mode == .system ? AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.15)],
                    startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color(white: dark ? 0.12 : 0.99)))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected ? .primary : .secondary)
                    AppLocalizedText(mode.title)
                }.font(.system(size: 13, weight: selected ? .medium : .regular))
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(Color.primary.opacity(selected ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(selected ? 0.45 : 0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("settings-appearance-\(mode.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "容量") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        AppLocalizedText("槽位数量")
                        Spacer()
                        AppLocalizedText("%ld 个槽位", slots).foregroundColor(.secondary).monospacedDigit()
                    }
                    HStack(spacing: 5) {
                        ForEach(1...10, id: \.self) { count in
                            Button { slots = count } label: {
                                Text(String(format: "%02d", count)).monospacedDigit().frame(maxWidth: .infinity)
                            }
                            .buttonStyle(CompactActionStyle(selected: slots == count, iconOnly: true))
                            .accessibilityIdentifier("settings-slot-count-\(count)")
                            .accessibilityLabel(AppInterfaceStrings.format("%ld 个槽位", arguments: [count]))
                        }
                    }
                }.padding(18)
            }
            SettingsGroup(title: "附件与性能") {
                SettingsRow("预览缓存") {
                    Picker(localized: "预览缓存", selection: $cacheBudgetMiB) {
                        AppLocalizedText("自动（推荐）").tag(0)
                        Text("64 MiB").tag(64)
                        Text("128 MiB").tag(128)
                        Text("256 MiB").tag(256)
                        if ![0, 64, 128, 256].contains(cacheBudgetMiB) {
                            AppLocalizedText("自定义 · %ld MiB", cacheBudgetMiB).tag(cacheBudgetMiB)
                        }
                    }.labelsHidden().frame(width: 208)
                        .localizedHelp("自动随可用内存调整，不影响原始文件。")
                        .accessibilityIdentifier("slot-preview-cache-budget")
                }
                SettingsDivider()
                SettingsRow("附件数量提醒") {
                    Picker(localized: "附件数量提醒", selection: $attachmentWarningCount) {
                        AppLocalizedText("50 项（推荐）").tag(50)
                        AppLocalizedText("100 项").tag(100)
                        AppLocalizedText("禁用").tag(0)
                        if ![0, 50, 100].contains(attachmentWarningCount) {
                            AppLocalizedText("%ld 项", attachmentWarningCount).tag(attachmentWarningCount)
                        }
                    }.labelsHidden().frame(width: 208)
                        .localizedHelp("仅在手动添加超过此数量时提醒，仍可继续添加。")
                        .accessibilityIdentifier("slot-attachment-warning-count")
                }
            }
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "全局快捷键") {
                SettingsRow("槽位编号") {
                    Picker(localized: "模板", selection: $hotkeyTemplateKind) {
                        ForEach(HotkeyTemplateKind.allCases) { kind in AppLocalizedText(kind.title).tag(kind) }
                    }.labelsHidden().frame(width: 208)
                }
                SettingsDivider()
                shortcutRow("保存快捷键", key: $saveKey, slots: true, id: "save")
                SettingsDivider()
                shortcutRow("粘贴快捷键", key: $pasteKey, slots: true, id: "paste")
                SettingsDivider()
                shortcutRow("圆盘菜单快捷键", key: $radialKey, slots: false, id: "radial")
            }
            SettingsDisclosure(title: "快捷键使用帮助") {
                AppLocalizedText("点击快捷键后按下新组合；保存与粘贴中的数字键代表全部槽位。Esc 取消录入，Tab 切换。")
                HStack {
                    AppLocalizedText("槽位组切换")
                    Spacer()
                    Text("⌘ ← / →").font(.system(size: 13, weight: .medium))
                }
            }
        }
    }

    private func shortcutRow(_ title: String, key: Binding<String>, slots: Bool, id: String) -> some View {
        SettingsRow(title) {
            ShortcutCaptureField(shortcut: key, allowsSlotPlaceholder: slots,
                                 slotLabel: hotkeyTemplateKind == .numeric ? "1…0" :
                                    hotkeyTemplateKind == .hybrid ? "1…5 / Q…T" : AppInterfaceStrings.text("槽位"))
                .frame(width: 208, height: 34)
                .accessibilityIdentifier("settings-shortcut-\(id)")
                .localizedAccessibilityLabel(title)
        }
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "操作确认") {
                SettingsToggleRow("覆盖槽位前询问", isOn: Binding(get: { !skipOverwriteConfirmation },
                    set: { skipOverwriteConfirmation = !$0 }))
                SettingsDivider()
                SettingsToggleRow("批量保存前询问", isOn: Binding(get: { !skipBatchSaveConfirmation },
                    set: { skipBatchSaveConfirmation = !$0 }))
            }
            SettingsGroup(title: "完成提示") {
                SettingsToggleRow("保存成功后显示提示", isOn: $showSaveToast)
                SettingsDivider()
                SettingsToggleRow("复制成功后显示提示", isOn: $showCopyToast)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "串联粘贴") {
                HStack(spacing: 0) {
                    ForEach(0..<3) { index in
                        if index > 0 {
                            Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary).padding(.trailing, 8)
                        }
                        Image(systemName: ["doc.text", "photo", "doc.on.clipboard"][index])
                            .font(.system(size: 19, weight: .regular))
                            .foregroundColor(enableSlotConnection ? .primary : .secondary)
                            .frame(width: 58, height: 54)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                    }
                }.padding(.horizontal, 36).padding(.vertical, 28).accessibilityHidden(true)
                SettingsDivider()
                SettingsToggleRow("启用槽位连接", isOn: $enableSlotConnection)
            }
            SettingsDisclosure(title: "连接如何工作") {
                AppLocalizedText("按连接顺序一次粘贴多个槽位。关闭后保留已有连接。")
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "操作历史") {
                SettingsRow("撤销步数") {
                    HStack(spacing: 12) {
                        Text("\(undoSteps)").monospacedDigit().frame(minWidth: 28)
                        Stepper(value: $undoSteps, in: SlotUndoStack.minLimitPerGroup...SlotUndoStack.maxLimitPerGroup) {
                            EmptyView()
                        }.labelsHidden().fixedSize().localizedAccessibilityLabel("撤销步数")
                    }
                    .localizedHelp("每个槽位组保留的撤销 / 重做步数（Cmd+Z / Cmd+Shift+Z），范围 1～100。")
                }
                SettingsDivider()
                SettingsRow("历史占用") {
                    Text(undoDiskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                        .foregroundColor(.secondary).monospacedDigit()
                }
            }
            SettingsGroup(title: "诊断") {
                SettingsToggleRow("输出详细日志", isOn: $verbose)
                    .localizedHelp("用于调试保存、粘贴、快捷键注册等问题。")
            }
            SettingsDisclosure(title: "历史保留规则") {
                AppLocalizedText("降低步数并保存后，超出的旧历史会被移除。当前槽位内容保持不变。")
            }
        }.task {
            undoDiskBytes = await Task.detached(priority: .utility) { ClipSlotsPaths.undoStackDiskBytes() }.value
        }
    }

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "CLI") {
                SettingsRow("clipslots") {
                    SettingsStatus(title: cliStatusTitle, color: cliStatusColor)
                    Button(localized: cliPrimaryButtonTitle) { cliManager.install() }
                        .disabled(cliManager.isBusy)
                }
                if let message = cliManager.lastMessage { operationMessage(message, error: cliManager.lastMessageIsError) }
                SettingsDivider()
                SettingsDisclosure(title: "安装详情", inset: true) {
                    Text(CLIInstallManager.targetPath).textSelection(.enabled)
                    if case .broken = cliManager.state {
                        AppLocalizedText("命令行软链已失效（目标不存在），请点击重新安装以修复。")
                    }
                    HStack {
                        Button(localized: "刷新") { cliManager.refreshState() }.disabled(cliManager.isBusy)
                        if cliIsInstalled {
                            Button(localized: "卸载 CLI", role: .destructive) { cliManager.uninstall() }
                                .disabled(cliManager.isBusy)
                        }
                    }
                }
            }
            SettingsGroup(title: "Agent Skill") {
                SettingsRow("ClipSlots Skill") {
                    SettingsStatus(title: skillManager.agentsWithSkillInstalled.isEmpty ? "未安装" :
                        AppInterfaceStrings.format("已安装 · %ld 个 Agent", arguments: [skillManager.agentsWithSkillInstalled.count]),
                        color: skillManager.agentsWithSkillInstalled.isEmpty ? .secondary : .green)
                    Button(localized: skillManager.agentsWithSkillInstalled.isEmpty ? "安装" : "重新安装") {
                        skillManager.reinstallSkillByOverwrite()
                    }.disabled(skillManager.busyAgentID != nil)
                }
                if let message = skillManager.lastMessage { operationMessage(message, error: skillManager.lastMessageIsError) }
                SettingsDivider()
                SettingsDisclosure(title: "已连接的 Agent", inset: true) {
                    if skillManager.agentsWithSkillInstalled.isEmpty {
                        AppLocalizedText("安装后，Agent 可读取 ClipSlots 的使用说明。")
                    }
                    ForEach(skillManager.agentsWithSkillInstalled) { agent in
                        HStack {
                            Text(agent.displayName)
                            Spacer()
                            SkillStatusPill(broken: skillManager.linkHealth(for: agent) == .broken)
                        }.help(agent.skillTargetPath)
                    }
                    if let version = skillManager.bundledSkillVersionInfo {
                        AppLocalizedText("当前 Skill 版本：%@", version)
                    }
                    if !skillManager.agentsWithSkillInstalled.isEmpty {
                        Button(localized: "卸载 Skill", role: .destructive) { skillManager.uninstallSkillFromAllAgents() }
                            .disabled(skillManager.busyAgentID != nil)
                    }
                }
            }
            SettingsGroup(title: "应用管理") {
                SettingsRow("卸载 ClipSlots") {
                    Button(localized: "卸载…", role: .destructive) { showUninstallSheet = true }
                        .buttonStyle(CompactActionStyle(destructive: true)).disabled(appUninstaller.isBusy)
                }
            }
        }
        .task {
            cliManager.refreshState()
            skillManager.refreshInBackground()
        }
    }

    private func operationMessage(_ text: String, error: Bool) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(error ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18).padding(.bottom, 14)
    }
    private var cliIsInstalled: Bool {
        if case .notInstalled = cliManager.state { return false }
        return true
    }
    private var cliStatusColor: Color {
        switch cliManager.state {
        case .notInstalled: return .secondary
        case .installed: return .green
        case .outdated: return .orange
        case .broken: return .red
        }
    }
    private var cliStatusTitle: String {
        switch cliManager.state {
        case .notInstalled: return "未安装"
        case .installed(let version): return "v\(version)"
        case .outdated: return "可更新"
        case .broken: return "需要修复"
        }
    }
    private var cliPrimaryButtonTitle: String {
        switch cliManager.state {
        case .notInstalled: return "安装"
        case .installed: return "重新安装"
        case .outdated: return "更新"
        case .broken: return "修复"
        }
    }

    private var uninstallConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppLocalizedText("确认卸载 ClipSlots？").font(.system(size: 20, weight: .semibold))
            AppLocalizedText("应用将移入废纸篓。选中删除的数据无法恢复。")
                .font(.system(size: 13)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Toggle(localized: "删除所有槽位数据", isOn: $uninstallDeleteData)
                Toggle(localized: "卸载 CLI", isOn: $uninstallRemoveCLI)
                Toggle(localized: "卸载 Skill", isOn: $uninstallRemoveSkills)
            }.toggleStyle(.checkbox).font(.system(size: 13))
            HStack {
                Spacer()
                Button(localized: "取消") { showUninstallSheet = false }.keyboardShortcut(.escape)
                Button(localized: "确认卸载", role: .destructive) {
                    showUninstallSheet = false
                    appUninstaller.performUninstall(deleteData: uninstallDeleteData, uninstallCLI: uninstallRemoveCLI,
                        uninstallSkills: uninstallRemoveSkills, skillManager: skillManager)
                }.buttonStyle(CompactActionStyle(destructive: true))
            }
        }.padding(28).frame(width: 460).buttonStyle(CompactActionStyle())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if selectedCategory != .permission && selectedCategory != .cli {
                Button(localized: "恢复默认", action: resetCurrentPage)
                    .accessibilityIdentifier("settings-reset")
            }
            Spacer()
            if hasChanges {
                Circle().fill(Color.primary.opacity(0.35)).frame(width: 5, height: 5)
                    .localizedAccessibilityLabel("未保存")
            }
            Button(localized: hasChanges ? "取消" : "完成", action: closeAction)
                .keyboardShortcut(.escape).accessibilityIdentifier("settings-cancel")
            Button(localized: "保存", action: save)
                .buttonStyle(CompactActionStyle(selected: true)).disabled(!hasChanges)
                .keyboardShortcut(.return).accessibilityIdentifier("settings-save")
        }
        .padding(.horizontal, 28).frame(height: 68)
        .background(AppTheme.elevatedBackground(scheme))
    }

    private func resetCurrentPage() {
        switch selectedCategory {
        case .appearance:
            appearanceRaw = ThemeMode.light.rawValue
            languageRaw = AppInterfaceLanguage.chinese.rawValue
        case .slot: slots = 10; cacheBudgetMiB = 0; attachmentWarningCount = 50
        case .shortcut:
            saveKey = "option+{n}"; pasteKey = "cmd+{n}"; radialKey = "ctrl+space"; hotkeyTemplateKind = .numeric
        case .notification:
            skipOverwriteConfirmation = false; skipBatchSaveConfirmation = false
            showSaveToast = true; showCopyToast = true
        case .connection: enableSlotConnection = true
        case .advanced: verbose = true; undoSteps = SlotUndoStack.defaultLimitPerGroup
        case .permission, .cli: break
        }
    }
    private func restorePreview() {
        guard !saved else { return }
        appearanceRaw = originalAppearance
        languageRaw = originalLanguage
    }
    private func closeAction() {
        restorePreview()
        if let onClose { onClose() } else { dismiss() }
    }
    private func save() {
        var next = config
        next.slots = slots
        next.saveKey = HotkeyTemplateNormalizer.normalizedShortcut(saveKey, allowsSlotPlaceholder: true)
        next.pasteKey = HotkeyTemplateNormalizer.normalizedShortcut(pasteKey, allowsSlotPlaceholder: true)
        next.radialKey = HotkeyTemplateNormalizer.normalizedShortcut(radialKey, allowsSlotPlaceholder: false)
        next.verbose = verbose
        next.undoSteps = SlotUndoStack.clampLimit(undoSteps)
        next.cacheBudgetMiB = cacheBudgetMiB
        next.attachmentWarningCount = attachmentWarningCount
        next.hotkeyTemplate.kind = hotkeyTemplateKind
        next.save()
        let defaults = UserDefaults.standard
        defaults.set(skipOverwriteConfirmation, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
        defaults.set(skipBatchSaveConfirmation, forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
        defaults.set(showSaveToast, forKey: UserPreferenceKeys.showSaveToast)
        defaults.set(showCopyToast, forKey: UserPreferenceKeys.showCopyToast)
        defaults.set(enableSlotConnection, forKey: UserPreferenceKeys.enableSlotConnection)
        saved = true
        onSave(next)
        closeAction()
    }
}

// The same tokens and row geometry are used on every settings page, including permissions.
struct SettingsGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppLocalizedText(title).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.elevatedBackground(scheme), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.075), lineWidth: 1))
        }
    }
}

struct SettingsRow<Content: View>: View {
    var title: String
    var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(spacing: 16) {
            AppLocalizedText(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            content
        }.padding(.horizontal, 18).padding(.vertical, 12).frame(minHeight: 58)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.horizontal, 18) }
}

struct SettingsToggleRow: View {
    var title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        SettingsRow(title) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().localizedAccessibilityLabel(title)
        }
    }
}

struct SettingsDisclosure<Content: View>: View {
    var title: String
    var inset = false
    @ViewBuilder var content: Content
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) { content }
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.bottom, 4)
        } label: {
            AppLocalizedText(title).font(.system(size: 13)).foregroundColor(.secondary)
        }
        .padding(inset ? 18 : 2)
    }
}

struct SettingsStatus: View {
    var title: String
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            AppLocalizedText(title).font(.system(size: 12)).foregroundColor(.secondary)
        }.fixedSize()
    }
}

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content
    var body: some View { SettingsGroup(title: title) { content.padding(18) } }
}

struct SkillStatusPill: View {
    let broken: Bool
    var body: some View { SettingsStatus(title: broken ? "软链已断开" : "已安装", color: broken ? .orange : .green) }
}
