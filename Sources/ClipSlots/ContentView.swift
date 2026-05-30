import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var showingSettings = false
    @State private var showingSpecialSlotManagement = false
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("appearanceMode") private var appearanceModeRaw = ThemeMode.system.rawValue

    private var appearanceModeBinding: Binding<ThemeMode> {
        Binding(
            get: { ThemeMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                headerView

                // Hotkey error banner
                if !store.hotkeyRegistrationErrors.isEmpty {
                    hotkeyErrorBanner
                }

                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 14)
                        ],
                        spacing: 14
                    ) {
                        ForEach(1...store.config.slots, id: \.self) { slot in
                            SlotCardView(
                                slot: slot,
                                content: store.slots[slot] ?? SlotContent(),
                                label: store.labels[slot] ?? "",
                                saveShortcut: shortcutPreview(store.config.saveKey, slot: slot),
                                pasteShortcut: shortcutPreview(store.config.pasteKey, slot: slot),
                                onPaste: {
                                    NSLog("[ClipSlots] UI paste button clicked slot=\(slot)")
                                    store.pasteSlotFromUI(slot)
                                },
                                onCopy: {
                                    NSLog("[ClipSlots] UI copy button clicked slot=\(slot)")
                                    store.copySlot(slot)
                                },
                                onSave: {
                                    NSLog("[ClipSlots] UI save/overwrite button clicked slot=\(slot)")
                                    store.saveToSlot(slot)
                                },
                                onClear: {
                                    NSLog("[ClipSlots] UI clear button clicked slot=\(slot)")
                                    store.clearSlotWithConfirmation(slot)
                                },
                                onSetLabel: { newLabel in
                                    store.setLabel(slot, label: newLabel.isEmpty ? nil : newLabel)
                                }
                            )
                        }
                    }
                    .padding(AppTheme.pagePadding)
                }
                .background(AppTheme.windowBackground(colorScheme))

                bottomBar
            }
            .background(AppTheme.windowBackground(colorScheme))

            // Toast overlay
            if let message = store.toastMessage {
                toastView(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toastMessage != nil)
    }

    private var hotkeyErrorBanner: some View {
        VStack(spacing: 4) {
            ForEach(store.hotkeyRegistrationErrors, id: \.self) { error in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                    Spacer()
                }
            }
            HStack(spacing: 4) {
                Text("💡 建议在设置中尝试 Cmd+Option+数字 以避免冲突")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
            )
            .padding(.top, 8)
    }

    // MARK: - Header Layers

    private var headerView: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 14)

            Divider()

            actionBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 10)

            specialSlotTagBar
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 6)

            activeHotkeyLayerNotice
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 8)

            Divider()
        }
        .background(.regularMaterial)
        .popover(isPresented: $showingSettings) {
            SettingsView(config: store.config) { newConfig in
                store.updateConfig(newConfig)
                showingSettings = false
            }
            .frame(width: 460, height: 610)
        }
        .popover(isPresented: $showingSpecialSlotManagement) {
            SpecialSlotManagementView(store: store)
        }
    }

    // Layer 1: Title + Stats + Settings
    private var titleBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.brandGradient(colorScheme))
                    .frame(width: 44, height: 44)
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)

                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("ClipSlots")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("快速保存、调用和粘贴你的常用剪贴板内容")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            statPill(
                title: "已使用",
                value: "\(filledSlotCount)/\(store.config.slots)",
                icon: "checkmark.circle.fill",
                color: AppTheme.success
            )

            Menu {
                Picker("外观", selection: appearanceModeBinding) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
            } label: {
                Image(systemName: (ThemeMode(rawValue: appearanceModeRaw) ?? .system).icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .help("外观")

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
    }

    // Layer 2: Current Slot + Actions
    private var actionBar: some View {
        HStack(spacing: 10) {
            // Slot selector dropdown
            Menu {
                ForEach(store.specialSlots) { special in
                    Button {
                        store.switchSpecialSlot(id: special.id)
                    } label: {
                        Label(
                            special.name,
                            systemImage: special.id == store.currentSpecialSlotId ? "checkmark.circle.fill" : "folder.fill"
                        )
                    }
                }
                Divider()
                Button("新建特殊槽位") { showingSpecialSlotManagement = true }
                Button("管理特殊槽位") { showingSpecialSlotManagement = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                    Text(store.currentSpecialSlot?.name ?? "默认槽位")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // Action buttons
            Button {
                store.chooseFolderAndImportIntoCurrentSpecialSlot()
            } label: {
                Label("导入", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("导入文件夹到当前槽位组")

            Button {
                store.pasteAllSlotsWithConfirmation()
            } label: {
                Label("全部粘贴", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("按顺序粘贴当前槽位组中的全部内容")

            Button(role: .destructive) {
                store.clearAllSlotsInCurrentSpecialSlotWithConfirmation()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("清空当前槽位组中的全部槽位")
        }
    }

    private var specialSlotTagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.specialSlots) { special in
                    let isCurrent = special.id == store.currentSpecialSlotId

                    Button {
                        store.switchSpecialSlot(id: special.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isCurrent ? "folder.fill" : "folder")
                            Text(special.name)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(
                                    isCurrent
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.05)
                                )
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    isCurrent
                                    ? Color.accentColor.opacity(0.45)
                                    : Color.secondary.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameSpecialSlot(id: special.id, currentName: special.name)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        if store.specialSlots.count > 1 {
                            Button(role: .destructive) {
                                store.deleteSpecialSlotWithConfirmation(id: special.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    showingSpecialSlotManagement = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .padding(7)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var activeHotkeyLayerNotice: some View {
        let name = store.currentSpecialSlot?.name ?? "默认槽位"
        return HStack(spacing: 6) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
            Text("当前槽位组：\(name) · Cmd+数字将粘贴该组内容")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    private func renameSpecialSlot(id: String, currentName: String) {
        let alert = NSAlert()
        alert.messageText = "重命名特殊槽位"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = currentName
        textField.placeholderString = "输入新名称"
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                store.renameSpecialSlot(id: id, name: newName)
            }
        }
    }

    private func statPill(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
    }

    private func humanReadableShortcut(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{n}", with: "数字")
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "option", with: "⌥")
            .replacingOccurrences(of: "shift", with: "⇧")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            keyChip("保存 \(humanReadableShortcut(store.config.saveKey))", icon: "square.and.arrow.down")
            keyChip("粘贴 \(humanReadableShortcut(store.config.pasteKey))", icon: "square.and.arrow.up")
            keyChip("圆盘 \(humanReadableShortcut(store.config.radialKey))", icon: "circle.grid.cross")

            Spacer()

            Text("v2.3.3")
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.65))
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func keyChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(AppTheme.chipBackground(colorScheme)))
    }

    private func shortcutPreview(_ template: String, slot: Int) -> String {
        template.replacingOccurrences(of: "{n}", with: "\(slot)")
    }

    private var filledSlotCount: Int {
        store.slots.values.filter { !$0.isEmpty }.count
    }
}
