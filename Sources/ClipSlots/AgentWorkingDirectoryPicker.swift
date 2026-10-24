import SwiftUI
import AppKit
import ClipSlotsKit

struct AgentWorkingDirectoryPicker: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var directories: AgentWorkingDirectoryStore
    var compact = false
    @State private var showing = false
    @State private var managing = false

    private var current: AgentWorkingDirectory? { directories.entry(model.workingDirectoryID) }
    private var title: String {
        current?.name ?? (model.workingDirectoryID == nil ? "添加本地目录" : "目录不可用")
    }
    var body: some View {
        Button {
            if !compact && directories.directories.isEmpty { choose() }
            else { showing.toggle(); managing = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: compact ? "shield" : (current == nil ? "folder.badge.plus" : "folder"))
                if !compact { Text(title).lineLimit(1).truncationMode(.middle) }
                if !compact && !directories.directories.isEmpty {
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
        .frame(width: compact ? 30 : nil, alignment: .leading)
        .frame(maxWidth: compact ? 30 : 170, alignment: .leading)
        .disabled(model.isRunning || model.canResumeGateway || model.isControllingRun || directories.isChoosing)
        .help(model.accessMode.title + " · " + model.accessMode.detail)
        .accessibilityLabel("添加本地目录或切换工作目录")
        .accessibilityIdentifier("agent-working-directory")
        .onChange(of: model.selectedConversationID) { _ in showing = false; managing = false }
        .onChange(of: model.backendKind) { _ in showing = false; managing = false }
        .popover(isPresented: $showing, arrowEdge: .top) {
            if compact && !managing {
                compactAccessMenu
            } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("访问权限").font(.system(size: 14, weight: .semibold))
                ForEach(AgentAccessMode.allCases, id: \.rawValue) { mode in
                    Button { model.selectAccessMode(mode) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: model.accessMode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(model.accessMode == mode ? TapSkin.accent : TapSkin.secondaryInk)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.title).font(.system(size: 12, weight: .medium))
                                Text(mode.detail).font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("agent-access-\(mode.rawValue)")
                }
                if model.canvasProjectID != nil {
                    Text(model.accessMode == .fullAccess ? "可创建、编辑、连线和生成画布节点，支持撤销；执行由审批模式决定。"
                         : model.accessMode == .allDirectoriesReadOnly ? "可以读取画布；修改和生成已关闭。"
                         : "可以操作当前画布，执行由审批模式决定。")
                        .font(.system(size: 10)).foregroundColor(TapSkin.secondaryInk)
                }
                Divider()
                HStack {
                    Text("本地工作目录").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { showing = false; choose() } label: { Label("添加", systemImage: "plus") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-directory-add")
                }
                Text(model.automaticApproval ? "安全读写自动执行；删除仍需确认。" : "本地文件/目录操作每次确认。")
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
        }
        .alert("工作目录不可用", isPresented: Binding(get: { directories.error != nil },
            set: { if !$0 { directories.error = nil } })) {
                Button("好") { directories.error = nil }
            } message: { Text(directories.error ?? "") }
    }
    private var compactAccessMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(AgentAccessMode.allCases, id: \.rawValue) { mode in
                AgentDirectoryModeRow(mode: mode, selected: model.accessMode == mode) {
                    model.selectAccessMode(mode)
                    showing = false
                }.accessibilityIdentifier("agent-access-\(mode.rawValue)")
            }
            Divider().padding(.vertical, 4)
            Button { managing = true } label: {
                HStack {
                    Text("管理本地目录")
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                    .padding(9).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("agent-directory-manage")
        }.padding(5).frame(width: 260)
            .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xffffff, 0x222222))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-access-menu")
    }
    private func choose() { directories.choose { model.selectWorkingDirectory($0) } }
}

private struct AgentDirectoryModeRow: View {
    let mode: AgentAccessMode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(mode == .fullAccess ? .orange : TapSkin.ink)
                    Text(mode.detail).font(.system(size: 11)).foregroundColor(TapSkin.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 11)).opacity(selected ? 1 : 0)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? TapSkin.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
