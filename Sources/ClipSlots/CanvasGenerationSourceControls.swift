import SwiftUI
import ClipSlotsKit

struct CanvasGenerationSourceControls: View {
    let node: CanvasNode
    @ObservedObject var canvas: CanvasStore
    @ObservedObject private var catalog = ByteArtistCatalogStore.shared
    @ObservedObject private var models = ModelWorkspaceStore.shared
    @State private var showingWorkflow = false
    @State private var showingLibrary = false
    @State private var showingEnvironment = false
    @State private var workflowID = ""
    @State private var allOutputs = true
    private var capability: GenerationCapability? { catalog.capability(id: node.byteArtist.workflowID) }
    private var inputPlan: CanvasWorkflowResolver.Plan? {
        canvas.byteArtistInputPlan?(node)
    }
    private var active: Bool {
        if case .running = node.state { return true }
        if case .queued = node.state { return true }
        return false
    }
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Crate · 模型生成") { canvas.updateNodeProvider(id: node.id, provider: .crate) }
                Button("BA · 工作流生成") {
                    canvas.updateNodeProvider(id: node.id, provider: .byteartist)
                    showingLibrary = true
                }
                Divider()
                Button("API · 使用默认模型") {
                    canvas.updateNode(id: node.id) { $0.modelProfileID = "__default__" }
                }
                ForEach(models.profiles.filter { !$0.isCLI && $0.kind.rawValue == node.kind.rawValue }) { profile in
                    Button("API · \(profile.name)") {
                        canvas.updateNode(id: node.id) { $0.modelProfileID = profile.id }
                    }
                }
                if node.generationTask?.context.provider == .byteartist {
                    Button("查看 BA 任务与产物") { showingWorkflow = true }
                }
            } label: {
                Text(node.modelProfileID != nil ? "API" : node.generationProvider == .byteartist ? "BA" : "Crate")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(CanvasSkin.chromeInk)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("canvas-generation-source")
            .help("生成来源；切换仅影响下次生成，已提交任务保留原来源")
            .canvasControlRegion("composer-provider")
            if node.modelProfileID != nil {
                Text(models.canvasProfile(for: node)?.name ?? "请设置默认 API")
                    .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 160)
            } else if node.generationProvider == .byteartist {
                Button { showingLibrary = true } label: {
                    HStack(spacing: 4) {
                        Text(capability?.title ?? (node.byteArtist.workflowID.isEmpty ? "选择工作流" : node.byteArtist.workflowID))
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down")
                    }
                    .font(.system(size: 11)).foregroundColor(CanvasSkin.chromeInk)
                }
                .buttonStyle(.plain).frame(maxWidth: 180)
                .accessibilityIdentifier("canvas-ba-workflow")
                .canvasControlRegion("composer-ba-workflow")
                Button { showingWorkflow = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 24, height: 28)
                }.buttonStyle(.plain).help("配置 BA 输入与查看任务")
                    .accessibilityIdentifier("canvas-ba-configuration")
                    .canvasControlRegion("composer-ba-configuration")
            }
        }
        .popover(isPresented: $showingWorkflow, arrowEdge: .bottom) { workflowPanel }
        .popover(isPresented: $showingLibrary, arrowEdge: .bottom) { library }
        .sheet(isPresented: $showingEnvironment) { EnvironmentSetupView() }
        .onAppear { if node.generationProvider == .byteartist { catalog.loadIfNeeded() } }
    }

    private var library: some View {
        let kind: GenerationArtifactKind = node.kind == .video ? .video : .image
        let disabled = Set(catalog.capabilities.filter { $0.kind != kind }.map(\.id))
        return CreativeModelPicker(options: catalog.entries.map { item in
            let capability = catalog.capability(id: item.id)
            let reference = capability?.metadata["reference"]?.stringValue ?? ""
            let slots = ByteArtistContract.slots(reference)
            let status = capability == nil ? "选择后加载输入要求" : capability?.kind == kind ? "已就绪" : "与当前节点类型不匹配"
            let detail = [status, item.description.isEmpty ? "暂无用途描述；选中后读取官方能力说明。" : item.description]
                + slots.map { "\($0.key)：\($0.description.isEmpty ? $0.format : $0.description)" }
                + slots.filter { !$0.limits.isEmpty }.map { "\($0.key)限制：\($0.limits)" }
            return CreativeModelOption(id: item.id, title: item.title,
                subtitle: (catalog.favorites.contains(item.id) ? "收藏 · " : "") + status, details: detail)
        }, selected: node.byteArtist.workflowID, loading: catalog.isLoading,
        searchPlaceholder: "搜索 BA 能力、用途或 ID", emptyMessage: "没有匹配的 BA 能力",
        notice: catalog.error ?? catalog.issues.first ?? (catalog.preparingID == nil ? "账号可见能力 · \(catalog.total) 项；选择后核对输入与输出类型。" : "正在读取所选能力，旧配置保持可用。"),
        disabledIDs: disabled, preparingID: catalog.preparingID,
        onMore: catalog.hasMore ? { catalog.loadMore() } : nil, onCancel: { catalog.cancel() },
        settingsTitle: "输入配置与任务…",
        onSettings: { showingLibrary = false; showingWorkflow = true }, onCustom: nil) { id in
            catalog.select(id: id, kind: kind) { item in
                select(item.id)
                showingLibrary = false
            }
        }
        .task { catalog.loadIfNeeded() }
        .onDisappear { if catalog.preparingID != nil { catalog.cancel() } }
    }
    private var workflowPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BA 工作流").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("环境检测") { showingEnvironment = true }
                Button("刷新") { catalog.reload() }.disabled(catalog.busy)
            }
            Text("选择能力，配置输入。提示词与素材可以绑定当前节点和上游连线。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if catalog.busy { ProgressView().controlSize(.small) }
                    if let error = catalog.error {
                        Text(error).font(.system(size: 11)).foregroundColor(.orange).textSelection(.enabled)
                    }
                    HStack {
                        Text(capability?.title ?? "尚未选择能力").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("更换能力") { showingWorkflow = false; showingLibrary = true }
                        if !node.byteArtist.workflowID.isEmpty {
                            Button("清空") {
                                var config = node.byteArtist; config.workflowID = ""
                                canvas.updateNodeProvider(id: node.id, configuration: config)
                            }.accessibilityIdentifier("canvas-ba-clear")
                        }
                    }.accessibilityIdentifier("canvas-ba-workflow-picker")
                    HStack {
                        TextField("输入工作流 ID", text: $workflowID).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("canvas-ba-workflow-id")
                        Button("添加") { add(workflowID) }.disabled(catalog.busy || workflowID.isEmpty)
                            .accessibilityIdentifier("canvas-ba-workflow-add")
                        if !catalog.available.isEmpty {
                            Menu("本机能力") {
                                ForEach(catalog.available, id: \.id) { item in
                                    Button(item.title) { add(item.id) }
                                }
                            }
                        }
                    }
                    if let capability {
                        Divider()
                        HStack {
                            Text("输入参数").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button("更新能力说明") { add(capability.id) }.disabled(catalog.busy)
                        }
                        HStack {
                            Button(catalog.favorites.contains(capability.id) ? "取消收藏" : "收藏能力") {
                                catalog.toggleFavorite(capability.id)
                            }
                            Spacer()
                            Button("从已加载列表移除") { catalog.remove(capability.id) }
                        }.font(.system(size: 11))
                        ForEach((capability.inputSchema["properties"]?.objectValue ?? [:]).keys.sorted(), id: \.self) { key in
                            field(key, rule: capability.inputSchema["properties"]?[key] ?? .null, capability: capability)
                        }
                        if capability.kind != (node.kind == .video ? .video : .image) {
                            Text("该工作流输出类型与节点不匹配，请选择\(node.kind == .video ? "视频" : "图片")工作流。")
                                .font(.system(size: 11)).foregroundColor(.orange)
                        }
                        DisclosureGroup("能力说明与输入限制") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(capability.metadata["description"]?.stringValue ?? "暂无用途描述。")
                                ForEach(ByteArtistContract.slots(capability.metadata["reference"]?.stringValue ?? ""), id: \.key) { slot in
                                    Text("\(slot.key) · \(slot.format)\n\(slot.description)\(slot.limits.isEmpty ? "" : "\n限制：" + slot.limits)")
                                }
                            }.font(.system(size: 11)).textSelection(.enabled)
                        }.font(.system(size: 11))
                        Text(node.byteArtist.draft.outputBindings.isEmpty
                             ? "官方媒体结果会自动保存；其他结构可在任务区确认产物。"
                             : "已设置产物字段，生成完成后自动保存到节点。")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        if !node.byteArtist.draft.outputBindings.isEmpty {
                            Button("恢复自动识别") { edit { $0.outputBindings = [] } }
                        }
                    }
                    if let task = node.generationTask, task.context.provider == .byteartist {
                        Divider()
                        Text("已提交任务 · BA / \(task.capabilityID)").font(.system(size: 11, weight: .semibold))
                        Text(node.generationDiagnostic?.stageLabel ?? "等待查询原任务")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        Text(task.taskID).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        if let raw = node.generationRawOutput {
                            let candidates = ByteArtistOutputSelection.candidates(raw)
                            if !candidates.isEmpty {
                                Text("选择媒体后确认取回，继续使用这个 BA 任务。")
                                    .font(.system(size: 11))
                                Toggle("同时保存数组中的其他产物", isOn: $allOutputs).font(.system(size: 11))
                                ForEach(candidates) { candidate in
                                    Button {
                                        bind(candidate, task: task)
                                        showingWorkflow = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("确认并取回 · \(candidate.label)").font(.system(size: 11, weight: .medium))
                                            Text(candidate.url.host ?? "").font(.system(size: 10)).foregroundColor(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.disabled(active).accessibilityIdentifier("canvas-ba-output-\(candidate.id)")
                                }
                            } else {
                                Text(node.generationDiagnostic?.rawStatus == "finished"
                                     ? "此次完成响应没有可直接下载的媒体；可继续查询或复制诊断信息。"
                                     : "尚未取得完成后的产物，请继续查询原 BA 任务。")
                                    .font(.system(size: 11)).foregroundColor(.orange)
                            }
                            DisclosureGroup("原始结果") {
                                Text((try? raw.encodedText()) ?? "").font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                            }.font(.system(size: 11))
                        }
                        Button("继续查询 BA 任务") { recover(task) }.disabled(active)
                            .accessibilityIdentifier("canvas-ba-recover")
                    }
                }.padding(.vertical, 2)
            }.frame(maxHeight: 500)
        }
        .padding(16).frame(width: 430)
        .background(CanvasTheme.canvasChromeSurface)
        .task { catalog.loadIfNeeded() }
    }

    @ViewBuilder
    private func field(_ key: String, rule: JSONValue, capability: GenerationCapability) -> some View {
        let type = rule["type"]?.stringValue ?? "JSON"
        let uploads = ByteArtistGenerationAdapter.uploadKeys(capability.metadata["reference"]?.stringValue ?? "",
                                                             keys: Set(capability.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? []))
        let source = node.byteArtist.draft.sources[key] ?? ""
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(rule["title"]?.stringValue ?? key).font(.system(size: 11, weight: .medium))
                Spacer()
                if type == "string" {
                    Picker("输入来源", selection: Binding(get: { source }, set: { value in edit { $0.sources[key] = value.isEmpty ? nil : value } })) {
                        Text("手动填写").tag("")
                        if !uploads.contains(key) { Text("节点与上游提示词").tag("prompt") }
                        if uploads.contains(key) {
                            if inputPlan?.edgeInputs.firstFramePath != nil { Text("上游首帧").tag("firstFrame") }
                            if inputPlan?.edgeInputs.lastFramePath != nil { Text("上游尾帧").tag("lastFrame") }
                            ForEach(Array((inputPlan?.providerImages ?? []).enumerated()), id: \.offset) { index, path in
                                Text("\(index + 1) · \(URL(fileURLWithPath: path).lastPathComponent)").tag("image:\(index)")
                            }
                            if !source.isEmpty && resolvedSource(source) == nil { Text("绑定素材不可用").tag(source) }
                        }
                    }.labelsHidden().frame(maxWidth: 180)
                }
            }
            if source.isEmpty {
                let value = Binding(get: { node.byteArtist.draft.fields[key] ?? "" }, set: { value in edit { $0.fields[key] = value } })
                if let options = rule["enum"]?.arrayValue {
                    Picker(key, selection: value) {
                        Text("请选择").tag("")
                        ForEach(options.indices, id: \.self) { index in
                            let text = options[index].stringValue ?? (try? options[index].encodedText()) ?? ""
                            Text(text).tag(text)
                        }
                    }.labelsHidden()
                } else if type == "boolean" {
                    Picker(key, selection: value) {
                        Text("请选择").tag("")
                        Text("开启").tag("true")
                        Text("关闭").tag("false")
                    }.labelsHidden()
                } else {
                    HStack {
                        TextField(type == "string" ? "输入内容" : "输入 \(type)", text: value, axis: .vertical)
                            .lineLimit(1...5).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("canvas-ba-input-\(key)")
                        if uploads.contains(key) {
                            Button("选择文件") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                panel.begin { response in
                                    if response == .OK, let url = panel.url { edit { $0.fields[key] = url.path } }
                                }
                            }
                        }
                    }
                }
            }
            if !source.isEmpty {
                if let resolved = resolvedSource(source) {
                    Text(source == "prompt" ? String(resolved.prefix(200)) : URL(fileURLWithPath: resolved).lastPathComponent)
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    Text("绑定的输入当前不可用，请补齐素材或改为手动填写。")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
            } else if let message = fieldError(key, rule: rule) {
                Text(message).font(.system(size: 10)).foregroundColor(.orange)
            }
            if let description = rule["description"]?.stringValue, !description.isEmpty {
                Text(description).font(.system(size: 10)).foregroundColor(.secondary)
            }
            if rule["minimum"] != nil || rule["maximum"] != nil {
                Text("范围：\(rule["minimum"].map { (try? $0.encodedText()) ?? "" } ?? "不限") — \(rule["maximum"].map { (try? $0.encodedText()) ?? "" } ?? "不限")")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
    private func resolvedSource(_ source: String) -> String? {
        guard let plan = inputPlan else { return nil }
        if source == "prompt" { return plan.prompt.isEmpty ? nil : plan.prompt }
        if source == "firstFrame" { return plan.edgeInputs.firstFramePath }
        if source == "lastFrame" { return plan.edgeInputs.lastFramePath }
        if source.hasPrefix("image:"), let index = Int(source.dropFirst(6)), plan.providerImages.indices.contains(index) {
            return plan.providerImages[index]
        }
        return nil
    }
    private func fieldError(_ key: String, rule: JSONValue) -> String? {
        guard let raw = node.byteArtist.draft.fields[key] else {
            return rule["default"] == nil ? "请填写此项" : nil
        }
        do { try ByteArtistContract.validateField(raw, schema: rule); return nil }
        catch { return error.localizedDescription }
    }
    private func edit(_ change: (inout ByteArtistCanvasConfiguration.Draft) -> Void) {
        guard let live = canvas.node(id: node.id), live.createdAt == node.createdAt else { return }
        var config = live.byteArtist
        var draft = config.draft; change(&draft); config.draft = draft
        canvas.updateNodeProvider(id: node.id, configuration: config)
    }
    private func select(_ id: String) {
        guard let capability = catalog.capability(id: id),
              let live = canvas.node(id: node.id), live.createdAt == node.createdAt else { return }
        var config = live.byteArtist; config.select(capability)
        if config.draft.outputBindings.isEmpty { config.draft.outputBindings = catalog.mappings(for: capability) }
        canvas.updateNodeProvider(id: node.id, configuration: config)
    }
    private func add(_ id: String) {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.add(id: clean) { capability in select(capability.id) }
    }
    private func bind(_ candidate: ByteArtistOutputSelection.Candidate, task: GenerationTaskHandle) {
        let binding = ByteArtistOutputSelection.binding(candidate, kind: task.kind, allItems: allOutputs)
        guard let handle = try? GenerationTaskHandle(context: task.context, taskID: task.taskID,
            capabilityID: task.capabilityID, capabilityRevision: task.capabilityRevision, kind: task.kind,
            outputBindings: [binding], cliVersion: task.cliVersion, seed: task.seed),
              let live = canvas.node(id: node.id), live.generationTask == task else { return }
        var config = live.byteArtist
        var draft = config.drafts[task.capabilityID] ?? .init()
        draft.outputBindings = [binding]; config.drafts[task.capabilityID] = draft
        canvas.updateNodeProvider(id: node.id, configuration: config)
        canvas.updateNode(id: node.id) { $0.generationTask = handle }
        catalog.saveMappings([binding], task: task)
        canvas.flushSave()
        recover(handle)
    }
    private func recover(_ task: GenerationTaskHandle) {
        guard let live = canvas.node(id: node.id), live.createdAt == node.createdAt,
              live.generationTask?.taskID == task.taskID else { return }
        showingWorkflow = false
        canvas.recoverGenerationAction?(live)
    }
}
