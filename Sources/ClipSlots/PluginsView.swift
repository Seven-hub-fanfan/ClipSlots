import SwiftUI

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

    // 保留旧标记键以兼容历史用户（当前仅作展示，不联动 CLI）。
    @AppStorage("skill_clipslots_manager_enabled") private var skillEnabled = true

    @State private var searchText = ""
    @State private var sort: PluginMarketSort = .recommended
    @State private var onlyInstalled = false
    @State private var selectedCategory: PluginMarketCategory = .officialSkill
    @State private var selectedItemID: String? = nil

    private var selectedItem: PluginMarketItem? {
        guard let id = selectedItemID else { return nil }
        return PluginCatalog.allItems.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let item = selectedItem {
                detailView(item)
            } else {
                marketView
            }
        }
        .frame(width: 560, height: 588)
        .background(AppTheme.windowBackground(scheme))
        // v2.9.30: 进入 Skill 市场页时也静默同步一次，确保已安装的 Skill 用到最新决策流。
        .onAppear { agentInstaller.syncInstalledSkillsOnLaunch() }
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
        Button {
            selectedItemID = item.id
        } label: {
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
        }
        .buttonStyle(.plain)
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
            badge(text: "内置", icon: "shippingbox.fill", color: .secondary)
        }
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
            badge(text: "内置", icon: "shippingbox.fill", color: .secondary)
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
                        detailInstallControl(for: item)
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
                    }

                    if item.installsToAgent {
                        Divider()
                        agentInstallSection
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
