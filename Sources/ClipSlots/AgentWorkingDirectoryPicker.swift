import SwiftUI
import AppKit
import ClipSlotsKit

struct AgentWorkingDirectoryPicker: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var directories: AgentWorkingDirectoryStore
    @State private var showing = false

    private var current: AgentWorkingDirectory? { directories.entry(model.workingDirectoryID) }
    private var title: String {
        current?.name ?? (model.workingDirectoryID == nil ? "添加本地目录" : "目录不可用")
    }
    var body: some View {
        Button {
            if directories.directories.isEmpty { choose() }
            else { showing.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current == nil ? "folder.badge.plus" : "folder")
                Text(title).lineLimit(1).truncationMode(.middle)
                if !directories.directories.isEmpty {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(TapSkin.secondaryInk)
            .padding(.horizontal, 7).frame(height: 30)
            .background(showing ? CreativeMenuStyle.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 170, alignment: .leading)
        .disabled(model.isRunning || directories.isChoosing)
        .help(current?.path ?? "选择 Agent 本轮可访问的本地工作目录")
        .accessibilityLabel("添加本地目录或切换工作目录")
        .accessibilityIdentifier("agent-working-directory")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本地工作目录").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { showing = false; choose() } label: { Label("添加", systemImage: "plus") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-directory-add")
                }
                Text(model.canvasProjectID == nil ? "本轮使用所选目录，写入前由你确认。" : "画布分析仅开放目录读取。")
                    .font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(directories.directories) { entry in
                            HStack(spacing: 8) {
                                Button {
                                    model.selectWorkingDirectory(entry.id)
                                    if model.workingDirectoryID == entry.id { showing = false }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: model.workingDirectoryID == entry.id ? "checkmark.circle.fill" : "folder")
                                            .foregroundColor(model.workingDirectoryID == entry.id ? TapSkin.accent : TapSkin.secondaryInk)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(entry.path).font(.system(size: 10))
                                                .foregroundColor(TapSkin.secondaryInk).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("agent-directory-select-\(entry.id)")
                                Menu {
                                    Button("在访达中显示") {
                                        do {
                                            let access = try directories.access(entry.id)
                                            NSWorkspace.shared.activateFileViewerSelecting([access.url])
                                        } catch { directories.error = error.localizedDescription }
                                    }
                                    Button("重新定位与授权…") {
                                        showing = false
                                        directories.choose(replacing: entry.id) { model.selectWorkingDirectory($0) }
                                    }
                                    Button("从列表移除") {
                                        do {
                                            try directories.remove(entry.id)
                                            if model.workingDirectoryID == entry.id { model.selectWorkingDirectory(nil) }
                                        } catch { directories.error = error.localizedDescription }
                                    }
                                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("管理目录；移除只影响列表，不删除文件")
                            }
                            .padding(8)
                            .background(model.workingDirectoryID == entry.id ? TapSkin.accent.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(maxHeight: 260)
                Button("不使用本地目录") {
                    model.selectWorkingDirectory(nil)
                    showing = false
                }.buttonStyle(.plain).font(.system(size: 11))
                    .accessibilityIdentifier("agent-directory-clear")
            }
            .padding(16).frame(width: 350)
            .foregroundColor(TapSkin.ink)
            .background(TapSkin.tone(0xffffff, 0x202020))
        }
        .alert("工作目录不可用", isPresented: Binding(get: { directories.error != nil },
            set: { if !$0 { directories.error = nil } })) {
                Button("好") { directories.error = nil }
            } message: { Text(directories.error ?? "") }
    }
    private func choose() { directories.choose { model.selectWorkingDirectory($0) } }
}
