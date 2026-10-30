import SwiftUI
import AppKit
import ClipSlotsKit

enum AgentMarketCategory: String, CaseIterable, Identifiable {
    case all = "全部", brand = "品牌设计", film = "影视创意", commerce = "电商广告"
    case game = "互动游戏", web = "网页应用", tools = "效率工具"
    var id: String { rawValue }
}

enum AgentMarketTab: String, CaseIterable {
    case all = "精选", apps = "应用", skills = "技能"
}

struct AgentMarketRecipe: Identifiable {
    let id: String
    let name: String
    let summary: String
    let category: AgentMarketCategory
    let symbol: String
    let color: UInt32
    let output: String
    let instruction: String
    let media: ModelPurpose?
    static let all: [Self] = [
        .init(id: "brand", name: "品牌视觉工作室", summary: "从品牌定位到一套统一的视觉方案",
              category: .brand, symbol: "square.stack.3d.up.fill", color: 0x6861c9,
              output: "品牌定位、视觉方向、配色与素材提示词",
              instruction: "先分析品牌定位、受众与使用场景，给出三套视觉方向，再整理统一的配色、构图、字体建议与图像提示词。先读取当前画布，保留已有素材；涉及修改先给出预览。", media: .canvasImage),
        .init(id: "film", name: "分镜创作助手", summary: "把一个故事变成可以制作的镜头脚本",
              category: .film, symbol: "film.stack.fill", color: 0x4b7d90,
              output: "故事结构、镜头表、角色设定与视频提示词",
              instruction: "先提炼故事、人物与情绪节奏，输出镜头编号、时长、景别、运镜、画面和声音的分镜表。整理角色一致性与参考素材要求；先规划，再按确认后的方案操作画布。", media: .canvasVideo),
        .init(id: "commerce", name: "产品广告创作", summary: "围绕卖点设计有节奏的产品广告",
              category: .commerce, symbol: "shippingbox.fill", color: 0xb77945,
              output: "卖点分析、广告脚本、主视觉与镜头提示词",
              instruction: "先读取产品信息和参考素材，明确目标受众、核心卖点、渠道与行动目标，输出广告主视觉、开场钩子、分镜及文案。不得编造产品规格；实际生成前确认模型、费用和方案。", media: .canvasImage),
        .init(id: "game", name: "互动游戏策划", summary: "把玩法想法整理成可验证的原型需求",
              category: .game, symbol: "gamecontroller.fill", color: 0x648870,
              output: "核心玩法、状态流、交互规则和原型需求",
              instruction: "把玩法拆成目标、核心循环、规则、状态、反馈与失败条件，输出可验证的原型需求和素材清单。明确当前环境的实现工具；没有工程执行工具时先交付需求与设计，不声称已完成游戏。", media: nil),
        .init(id: "web", name: "网页应用设计", summary: "从需求梳理到页面结构与交互说明",
              category: .web, symbol: "rectangle.3.group.fill", color: 0x5e78b4,
              output: "用户流程、页面结构、交互说明和实现需求",
              instruction: "先梳理目标用户、关键任务和数据，再输出页面结构、用户流程、组件状态、响应式布局和实现需求。复用当前画布资料；实际开发需使用已接入的工程工具，不把设计方案当作已部署应用。", media: nil)
    ]

    func prompt(topic: String, requirements: String, ratio: String) -> String? {
        let subject = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }
        return """
        使用「\(name)」创作用例。
        主题 / 产品：\(subject)
        补充要求：\(requirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "先提出必要的澄清问题" : requirements)
        画面比例：\(ratio)
        \(instruction)
        本轮附件与画布引用作为参考资料。只使用当前可用工具；缺少服务配置时说明所需配置。未经确认不要发起付费生成。
        """
    }
}

struct AgentLocalAppMarketView: View {
    @ObservedObject var model: AgentChatModel
    var isReadOnly = false
    var fixtureSkills: [AgentSkill]? = nil
    var onClose: () -> Void
    var onUse: () -> Void
    @ObservedObject private var library = AgentSkillLibrary.shared
    @AppStorage(AgentPreferences.enabledSkillsKey) private var enabledRaw = ""
    @State private var tab = AgentMarketTab.all
    @State private var category = AgentMarketCategory.all
    @State private var search = ""
    @State private var selection: String?
    @State private var topic = ""
    @State private var requirements = ""
    @State private var ratio = "16:9"
    @State private var notice: String?
    @State private var plugin: PluginMarketItem?
    @State private var connection: AgentExternalProjectContext?
    @State private var showSkills = false
    @State private var showWorkflows = false
    @State private var showConfig = false

    private var skills: [AgentSkill] { fixtureSkills ?? library.skills }
    private var enabled: Set<String> { AgentPreferences.decodeEnabledSlugs(enabledRaw) }
    private var cardFill: Color { TapSkin.tone(0xffffff, 0x1e1e1e) }
    private var border: Color { TapSkin.tone(0xe4e4e8, 0x333333) }
    private var filteredRecipes: [AgentMarketRecipe] {
        (fixtureSkills == nil ? [] : AgentMarketRecipe.all).filter { (category == .all || $0.category == category) && matches($0.name + $0.summary + $0.output) }
    }
    private var filteredSkills: [AgentSkill] {
        skills.filter { matches($0.name + $0.description + $0.source.displayName) }
    }
    private var filteredPlugins: [PluginMarketItem] {
        PluginCatalog.allItems.filter { !$0.installsToAgent && matches($0.name + $0.summary) }
    }
    private var browsing: Bool { selection == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(border).frame(height: 1)
            if browsing { browse } else { detail }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(TapSkin.ink)
        .background(TapSkin.tone(0xfafafa, 0x111111))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-app-market")
        .onAppear {
            if fixtureSkills == nil && (library.lastScanAt?.timeIntervalSinceNow ?? -999) < -30 { library.refresh() }
        }
        .onChange(of: model.selectedConversationID) { _ in selection = nil; connection = nil; notice = nil }
        .sheet(item: $plugin, onDismiss: { if fixtureSkills == nil { library.refresh() } }) { item in
            PluginsView(onClose: { plugin = nil }, initialCategory: item.category, initialItemID: item.id)
        }
        .sheet(isPresented: Binding(get: { connection != nil }, set: { if !$0 { connection = nil } })) {
            if let connection { AgentExternalHandoffView(context: connection, onClose: { self.connection = nil }) }
        }
        .sheet(isPresented: $showSkills, onDismiss: { if fixtureSkills == nil { library.refresh() } }) {
            VStack(spacing: 0) {
                HStack { Text("管理本地技能"); Spacer(); Button("完成") { showSkills = false } }.padding(12)
                AgentSkillPickerView(builtinToolCount: AgentBuiltinTools().specs().count)
            }
        }
        .sheet(isPresented: $showWorkflows) {
            if let context = model.canvasContext { WorkflowSkillLibraryView(model: model, context: context) }
        }
        .sheet(isPresented: $showConfig) { AgentConfigView(isWorkspace: model.usesWorkspaceBackend) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if browsing { onClose() } else { selection = nil; notice = nil }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 28)
            }.buttonStyle(.plain)
                .accessibilityLabel(browsing ? "返回对话" : "返回应用市场")
                .accessibilityIdentifier(browsing ? "agent-market-close" : "agent-market-back")
            Text(browsing ? "应用市场" : "应用详情").font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 0)
            Menu {
                Button("管理本地技能") { showSkills = true }.disabled(isReadOnly)
                Button("上传与安装技能") { plugin = PluginCatalog.clipSlotsSkill }.disabled(isReadOnly)
                Button("我的创作 Skill") { showWorkflows = true }.disabled(isReadOnly || model.canvasContext == nil)
                Button("Agent 设置") { showConfig = true }.disabled(isReadOnly)
                Button("刷新技能") { library.refresh() }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("agent-market-manage")
        }.padding(.horizontal, 12).frame(height: 48)
    }

    private var browse: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(TapSkin.secondaryInk)
                TextField("搜索应用、技能或用例", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("agent-market-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        .accessibilityIdentifier("agent-market-clear-search")
                }
            }.font(.system(size: 12)).padding(10)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 0.5))
                .padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 20) {
                ForEach(AgentMarketTab.allCases, id: \.self) { item in
                    Button { tab = item; if item == .skills { category = .all } } label: {
                        VStack(spacing: 8) {
                            Text(item.rawValue).font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                            Capsule().fill(tab == item ? TapSkin.ink : .clear).frame(height: 2)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("agent-market-tab-\(item)")
                }
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 16)
            if tab != .skills {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AgentMarketCategory.allCases) { item in
                            Button { category = item } label: {
                                Text(item.rawValue).font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(category == item ? TapSkin.tone(0xe9e9ed, 0x303033) : cardFill, in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("agent-market-category-\(item.id)")
                        }
                    }.padding(.horizontal, 16)
                }.padding(.vertical, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if fixtureSkills != nil && tab == .all && category == .all && search.isEmpty {
                        heading("最新上线")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(AgentMarketRecipe.all.prefix(3)) { recipe in
                                    Button { open(recipe.id) } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            cover(recipe.symbol, color: recipe.color, title: recipe.category.rawValue, height: 112)
                                            Text(recipe.name).font(.system(size: 12, weight: .semibold))
                                            Text(recipe.summary).font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk).lineLimit(2)
                                        }.frame(width: 222, alignment: .leading)
                                    }.buttonStyle(.plain).accessibilityIdentifier("agent-market-featured-\(recipe.id)")
                                }
                            }
                        }
                        heading("官方技能")
                        Button { open("canvas-mcp") } label: {
                            itemRow("画布 MCP", summary: "连接当前画布，让其他 Agent 参与创作",
                                    symbol: "point.3.connected.trianglepath.dotted", badge: model.canvasContext?.isActive == true ? "项目可连接" : "需打开画布")
                        }.buttonStyle(.plain).accessibilityIdentifier("agent-market-item-canvas-mcp")
                        ForEach(skills.filter { $0.source == .bundled }) { skill in skillRow(skill) }
                    }
                    if !(fixtureSkills != nil && tab == .all && category == .all && search.isEmpty),
                       (category == .all || category == .tools), matches("画布 MCP 连接当前项目") {
                        Button { open("canvas-mcp") } label: {
                            itemRow("画布 MCP", summary: "连接当前项目，让其他 Agent 参与创作",
                                    symbol: "point.3.connected.trianglepath.dotted", badge: "本地连接")
                        }.buttonStyle(.plain).accessibilityIdentifier("agent-market-item-canvas-mcp")
                    }
                    if tab != .skills && category != .tools && !filteredRecipes.isEmpty {
                        heading(tab == .all ? "创作用例" : "创作应用")
                        ForEach(filteredRecipes) { recipe in
                            Button { open(recipe.id) } label: {
                                itemRow(recipe.name, summary: recipe.summary, symbol: recipe.symbol,
                                        badge: category == .all ? recipe.category.rawValue : "")
                            }.buttonStyle(.plain).accessibilityIdentifier("agent-market-item-\(recipe.id)")
                        }
                    }
                    if tab != .apps && (category == .all || category == .tools) {
                        if !filteredSkills.isEmpty {
                            heading("本地技能", metadata: "\(filteredSkills.count) 项 · 已启用 \(enabled.intersection(Set(skills.map(\.slug))).count) 项")
                            ForEach(filteredSkills) { skill in skillRow(skill) }
                        } else if tab == .skills && search.isEmpty {
                            Text(library.isScanning ? "正在读取本地技能…" : "暂无本地技能，可从管理菜单上传或安装。")
                                .font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk)
                        }
                    }
                    if tab != .skills && (category == .all || category == .tools) && !filteredPlugins.isEmpty {
                        heading("效率工具")
                        ForEach(filteredPlugins) { item in
                            Button { open("plugin:" + item.id) } label: {
                                itemRow(item.name, summary: item.summary, symbol: item.iconSystemName, badge: "")
                            }.buttonStyle(.plain).accessibilityIdentifier("agent-market-item-plugin-\(item.id)")
                        }
                    }
                    if noResults {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 25))
                            Text("没有找到匹配的应用或技能").font(.system(size: 12))
                            Button("清除搜索") { search = ""; category = .all }.buttonStyle(.plain).font(.system(size: 11))
                        }.foregroundStyle(TapSkin.secondaryInk).frame(maxWidth: .infinity).padding(.vertical, 50)
                            .accessibilityIdentifier("agent-market-empty")
                    }
                }.padding(16)
            }
        }
    }

    private var noResults: Bool {
        !search.isEmpty && (tab == .skills || filteredRecipes.isEmpty || category == .tools)
            && (tab == .apps || filteredSkills.isEmpty || (category != .all && category != .tools))
            && (tab == .skills || filteredPlugins.isEmpty || (category != .all && category != .tools))
            && (!matches("画布 MCP 连接当前项目") || (category != .all && category != .tools))
    }

    @ViewBuilder private var detail: some View {
        if let recipe = AgentMarketRecipe.all.first(where: { $0.id == selection }) {
            recipeDetail(recipe)
        } else if let skill = skills.first(where: { "skill:" + $0.slug == selection }) {
            skillDetail(skill)
        } else if selection == "canvas-mcp" {
            connectionDetail
        } else if let item = PluginCatalog.allItems.first(where: { "plugin:" + $0.id == selection }) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        cover(item.iconSystemName, color: 0x647484, title: "效率工具", height: 146)
                        Text(item.name).font(.system(size: 22, weight: .semibold))
                        detailSection("能做什么", text: item.detail)
                        detailSection("接入方式", text: "这是独立应用。安装状态、下载与实际运行由插件管理页提供；安装独立应用不会自动授权给本轮 Agent。")
                    }.padding(16)
                }
                actionBar("查看安装与接入", disabled: isReadOnly) { plugin = item }
            }
        } else {
            VStack { Text("该技能已不在本地目录中"); Button("返回市场") { selection = nil } }.padding(24)
        }
    }

    private func recipeDetail(_ recipe: AgentMarketRecipe) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cover(recipe.symbol, color: recipe.color, title: recipe.category.rawValue, height: 142)
                    Text(recipe.name).font(.system(size: 22, weight: .semibold))
                    Text(recipe.summary).font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk)
                    detailSection("你将获得", text: recipe.output)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("准备创作资料").font(.system(size: 13, weight: .semibold))
                        TextField("主题 / 产品名称（必填）", text: $topic).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("agent-market-topic")
                        TextField("受众、风格、时长等补充要求", text: $requirements).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("agent-market-requirements")
                        HStack {
                            Text("画面比例")
                            Picker("画面比例", selection: $ratio) {
                                ForEach(["16:9", "9:16", "1:1", "4:3"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 105)
                            Spacer()
                            Button { model.chooseAttachments() } label: { Label("添加资料", systemImage: "paperclip") }
                                .disabled(isReadOnly || model.isImportingAttachments)
                        }.font(.system(size: 11))
                        if !model.draftAttachments.isEmpty || !model.draftReferences.isEmpty {
                            HStack(spacing: 12) {
                                if !model.draftAttachments.isEmpty {
                                    Label("\(model.draftAttachments.count) 个附件", systemImage: "paperclip")
                                }
                                if !model.draftReferences.isEmpty {
                                    Label("\(model.draftReferences.count) 个画布引用", systemImage: "square.on.square")
                                }
                            }.font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk)
                        }
                    }
                    if let purpose = recipe.media {
                        let configured = ModelConfigurationBridge.profile(purpose) != nil
                        detailSection("生成服务", text: configured ? "已配置\(purpose == .canvasVideo ? "视频" : "图像")用途路由；实际生成仍需可用凭据与确认。" : "尚未配置\(purpose == .canvasVideo ? "视频" : "图像")用途路由。可先完成方案，在「模型 → 配置中心」接入服务后生成。")
                    }
                    if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(.orange) }
                }.padding(16)
            }
            actionBar("在对话中试用", disabled: isReadOnly || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      help: "先整理需求与方案，再使用当前可用的画布和技能工具推进。内容会追加至当前草稿，保留附件与画布引用，你可编辑后发送。") {
                guard let prompt = recipe.prompt(topic: topic, requirements: requirements, ratio: ratio) else { return }
                model.draft += (model.draft.isEmpty ? "" : "\n\n") + prompt
                onUse()
            }
        }
    }

    private func skillDetail(_ skill: AgentSkill) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cover("puzzlepiece.extension.fill", color: 0x766ba0, title: skill.source.displayName, height: 142)
                    Text(skill.name).font(.system(size: 22, weight: .semibold))
                    detailSection("能做什么", text: skill.description.isEmpty ? "使用本地 Skill 文档指导当前 Agent。" : skill.description)
                    detailSection("能力组成", text: "\(skill.declaredTools.count) 个声明工具 · \(skill.scripts.count) 个目录脚本\n本轮引用读取实际 SKILL.md；启用后加入真实工具集合。")
                    detailSection("本地来源", text: skill.markdownPath)
                    Button {
                        var slugs = enabled
                        if slugs.contains(skill.slug) { slugs.remove(skill.slug) } else { slugs.insert(skill.slug) }
                        enabledRaw = AgentPreferences.encodeEnabledSlugs(slugs)
                    } label: {
                        Label(enabled.contains(skill.slug) ? "停用技能" : "启用技能",
                              systemImage: enabled.contains(skill.slug) ? "checkmark.circle.fill" : "plus.circle")
                    }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).padding(12)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(isReadOnly).accessibilityIdentifier("agent-market-enable-skill")
                    detailSection("使用范围", text: "启用该技能会允许 Agent 读取说明并使用其目录内脚本；访问范围和确认策略继续生效。")
                    if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(.orange) }
                }.padding(16)
            }
            actionBar(model.isAddingSkill ? "正在读取技能…" : "引用到本轮对话",
                      disabled: isReadOnly || model.isAddingSkill) {
                Task {
                    do { if try await model.referenceSkill(name: skill.name, path: skill.markdownPath) { onUse() } }
                    catch { notice = error.localizedDescription }
                }
            }
        }
    }

    private var connectionDetail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cover("point.3.connected.trianglepath.dotted", color: 0x527b85, title: "当前项目", height: 142)
                    Text("画布 MCP").font(.system(size: 22, weight: .semibold))
                    detailSection("让其他 Agent 参与创作", text: "连接当前项目与会话，读取节点和素材；支持节点编辑、连线、编组、布局及生成等原生画布能力。")
                    detailSection("访问范围", text: isReadOnly || model.accessMode == .allDirectoriesReadOnly
                                  ? "当前为只读模式，只提供读取能力。"
                                  : "修改遵守当前访问范围、原生确认和版本检查；生成需要已配置服务。")
                    detailSection("连接方式", text: "通过本机 MCP 服务连接，项目连接有效期为 30 分钟。选择其他 Agent 后复制配置或打开应用。")
                    if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(.orange).accessibilityIdentifier("agent-market-notice") }
                }.padding(16)
            }
            actionBar("连接当前画布", disabled: model.canvasContext?.isActive != true) {
                do { connection = try model.externalHandoffContext(readOnly: isReadOnly) }
                catch { notice = error.localizedDescription }
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }
    private func open(_ id: String) { selection = id; notice = nil; topic = ""; requirements = "" }
    private func heading(_ title: String, metadata: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if !metadata.isEmpty {
                Text(metadata).font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }
    private func skillRow(_ skill: AgentSkill) -> some View {
        Button { open("skill:" + skill.slug) } label: {
            itemRow(skill.name, summary: skill.description, symbol: "puzzlepiece.extension",
                    badge: enabled.contains(skill.slug) ? "已添加" : skill.source.displayName)
        }.buttonStyle(.plain).accessibilityIdentifier("agent-market-item-skill-\(skill.slug)")
    }
    private func itemRow(_ title: String, summary: String, symbol: String, badge: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 36, height: 38)
                .background(TapSkin.tone(0xf0f0f3, 0x2c2c30), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if !badge.isEmpty {
                        Text(badge).font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk)
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk)
                    }
                }
                Text(summary).font(.system(size: 10)).foregroundStyle(TapSkin.secondaryInk).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(border, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }
    private func cover(_ symbol: String, color: UInt32, title: String, height: CGFloat) -> some View {
        let tint = Color(red: Double((color >> 16) & 255) / 255,
                         green: Double((color >> 8) & 255) / 255, blue: Double(color & 255) / 255)
        return ZStack {
            LinearGradient(colors: [tint.opacity(0.82), tint.opacity(0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().stroke(.white.opacity(0.14), lineWidth: 1).frame(width: 180, height: 180).offset(x: 75, y: 45)
            RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1)
                .frame(width: 110, height: 110).rotationEffect(.degrees(25)).offset(x: -80, y: -38)
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.92))
        }.frame(height: height)
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
    }
    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(TapSkin.secondaryInk)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func actionBar(_ title: String, disabled: Bool = false, help: String? = nil, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(border).frame(height: 1)
            HStack(spacing: 6) {
              Button(action: action) {
                Text(title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 38)
                    .foregroundStyle(TapSkin.tone(0xffffff, 0x181818))
                    .background(TapSkin.tone(0x262626, 0xededed), in: RoundedRectangle(cornerRadius: 10))
                    .opacity(disabled ? 0.45 : 1)
              }.buttonStyle(.plain).disabled(disabled)
                .accessibilityIdentifier("agent-market-primary")
              if let help {
                  InterfaceHelpButton(title: "试用方式", text: help, identifier: "agent-market-recipe-help")
              }
            }.padding(14)
        }.background(TapSkin.tone(0xfafafa, 0x111111))
    }
}
