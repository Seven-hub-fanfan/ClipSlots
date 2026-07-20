import SwiftUI
import AppKit
import UniformTypeIdentifiers

// v2.9.17: Plugin marketplace (Obsidian community-plugins style).
//
// Replaces the old stacked-text plugin panel. Structure:
//   - Toolbar: 搜索框 + 排序按钮 + 「仅显示已安装」开关
//   - 分类 Tab：官方 Skill / 官方插件 / 社区插件（社区暂为占位）
//   - 主列表：卡片网格（图标/emoji + 名称 + 来源 + 一句描述 + 安装状态徽章）
//   - 详情页：点击卡片后展示完整描述 + 安装到 Agent 操作
//
// Data-driven via `PluginCatalog`, so新增官方 Skill 只需扩充 catalog。
// Stays an independent popover (NOT embedded into the settings window).
struct PluginsView: View {
    var onClose: () -> Void

    @Environment(\.colorScheme) private var scheme

    // v2.9.14: 一键安装到 Agent。
    @StateObject private var agentInstaller = AgentSkillInstallManager()

    // v2.9.53: 社区 Skill——用户自定义上传 Skill 并软链安装到各 Agent。
    @StateObject private var communitySkills = CommunitySkillManager()

    // v2.9.54: 社区插件（第三方工具）安装状态标记（持久化到 UserDefaults）。
    @StateObject private var communityPlugins = CommunityPluginInstallStore()

    // 保留旧标记键以兼容历史用户（当前仅作展示，不联动 CLI）。
    @AppStorage("skill_clipslots_manager_enabled") private var skillEnabled = true

    @State private var searchText = ""
    @State private var sort: PluginMarketSort = .recommended
    @State private var onlyInstalled = false
    @State private var selectedCategory: PluginMarketCategory = .officialSkill
    @State private var selectedItemID: String? = nil

    // v2.9.54: 社区 Skill 详情页选中态（与官方 selectedItemID 并列，独立数据源）。
    @State private var selectedCommunitySkillID: String? = nil

    // v2.9.54: 社区 Skill 上传区域的拖拽高亮态。
    @State private var isSkillDropTargeted = false

    private var selectedItem: PluginMarketItem? {
        guard let id = selectedItemID else { return nil }
        return PluginCatalog.allItems.first { $0.id == id }
    }

    // v2.9.54: 当前选中的社区 Skill（用于详情页）。
    private var selectedCommunitySkill: CommunitySkillManager.CommunitySkill? {
        guard let id = selectedCommunitySkillID else { return nil }
        return communitySkills.skills.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let skill = selectedCommunitySkill {
                communitySkillDetailView(skill)
            } else if let item = selectedItem {
                detailView(item)
            } else {
                marketView
            }
        }
        .frame(width: 560, height: 588)
        .background(AppTheme.windowBackground(scheme))
        // v2.9.30: 进入 Skill 市场页时也静默同步一次，确保已安装的 Skill 用到最新决策流。
        .onAppear {
            agentInstaller.syncInstalledSkillsOnLaunch()
            // v2.9.53: 扫描已上传的社区 Skill 及其在各 Agent 的安装状态。
            communitySkills.refresh()
        }
    }

    // MARK: - Market (list) view

    private var marketView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            toolbar
            categoryTabs
            Divider()
            listScroll
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.brandGradient(scheme))
                    .frame(width: 32, height: 32)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("插件市场")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("发现并安装 Skill 与插件扩展")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AppTheme.chipBackground(scheme)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Toolbar (search + sort + toggle)

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("搜索 Skill 或插件…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.searchFieldBackground(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.searchFieldStroke(scheme), lineWidth: 1)
            )

            Menu {
                ForEach(PluginMarketSort.allCases) { option in
                    Button {
                        sort = option
                    } label: {
                        Label(option.title, systemImage: sort == option ? "checkmark" : option.iconName)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.softButtonBackground(scheme))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help("排序：\(sort.title)")

            Toggle(isOn: $onlyInstalled) {
                Text("仅显示已安装")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Category tabs

    private var categoryTabs: some View {
        HStack(spacing: 8) {
            ForEach(PluginMarketCategory.allCases) { category in
                categoryTab(category)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func categoryTab(_ category: PluginMarketCategory) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 5) {
                Text(category.title)
                    .font(.system(size: 12, weight: .medium))
                if category.comingSoon {
                    Text("即将开放")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? .white : .secondary)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : AppTheme.chipBackground(scheme))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    private var listScroll: some View {
        ScrollView {
            // v2.9.53: 社区 Skill 分类走独立渲染（动态读取本地上传的 Skill + 上传入口）。
            if selectedCategory == .communitySkill {
                communitySkillContent
            } else {
                let items = filteredItems
                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(items) { item in
                            card(item)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var emptyState: some View {
        let placeholder = selectedCategory.emptyPlaceholder
        return VStack(spacing: 10) {
            Image(systemName: placeholder.icon)
                .font(.system(size: 30))
                .foregroundColor(.secondary.opacity(0.5))
            Text(searchText.isEmpty ? placeholder.text : "未找到匹配「\(searchText)」的结果")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if selectedCategory.comingSoon && searchText.isEmpty {
                Text("敬请期待，下个版本将支持第三方/社区插件。")
                    // v2.9.18: 空状态说明字上调到 AppTheme.Fonts.caption（12pt），提升可读。
                    .font(AppTheme.Fonts.caption)
                    .foregroundColor(.secondary.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        // v2.9.18: 空状态硬编码 .padding(.top, 70) 改为自适应的 AppTheme.spacingLarge，避免大片留白。
        .padding(.top, AppTheme.spacingLarge)
    }

    // MARK: Card

    private func card(_ item: PluginMarketItem) -> some View {
        // v2.9.54: 卡片改用 .onTapGesture 打开详情（不再整体包 Button），
        // 以便社区插件卡片内嵌「安装/卸载」按钮时不与外层点击冲突。
        VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    itemIcon(item, size: 36, corner: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        Text(item.source)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                Text(item.summary)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    if !item.version.isEmpty {
                        Text("v\(item.version)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    Spacer()
                    statusBadge(for: item)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.elevatedBackground(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.subtleBorder(scheme), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                selectedItemID = item.id
            }
    }

    @ViewBuilder
    private func itemIcon(_ item: PluginMarketItem, size: CGFloat, corner: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: size, height: size)
            if let emoji = item.emoji {
                Text(emoji)
                    .font(.system(size: size * 0.5))
            } else {
                Image(systemName: item.iconSystemName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
        }
    }

    // 卡片状态徽章：仅对可安装到 Agent 的 Skill 反映聚合状态。
    @ViewBuilder
    private func statusBadge(for item: PluginMarketItem) -> some View {
        if item.installsToAgent {
            switch agentInstaller.aggregateState {
            case .installed:
                badge(text: "已安装", icon: "checkmark.seal.fill", color: .green)
            case .needsUpdate:
                badge(text: "可更新", icon: "arrow.triangle.2.circlepath", color: .orange)
            case .notInstalled:
                badge(text: "安装", icon: "square.and.arrow.down", color: .accentColor)
            }
        } else {
            // v2.9.54: 社区插件（第三方工具）改为真实安装/卸载状态（替换旧「内置」标签）。
            pluginInstallControl(for: item, compact: true)
        }
    }

    // v2.9.54: 社区插件安装状态控件。
    // - 未安装：显示「安装」按钮（点击打开下载页 + 标记已安装）；
    // - 已安装：显示非交互的「已安装 ✓」Text 标签 +「卸载」按钮（仅清除标记）。
    // 「已安装 ✓」用 Text 而非 Button，修复历史上标签出现蓝色焦点框的问题。
    @ViewBuilder
    private func pluginInstallControl(for item: PluginMarketItem, compact: Bool) -> some View {
        if communityPlugins.isInstalled(item.id) {
            HStack(spacing: 8) {
                badge(text: "已安装 ✓", icon: "checkmark.circle.fill", color: .green)
                Button {
                    communityPlugins.markUninstalled(item.id)
                } label: {
                    badge(text: "卸载", icon: "xmark.circle", color: .secondary)
                }
                .buttonStyle(.plain)
                .help("清除安装标记（不会真正卸载第三方工具）")
            }
        } else {
            Button {
                installCommunityPlugin(item)
            } label: {
                badge(text: "安装", icon: "square.and.arrow.down", color: .accentColor)
            }
            .buttonStyle(.plain)
            .help("打开下载页并标记为已安装")
        }
    }

    /// 打开第三方项目下载页并标记为已安装。
    private func installCommunityPlugin(_ item: PluginMarketItem) {
        if let urlString = item.projectURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        communityPlugins.markInstalled(item.id)
    }

    // 详情页右上角安装控件：可点击，一键安装到全部已检测到的 Agent（修复"点击无反应"）。
    @ViewBuilder
    private func detailInstallControl(for item: PluginMarketItem) -> some View {
        if item.installsToAgent {
            switch agentInstaller.aggregateState {
            case .installed:
                badge(text: "已安装", icon: "checkmark.seal.fill", color: .green)
            case .needsUpdate:
                Button {
                    agentInstaller.installToAllDetectedAgents()
                } label: {
                    badge(text: "更新到全部 Agent", icon: "arrow.triangle.2.circlepath", color: .orange)
                }
                .buttonStyle(.plain)
                .disabled(agentInstaller.busyAgentID != nil)
                .help("把本 Skill 更新/安装到所有检测到的 Agent")
            case .notInstalled:
                Button {
                    agentInstaller.installToAllDetectedAgents()
                } label: {
                    badge(text: "安装", icon: "square.and.arrow.down", color: .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(agentInstaller.busyAgentID != nil)
                .help("一键安装到所有检测到的 Agent")
            }
        } else {
            // v2.9.54: 社区插件详情页也改为真实安装/卸载控件。
            pluginInstallControl(for: item, compact: false)
        }
    }

    private func badge(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    // v2.9.49: 小号次要按钮——用 Finder 打开 bundle 内 Skill 文件目录。
    private var openSkillDirButton: some View {
        Button {
            if let dir = agentInstaller.bundledSkillDir {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 9))
                Text("打开目录").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("在 Finder 中打开 Skill 文件目录，可手动复制到其他 Agent")
    }

    // MARK: - Detail view

    private func detailView(_ item: PluginMarketItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Detail header with back button.
            HStack(spacing: 10) {
                Button {
                    selectedItemID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("市场")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(AppTheme.chipBackground(scheme)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title block
                    HStack(alignment: .top, spacing: 14) {
                        itemIcon(item, size: 52, corner: 12)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: 18, weight: .bold))
                                if !item.version.isEmpty {
                                    Text("v\(item.version)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                            }
                            Text(item.source)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            detailInstallControl(for: item)
                            // v2.9.49: 「打开目录」按钮——用 Finder 打开 bundle 内 Skill 文件目录，
                            // 方便用户手动把 clipslots-manager 复制到其他 Agent 的 skills 目录。
                            if item.installsToAgent, agentInstaller.bundledSkillDir != nil {
                                openSkillDirButton
                            }
                        }
                    }

                    // Full description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("介绍")
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.detail)
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)

                        // v2.9.45: 介绍区域底部展示 bundle 内 SKILL.md 的版本信息。
                        // 取自 SKILL.md frontmatter 的 version 字段，缺失时回退为文件最后修改时间。
                        if item.installsToAgent, let versionInfo = agentInstaller.bundledSkillVersionInfo {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
                                Text("SKILL.md 版本：\(versionInfo)")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        }
                    }

                    if item.installsToAgent {
                        Divider()
                        agentInstallSection
                    }

                    // v2.9.53: 第三方/社区项目展示「访问项目」链接（在浏览器中打开仓库/主页）。
                    if let urlString = item.projectURL, let url = URL(string: urlString) {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("项目主页")
                                .font(.system(size: 13, weight: .semibold))
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 11))
                                    Text("访问项目")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help(urlString)
                            Text(urlString)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    // MARK: - 安装到 Agent（迁移自旧版，保持功能）

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
                    agentInstaller.rescan()
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

            // v2.9.49: 手动安装说明——提示其他 Agent 的安装方式。
            Text("其他 Agent：打开上方目录，将 clipslots-manager 文件夹复制到该 Agent 对应的 skills 目录下即可。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            // v2.9.45: 「已安装」不再是静态徽章，改为可点击菜单（更新 / 打开目录 / 卸载）。
            Menu {
                Button {
                    agentInstaller.update(agent)
                } label: {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    agentInstaller.openInstallDirectory(agent)
                } label: {
                    Label("打开目录", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    agentInstaller.uninstall(agent)
                } label: {
                    Label("卸载", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                    Text("已安装")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("已安装到 \(agent.displayName)，点击可更新 / 打开目录 / 卸载")
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

    // MARK: - 社区 Skill（v2.9.53：用户自定义上传）

    private var communitySkillContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 上传入口 + 刷新
            HStack(spacing: 10) {
                Button {
                    communitySkills.presentUploadPanel()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("上传 Skill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(communitySkills.isBusy)
                .help("选择 .zip（Skill 打包包）或单个 SKILL.md 文件上传")

                if communitySkills.isBusy {
                    ProgressView().scaleEffect(0.6)
                }

                Spacer()

                Button {
                    communitySkills.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("重新扫描本地已上传的 Skill")
            }

            // v2.9.54: 拖拽导入区——支持把 .zip / .md / SKILL.md 拖到此处，走与点击上传一致的校验安装流程。
            skillDropZone

            if let msg = communitySkills.lastMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: communitySkills.lastMessageIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(msg)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(communitySkills.lastMessageIsError ? .orange : .green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((communitySkills.lastMessageIsError ? Color.orange : Color.green).opacity(0.08))
                )
            }

            let items = filteredCommunitySkills
            if items.isEmpty {
                communityEmptyState
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(items) { skill in
                        communityCard(skill)
                    }
                }
            }
        }
        .padding(18)
    }

    // v2.9.54: 拖拽导入区（drop target）。支持拖入 .zip / .md / SKILL.md，
    // 拖拽悬停时高亮虚线边框；松手后走与点击「上传 Skill」相同的校验+安装流程。
    private var skillDropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: isSkillDropTargeted ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isSkillDropTargeted ? .accentColor : .secondary)
            Text(isSkillDropTargeted ? "松手即可导入" : "把 .zip 或 SKILL.md 拖到这里")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSkillDropTargeted ? .accentColor : .secondary)
            Text("也可点击上方「上传 Skill」按钮；校验 frontmatter（须含 name / description）通过后落盘并以软链接安装到各 Agent。")
                .font(AppTheme.Fonts.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(isSkillDropTargeted ? 0.10 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSkillDropTargeted ? Color.accentColor : AppTheme.subtleBorder(scheme),
                    style: StrokeStyle(lineWidth: isSkillDropTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .animation(.easeInOut(duration: 0.12), value: isSkillDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isSkillDropTargeted) { providers in
            handleSkillDrop(providers)
        }
    }

    /// 处理拖拽进来的文件：取第一个 file URL，交给 importSkill（其内部会校验扩展名与 frontmatter）。
    private func handleSkillDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async {
                communitySkills.importSkill(at: url)
            }
        }
        return true
    }

    private var communityEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 30))
                .foregroundColor(.secondary.opacity(0.5))
            Text(searchText.isEmpty ? "还没有上传任何社区 Skill" : "未找到匹配「\(searchText)」的结果")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if searchText.isEmpty {
                Text("点击上方「上传 Skill」，选择 .zip 或 SKILL.md 即可添加。")
                    .font(AppTheme.Fonts.caption)
                    .foregroundColor(.secondary.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppTheme.spacingLarge)
    }

    private func communityCard(_ skill: CommunitySkillManager.CommunitySkill) -> some View {
        let state = communitySkills.aggregateState(for: skill)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                communityIcon(size: 36, corner: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text("社区 · 自定义上传")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                communityMoreMenu(skill)
            }

            Text(skill.summary)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if let v = skill.version, !v.isEmpty {
                    Text("v\(v)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Spacer()
                communityStatusControl(skill: skill, state: state)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.elevatedBackground(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.subtleBorder(scheme), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // v2.9.54: 点击卡片进入社区 Skill 详情页（内嵌按钮/菜单会各自捕获点击，不冲突）。
        .onTapGesture {
            selectedCommunitySkillID = skill.id
        }
    }

    private func communityIcon(size: CGFloat, corner: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: size, height: size)
            Text("🧩")
                .font(.system(size: size * 0.5))
        }
    }

    // 卡片状态控件：已安装绿色 pill；未安装/待更新为可点击安装按钮。
    @ViewBuilder
    private func communityStatusControl(skill: CommunitySkillManager.CommunitySkill,
                                        state: CommunitySkillManager.InstallState) -> some View {
        switch state {
        case .installed:
            badge(text: "已安装", icon: "checkmark.seal.fill", color: .green)
        case .needsUpdate:
            Button { communitySkills.install(skill) } label: {
                badge(text: "更新", icon: "arrow.triangle.2.circlepath", color: .orange)
            }
            .buttonStyle(.plain)
            .disabled(communitySkills.isBusy)
            .help("软链目标已变化，点击重新安装到各 Agent")
        case .notInstalled:
            Button { communitySkills.install(skill) } label: {
                badge(text: "安装到 Agent", icon: "square.and.arrow.down", color: .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(communitySkills.isBusy)
            .help("以软链接方式安装到所有检测到的 Agent")
        }
    }

    private func communityMoreMenu(_ skill: CommunitySkillManager.CommunitySkill) -> some View {
        Menu {
            Button {
                communitySkills.openStorageDirectory(skill)
            } label: {
                Label("打开目录", systemImage: "folder")
            }
            if communitySkills.aggregateState(for: skill) != .notInstalled {
                Button {
                    communitySkills.uninstall(skill)
                } label: {
                    Label("卸载（保留本地文件）", systemImage: "eject")
                }
            }
            Divider()
            Button(role: .destructive) {
                communitySkills.delete(skill)
            } label: {
                Label("删除（含本地文件）", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作：打开目录 / 卸载 / 删除")
    }

    // MARK: - 社区 Skill 详情页（v2.9.54：布局与官方 Skill 详情页一致）

    private func communitySkillDetailView(_ skill: CommunitySkillManager.CommunitySkill) -> some View {
        let state = communitySkills.aggregateState(for: skill)
        return VStack(alignment: .leading, spacing: 0) {
            // 顶栏：返回 + 关闭。
            HStack(spacing: 10) {
                Button {
                    selectedCommunitySkillID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("市场")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(AppTheme.chipBackground(scheme)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 标题块
                    HStack(alignment: .top, spacing: 14) {
                        communityIcon(size: 52, corner: 13)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name)
                                .font(.system(size: 18, weight: .bold))
                            Text("社区 · 自定义上传")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            if let v = skill.version, !v.isEmpty {
                                Text("v\(v)")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                        Spacer()
                        communityStatusControl(skill: skill, state: state)
                    }

                    // 描述
                    VStack(alignment: .leading, spacing: 6) {
                        Text("介绍")
                            .font(.system(size: 13, weight: .semibold))
                        Text(skill.summary)
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }

                    Divider()

                    // 来源 + 安装路径
                    VStack(alignment: .leading, spacing: 8) {
                        detailInfoRow(label: "来源", value: "社区 / 自定义上传")
                        detailInfoRow(label: "安装路径", value: skill.storagePath, mono: true)
                    }

                    Divider()

                    // 已安装到哪些 Agent
                    communityAgentSection(skill)

                    Divider()

                    // 操作按钮
                    VStack(alignment: .leading, spacing: 8) {
                        Text("操作")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 10) {
                            Button {
                                communitySkills.install(skill)
                            } label: {
                                Label("重新安装", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(communitySkills.isBusy)
                            .help("强制重建到所有检测到的 Agent 的软链接")

                            Button {
                                communitySkills.uninstall(skill)
                            } label: {
                                Label("卸载", systemImage: "eject")
                            }
                            .disabled(communitySkills.isBusy || state == .notInstalled)
                            .help("删除各 Agent 软链接（保留本地文件）")

                            Button {
                                communitySkills.openStorageDirectory(skill)
                            } label: {
                                Label("打开目录", systemImage: "folder")
                            }
                            .help("在 Finder 中打开该 Skill 的落盘目录")
                        }
                        Button(role: .destructive) {
                            let id = skill.id
                            communitySkills.delete(skill)
                            // 删除后该 Skill 已不存在，退回市场页。
                            if !communitySkills.skills.contains(where: { $0.id == id }) {
                                selectedCommunitySkillID = nil
                            }
                        } label: {
                            Label("删除（含本地文件与各 Agent 软链）", systemImage: "trash")
                                .foregroundColor(.red)
                        }
                        .help("彻底删除本地落盘文件并移除各 Agent 软链接")
                    }

                    if let msg = communitySkills.lastMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: communitySkills.lastMessageIsError
                                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text(msg)
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(communitySkills.lastMessageIsError ? .orange : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((communitySkills.lastMessageIsError ? Color.orange : Color.green).opacity(0.08))
                        )
                    }
                }
                .padding(18)
            }
        }
    }

    // 详情页信息行（label + value）。
    private func detailInfoRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: mono ? 11 : 12.5, design: mono ? .monospaced : .default))
                .foregroundColor(mono ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // 详情页「已安装到」区块：列出各检测到的 Agent 及其软链目标。
    @ViewBuilder
    private func communityAgentSection(_ skill: CommunitySkillManager.CommunitySkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("已安装到 Agent")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(communitySkills.installedAgentCount(for: skill)) / \(communitySkills.detectedAgents.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if communitySkills.detectedAgents.isEmpty {
                Text("未检测到任何 Agent（Claude Code / Cursor / Codex / Gemini CLI）。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            } else {
                ForEach(communitySkills.detectedAgents) { agent in
                    let installed = communitySkills.states[skill.id]?[agent.id] == .installed
                    HStack(spacing: 8) {
                        Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundColor(installed ? .green : .secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName)
                                .font(.system(size: 12.5, weight: .medium))
                            if installed {
                                Text((agent.skillsDir as NSString).appendingPathComponent(skill.id))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var filteredCommunitySkills: [CommunitySkillManager.CommunitySkill] {
        var items = communitySkills.skills
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            items = items.filter {
                $0.name.lowercased().contains(query) || $0.summary.lowercased().contains(query)
            }
        }
        if onlyInstalled {
            items = items.filter { communitySkills.aggregateState(for: $0) == .installed }
        }
        switch sort {
        case .recommended:
            break
        case .nameAscending:
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .installedFirst:
            items.sort {
                (communitySkills.aggregateState(for: $0) == .installed)
                && (communitySkills.aggregateState(for: $1) != .installed)
            }
        }
        return items
    }

    // MARK: - Filtering & sorting

    private var filteredItems: [PluginMarketItem] {
        var items = PluginCatalog.items(in: selectedCategory)

        // 搜索过滤（名称 / 来源 / 描述）。
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            items = items.filter {
                $0.name.lowercased().contains(query)
                || $0.source.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || $0.detail.lowercased().contains(query)
            }
        }

        // 仅显示已安装。
        if onlyInstalled {
            items = items.filter { isInstalled($0) }
        }

        // 排序。
        switch sort {
        case .recommended:
            break
        case .nameAscending:
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .installedFirst:
            items.sort { isInstalled($0) && !isInstalled($1) }
        }
        return items
    }

    private func isInstalled(_ item: PluginMarketItem) -> Bool {
        guard item.installsToAgent else { return false }
        return agentInstaller.aggregateState == .installed
    }
}
