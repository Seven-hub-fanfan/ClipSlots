import SwiftUI

// v2.9.8: 插件页面（C+ 方案）
// 三个区域：
//   1. ClipSlots Skill（官方）— 展示 skills/clipslots-manager/SKILL.md，可启用/禁用
//   2. 官方插件 — 预留占位
//   3. 第三方插件 — 预留占位 +「添加插件」按钮（本期仅提示，格式规范制定中）
struct PluginsView: View {
    var onClose: () -> Void

    // Skill 标记状态持久化。
    // v2.9.9 降级说明：该开关目前仅作为「标记」，不联动 CLI 的实际行为（CLI 与 GUI 共享磁盘数据，
    // 始终可用）。因此本期改为纯展示 + 说明文案，避免给用户「关掉开关即可禁用 CLI」的错误预期。
    @AppStorage("skill_clipslots_manager_enabled") private var skillEnabled = true

    @State private var showingAddPluginNotice = false

    // v2.9.14: 一键安装到 Agent。
    @StateObject private var agentInstaller = AgentSkillInstallManager()

    // 官方 Skill 元信息（对应 skills/clipslots-manager/SKILL.md）
    private let skillName = "ClipSlots Skill"
    private let skillIdentifier = "clipslots-manager"
    // v2.9.9: 动态读取自 Info.plist，与 App 版本保持同源。
    private let skillVersion = AppVersion.current
    private let skillDescription = "通过命令行工具 clipslots 以编程方式操作 ClipSlots：读取/写入/检索槽位内容、把内容加载到系统剪贴板、批量整理素材到「页面→槽位组→槽位」三层结构、创建/删除页面与槽位组。专为智能体（Agent）调用设计，输出结构化 JSON。"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    officialSkillSection
                    officialPluginsSection
                    thirdPartyPluginsSection
                }
                .padding(18)
            }
        }
        .frame(width: 460, height: 520)
        .alert("敬请期待", isPresented: $showingAddPluginNotice) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("插件格式规范（.clipslot-plugin）制定中，敬请期待。下个版本将支持安装第三方插件。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("插件")
                    .font(.system(size: 17, weight: .bold))
                Text("管理 ClipSlots 的 Skill 与插件扩展")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Section 1: Official Skill

    private var officialSkillSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ClipSlots Skill", subtitle: "官方")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(skillName)
                                .font(.system(size: 15, weight: .semibold))
                            Text("v\(skillVersion)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Text(skillIdentifier)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // v2.9.9: 降级为纯展示标记，不再是可交互开关。
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                        Text("已启用")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }

                Text(skillDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // v2.9.9: 说明文案 —— 该标记不联动 CLI 的实际行为。
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("此标记暂不影响 CLI（clipslots）的实际行为，仅作展示。CLI 与 App 共享本地数据，安装后始终可被智能体调用。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                agentInstallSection
            }
            .padding(14)
            .background(cardBackground)
        }
        .onAppear { agentInstaller.refresh() }
    }

    // MARK: - 安装到 Agent（v2.9.14）

    private var agentInstallSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("安装到 Agent")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    agentInstaller.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("重新扫描本机 Agent")
            }

            Text("检测到已安装的 Agent 后，可一键把本 Skill 以软链接方式安装进去。App 升级时 Agent 侧自动同步。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if agentInstaller.detectedAgents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("未检测到已安装的 Agent（Claude Code / Cursor / Codex / Gemini CLI）")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(agentInstaller.detectedAgents) { agent in
                        agentRow(agent)
                    }
                }
            }

            if let msg = agentInstaller.lastMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: agentInstaller.lastMessageIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(msg)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(agentInstaller.lastMessageIsError ? .orange : .green)
            }
        }
    }

    private func agentRow(_ agent: AgentSkillInstallManager.Agent) -> some View {
        let state = agentInstaller.states[agent.id] ?? .notInstalled
        let isBusy = agentInstaller.busyAgentID == agent.id
        return HStack(spacing: 10) {
            Image(systemName: agent.iconSystemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.system(size: 13, weight: .medium))
                if case .installed = state {
                    Text(agent.skillTargetPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 70)
            } else {
                agentActionButton(agent: agent, state: state)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func agentActionButton(agent: AgentSkillInstallManager.Agent,
                                   state: AgentSkillInstallManager.InstallState) -> some View {
        switch state {
        case .installed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                Text("已安装")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.12))
            .clipShape(Capsule())
        case .needsUpdate:
            Button("可更新") { agentInstaller.install(agent) }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .notInstalled:
            Button("安装") { agentInstaller.install(agent) }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Section 2: Official plugins

    private var officialPluginsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("官方插件", subtitle: nil)
            placeholderCard(icon: "shippingbox", text: "暂无官方插件")
        }
    }

    // MARK: - Section 3: Third-party plugins

    private var thirdPartyPluginsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("第三方插件", subtitle: nil)

            VStack(spacing: 12) {
                placeholderCard(icon: "puzzlepiece", text: "暂无第三方插件")

                Button {
                    presentAddPluginPanel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("添加插件")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.borderless)
                .background(Color.accentColor.opacity(0.12))
                .foregroundColor(.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text("支持拖入 .clipslot-plugin 格式的插件包（格式规范制定中）。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // 弹出文件选择器（本期：选择后统一提示"格式规范制定中"）。
    private func presentAddPluginPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择插件包"
        panel.prompt = "选择"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.message = "选择 .clipslot-plugin 插件包"

        let result = panel.runModal()
        // 无论是否选择文件，本期都提示格式规范制定中。
        _ = result
        showingAddPluginNotice = true
    }

    // MARK: - Reusable pieces

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private func placeholderCard(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
    }
}
