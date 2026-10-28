import SwiftUI
import ClipSlotsKit

/// One control treatment for the entry point and all batch actions.
struct BatchGenerationButtonStyle: ButtonStyle {
    var iconOnly = false
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, iconOnly: iconOnly)
    }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let iconOnly: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(Color(red: 0.04, green: 0.10, blue: 0.16))
                .padding(.horizontal, iconOnly ? 0 : 12)
                .frame(minWidth: 32, minHeight: 32)
                .background(LinearGradient(colors: [Color(red: 0.71, green: 0.89, blue: 1),
                                                    Color(red: 0.47, green: 0.73, blue: 0.94)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Color.white.opacity(hovered && isEnabled ? 0.14 : 0))
                .overlay(Color.black.opacity(configuration.isPressed ? 0.08 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(isEnabled ? (hovered ? 0.13 : 0.07) : 0),
                        radius: hovered ? 4 : 2, y: 1)
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct BatchGenerationEntry: View {
    @ObservedObject private var controller = BatchGenerationController.shared
    var canvasHeader = false
    var iconOnly = false
    let action: () -> Void
    var body: some View {
        entry
        .accessibilityIdentifier("batch-generation-entry")
        .help("选择页面和槽位组，逐槽位生成")
    }

    @ViewBuilder private var entry: some View {
        if canvasHeader {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: controller.runningID == nil ? "square.stack.3d.up" : "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .regular))
                    if !iconOnly {
                        Text(controller.runningID == nil ? "批量生成" : "批量进度")
                    }
                }
                .frame(width: iconOnly ? 44 : nil)
            }
            .buttonStyle(CanvasHeaderButtonStyle(iconOnly: iconOnly, isActive: controller.runningID != nil))
            .accessibilityLabel(controller.runningID == nil ? "批量生成" : "批量进度")
        } else {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: controller.runningID == nil ? "square.stack.3d.up.fill" : "clock.arrow.circlepath")
                Text(controller.runningID == nil ? "批量生成" : "批量进度")
            }
        }
        .buttonStyle(BatchGenerationButtonStyle())
        }
    }
}

struct BatchGenerationView: View {
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject private var controller = BatchGenerationController.shared
    @ObservedObject private var catalog = CrateModelCatalogStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var search = ""
    @State private var configuration: CanvasNode
    @State private var displayedBatch: UUID?
    @State private var showingRatio = false
    @State private var showingModels = false
    @State private var showingHistory = false
    @State private var showingEnvironment = false
    @State private var concurrency = BatchGeneration.maximumConcurrency
    let projectID: String
    let size: CGSize

    init(store: SlotStoreObservable, canvas: CanvasStore, size: CGSize) {
        self.store = store; projectID = canvas.activeProjectId; self.size = size
        var node = CanvasNode(pageId: "", groupId: "", slot: 1, kind: .image, x: 0, y: 0)
        if let source = canvas.soleSelectedNode, source.canGenerate { node = source }
        node.kind = node.kind == .video ? .video : .image
        node.mediaRole = .generation; node.count = 1
        _configuration = State(initialValue: node)
        _displayedBatch = State(initialValue: BatchGenerationController.shared.runningID)
    }

    private var models: [CrateModelCatalog.ModelInfo] {
        configuration.kind == .video ? catalog.videoModels : catalog.imageModels
    }
    private var model: CrateModelCatalog.ModelInfo? { models.first { $0.id == configuration.model } }
    private var visibleGroups: [BatchGenerationGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.groups.filter {
            query.isEmpty || "\($0.page.name) \($0.group.name)".localizedCaseInsensitiveContains(query)
        }
    }
    private var visiblePages: [SlotPage] {
        var ids = Set<String>()
        return visibleGroups.compactMap { ids.insert($0.page.id).inserted ? $0.page : nil }
    }
    private var preview: BatchGeneration {
        var batch = controller.plan(projectID: projectID, selected: selected, configuration: configuration, model: model)
        batch.concurrency = concurrency
        return batch
    }
    private var eligibleIDs: Set<String> { Set(visibleGroups.filter { !$0.sources.isEmpty }.map(\.id)) }
    private var dialogWidth: CGFloat { min(740, max(320, size.width - 32)) }
    private var compact: Bool { dialogWidth < 620 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(TapSkin.chromeDivider)
            if let id = displayedBatch, let batch = controller.batch(id) {
                BatchGenerationProgressView(batch: batch, isRunning: controller.runningID == id, compact: compact,
                    onStop: { controller.stop(id) },
                    onRecover: { controller.recover(id, store: store) })
            } else {
                selectionBody
            }
            if let error = controller.error {
                Text(error).font(.system(size: 12)).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider().overlay(TapSkin.chromeDivider)
            footer
        }
        .frame(width: dialogWidth, height: min(740, max(320, size.height - 48)))
        .buttonStyle(BatchGenerationButtonStyle())
        .foregroundColor(TapSkin.chromeInk)
        .background(TapSkin.chromeFill)
        .task {
            catalog.loadIfNeeded()
            await controller.loadLibrary(store: store)
            if let running = controller.runningID { displayedBatch = running }
            normalizeModel()
        }
        .onChange(of: catalog.state) { _ in normalizeModel() }
        .sheet(isPresented: $showingEnvironment) { EnvironmentSetupView() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 18))
                    .foregroundColor(Color(red: 0.56, green: 0.77, blue: 0.90))
                    .frame(width: 32, height: 32).background(TapSkin.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(displayedBatch == nil ? "批量生成" : "批量任务")
                    .font(.system(size: compact ? 17 : 20, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { showingEnvironment = true } label: {
                    Label("环境检测", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("batch-environment")
                Button { showingHistory.toggle() } label: {
                    Label("批次记录", systemImage: "clock.arrow.circlepath")
                }
                .disabled(controller.batches.isEmpty)
                .accessibilityIdentifier("batch-history")
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) { history }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(BatchGenerationButtonStyle(iconOnly: true))
                    .accessibilityLabel("关闭批量生成")
                    .accessibilityIdentifier("batch-close")
            }
            Text("选择页面下的槽位组，每个非空槽位生成一份结果")
                .font(.system(size: 12)).foregroundColor(TapSkin.chromeInkDim)
        }
        .padding(16)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批次记录").font(.system(size: 14, weight: .semibold))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(controller.batches) { batch in
                        Button {
                            displayedBatch = batch.id
                            showingHistory = false
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(batch.outputNaming?.label ??
                                         batch.createdAt.formatted(date: .numeric, time: .shortened))
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("\(batch.createdAt.formatted(date: .omitted, time: .shortened)) · 已写回 \(batch.completedCount) / \(batch.items.count) 项")
                                        .font(.system(size: 11))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: displayedBatch == batch.id ? "checkmark.circle.fill" : "chevron.right")
                            }.padding(.vertical, 6)
                        }
                        .buttonStyle(BatchGenerationButtonStyle())
                        .accessibilityIdentifier("batch-history-" + batch.id.uuidString)
                    }
                }.padding(3)
            }.frame(maxHeight: 320)
        }
        .padding(16).frame(width: min(360, dialogWidth - 32))
        .foregroundColor(TapSkin.chromeInk).background(TapSkin.chromeFill)
    }

    private var selectionBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                parameters
                searchControls
                if controller.isLoading {
                    VStack(spacing: 12) {
                        CreativeLoadingMark().frame(width: 64, height: 64)
                        Text("正在读取槽位库…").foregroundColor(TapSkin.chromeInkDim)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if visibleGroups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 26))
                        Text(search.isEmpty ? "暂无可选槽位组" : "没有匹配的页面或槽位组")
                    }.foregroundColor(TapSkin.chromeInkDim).frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(visiblePages) { page in pageSection(page) }
                }
            }.padding(16)
        }.frame(maxHeight: .infinity)
    }

    private var searchControls: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(TapSkin.chromeInkDim)
                TextField("搜索页面或槽位组", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("batch-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(BatchGenerationButtonStyle(iconOnly: true)).accessibilityLabel("清除搜索")
                }
            }.frame(minHeight: 32)
            HStack(spacing: 8) {
                Button(search.isEmpty ? "全选" : "全选搜索结果") { selected.formUnion(eligibleIDs) }
                    .disabled(eligibleIDs.isEmpty).accessibilityIdentifier("batch-select-all")
                Button("取消全选") { selected.removeAll() }.disabled(selected.isEmpty)
                    .accessibilityIdentifier("batch-deselect-all")
            }.fixedSize()
        }
        .font(.system(size: 12)).padding(10)
        .background(TapSkin.subtleFill).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                 : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Picker("生成类型", selection: Binding(get: { configuration.kind }, set: { kind in
                    configuration.kind = kind
                    configuration.model = CanvasNode.defaultModel(for: kind)
                    configuration.ratio = CanvasNode.defaultRatio(for: kind)
                    configuration.resolution = ""; configuration.duration = nil; configuration.generateAudio = nil
                    normalizeModel()
                })) {
                    Text("图片").tag(CanvasNodeKind.image)
                    Text("视频").tag(CanvasNodeKind.video)
                }.pickerStyle(.segmented).frame(width: 136, height: 32).labelsHidden()
                HStack(spacing: 8) {
                    Button {
                        showingRatio = false
                        showingModels.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Label(model?.displayName ?? configuration.model, systemImage: "sparkles").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity)
                        .accessibilityIdentifier("batch-model-picker")
                        .popover(isPresented: $showingModels) {
                            CreativeModelPicker(options: models.map(CreativeModelOption.init),
                                                selected: configuration.model, loading: catalog.isLoading) { id in
                                if let info = models.first(where: { $0.id == id }) { pickModel(info) }
                                showingModels = false
                            }
                        }
                    if model?.supportsRatio == true || CanvasImageConfiguration.supportsSplit(model) {
                        Button { showingModels = false; showingRatio.toggle() } label: {
                            HStack(spacing: 5) {
                                CanvasAspectGlyph(ratio: configuration.ratio)
                                Text(configuration.ratio.isEmpty ? "默认比例" : configuration.ratio)
                            }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("batch-aspect-picker")
                        .popover(isPresented: $showingRatio) {
                            if configuration.kind == .image, CanvasImageConfiguration.supportsSplit(model) {
                                CanvasImageSizePicker(selection: CanvasImageConfiguration.selection(
                                    ratio: configuration.ratio, resolution: configuration.resolution), model: model) { ratio, quality in
                                    configuration.ratio = ratio; configuration.resolution = quality
                                }
                            } else {
                                CanvasAspectPicker(options: model?.ratioOptions ?? [], selected: configuration.ratio) {
                                    configuration.ratio = $0; showingRatio = false
                                }
                            }
                        }
                    }
                }
            }
            if configuration.kind == .image, let model, model.supportsResolution {
                Picker("分辨率", selection: $configuration.resolution) {
                    Text("模型默认").tag("")
                    ForEach(model.resolutionOptions, id: \.value) { Text($0.label).tag($0.value) }
                }.font(.system(size: 11))
            }
            if configuration.kind == .video, let model {
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                     : AnyLayout(HStackLayout(spacing: 14))
                layout {
                    if model.supportsResolution {
                        Picker("分辨率", selection: $configuration.resolution) {
                            Text("默认").tag("")
                            ForEach(model.resolutionOptions, id: \.value) { Text($0.label).tag($0.value) }
                        }
                    }
                    if model.supportsDuration {
                        Picker("时长", selection: Binding(get: { configuration.duration ?? 0 },
                                                         set: { configuration.duration = $0 == 0 ? nil : $0 })) {
                            Text("默认").tag(0)
                            ForEach((1...60).filter { model.durationSpec?.allows($0) == true }, id: \.self) {
                                Text("\($0) 秒").tag($0)
                            }
                        }
                    }
                    if model.supportsAudio {
                        Toggle("生成音频", isOn: Binding(get: { configuration.generateAudio ?? false },
                                                     set: { configuration.generateAudio = $0 }))
                    }
                }.font(.system(size: 11))
            }
            if case .failed(let reason) = catalog.state {
                HStack {
                    Text(reason).foregroundColor(.orange).lineLimit(2)
                    Button("重试") { catalog.reload() }
                }.font(.system(size: 11))
            }
            Text("使用各槽位的正文与参考图，结果追加到原槽位。空槽位不参与。")
                .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
            HStack {
                Picker("同时处理", selection: $concurrency) {
                    ForEach([1, 2, 4, 8, 16, BatchGeneration.maximumConcurrency], id: \.self) {
                        Text("\($0) 项").tag($0)
                    }
                }.frame(maxWidth: 240).accessibilityIdentifier("batch-concurrency")
                Spacer()
                Text("最高 \(BatchGeneration.maximumConcurrency) 项并发").font(.system(size: 11, weight: .medium))
            }
            Text("独立任务并行提交和取回，最多 4 个本机 CLI 进程；实际生成速度受账号配额和服务端排队影响。同一批次全部产物存放在一个文件夹。")
                .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
        }
    }

    private func pageSection(_ page: SlotPage) -> some View {
        let groups = visibleGroups.filter { $0.page.id == page.id }
        let ids = Set(groups.filter { !$0.sources.isEmpty }.map(\.id))
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                selected = BatchGenerationSelection.toggled(ids: ids, selected: selected)
            } label: {
                HStack(spacing: 8) {
                    checkbox(BatchGenerationSelection.state(ids: ids, selected: selected))
                    Text(page.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(groups.count) 个组").font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
                }.contentShape(Rectangle()).padding(.vertical, 6)
            }.buttonStyle(.plain).disabled(ids.isEmpty)
                .accessibilityLabel("选择页面 \(page.name)")
                .accessibilityIdentifier("batch-page-" + page.id)
            ForEach(groups) { group in
                Button {
                    if !selected.insert(group.id).inserted { selected.remove(group.id) }
                } label: {
                    HStack(spacing: 10) {
                        checkbox(selected.contains(group.id) ? .all : .none)
                        Image(systemName: group.group.icon).foregroundColor(TapSkin.chromeInkDim).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(group.sources.isEmpty ? "空槽位组" : "\(group.sources.count) 个非空槽位")
                                .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
                        }
                        Spacer()
                        if group.eligibleCount < group.sources.count {
                            Label("\(group.sources.count - group.eligibleCount) 项需补充输入", systemImage: "exclamationmark.circle")
                                .font(.system(size: 10)).foregroundColor(.orange).lineLimit(2)
                        }
                    }
                    .padding(12).contentShape(Rectangle())
                    .background(selected.contains(group.id) ? Color.blue.opacity(0.12) : TapSkin.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                        selected.contains(group.id) ? Color(red: 0.56, green: 0.77, blue: 0.90).opacity(0.7) : .clear, lineWidth: 1))
                }.buttonStyle(.plain).disabled(group.sources.isEmpty)
                    .accessibilityLabel("槽位组 \(page.name) \(group.group.name)，\(selected.contains(group.id) ? "已选择" : "未选择")")
                    .accessibilityValue(selected.contains(group.id) ? "已选择" : "未选择")
                    .accessibilityIdentifier("batch-group-" + group.id)
            }
        }
    }

    private func checkbox(_ state: BatchGenerationSelection.State) -> some View {
        Image(systemName: state == .all ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(state == .none ? TapSkin.chromeInkDim : Color(red: 0.56, green: 0.77, blue: 0.90))
    }

    private var footer: some View {
        Group {
            if displayedBatch != nil {
                HStack(spacing: 10) {
                    Button("新建批次") { displayedBatch = nil; selected = [] }
                        .disabled(controller.runningID != nil)
                        .accessibilityIdentifier("batch-new")
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                let plan = preview
                let count = plan.items.filter { $0.status == .pending }.count
                let skipped = plan.items.filter { $0.status == .skipped }
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                     : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选 \(selected.count) 个组 · 将生成 \(count) 项").font(.system(size: 13, weight: .medium))
                        if !skipped.isEmpty {
                            Text("跳过 \(skipped.count) 项：\(Set(skipped.compactMap(\.detail)).sorted().joined(separator: "、"))")
                                .font(.system(size: 10)).foregroundColor(.orange).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        if compact { Spacer(minLength: 0) }
                        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button("确认生成 \(count) 项") {
                            if controller.start(plan, store: store, model: model) { displayedBatch = plan.id }
                        }
                        .disabled(count == 0 || model == nil || controller.isLoading || controller.runningID != nil)
                        .accessibilityIdentifier("batch-confirm")
                    }.fixedSize(horizontal: !compact, vertical: true)
                }
            }
        }.padding(16)
    }

    private func normalizeModel() {
        guard !models.isEmpty else { return }
        if let current = model { pickModel(current) }
        else if let first = models.first { pickModel(first) }
    }
    private func pickModel(_ info: CrateModelCatalog.ModelInfo) {
        configuration.model = info.id
        if configuration.kind == .image, CanvasImageConfiguration.supportsSplit(info) {
            let selection = CanvasImageConfiguration.selection(ratio: configuration.ratio, resolution: configuration.resolution)
            configuration.ratio = selection.ratio
            let qualities = CanvasImageConfiguration.qualities(for: info)
            configuration.resolution = qualities.contains(selection.quality) ? selection.quality : qualities[0]
        } else {
            configuration.ratio = CrateModelCatalog.resolvedRatio(current: configuration.ratio, for: info)
        }
        if !CanvasImageConfiguration.supportsSplit(info),
           !info.supportsResolution || (!configuration.resolution.isEmpty && !info.resolutionOptions.contains(where: { $0.value == configuration.resolution })) {
            configuration.resolution = ""
        }
        if let duration = configuration.duration, info.durationSpec?.allows(duration) != true { configuration.duration = nil }
        if !info.supportsAudio { configuration.generateAudio = nil }
    }
}

private struct BatchGenerationProgressView: View {
    let batch: BatchGeneration
    let isRunning: Bool
    let compact: Bool
    let onStop: () -> Void
    let onRecover: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if isRunning { CreativeLoadingMark().frame(width: 42, height: 42) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(isRunning ? (batch.stopRequested ? "正在停止…" : "正在批量生成") : "批次记录")
                        .font(.system(size: 17, weight: .semibold))
                    Text("已写回 \(batch.completedCount) / \(batch.items.count) 项")
                        .font(.system(size: 12)).foregroundColor(TapSkin.chromeInkDim)
                }
                Spacer()
                if isRunning {
                    Button("停止后续任务", action: onStop).disabled(batch.stopRequested)
                } else if batch.items.contains(where: \.canRecover) {
                    Button("取回已提交结果", action: onRecover)
                }
            }
            if let naming = batch.outputNaming {
                HStack {
                    Text(naming.label).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(TapSkin.chromeInkDim).textSelection(.enabled)
                    Spacer()
                    if let file = batch.items.compactMap(\.localFile).first {
                        Button("打开批次文件夹") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: file).deletingLastPathComponent())
                        }.accessibilityIdentifier("batch-open-folder")
                    }
                }
            }
            Text("本批并发 \(batch.effectiveConcurrency) · 最高支持 \(BatchGeneration.maximumConcurrency)")
                .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
            Text("停止后不再提交新任务。远端已提交任务仍可能继续，可在这里取回结果。")
                .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(batch.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: item.status == .succeeded ? "checkmark.circle.fill" :
                                        item.status == .retained ? "tray.and.arrow.down.fill" : "circle")
                                    .foregroundColor(item.status == .succeeded ? .green : TapSkin.chromeInkDim)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.source.location).font(.system(size: 10)).foregroundColor(TapSkin.chromeInkDim)
                                    Text(item.source.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if !compact { itemActions(item) }
                            }
                            if compact { itemActions(item).padding(.leading, 28) }
                            VStack(alignment: .leading, spacing: 5) {
                                if let detail = item.detail {
                                    Text(detail).font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim).textSelection(.enabled)
                                }
                                if let taskID = item.taskID {
                                    Text("Task \(taskID)").font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(TapSkin.chromeInkDim).textSelection(.enabled)
                                }
                            }.padding(.leading, 28)
                        }.padding(12).background(TapSkin.subtleFill).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(16).frame(maxHeight: .infinity)
    }

    private func itemActions(_ item: BatchGeneration.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.status.label).font(.system(size: 11))
                .frame(width: 72, alignment: compact ? .leading : .trailing)
            if compact { Spacer(minLength: 0) }
            if let file = item.localFile {
                Button("查看产物") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                    .accessibilityIdentifier("batch-output-" + item.id.uuidString)
            } else if !compact {
                Color.clear.frame(width: 72, height: 32)
            }
        }.fixedSize(horizontal: !compact, vertical: true)
    }
}
