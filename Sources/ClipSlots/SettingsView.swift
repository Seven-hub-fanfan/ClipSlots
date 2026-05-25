import SwiftUI

struct SettingsView: View {
    @State var config: AppConfig
    var onSave: (AppConfig) -> Void

    @State private var slots: Double
    @State private var saveKey: String
    @State private var pasteKey: String
    @State private var radialKey: String
    @Environment(\.dismiss) private var dismiss

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _slots = State(initialValue: Double(config.slots))
        _saveKey = State(initialValue: config.saveKey)
        _pasteKey = State(initialValue: config.pasteKey)
        _radialKey = State(initialValue: config.radialKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ClipSlots 设置")
                .font(.headline)

            Divider()

            HStack(spacing: 12) {
                Text("槽位数量:")
                    .frame(width: 80, alignment: .leading)
                Slider(value: $slots, in: 1...10, step: 1)
                Text("\(Int(slots))")
                    .frame(width: 24)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("保存快捷键:")
                    .font(.subheadline)
                TextField("例如: ctrl+option+{n}", text: $saveKey)
                    .textFieldStyle(.roundedBorder)
                Text("按下此快捷键将当前剪贴板内容保存到槽位")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("粘贴快捷键:")
                    .font(.subheadline)
                TextField("例如: ctrl+{n}", text: $pasteKey)
                    .textFieldStyle(.roundedBorder)
                Text("按下此快捷键从槽位粘贴内容")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("圆盘菜单快捷键:")
                    .font(.subheadline)
                TextField("例如: ctrl+space", text: $radialKey)
                    .textFieldStyle(.roundedBorder)
                Text("按下此快捷键在鼠标位置弹出圆盘菜单")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("可用修饰键: ctrl, option, cmd, shift")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("可用键位: 0-9, a-z, f1-f12, space, tab, 方向键")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("{n} 代表槽位编号（圆盘菜单不需要）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Button("重置默认") {
                    slots = 5
                    saveKey = "ctrl+option+{n}"
                    pasteKey = "ctrl+{n}"
                    radialKey = "ctrl+space"
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("保存") {
                    var newConfig = config
                    newConfig.slots = Int(slots)
                    newConfig.saveKey = saveKey
                    newConfig.pasteKey = pasteKey
                    newConfig.radialKey = radialKey
                    newConfig.save()
                    onSave(newConfig)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
