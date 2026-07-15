import SwiftUI
import ClipSlotsKit

struct SpecialSlotManagementView: View {
    @ObservedObject var store: SlotStoreObservable
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedId: String = ""
    @State private var showingNewDialog = false
    @State private var showingRenameDialog = false
    @State private var newName = ""
    @State private var renameText = ""

    private var selected: SpecialSlot? {
        store.currentPageSlotGroups.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.brandGradient(colorScheme))
                        .frame(width: 38, height: 38)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("槽位组管理")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("创建、编辑和切换槽位组")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }

            // Content
            HStack(spacing: 0) {
                // Left list
                List(store.currentPageSlotGroups) { special in
                    HStack {
                        Image(systemName: special.id == store.currentSpecialSlotId ? "folder.fill" : "folder")
                            .foregroundColor(special.id == store.currentSpecialSlotId ? .accentColor : .secondary)
                        Text(special.name)
                            .font(.system(size: 13, weight: special.id == store.currentSpecialSlotId ? .semibold : .regular))
                        Spacer()
                        if special.id == store.currentSpecialSlotId && special.id == store.activeHotkeySpecialSlotId {
                            Text("快捷键槽位组")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        } else if special.id == store.currentSpecialSlotId {
                            Text("预览中")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        } else if special.id == store.activeHotkeySpecialSlotId {
                            Text("快捷键")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedId = special.id
                        store.selectAndActivateSpecialSlot(id: special.id)
                    }
                }
                .listStyle(.sidebar)
                // v2.9.18: 侧栏由固定宽度改为弹性宽度，长槽位组名更从容（不破坏整体布局）。
                .frame(minWidth: 160, idealWidth: 180)

                // Right detail
                if let special = selected {
                    specialDetail(special)
                } else {
                    VStack {
                        Spacer()
                        Text("请从左侧选择一个槽位组")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("点击槽位组即可切换 Cmd+数字对应内容")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Bottom bar
            HStack {
                Button { showingNewDialog = true } label: {
                    Label("新建", systemImage: "plus")
                }
                .disabled(store.currentPageSlotGroups.count >= store.specialSlotSettings.maxSpecialSlots)

                Button { showingRenameDialog = true } label: {
                    Label("重命名", systemImage: "pencil")
                }
                .disabled(selectedId.isEmpty)

                Button(role: .destructive) {
                    store.deleteSpecialSlotWithConfirmation(id: selectedId)
                    selectedId = store.currentSpecialSlotId
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selectedId.isEmpty || store.currentPageSlotGroups.count <= 1)

                Spacer()

                Button {
                    store.startToolbarImport()
                } label: {
                    Label("导入文件夹", systemImage: "folder.badge.plus")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 500, height: 380)
        .background(AppTheme.windowBackground(colorScheme))
        .onAppear { selectedId = store.currentSpecialSlotId }
        .sheet(isPresented: $showingNewDialog) {
            newSpecialSlotSheet()
        }
        .sheet(isPresented: $showingRenameDialog) {
            renameSheet()
        }
    }

    @ViewBuilder
    private func specialDetail(_ special: SpecialSlot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(special.name).font(.title3).bold()
                    Text(sourceDescription(for: special.sourceType)).font(.caption).foregroundColor(.secondary)
                }
            }

            Divider()

            infoRow("来源类型", sourceDescription(for: special.sourceType))
            if let path = special.sourcePath {
                infoRow("来源路径", path)
            }
            infoRow("创建时间", dateFormatter.string(from: special.createdAt))
            if special.createdAt != special.updatedAt {
                infoRow("最近更新", dateFormatter.string(from: special.updatedAt))
            }

            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func newSpecialSlotSheet() -> some View {
        VStack(spacing: 16) {
            Text("新建槽位组").font(.headline)
            TextField("槽位名称", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack(spacing: 12) {
                Button("取消") { showingNewDialog = false; newName = "" }
                Button("创建") {
                    guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    store.createSpecialSlot(name: newName)
                    selectedId = store.currentSpecialSlotId
                    showingNewDialog = false
                    newName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300, height: 160)
    }

    @ViewBuilder
    private func renameSheet() -> some View {
        VStack(spacing: 16) {
            Text("重命名「\(selected?.name ?? "")」").font(.headline)
            TextField("新名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack(spacing: 12) {
                Button("取消") { showingRenameDialog = false; renameText = "" }
                Button("确认") {
                    guard !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    store.renameSpecialSlot(id: selectedId, name: renameText)
                    showingRenameDialog = false
                    renameText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300, height: 160)
    }

    private func sourceDescription(for type: SpecialSlotSourceType) -> String {
        switch type {
        case .manual: return "手动创建"
        case .folderImport: return "文件夹导入"
        case .migratedDefault: return "旧版本迁移"
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }
}
