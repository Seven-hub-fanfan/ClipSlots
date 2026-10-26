import SwiftUI
import ClipSlotsKit
import AppKit
import AVKit

private enum ModelWorkspaceTab: String, CaseIterable, Identifiable {
    case evaluation = "测评", ranking = "排行榜", configuration = "配置中心", news = "AI 日报"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .evaluation: return "square.grid.3x3"; case .ranking: return "chart.bar.xaxis"
        case .configuration: return "slider.horizontal.3"; case .news: return "newspaper" }
    }
}

struct ModelWorkspaceView: View {
    let store: SlotStoreObservable
    @ObservedObject var models = ModelWorkspaceStore.shared
    @State private var tab: ModelWorkspaceTab = .evaluation
    @State private var bankID = ""
    @State private var selectedModels = Set<String>()
    @State private var showingBank = false
    @State private var editingBank = false
    @State private var selectedQuestions = Set<String>()
    @State private var useAllQuestions = true
    @State private var showingQuestionGenerator = false
    @State private var profileDraft: ModelProfile?
    @State private var questionDraft: ModelQuestion?
    @State private var scoreCell: ModelEvaluationCell?
    @State private var previewCell: ModelEvaluationCell?
    @State private var filingCell: ModelEvaluationCell?
    @State private var showingRunPreview = false
    @State private var configurationCLI = false
    @State private var showingEnvironment = false
    @State private var rankKind: ModelKind = .llm
    @State private var newsSearch = ""
    @State private var newsSourceID = ""
    @State private var showingSources = false
    private var bank: ModelQuestionBank? { models.document.banks.first { $0.id == bankID } }
    private var run: ModelEvaluationRun? { models.document.runs.first { $0.id == models.selectedRunID } }
    init(store: SlotStoreObservable, models: ModelWorkspaceStore = .shared, initialTab: String = "测评") {
        self.store = store; self.models = models
        _tab = State(initialValue: ModelWorkspaceTab(rawValue: initialTab) ?? .evaluation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("模型").font(.system(size: 27, weight: .semibold))
                    Text("出题、测评、配置与每日 AI 资讯").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if !models.loaded { ProgressView().controlSize(.small) }
                HStack(spacing: 4) {
                    ForEach(ModelWorkspaceTab.allCases) { item in
                        Button { tab = item } label: {
                            Label(item.rawValue, systemImage: item.symbol).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(tab == item ? TapSkin.tone(0xe9ebf0, 0x34373f) : .clear, in: Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("models-tab-\(item.id)")
                    }
                }.padding(4).background(TapSkin.tone(0xf5f5f7, 0x25272c), in: Capsule())
            }
            if let message = models.message {
                HStack {
                    Image(systemName: "info.circle")
                    Text(message).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button { models.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(TapSkin.tone(0xf4f1e8, 0x353025), in: RoundedRectangle(cornerRadius: 10))
            }
            Group {
                switch tab {
                case .evaluation: evaluation
                case .ranking: ranking
                case .configuration: configuration
                case .news: news
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("models-section-\(tab.rawValue)")
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 20)
        .background(TapSkin.tone(0xfafafb, 0x1b1d21))
        .accessibilityIdentifier("model-workspace")
        .task {
            await models.load()
            if bankID.isEmpty { bankID = models.document.banks.first?.id ?? "" }
            ModelConfigurationBridge.update(models.document)
        }
        .onChange(of: tab) { value in if value == .news { Task { await models.refreshNews() } } }
        .sheet(isPresented: $showingBank) { bankEditor }
        .sheet(isPresented: $editingBank) { ModelBankEditor(models: models, store: store, existing: bank) { bankID = $0 } }
        .sheet(isPresented: $showingQuestionGenerator) { ModelQuestionGenerator(models: models, bankID: bankID, store: store) }
        .sheet(item: $profileDraft) { draft in
            ModelProfileEditor(profile: draft, models: models)
        }
        .sheet(item: $questionDraft) { draft in
            ModelQuestionEditor(question: draft) { question in
                await models.editQuestion(question, bankID: bankID, store: store)
            }
        }
        .sheet(item: $scoreCell) { cell in
            if let question = run?.bank.questions.first(where: { $0.id == cell.questionID }) {
                ModelScoreEditor(cell: cell, question: question, models: models)
            }
        }
        .sheet(item: $previewCell) { cell in ModelResultPreview(cell: cell, kind: run?.models.first { $0.id == cell.modelID }?.kind ?? .llm) }
        .sheet(item: $filingCell) { cell in ModelResultSlotEditor(cell: cell, models: models, store: store) }
        .sheet(isPresented: $showingEnvironment) { EnvironmentSetupView() }
        .sheet(isPresented: $showingSources) { ModelNewsSourcesEditor(models: models) }
        .alert("启动测评", isPresented: $showingRunPreview) {
            Button("取消", role: .cancel) {}
            Button("开始请求") { Task { await models.start(bankID: bankID, selectedIDs: selectedModels, questionIDs: useAllQuestions ? nil : selectedQuestions) } }
        } message: {
            Text("\(chosenQuestions.count) 道题 · \(selectedModels.count) 个模型 · \(plannedCells) 次匹配请求。\n使用当前题库与配置快照，实际并发最多 4，遵守各模型限流。服务可能计费。")
        }
    }

    private var chosenQuestions: [ModelQuestion] {
        (bank?.questions ?? []).filter { useAllQuestions || selectedQuestions.contains($0.id) }
    }
    private var plannedCells: Int {
        chosenQuestions.reduce(0) { total, q in total + models.profiles.filter { selectedModels.contains($0.id) && $0.kind == q.kind }.count }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(TapSkin.tone(0xffffff, 0x24262b), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TapSkin.tone(0xe5e6eb, 0x353840), lineWidth: 1))
    }
    private func empty(_ title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(36)
    }

    private var evaluation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("题库").font(.system(size: 16, weight: .semibold))
                            Picker("题库", selection: $bankID) {
                                Text("选择题库").tag("")
                                ForEach(models.document.banks) { bank in Text("\(bank.name) · \(bank.questions.count) 题").tag(bank.id) }
                            }.labelsHidden().frame(maxWidth: 300)
                            Spacer()
                            Button("绑定槽位") { showingBank = true }.accessibilityIdentifier("models-bind-bank")
                            Button("同步") { Task { await models.synchronizeBank(bankID) } }.disabled(bank == nil)
                            Button("题库配置") { editingBank = true }.disabled(bank == nil)
                            Button("出题") { showingQuestionGenerator = true }.disabled(bank == nil)
                        }
                        if let bank {
                            Toggle("运行全部题目", isOn: $useAllQuestions).font(.system(size: 11))
                            Text("版本 \(bank.revision.prefix(8)) · 与 \(bank.groupIDs.count) 个槽位组同步")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            ForEach(bank.questions) { q in
                                HStack(alignment: .top, spacing: 12) {
                                    if !useAllQuestions {
                                        Toggle("", isOn: Binding(get: { selectedQuestions.contains(q.id) }, set: {
                                            if $0 { selectedQuestions.insert(q.id) } else { selectedQuestions.remove(q.id) }
                                        })).labelsHidden()
                                    }
                                    Text(q.kind.title).font(.system(size: 10, weight: .medium)).frame(width: 42)
                                        .padding(6).background(TapSkin.tone(0xf1f2f6, 0x33363d), in: Capsule())
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(q.title.isEmpty ? "未命名题目" : q.title).font(.system(size: 12, weight: .semibold))
                                        Text(q.prompt.isEmpty ? "缺少题干，请编辑" : q.prompt).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        if q.conflict { Text("槽位内容变化且题目有修改，请打开编辑核对。").font(.system(size: 11)).foregroundStyle(.orange) }
                                    }
                                    Spacer()
                                    Text(q.slot.map { "槽位 \($0)" } ?? "未绑定").font(.system(size: 11)).foregroundStyle(.secondary)
                                    Button("编辑") { questionDraft = q }
                                }.padding(.vertical, 5)
                            }
                            if bank.questions.isEmpty { empty("题库为空", subtitle: "同步已有槽位，或生成题目草稿后审核保存。", symbol: "tray") }
                        } else { empty("建立第一份题库", subtitle: "绑定槽位组，复用已有提示词与参考素材。", symbol: "rectangle.stack.badge.plus") }
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("对比模型").font(.system(size: 16, weight: .semibold))
                            Text("\(selectedModels.count) / 14").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("配置模型") { tab = .configuration }
                            Button("预览并启动") { showingRunPreview = true }
                                .disabled(bank == nil || selectedModels.isEmpty || plannedCells == 0)
                                .accessibilityIdentifier("models-start-evaluation")
                        }
                        if models.profiles.isEmpty { Text("尚无模型配置。").foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                            ForEach(models.profiles) { profile in
                                Button {
                                    if selectedModels.contains(profile.id) { selectedModels.remove(profile.id) }
                                    else if selectedModels.count < 14 { selectedModels.insert(profile.id) }
                                    else { models.message = "一次最多对比 14 个模型，已有选择已保留。" }
                                } label: {
                                    HStack {
                                        Image(systemName: selectedModels.contains(profile.id) ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text("\(profile.kind.title) · \(profile.cliContext?.provider.rawValue ?? "API")")
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.padding(12).background(TapSkin.tone(0xf6f6f9, 0x2c2e34), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                results
            }.padding(.bottom, 8)
        }
    }
    private var results: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("结果集").font(.system(size: 16, weight: .semibold))
                    Picker("结果集", selection: Binding(get: { models.selectedRunID ?? "" }, set: { models.selectedRunID = $0 })) {
                        Text("选择结果集").tag("")
                        ForEach(models.document.runs.reversed()) { run in
                            Text("\(run.title) · \(run.createdAt.formatted(date: .abbreviated, time: .shortened))").tag(run.id)
                        }
                    }.labelsHidden().frame(maxWidth: 350)
                    Spacer()
                    if let run {
                        Button("导出") { export(run) }
                        Button("取消剩余") { Task { await models.cancel(run.id) } }.disabled(!run.cells.contains(where: { $0.state.active }))
                    }
                }
                if let run {
                    Text("\(run.cells.filter { $0.state == .succeeded }.count) / \(run.cells.count) 已成功 · 固定题库版本 \(run.bank.revision.prefix(8))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("题目").font(.system(size: 12, weight: .semibold)).frame(width: 160, alignment: .leading)
                                ForEach(run.models) { p in Text(p.name).font(.system(size: 12, weight: .semibold)).frame(width: 210, alignment: .leading) }
                            }
                            ForEach(run.bank.questions) { q in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(q.title).font(.system(size: 12, weight: .medium))
                                        Text(q.prompt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
                                    }.frame(width: 160, alignment: .leading).padding(.vertical, 8)
                                    ForEach(run.models) { p in
                                        if let cell = run.cells.first(where: { $0.questionID == q.id && $0.modelID == p.id }) {
                                            resultCell(cell)
                                        } else { Text("类型不适用").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 210, height: 120) }
                                    }
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                } else { empty("还没有结果集", subtitle: "选择题库和模型，预览请求数后启动测评。", symbol: "square.grid.3x3") }
            }
        }
    }
    private func resultCell(_ cell: ModelEvaluationCell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(cell.state == .succeeded ? Color.green : cell.state == .failed || cell.state == .unknown ? .orange : .gray).frame(width: 6, height: 6)
                Text(cell.state.title).font(.system(size: 11, weight: .medium))
                Spacer()
                if let started = cell.startedAt, let end = cell.completedAt { Text(String(format: "%.1fs", end.timeIntervalSince(started))).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if !cell.text.isEmpty { Text(cell.text).font(.system(size: 11)).lineLimit(5).textSelection(.enabled) }
            if !cell.mediaURLs.isEmpty { Label("\(cell.mediaURLs.count) 个媒体产物", systemImage: "photo.on.rectangle").font(.system(size: 11)) }
            if !cell.detail.isEmpty { Text(cell.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(4) }
            if cell.state == .queued { Text("等待并发额度").font(.system(size: 10)).foregroundStyle(.secondary) }
            HStack {
                if cell.state == .succeeded {
                    Button("查看") { previewCell = cell }
                    Button("存槽位") { filingCell = cell }
                    Button(cell.scoredAt == nil ? "评分" : "改分") { scoreCell = cell }
                } else if [.failed, .cancelled, .polling].contains(cell.state) {
                    Button(cell.taskID == nil || cell.terminalRemoteFailure ? "重试" : "继续查询") { Task { await models.retry(cell.id) } }
                }
            }.font(.system(size: 10))
        }.padding(12).frame(width: 210, alignment: .topLeading).frame(minHeight: 120)
            .background(TapSkin.tone(0xf6f6f8, 0x2d3036), in: RoundedRectangle(cornerRadius: 10))
    }
    private func export(_ run: ModelEvaluationRun) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "模型测评-\(run.id.prefix(8)).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(run).write(to: url, options: .atomic)
            } catch { models.message = error.localizedDescription }
        }
    }
    private var ranking: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("本地测评能力榜").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Picker("类型", selection: $rankKind) { ForEach(ModelKind.allCases) { Text($0.title).tag($0) } }.frame(width: 130)
                    Picker("结果集", selection: Binding(get: { models.selectedRunID ?? "" }, set: { models.selectedRunID = $0 })) {
                        Text("选择测评口径").tag("")
                        ForEach(models.document.runs.reversed()) { Text($0.title + " · " + String($0.bank.revision.prefix(8))).tag($0.id) }
                    }.frame(maxWidth: 330)
                }
                Text("0–100 分 · 人工评分 · 题库权重 · 按同一适用维度与评分来源分榜。未评分与不适用维度不计为零。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let run {
                    let entries = ModelRanking.entries(run: run, kind: rankKind)
                    if entries.isEmpty { empty("暂无有效排名", subtitle: "完成测评后为全部适用维度评分，即可生成可追溯的能力榜。", symbol: "chart.bar.xaxis") }
                    ForEach(Array(Set(entries.map(\.dimensionKey))).sorted(), id: \.self) { key in
                        let group = entries.filter { $0.dimensionKey == key }
                        card {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(group.first.map { $0.scores.keys.sorted().compactMap(ModelDimension.init(rawValue:)).map(\.title).joined(separator: " · ") } ?? "")
                                    .font(.system(size: 12, weight: .medium))
                                ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                                    HStack(spacing: 24) {
                                        Text(String(index + 1)).font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28)
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(entry.model.name).font(.system(size: 16, weight: .semibold))
                                            Text(String(format: "%.1f 分 · %d 个有效样本", entry.total, entry.samples)).font(.system(size: 12))
                                            Text(entry.updatedAt.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
                                            Text("模型版本 \(entry.model.revision.prefix(8)) · 题库版本 \(run.bank.revision.prefix(8))").font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        ModelRadarView(scores: entry.scores).frame(width: 300, height: 240)
                                    }
                                }
                            }
                        }
                    }
                } else { empty("选择一个结果集", subtitle: "LLM、图像与视频榜使用相同题库版本的实际测评分数。", symbol: "chart.bar.xaxis") }
            }
        }
    }
    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("合集", selection: $configurationCLI) { Text("API 模型").tag(false); Text("内部产品 CLI").tag(true) }
                        .pickerStyle(.segmented).frame(width: 300)
                    Spacer()
                    Button(configurationCLI ? "环境检测" : "新增 API 模型") {
                        if configurationCLI { showingEnvironment = true } else { profileDraft = ModelProfile() }
                    }
                }
                if configurationCLI {
                    card {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("内部产品 CLI").font(.system(size: 17, weight: .semibold))
                            Text("沿用各产品的本地安装、登录与账号配置。发现能力不发起生成。").font(.system(size: 12)).foregroundStyle(.secondary)
                            ForEach([LocalTool.crate, .ba, .tika], id: \.rawValue) { tool in
                                HStack {
                                    Label(tool.title, systemImage: "terminal").font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text(LocalToolchain().resolve(tool) == nil ? "未安装" : "已安装").font(.system(size: 11)).foregroundStyle(.secondary)
                                    if tool != .tika {
                                        Button("发现能力") { Task { await models.discoverCLI(tool == .crate ? .crate : .byteartist) } }.disabled(models.discoveringCLI)
                                    } else { Text("Agent 后端").font(.system(size: 11)).foregroundStyle(.secondary) }
                                    Button("配置") { showingEnvironment = true }
                                }.padding(.vertical, 4)
                            }
                            if models.discoveringCLI { ProgressView().controlSize(.small) }
                            ForEach(models.cliCapabilities, id: \.id) { capability in
                                HStack {
                                    Text(capability.title).font(.system(size: 12))
                                    Text(capability.kind.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("加入模型目录") { Task { await models.importCapability(capability) } }
                                }
                            }
                        }
                    }
                }
                ForEach(models.document.profiles.filter { $0.isCLI == configurationCLI }) { profile in
                    card {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(profile.name).font(.system(size: 15, weight: .semibold))
                                Text("\(profile.kind.title) · \(profile.model)").font(.system(size: 12)).foregroundStyle(.secondary)
                                Text(profile.isCLI ? "\(profile.cliContext?.provider.rawValue ?? "") · \(profile.cliContext?.controlPlane ?? "") · \(profile.cliContext?.accountAlias ?? "")" : profile.endpoint)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("编辑") { profileDraft = profile }
                            Button("移除") { Task { await models.removeProfile(profile.id) } }
                        }
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("默认用途").font(.system(size: 16, weight: .semibold))
                        ForEach(ModelPurpose.allCases) { purpose in
                            Picker(purpose.title, selection: Binding(get: { models.document.defaults[purpose.rawValue] ?? "" }, set: { id in Task { await models.setDefault(purpose, id: id) } })) {
                                Text("沿用原配置 / 未设置").tag("")
                                ForEach(models.profiles.filter { !$0.isCLI && $0.kind == purpose.kind && !([ModelPurpose.agent, .questions].contains(purpose)
                                    && $0.contract != .chatCompletions) }) { Text($0.name).tag($0.id) }
                            }.frame(maxWidth: 500)
                        }
                    }
                }
            }
        }
    }
    private var news: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("搜索 AI 新闻", text: $newsSearch).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                Picker("来源", selection: $newsSourceID) {
                    Text("全部来源").tag("")
                    ForEach(models.document.newsSources) { Text($0.name).tag($0.id) }
                }.frame(width: 180)
                Spacer()
                if models.refreshingNews { ProgressView().controlSize(.small) }
                Button("来源配置") { showingSources = true }
                Button("刷新") { Task { await models.refreshNews(force: true) } }.disabled(models.refreshingNews)
            }
            Text(models.document.newsRefreshedAt.map { "最近成功抓取：\($0.formatted()) · 按原文发布时间排序" } ?? "尚未成功抓取新闻")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !models.document.newsErrors.isEmpty {
                Text("部分来源暂不可用，保留离线缓存。\(models.document.newsErrors.values.joined(separator: " "))")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let items = models.document.news.filter { (newsSourceID.isEmpty || $0.sourceID == newsSourceID)
                        && (newsSearch.isEmpty || ($0.title + $0.summary).localizedCaseInsensitiveContains(newsSearch)) }
                    if items.isEmpty { empty("暂无新闻", subtitle: "刷新公开新闻源，或在来源配置中添加 RSS / Atom 地址。", symbol: "newspaper") }
                    ForEach(items) { item in
                        card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(item.sourceName).font(.system(size: 11, weight: .medium))
                                    Text(item.publishedAt.map { Calendar.current.isDateInToday($0) ? "今日 · \($0.formatted(date: .omitted, time: .shortened))" : $0.formatted(date: .abbreviated, time: .shortened) } ?? "发布时间未知")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                    if let url = URL(string: item.url) { Link("原文 ↗", destination: url).font(.system(size: 11)) }
                                }
                                Text(item.title).font(.system(size: 16, weight: .semibold))
                                if !item.summary.isEmpty { Text(item.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4) }
                                Text("来源摘要 · 抓取于 \(item.fetchedAt.formatted())").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
    private var bankEditor: some View { ModelBankEditor(models: models, store: store) { id in bankID = id } }
}

struct ModelRadarView: View {
    let scores: [String: Double]
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)
            let radius = Double(min(geometry.size.width, geometry.size.height)) * 0.32
            ZStack {
                ForEach(1..<5) { level in
                    polygon(center: center, radius: radius * Double(level) / 4, values: nil)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                }
                if scores.count == 6 {
                    polygon(center: center, radius: radius, values: scores).fill(Color.accentColor.opacity(0.16))
                    polygon(center: center, radius: radius, values: scores).stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                }
                ForEach(Array(ModelDimension.allCases.enumerated()), id: \.element.id) { index, dimension in
                    if let score = scores[dimension.rawValue] {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .position(point(center, radius * max(0, min(100, score)) / 100, index))
                    }
                }
                ForEach(Array(ModelDimension.allCases.enumerated()), id: \.element.id) { index, dimension in
                    let point = point(center, radius * 1.35, index)
                    VStack(spacing: 3) {
                        Text(dimension.title).font(.system(size: 10))
                        Text(scores[dimension.rawValue].map { String(format: "%.0f", $0) } ?? "不适用")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }.position(point)
                }
            }
        }.accessibilityLabel(ModelDimension.allCases.map { "\($0.title)：\(scores[$0.rawValue].map { String(format: "%.1f", $0) } ?? "不适用")" }.joined(separator: "，"))
    }
    private func point(_ center: CGPoint, _ radius: Double, _ index: Int) -> CGPoint {
        let angle = Double(index) * .pi / 3 - .pi / 2
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    private func polygon(center: CGPoint, radius: Double, values: [String: Double]?) -> Path {
        Path { path in
            for (index, dimension) in ModelDimension.allCases.enumerated() {
                let value = values.map { max(0, min(100, $0[dimension.rawValue] ?? 0)) / 100 } ?? 1
                let p = point(center, radius * value, index)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }
}
