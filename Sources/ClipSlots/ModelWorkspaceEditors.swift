import SwiftUI
import ClipSlotsKit
import AppKit
import AVKit

struct ModelProfileEditor: View {
    @State var profile: ModelProfile
    @ObservedObject var models: ModelWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var parameters = "{}"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.isCLI ? "CLI 模型配置" : "API 模型配置").font(.system(size: 20, weight: .semibold))
            ScrollView {
                Form {
                    TextField("名称", text: $profile.name)
                    TextField("模型标识", text: $profile.model)
                    Picker("输出类型", selection: $profile.kind) { ForEach(ModelKind.allCases) { Text($0.title).tag($0) } }
                    if !profile.isCLI {
                        TextField("完整请求地址", text: $profile.endpoint)
                        Text("请填写实际接口 URL，例如 …/v1/chat/completions。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("接口契约", selection: $profile.contract) { ForEach(ModelAPIContract.allCases) { Text($0.title).tag($0) } }
                        Toggle("需要密钥", isOn: $profile.requiresKey)
                        if profile.requiresKey {
                            SecureField("新密钥（留空保留已有）", text: $key)
                            TextField("认证请求头", text: $profile.authHeader)
                            TextField("认证前缀", text: $profile.authPrefix)
                            Text("密钥保存到 macOS 钥匙串，不进入题库和结果导出。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Toggle("支持 LLM 图像参考输入", isOn: $profile.supportsImages)
                        if profile.contract == .asyncMedia {
                            TextField("参考输入字段（可选）", text: Binding(get: { profile.referenceInputField ?? "" },
                                set: { profile.referenceInputField = $0.isEmpty ? nil : $0 }))
                            Text("填写接口接收 data URL 数组的字段名；请按服务文档配置。").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("查询 URL（含 {id}）", text: $profile.asynchronous.queryURL)
                            TextField("提交任务 ID 路径", text: $profile.asynchronous.taskIDPath)
                            TextField("查询状态路径", text: $profile.asynchronous.statusPath)
                            TextField("媒体 URL 路径", text: $profile.asynchronous.outputPath)
                            TextField("成功状态（逗号分隔）", text: Binding(get: { profile.asynchronous.successValues.joined(separator: ",") }, set: { profile.asynchronous.successValues = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                            TextField("失败状态（逗号分隔）", text: Binding(get: { profile.asynchronous.failureValues.joined(separator: ",") }, set: { profile.asynchronous.failureValues = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                            Text("字段路径按点号分隔，例如 data.outputs.0.url。异步提交使用 model、prompt 和下方参数。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else { TextField("提示词字段", text: $profile.cliPromptKey) }
                    Stepper("并发上限：\(profile.concurrency)", value: $profile.concurrency, in: 1...14)
                    TextField("请求超时（秒）", value: $profile.timeout, format: .number)
                    Toggle("启用", isOn: $profile.enabled)
                    Text("默认参数 JSON").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $parameters).font(.system(size: 11, design: .monospaced)).frame(height: 120)
                }.textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Text("保存配置不会发起模型请求。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    busy = true
                    Task {
                        defer { busy = false }
                        guard let raw = try? JSONValue.decode(jsonText: parameters).objectValue else {
                            error = "默认参数需要 JSON 对象。"; return
                        }
                        profile.parameters = raw
                        if await models.saveProfile(profile, key: key) { dismiss() }
                        else { error = models.message }
                    }
                }.disabled(busy)
            }
        }.padding(24).frame(width: 580, height: 680)
            .onAppear { parameters = (try? JSONValue.object(profile.parameters).encodedText()) ?? "{}" }
    }
}

struct ModelBankEditor: View {
    @ObservedObject var models: ModelWorkspaceStore
    let store: SlotStoreObservable
    var existing: ModelQuestionBank? = nil
    var selected: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ModelKind = .llm
    @State private var groups: [SpecialSlot] = []
    @State private var selectedGroups = Set<String>()
    @State private var busy = false
    @State private var weights: [String: Double] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "绑定槽位题库" : "题库配置").font(.system(size: 20, weight: .semibold))
            TextField("题库名称", text: $name).textFieldStyle(.roundedBorder)
            Picker("题目类型", selection: $kind) { ForEach(ModelKind.allCases) { Text($0.title).tag($0) } }
            Text("题干与附件读取自槽位；审核后编辑题目会同步正文，原附件保留。").font(.system(size: 12)).foregroundStyle(.secondary)
            List(groups) { group in
                Toggle(group.name, isOn: Binding(get: { selectedGroups.contains(group.id) }, set: {
                    if $0 { selectedGroups.insert(group.id) } else { selectedGroups.remove(group.id) }
                }))
            }.frame(height: 260)
            if existing != nil {
                Text("评分权重（解绑只移出题库，槽位内容保留）").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    ForEach(ModelDimension.allCases) { dimension in
                        VStack {
                            Text(dimension.title).font(.system(size: 10))
                            TextField("权重", value: Binding(get: { weights[dimension.rawValue] ?? 1 },
                                set: { weights[dimension.rawValue] = $0 }), format: .number).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            HStack {
                Button("新建独立槽位页面") {
                    store.createPage(name: name.isEmpty ? "模型题库" : name)
                    Task { groups = await availableGroups() }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("绑定并同步") {
                    busy = true
                    Task {
                        if var bank = existing {
                            bank.name = name; bank.groupIDs = Array(selectedGroups).sorted(); bank.weights = weights
                            await models.updateBank(bank); selected(bank.id)
                        } else {
                            await models.bindBank(name: name, groupIDs: Array(selectedGroups).sorted(), kind: kind)
                            if let id = models.document.banks.last?.id { selected(id) }
                        }
                        busy = false; dismiss()
                    }
                }.disabled(selectedGroups.isEmpty || busy)
            }
        }.padding(24).frame(width: 550)
            .task {
                groups = await availableGroups()
                if let existing {
                    name = existing.name; selectedGroups = Set(existing.groupIDs)
                    weights = Dictionary(uniqueKeysWithValues: ModelDimension.allCases.map { ($0.rawValue, existing.weights[$0.rawValue] ?? 1) })
                }
            }
    }
    private func availableGroups() async -> [SpecialSlot] {
        await Task.detached { SpecialSlotStorage.shared.loadIndex().specialSlots.filter { !SpecialSlotStorage.isReservedGroupId($0.id) } }.value
    }
}

struct ModelQuestionEditor: View {
    @State var question: ModelQuestion
    var save: (ModelQuestion) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var currentSlot: SlotContent?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑测评题目").font(.system(size: 20, weight: .semibold))
            TextField("标题", text: $question.title).textFieldStyle(.roundedBorder)
            Picker("类型", selection: $question.kind) { ForEach(ModelKind.allCases) { Text($0.title).tag($0) } }
            Text("题干").font(.system(size: 12, weight: .semibold))
            TextEditor(text: $question.prompt).frame(height: 150)
            Text("可观察的评分标准").font(.system(size: 12, weight: .semibold))
            TextEditor(text: $question.criteria).frame(height: 90)
            TextField("标签 / 难度", text: $question.tags).textFieldStyle(.roundedBorder)
            HStack {
                ForEach(ModelDimension.allCases) { dimension in
                    Toggle(dimension.title, isOn: Binding(get: { question.dimensions.contains(dimension) }, set: {
                        if $0 { question.dimensions.append(dimension) } else { question.dimensions.removeAll { $0 == dimension } }
                    })).font(.system(size: 10))
                }
            }
            if let currentSlot, question.conflict || question.slotRevision != BatchGenerationSource.revision(of: currentSlot) {
                Text("请核对并选择保留正文；保存时仍会核验最新版本。").font(.system(size: 12)).foregroundStyle(.orange)
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("同步时正文").font(.system(size: 11, weight: .medium))
                        Text(question.syncedPrompt ?? "").font(.system(size: 11)).lineLimit(4)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text("当前槽位正文").font(.system(size: 11, weight: .medium))
                        Text(currentSlot.plainText ?? "").font(.system(size: 11)).lineLimit(4)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("保留槽位正文") { question.prompt = currentSlot.plainText ?? ""; accept(currentSlot) }
                    Button("保留上方编辑正文") { accept(currentSlot) }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Text("\(question.references.count) 个参考素材 · 不适用维度自动排除").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并同步槽位") {
                    busy = true
                    Task {
                        if await save(question) { dismiss() }
                        else { error = "未保存，请核对最新槽位与页面提示。"; await readSlot() }
                        busy = false
                    }
                }.disabled(busy || question.conflict || question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || currentSlot.map { question.slotRevision != BatchGenerationSource.revision(of: $0) } == true)
            }
        }.padding(24).frame(width: 660).task { await readSlot() }
    }
    private func accept(_ content: SlotContent) {
        question.slotRevision = BatchGenerationSource.revision(of: content)
        question.syncedPrompt = content.plainText ?? ""; question.conflict = false
        question.references = content.attachments.compactMap { attachment in
            (attachment.storageFileURL?.path ?? attachment.storagePath ?? attachment.path).map { ModelReference(path: $0, name: attachment.name) }
        }
    }
    private func readSlot() async {
        guard let group = question.groupID, let slot = question.slot else { return }
        currentSlot = await Task.detached { SpecialSlotStorage.shared.getOrUnknown(slot, in: group) }.value
        if currentSlot == nil { error = "无法读取权威槽位，暂停同步。"; question.conflict = true }
    }
}

struct ModelQuestionGenerator: View {
    @ObservedObject var models: ModelWorkspaceStore
    let bankID: String
    let store: SlotStoreObservable
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var kind: ModelKind = .llm
    @State private var count = 5
    @State private var editing: ModelQuestion?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("出题与草稿审核").font(.system(size: 20, weight: .semibold))
            TextField("主题、能力要求、难度", text: $topic).textFieldStyle(.roundedBorder)
            HStack {
                Picker("测评类型", selection: $kind) { ForEach(ModelKind.allCases) { Text($0.title).tag($0) } }
                Stepper("\(count) 题", value: $count, in: 1...50)
                Spacer()
                Button("请求出题 LLM") { Task { await models.generateQuestions(topic: topic, kind: kind, count: count) } }
                    .disabled(models.generatingQuestions || topic.isEmpty)
            }
            Text("模型：\(models.defaultProfile(.questions)?.name ?? "请先设置出题 LLM")。主动点击后发送请求；草稿审核保存前不写入槽位。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if models.generatingQuestions { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(models.drafts) { q in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(q.title).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button("编辑") { editing = q }
                                Button("排除") { models.drafts.removeAll { $0.id == q.id } }
                            }
                            Text(q.prompt).font(.system(size: 12))
                            Text(q.criteria).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(12).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(height: 280)
            if let message = models.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                Button("确认保存 \(models.drafts.count) 道草稿到题库槽位") { Task { await models.saveDrafts(bankID: bankID, store: store) } }
                    .disabled(models.drafts.isEmpty || models.generatingQuestions)
            }
        }.padding(24).frame(width: 660)
            .sheet(item: $editing) { q in
                ModelQuestionEditor(question: q) { saved in
                    if let index = models.drafts.firstIndex(where: { $0.id == saved.id }) { models.drafts[index] = saved }
                    return true
                }
            }
    }
}

struct ModelScoreEditor: View {
    let cell: ModelEvaluationCell
    let question: ModelQuestion
    @ObservedObject var models: ModelWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var scores: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("人工评分 · 0–100").font(.system(size: 20, weight: .semibold))
            Text(question.title).font(.system(size: 14, weight: .medium))
            Text(question.criteria.isEmpty ? "按照题目要求评价实际结果。" : question.criteria).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(ModelDimension.allCases) { dimension in
                HStack {
                    Text(dimension.title).frame(width: 100, alignment: .leading)
                    if question.applicableDimensions.contains(dimension) {
                        TextField("待评分", text: Binding(get: { scores[dimension.rawValue] ?? "" }, set: { scores[dimension.rawValue] = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                    } else { Text("不适用").foregroundStyle(.secondary) }
                }.font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存评分") {
                    let parsed = scores.compactMapValues(Double.init)
                    Task { await models.score(cell.id, scores: parsed); dismiss() }
                }.disabled(!question.applicableDimensions.allSatisfy { d in scores[d.rawValue].flatMap(Double.init).map { $0.isFinite && (0...100).contains($0) } ?? false })
            }
        }.padding(24).frame(width: 440)
            .onAppear { scores = cell.scores.mapValues { String($0) } }
    }
}

struct ModelResultPreview: View {
    let cell: ModelEvaluationCell
    let kind: ModelKind
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("测评产物").font(.system(size: 18, weight: .semibold)); Spacer(); Button("关闭") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !cell.text.isEmpty { Text(cell.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(cell.localMediaPaths, id: \.self) { path in
                        if let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 660, maxHeight: 420)
                        }
                    }
                    if let player { VideoPlayer(player: player).frame(height: 340) }
                    ForEach(cell.mediaURLs, id: \.self) { raw in
                        if let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") {
                            if kind == .image {
                                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                                    .frame(maxWidth: 660, maxHeight: 420)
                            }
                            HStack {
                                Link("打开原始产物 ↗", destination: url)
                                if kind == .video || kind == .audio { Button("播放") { player?.pause(); player = AVPlayer(url: url) } }
                            }.font(.system(size: 12))
                        }
                    }
                    if let id = cell.taskID { Text("任务 ID：\(id)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                }
            }
        }.padding(24).frame(width: 720, height: 580).onDisappear { player?.pause(); player = nil }
    }
}

struct ModelNewsSourcesEditor: View {
    @ObservedObject var models: ModelWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [ModelNewsSource] = []
    @State private var name = ""
    @State private var url = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新闻来源 · RSS / Atom").font(.system(size: 20, weight: .semibold))
            List {
                ForEach($sources) { $source in
                    HStack {
                        Toggle(source.name, isOn: $source.enabled)
                        Text(source.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Button("移除") { sources.removeAll { $0.id == source.id } }
                    }
                }
            }.frame(height: 220)
            TextField("来源名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("订阅地址", text: $url).textFieldStyle(.roundedBorder)
            HStack {
                Button("添加") {
                    do {
                        try ModelProfile.validateURL(url)
                        guard !name.isEmpty else { error = "请输入来源名称。"; return }
                        sources.append(.init(name: name, url: url)); name = ""; url = ""; error = nil
                    } catch { self.error = error.localizedDescription }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { models.document.newsSources = sources; Task { await models.persist(); dismiss() } }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }.padding(24).frame(width: 620).onAppear { sources = models.document.newsSources }
    }
}
