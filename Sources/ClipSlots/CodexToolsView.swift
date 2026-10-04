import SwiftUI
import ClipSlotsKit

struct CodexToolsView: View {
    @ObservedObject var chat: AgentChatModel
    var embedded = false
    var onUse: (() -> Void)?
    @ObservedObject private var desktop = CodexWorkspaceModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var cwd: String { chat.codexContext?.cwd ?? AgentBackendCoordinator.codexConfiguration().workingDirectory }
    private var skills: [CodexWorkspaceModel.Skill] {
        desktop.skills.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Skills 与 MCP").font(.system(size: 20, weight: .semibold))
                Spacer()
                if desktop.toolsBusy { ProgressView().controlSize(.small) }
                Button("刷新") { desktop.refreshTools(cwd: cwd) }.disabled(desktop.toolsBusy)
                if !embedded { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            Text("与本机 Codex 共用配置。启停 Skill 会同步到桌面端，下一次任务生效。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            TextField("搜索 Skills", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Skills").font(.headline)
                    ForEach(skills) { skill in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(get: { skill.enabled }, set: {
                                desktop.setSkill(skill, enabled: $0, cwd: cwd)
                            })).labelsHidden().disabled(desktop.toolsBusy)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name).font(.system(size: 12, weight: .medium))
                                Text(skill.description).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("使用") {
                                chat.addSkillReference(name: skill.name, path: skill.id)
                                if let onUse { onUse() } else { dismiss() }
                            }.controlSize(.small).disabled(!skill.enabled || chat.isAddingSkill)
                        }
                    }
                    if skills.isEmpty { Text("此目录暂无匹配的 Skill。").font(.caption).foregroundColor(.secondary) }
                    Divider()
                    Text("MCP 服务").font(.headline)
                    HStack {
                        Label("ClipSlots 槽位工具", systemImage: "square.grid.2x2")
                        Spacer()
                        Text("发送时连接").foregroundColor(.secondary)
                    }.font(.system(size: 12))
                    ForEach(desktop.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.id).font(.system(size: 12, weight: .medium))
                                Text("\(server.toolCount) 个工具 · \(server.status)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if server.auth == "notLoggedIn" {
                                Button("授权") { desktop.authorize(server) }.disabled(desktop.toolsBusy)
                            } else {
                                Text(server.auth == "oAuth" ? "已授权" : "已配置").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if let error = desktop.toolsError {
                        Text(error).font(.caption).foregroundColor(.orange).textSelection(.enabled)
                    }
                    Divider()
                    Text("ClipSlots 本地扩展").font(.headline)
                    AgentSkillPickerView(builtinToolCount: AgentBuiltinTools().specs().count)
                }.padding(2)
            }
        }
        .padding(24).frame(width: embedded ? nil : 650, height: embedded ? nil : 650)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { desktop.refreshTools(cwd: cwd) }
    }
}
