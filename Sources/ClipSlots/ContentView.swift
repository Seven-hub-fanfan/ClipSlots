import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Slot cards
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(1...store.config.slots, id: \.self) { slot in
                        SlotCardView(
                            slot: slot,
                            content: store.slots[slot] ?? SlotContent(),
                            label: store.labels[slot] ?? "",
                            onPaste: { store.pasteSlot(slot) },
                            onCopy: { store.copySlot(slot) },
                            onSave: { store.saveToSlot(slot) },
                            onClear: { store.clearSlot(slot) },
                            onSetLabel: { newLabel in
                                store.setLabel(slot, label: newLabel.isEmpty ? nil : newLabel)
                            }
                        )
                    }
                }
                .padding(16)
            }
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Bottom toolbar
            bottomBar
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("ClipSlots")
                .font(.title2.bold())
            Spacer()
            Text("\(filledSlotCount) / \(store.config.slots) 个槽位已使用")
                .font(.caption)
                .foregroundColor(.secondary)
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .popover(isPresented: $showingSettings) {
            SettingsView(config: store.config) { newConfig in
                store.updateConfig(newConfig)
                showingSettings = false
            }
            .frame(width: 400, height: 520)
        }
    }

    private var bottomBar: some View {
        HStack {
            Text("全局快捷键：")
                .font(.caption)
                .foregroundColor(.secondary)
            Label("\(store.config.saveKey) 保存", systemImage: "square.and.arrow.down")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.1)))
            Label("\(store.config.pasteKey) 粘贴", systemImage: "square.and.arrow.up")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.1)))
            Spacer()
            Text("ClipSlots 2.0")
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var filledSlotCount: Int {
        store.slots.values.filter { !$0.isEmpty }.count
    }
}
