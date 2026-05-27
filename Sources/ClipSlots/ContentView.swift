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
        VStack(spacing: 0) {
            headerView

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)
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
                                store.clearSlot(slot)
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
    }

    private var headerView: some View {
        VStack(spacing: 0) {
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

                    HStack(spacing: 6) {
                        Text("快速保存、调用和粘贴你的常用剪贴板内容")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Menu {
                            ForEach(store.specialSlots) { special in
                                Button {
                                    store.switchSpecialSlot(id: special.id)
                                } label: {
                                    Label(
                                        special.name,
                                        systemImage: special.id == store.currentSpecialSlotId ? "checkmark" : "folder"
                                    )
                                }
                            }
                            Divider()
                            Button("新建特殊槽位") {
                                showingSpecialSlotManagement = true
                            }
                            Button("管理特殊槽位") {
                                showingSpecialSlotManagement = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9))
                                Text(store.currentSpecialSlot?.name ?? "默认槽位")
                                    .font(.system(size: 10, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                Spacer()

                Button {
                    store.chooseFolderAndImportIntoCurrentSpecialSlot()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("导入文件夹到当前特殊槽位")

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
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 16)

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

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("快捷键")
                .font(.caption)
                .foregroundColor(.secondary)

            keyChip("\(store.config.saveKey) 保存", icon: "square.and.arrow.down")
            keyChip("\(store.config.pasteKey) 粘贴", icon: "square.and.arrow.up")
            keyChip("\(store.config.radialKey) 圆盘", icon: "circle.grid.cross")

            Spacer()

            Text("v2.2.0")
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
