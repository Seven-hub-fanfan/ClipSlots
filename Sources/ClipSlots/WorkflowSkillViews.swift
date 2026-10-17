import SwiftUI
import UniformTypeIdentifiers
import ClipSlotsKit

struct WorkflowSkillEditor: View {
    @State var draft: WorkflowSkill
    let context: CanvasAgentContext
    var source: CanvasAgentContext.SkillDraft?
    var original: WorkflowSkill?
    var onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selectedWorkflow = false
    @State private var saving = false
    @State private var error: String?
    @State private var bindingNode = ""
    @State private var bindingField: WorkflowSkill.Field = .body
    @State private var bindingName = ""
    @State private var bindingMatch = ""
    @State private var bindingVariable = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(original == nil ? "保存创作 Skill" : "编辑 Skill · 新版本")
                        .font(.system(size: 21, weight: .semibold))
                    Text("核对方法，定义变化的输入，让节点与连线可以再次使用。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.disabled(saving)
                    .accessibilityIdentifier("workflow-skill-cancel")
            }
            HStack {
                TextField("Skill 名称", text: $draft.name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workflow-skill-name")
                if original == nil {
                    Picker("保存到", selection: $draft.scope) {
                        Text("个人 Skill 库").tag(WorkflowSkill.Scope.personal)
                        Text("当前项目").tag(WorkflowSkill.Scope.project)
                    }.frame(width: 220)
                    .onChange(of: draft.scope) { scope in draft.projectID = scope == .project ? context.projectID : nil }
                } else {
                    Text("v\(original?.version ?? 0) → 新版本").font(.caption).foregroundColor(.secondary)
                }
            }
            TextField("适用场景，例如：保持角色一致的产品短片", text: $draft.summary).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-skill-summary")
            if let source, !source.turn.selectionIDs.isEmpty {
                Picker("工作流范围", selection: $selectedWorkflow) {
                    Text("整个项目").tag(false)
                    Text("发送时选区与上游").tag(true)
                }.pickerStyle(.segmented)
                    .help("更改范围会重新建立变量绑定。")
                    .onChange(of: selectedWorkflow) { value in
                        do {
                            let rebuilt = try WorkflowSkill(snapshot: source.snapshot, method: draft.method,
                                messageID: draft.provenance.messageID, receipts: draft.provenance.readReceipts, selectedWorkflow: value)
                            draft.graph = rebuilt.graph; draft.provenance = rebuilt.provenance
                            bindingNode = ""; bindingVariable = ""
                        } catch { self.error = error.localizedDescription }
                    }
            }
            Picker("", selection: $tab) {
                Text("方法说明").tag(0)
                Text("输入变量 · \(draft.graph.variables.count)").tag(1)
                Text("流程与来源 · \(draft.graph.nodes.count) 节点").tag(2)
            }.pickerStyle(.segmented)
            Group {
                if tab == 0 { methodEditor }
                else if tab == 1 { variablesEditor }
                else { graphPreview }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error { Text(error).font(.caption).foregroundColor(.orange) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Text(original == nil ? "同名 Skill 分别保存，使用独立身份。" : "保留旧版本及已发送的引用快照。")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(original == nil ? "确认保存" : "确认保存新版本", action: save)
                    .buttonStyle(.borderedProminent).disabled(saving || !context.isActive)
                    .accessibilityIdentifier("workflow-skill-save")
            }
        }.padding(24).frame(width: 780, height: 660)
            .background(TapSkin.tone(0xfafafa, 0x161616))
    }

    private var methodEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议保留：适用条件、稳定步骤、审美约束、验收标准；区分图事实、已确认决策与推测。")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $draft.method).font(.system(size: 13))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
                .accessibilityIdentifier("workflow-skill-method")
            if let original {
                DisclosureGroup("比较旧版 · \(original.method == draft.method ? "方法未变" : "方法已修改") · \(original.graph == draft.graph ? "流程未变" : "流程或变量已修改")") {
                    ScrollView { Text(original.method).font(.caption).textSelection(.enabled) }.frame(maxHeight: 90)
                }.font(.caption)
            }
        }
    }

    private var variablesEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("只替换绑定的字段。填写替换片段可保留其余文字；留空则替换整个字段。")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(draft.graph.variables) { variable in
                    variableRow(variable)
                }
                Divider()
                Text("添加字段绑定").font(.headline)
                HStack {
                    Picker("变量", selection: $bindingVariable) {
                        Text("新变量").tag("")
                        ForEach(draft.graph.variables) { Text($0.name).tag($0.id) }
                    }
                    if bindingVariable.isEmpty { TextField("变量名称，例如产品", text: $bindingName).textFieldStyle(.roundedBorder) }
                }
                HStack {
                    Picker("节点", selection: $bindingNode) {
                        Text("选择节点").tag("")
                        ForEach(draft.graph.nodes) { Text("\($0.id) · \($0.title)").tag($0.id) }
                    }
                    Picker("字段", selection: $bindingField) {
                        ForEach(WorkflowSkill.Field.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                if bindingField.type == .text {
                    TextField("仅替换这个片段（留空替换整个字段）", text: $bindingMatch).textFieldStyle(.roundedBorder)
                }
                Button("添加绑定", action: addBinding).disabled(bindingNode.isEmpty)
                    .accessibilityIdentifier("workflow-skill-add-binding")
            }.padding(2)
        }
    }
    private func variableRow(_ variable: WorkflowSkill.Variable) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                TextField("变量名称", text: Binding(get: {
                    draft.graph.variables.first { $0.id == variable.id }?.name ?? ""
                }, set: { value in editVariable(variable.id) { $0.name = value } })).textFieldStyle(.roundedBorder)
                Text(variable.kind.rawValue).font(.caption).foregroundColor(.secondary)
                Toggle("必填", isOn: Binding(get: { variable.required },
                    set: { value in editVariable(variable.id) { $0.required = value } })).toggleStyle(.checkbox)
                Button(role: .destructive) { draft.graph.variables.removeAll { $0.id == variable.id } } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.plain).help("移除变量及其绑定")
            }
            Text(variable.bindings.map {
                "\($0.nodeID) · \($0.field.label)" + ($0.match.map { " · “\($0)”" } ?? " · 整个字段")
            }.joined(separator: "\n")).font(.caption).foregroundColor(.secondary)
            if variable.kind == .text {
                TextField("默认值（可留空）", text: Binding(get: { variable.defaultValue?.displayText ?? "" },
                    set: { value in editVariable(variable.id) { $0.defaultValue = value.isEmpty ? nil : .text(value) } }))
                    .textFieldStyle(.roundedBorder)
            } else if variable.kind == .integer {
                HStack {
                    TextField("默认秒数", text: Binding(get: { variable.defaultValue?.displayText ?? "" },
                        set: { value in editVariable(variable.id) { $0.defaultValue = Int(value).map(WorkflowSkill.Value.integer) } }))
                    TextField("最小值", value: Binding(get: { variable.minimum },
                        set: { value in editVariable(variable.id) { $0.minimum = value } }), format: .number)
                    TextField("最大值", value: Binding(get: { variable.maximum },
                        set: { value in editVariable(variable.id) { $0.maximum = value } }), format: .number)
                }.textFieldStyle(.roundedBorder)
            } else if variable.kind == .boolean {
                Picker("默认值", selection: Binding(get: { variable.defaultValue?.displayText ?? "" }, set: { value in
                    editVariable(variable.id) { $0.defaultValue = value.isEmpty ? nil : .boolean(value == "true") }
                })) {
                    Text("不预设").tag(""); Text("是").tag("true"); Text("否").tag("false")
                }
            } else {
                Text("每次复用时通过文件选择器绑定素材。").font(.caption).foregroundColor(.secondary)
            }
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private var graphPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WorkflowSkillGraphView(nodes: draft.graph.nodes, edges: draft.graph.edges)
                ForEach(draft.graph.nodes) { node in
                    DisclosureGroup("\(node.id) · \(node.title) · \(node.configuration.displayName)") {
                        Text(node.body.isEmpty ? "无正文" : node.body).textSelection(.enabled)
                        if !node.configuration.textGenerationPrompt.isEmpty {
                            Text("优化指令：" + node.configuration.textGenerationPrompt)
                        }
                        Text("模型：\(node.configuration.model) · 比例：\(node.configuration.ratio)")
                        if let source = draft.provenance.sources.first(where: { $0.localID == node.id }) {
                            Text("来源修订：\(source.bodyRevision.prefix(16))" + (source.runID == nil ? " · 无运行记录" : " · 有运行记录"))
                            if let turn = self.source?.turn {
                                Button("定位来源节点") { context.locate(nodeID: source.nodeID, turn: turn) }
                            }
                        }
                    }.font(.caption)
                }
                Divider()
                ForEach(draft.provenance.limitations, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) }
            }
        }
    }
    private func editVariable(_ id: String, change: (inout WorkflowSkill.Variable) -> Void) {
        guard let index = draft.graph.variables.firstIndex(where: { $0.id == id }) else { return }
        change(&draft.graph.variables[index])
    }
    private func addBinding() {
        let binding = WorkflowSkill.Binding(nodeID: bindingNode, field: bindingField,
            match: bindingField.type == .text && !bindingMatch.isEmpty ? bindingMatch : nil)
        var next = draft
        if let index = next.graph.variables.firstIndex(where: { $0.id == bindingVariable }) {
            next.graph.variables[index].bindings.append(binding)
        } else {
            next.graph.variables.append(.init(name: bindingName, kind: bindingField.type, bindings: [binding]))
        }
        do {
            try next.validate()
            draft = next; error = nil; bindingMatch = ""; bindingName = ""
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard context.isActive else { return }
        let value = draft, expected = original?.version
        saving = true; error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WorkflowSkillStore().save(value, expectedVersion: expected) }
            }.value
            saving = false
            switch result {
            case .success:
                AgentSkillLibrary.shared.refreshWorkflows(projectID: context.projectID)
                AgentSkillLibrary.shared.refreshWorkflows(projectID: nil)
                onSaved?(); dismiss()
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}

/// Geometry and directional edges are shown together with full text below the preview.
struct WorkflowSkillGraphView: View {
    let nodes: [WorkflowSkill.Node]
    let edges: [WorkflowSkill.Edge]
    var body: some View {
        Canvas { graphics, size in
            guard !nodes.isEmpty else { return }
            let minX = nodes.map { $0.configuration.x }.min() ?? 0
            let minY = nodes.map { $0.configuration.y }.min() ?? 0
            let maxX = nodes.map { $0.configuration.x + $0.configuration.width }.max() ?? 1
            let maxY = nodes.map { $0.configuration.y + $0.configuration.height }.max() ?? 1
            let scale = min((size.width - 30) / max(1, maxX - minX), (size.height - 30) / max(1, maxY - minY))
            var rects: [String: CGRect] = [:]
            for node in nodes {
                let c = node.configuration
                rects[node.id] = CGRect(x: 15 + (c.x - minX) * scale, y: 15 + (c.y - minY) * scale,
                    width: c.width * scale, height: c.height * scale)
            }
            for edge in edges {
                guard let a = rects[edge.from], let b = rects[edge.to] else { continue }
                var path = Path()
                let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX, y: b.midY)
                path.move(to: start); path.addCurve(to: end,
                    control1: CGPoint(x: (start.x + end.x) / 2, y: start.y),
                    control2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
                graphics.stroke(path, with: .color(.secondary.opacity(0.55)), lineWidth: 1.5)
                var arrow = Path(); arrow.move(to: CGPoint(x: end.x - 5, y: end.y - 3))
                arrow.addLine(to: end); arrow.addLine(to: CGPoint(x: end.x - 5, y: end.y + 3))
                graphics.stroke(arrow, with: .color(.secondary), lineWidth: 1.5)
            }
            for node in nodes {
                guard let rect = rects[node.id] else { continue }
                graphics.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(TapSkin.accent.opacity(0.09)))
                graphics.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(TapSkin.accent.opacity(0.45)), lineWidth: 1)
                graphics.draw(Text(node.id + " · " + String(node.title.prefix(10)))
                    .font(.system(size: min(11, max(6, rect.width / 12)))).foregroundColor(TapSkin.ink),
                    at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }.frame(height: 200).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("\(nodes.count) 个节点，\(edges.count) 条有向连线")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(edges.sorted { $0.order < $1.order }) { edge in
                Text("\(edge.order + 1). \(edge.from) → \(edge.to) · \(edge.role.displayName)").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

struct WorkflowSkillLibraryView: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var context: CanvasAgentContext
    @ObservedObject private var library = AgentSkillLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var opened: Opened?
    @State private var error: String?
    @State private var loading = false
    private struct Opened: Identifiable {
        let id = UUID()
        let skill: WorkflowSkill
        let editing: Bool
    }
    private var entries: [WorkflowSkillStore.Entry] {
        (library.workflowEntries[context.projectID] ?? []).filter {
            query.isEmpty || ($0.name + $0.summary + $0.sourceLabel).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("我的创作 Skill").font(.system(size: 21, weight: .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("刷新") { library.refreshWorkflows(projectID: context.projectID) }
                Button("关闭") { dismiss() }.accessibilityIdentifier("workflow-skill-library-close")
            }
            TextField("搜索名称、适用场景或来源", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-skill-search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        Text("还没有匹配的 Skill。在 Agent 回复下方选择“保存为 Skill”，核对方法和流程后即可加入。")
                            .foregroundColor(.secondary).padding(.vertical, 30)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(entry.name).font(.headline)
                                Spacer()
                                Text(entry.sourceLabel).font(.caption).foregroundColor(.secondary)
                            }
                            Text(entry.summary.isEmpty ? "未填写适用场景" : entry.summary).font(.callout).foregroundColor(.secondary)
                            HStack {
                                Text("\(entry.nodeCount) 节点 · \(entry.edgeCount) 连线").font(.caption)
                                Spacer()
                                Button("引用到对话") {
                                    model.addSkillReference(name: entry.name, path: WorkflowSkillStore().markdownURL(entry).path, workflow: entry)
                                    dismiss()
                                }.disabled(model.isRunning).accessibilityIdentifier("workflow-skill-reference")
                                Button("编辑新版本") { open(entry, editing: true) }
                                    .accessibilityIdentifier("workflow-skill-edit")
                                Button("在新项目使用") { open(entry, editing: false) }.buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("workflow-skill-reuse")
                            }
                        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundColor(.orange) }
            Text("创建流程后，再从画布生成。历史版本保留在个人库中。").font(.caption).foregroundColor(.secondary)
        }.padding(24).frame(width: 760, height: 580)
            .background(TapSkin.tone(0xfafafa, 0x161616))
            .onAppear { library.refreshWorkflows(projectID: context.projectID) }
            .sheet(item: $opened) { item in
                if item.editing {
                    WorkflowSkillEditor(draft: item.skill, context: context, original: item.skill)
                } else {
                    WorkflowSkillReuseView(skill: item.skill, context: context)
                }
            }
    }
    private func open(_ entry: WorkflowSkillStore.Entry, editing: Bool) {
        let project = context.projectID
        loading = true; error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WorkflowSkillStore().load(entry, projectID: project) }
            }.value
            loading = false
            guard context.isActive else { return }
            switch result {
            case .success(let skill): opened = Opened(skill: skill, editing: editing)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}

struct WorkflowSkillReuseView: View {
    let skill: WorkflowSkill
    @ObservedObject var context: CanvasAgentContext
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: WorkflowSkill.Value] = [:]
    @State private var textValues: [String: String] = [:]
    @State private var projectName = ""
    @State private var instance: WorkflowSkill.Instance?
    @State private var error: String?
    @State private var creating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("使用 \(skill.name)").font(.system(size: 21, weight: .semibold))
                Spacer(); Button("取消") { dismiss() }.disabled(creating)
            }
            TextField("新项目名称", text: $projectName).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-skill-project-name")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let instance {
                        WorkflowSkillGraphView(nodes: instance.nodes, edges: instance.edges)
                        ForEach(instance.nodes) { node in
                            DisclosureGroup("\(node.id) · \(node.title)") {
                                Text(node.body).font(.caption).textSelection(.enabled)
                                Text("指令：\(node.configuration.textGenerationPrompt)\n模型：\(node.configuration.model) · \(node.configuration.ratio)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        ForEach(Array(instance.issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundColor(.orange)
                        }
                    } else {
                        ForEach(skill.graph.variables) { variable in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(variable.name + (variable.required ? " · 必填" : " · 可选")).font(.headline)
                                variableInput(variable)
                                Text(variable.bindings.map { "\($0.nodeID) · \($0.field.label)" }.joined(separator: "、"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        if skill.graph.variables.isEmpty { Text("此 Skill 使用固定内容，可在创建后的画布继续编辑。").foregroundColor(.secondary) }
                    }
                }
            }
            if let error { Text(error).foregroundColor(.orange).font(.caption) }
            Text("确认后创建可编辑节点与连线。待绑定素材和模型提示会保留；本次操作不提交生成任务。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                if instance != nil { Button("返回填写") { instance = nil } }
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                if let instance {
                    Button("确认创建项目") {
                        creating = true
                        Task {
                            do {
                                try await context.createWorkflowProject(name: projectName, instance: instance)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            creating = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(creating || !context.isActive)
                        .accessibilityIdentifier("workflow-skill-create-project")
                } else {
                    Button("预览工作流", action: prepare).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("workflow-skill-preview-graph")
                }
            }
        }.padding(24).frame(width: 760, height: 650).background(TapSkin.tone(0xfafafa, 0x161616))
            .onAppear {
                projectName = skill.name
                for variable in skill.graph.variables { textValues[variable.id] = variable.defaultValue?.displayText ?? "" }
            }
    }
    @ViewBuilder private func variableInput(_ variable: WorkflowSkill.Variable) -> some View {
        if variable.kind == .images || variable.kind == .video {
            HStack {
                Button("选择\(variable.kind == .images ? "图片" : "视频")…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = variable.kind == .images ? [.image] : [.movie]
                    panel.allowsMultipleSelection = variable.kind == .images
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK { values[variable.id] = .resources(panel.urls.map(\.path)) }
                }
                if case .resources(let paths) = values[variable.id] {
                    Text(paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")).font(.caption).lineLimit(2)
                    Button("清除") { values[variable.id] = nil }
                }
            }
        } else if variable.kind == .boolean {
            Picker("", selection: Binding(get: { textValues[variable.id] ?? "" }, set: { textValues[variable.id] = $0 })) {
                Text("请选择").tag(""); Text("是").tag("true"); Text("否").tag("false")
            }.pickerStyle(.segmented)
        } else {
            TextField(variable.kind == .integer ? "整数" : "输入内容",
                text: Binding(get: { textValues[variable.id] ?? "" }, set: { textValues[variable.id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-skill-value-" + variable.id)
        }
    }
    private func prepare() {
        do {
            var inputs = values
            for variable in skill.graph.variables where variable.kind != .images && variable.kind != .video {
                inputs[variable.id] = try variable.parse(textValues[variable.id] ?? "")
                if variable.required && inputs[variable.id] == nil && variable.defaultValue == nil {
                    throw AgentOperationError("请填写\(variable.name)。")
                }
            }
            instance = try skill.instantiate(values: inputs,
                models: CrateModelCatalogStore.shared.imageModels + CrateModelCatalogStore.shared.videoModels)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
