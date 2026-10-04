import SwiftUI
import AppKit
import ClipSlotsKit

enum CodexPage: String, CaseIterable {
    case chat, automations, tools, projects, review
    var title: String {
        switch self {
        case .chat: return "Codex"; case .automations: return "定时任务"; case .tools: return "Skills 与 MCP"
        case .projects: return "项目"; case .review: return "代码审查"
        }
    }
}

private func chooseCodexFolder(_ selected: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.prompt = "选择项目"
    panel.begin { if $0 == .OK, let url = panel.url { selected(url) } }
}

struct CodexPageHeader: View {
    let title: String
    var body: some View {
        HStack { Text(title).font(.system(size: 22, weight: .semibold)); Spacer() }
            .accessibilityIdentifier("codex-page-\(title)")
    }
}

struct CodexAutomationsView: View {
    @ObservedObject private var scheduler = CodexAutomationModel.shared
    @ObservedObject private var execution = CodexAutomationModel.shared.execution
    @ObservedObject var chat: AgentChatModel
    @Binding var editing: CodexAutomation?
    var openThread: (String) -> Void
    @State private var search = ""
    @State private var tab = "即将执行"
    @State private var deleting: CodexAutomation?
    @State private var result: CodexAutomationRun?
    private var matches: [CodexAutomation] {
        scheduler.tasks.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
            && (tab == "已暂停" ? !$0.enabled : $0.enabled) }.sorted { $0.nextRun < $1.nextRun }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if scheduler.tasks.isEmpty && scheduler.runs.isEmpty {
                Spacer()
                VStack(spacing: 18) {
                    Text("🕘").font(.system(size: 54))
                    Text("安排任务").font(.system(size: 23, weight: .medium))
                    Text("让 Codex 按计划检查项目、整理信息和生成报告。")
                        .font(.system(size: 14)).foregroundColor(TapSkin.secondaryInk)
                    Button { create() } label: {
                        Text("新建任务").font(.system(size: 13, weight: .semibold))
                            .foregroundColor(TapSkin.tone(0xffffff, 0x111111))
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(TapSkin.ink, in: Capsule())
                    }.buttonStyle(.plain).padding(.top, 12).accessibilityIdentifier("codex-automation-create")
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
            HStack {
                CodexPageHeader(title: "定时任务")
                Button("新建", systemImage: "plus") { create() }.accessibilityIdentifier("codex-automation-create")
            }
            HStack {
                Picker("查看", selection: $tab) {
                    Text("即将执行").tag("即将执行"); Text("已暂停").tag("已暂停"); Text("执行记录").tag("执行记录")
                }.pickerStyle(.segmented).frame(maxWidth: 310)
                Spacer()
                TextField("搜索任务", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            if let error = scheduler.error {
                HStack {
                    Text(error).font(.caption).foregroundColor(.orange).textSelection(.enabled)
                    Button("重试读取") { scheduler.start() }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if tab == "执行记录" {
                        ForEach(scheduler.runs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { run in
                            Button { result = run } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(run.name).font(.system(size: 14, weight: .medium))
                                        Text(run.startedAt, style: .date).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(run.status.title).font(.caption)
                                    Image(systemName: "chevron.right")
                                }.padding(16).background(TapSkin.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                        if scheduler.runs.isEmpty { empty("还没有执行记录", "任务执行后的结果会保存在这里。") }
                    } else {
                        ForEach(matches) { task in taskRow(task) }
                        if matches.isEmpty { empty("没有\(tab == "已暂停" ? "已暂停" : "即将执行")的任务", "创建一个任务，让 Codex 按计划检查项目或整理信息。") }
                    }
                }
            }
            }
            Text("在此 Mac 上由 ClipSlots 执行 · Codex 只读权限\n应用须保持运行；休眠或退出后补执行一次。此处任务不与官方本地 / 云端任务共享。")
                .font(.system(size: 11)).foregroundColor(TapSkin.faintInk)
            if scheduler.tasks.isEmpty, let error = scheduler.error {
                Text(error).font(.caption).foregroundColor(.orange)
                Button("重试读取") { scheduler.start() }
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { scheduler.start() }
            .sheet(item: $editing) { task in CodexAutomationEditor(value: task, scheduler: scheduler) }
            .sheet(item: $result) { run in
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(run.name).font(.title2); Spacer(); Button("完成") { result = nil } }
                    Text(run.status.title).foregroundColor(.secondary)
                    ScrollView { Text(run.output.isEmpty ? "执行中，请关闭后重新查看。" : run.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if let id = run.threadID { Button("在 Codex 会话中查看") { result = nil; openThread(id) }.disabled(chat.isRunning) }
                }.padding(24).frame(width: 650, height: 520)
            }
            .alert("删除定时任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let task = deleting { scheduler.delete(task.id) }; deleting = nil }
            } message: { Text("停止后续计划，保留已有执行记录。") }
    }
    private func create() {
        var value = CodexAutomation()
        value.cwd = chat.codexContext?.cwd ?? AgentBackendCoordinator.codexConfiguration().workingDirectory
        value.model = chat.codexContext?.model ?? CodexWorkspaceModel.shared.settings.model
        value.provider = chat.codexContext?.provider ?? CodexWorkspaceModel.shared.settings.provider
        editing = value
    }
    private func empty(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "clock").font(.system(size: 34)).foregroundColor(TapSkin.faintInk)
            Text(title).font(.system(size: 17, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk)
        }.frame(maxWidth: .infinity).padding(.vertical, 90)
    }
    private func taskRow(_ task: CodexAutomation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock").foregroundColor(TapSkin.secondaryInk)
                Text(task.name).font(.system(size: 15, weight: .medium))
                Spacer()
                if scheduler.activeID == task.id {
                    ProgressView().controlSize(.small)
                    Button("停止") { scheduler.stop() }
                } else {
                    Button("立即运行") { scheduler.run(task) }.disabled(scheduler.activeID != nil)
                }
                Menu {
                    Button("编辑") { editing = task }
                    Button(task.enabled ? "暂停" : "恢复") { scheduler.toggle(task) }
                    Button("删除", role: .destructive) { deleting = task }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .disabled(scheduler.activeID == task.id)
            }
            Text(task.prompt).font(.system(size: 12)).lineLimit(2).foregroundColor(TapSkin.secondaryInk)
            HStack {
                Text(task.frequency.title)
                Text(task.nextRun, style: .date)
                Text(task.nextRun, style: .time)
                Spacer()
                Text(URL(fileURLWithPath: task.cwd).lastPathComponent)
            }.font(.system(size: 11)).foregroundColor(TapSkin.faintInk)
            if scheduler.activeID == task.id && !execution.output.isEmpty {
                Text(execution.output).lineLimit(4).font(.caption).textSelection(.enabled)
            }
        }.padding(18).background(TapSkin.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CodexAutomationEditor: View {
    @State var value: CodexAutomation
    @ObservedObject var scheduler: CodexAutomationModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("定时任务").font(.title2)
            TextField("任务名称", text: $value.name).textFieldStyle(.roundedBorder)
            Text("任务指令").font(.headline)
            TextEditor(text: $value.prompt).font(.body).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            HStack {
                Text(value.cwd.isEmpty ? "选择项目文件夹" : value.cwd).font(.caption).lineLimit(2)
                Spacer()
                Button("选择文件夹") { chooseCodexFolder { value.cwd = $0.path } }
            }
            HStack {
                Picker("重复", selection: $value.frequency) {
                    ForEach(CodexAutomation.Frequency.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                DatePicker("首次执行", selection: $value.nextRun, in: Date()...)
            }
            Text("时间按 \(value.timeZoneID) 保存。使用当前 Codex 配置，只读运行；执行会消耗所选模型额度。")
                .font(.caption).foregroundColor(.secondary)
            TextField("模型（留空则使用 Codex 默认模型）", text: $value.model).textFieldStyle(.roundedBorder)
            Toggle("启用任务", isOn: $value.enabled)
            if let error { Text(error).font(.caption).foregroundColor(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try value.validate()
                        guard value.nextRun > Date() || !value.enabled else { throw CodexServerError("请选择未来的执行时间。") }
                        if scheduler.save(value) { dismiss() } else { error = scheduler.error }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("codex-automation-save")
            }
        }.padding(24).frame(width: 600)
    }
}

struct CodexProjectsView: View {
    @ObservedObject private var desktop = CodexWorkspaceModel.shared
    @ObservedObject var chat: AgentChatModel
    var openChat: () -> Void
    @State private var search = ""
    @State private var name = ""
    @State private var path = ""
    @State private var key = UUID().uuidString
    @State private var editing: CodexProject?
    @State private var showEditor = false
    @State private var deleting: CodexProject?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                CodexPageHeader(title: "项目")
                if desktop.projectsBusy { ProgressView().controlSize(.small) }
                Button("刷新") { desktop.reloadProjects() }
                Button("新建项目") {
                    editing = nil; name = ""; path = ""; key = UUID().uuidString; showEditor = true
                }.accessibilityIdentifier("codex-project-create")
            }
            Text("Codex 项目与本机历史中的文件夹。选择项目后在对应目录开启新对话。")
                .font(.caption).foregroundColor(TapSkin.secondaryInk)
            TextField("搜索项目", text: $search).textFieldStyle(.roundedBorder)
            if let error = desktop.projectsError { Text(error).foregroundColor(.orange).font(.caption).textSelection(.enabled) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(desktop.projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) }) { project in
                        HStack(spacing: 14) {
                            Image(systemName: "folder").font(.title2)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(project.name).font(.system(size: 15, weight: .medium))
                                Text(project.path).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                Text(project.isOfficial ? "Codex 项目" : "历史文件夹").font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("打开") {
                                desktop.cancelSelection(); chat.selectProject(project); openChat()
                            }.disabled(chat.isRunning)
                            Menu {
                                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                                if project.isOfficial {
                                    Button("重命名") { editing = project; name = project.name; path = project.path; showEditor = true }
                                    Button("移除项目", role: .destructive) { deleting = project }
                                } else {
                                    Button("添加为 Codex 项目") {
                                        editing = nil; name = project.name; path = project.path; key = UUID().uuidString; showEditor = true
                                    }
                                }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(18).background(TapSkin.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if desktop.projects.isEmpty { Text("添加项目文件夹，开始构建。").foregroundColor(.secondary).padding(70) }
                }
            }
        }.padding(32).onAppear { desktop.reloadProjects() }
            .sheet(isPresented: $showEditor) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(editing == nil ? "新建项目" : "重命名项目").font(.title2)
                    TextField("项目名称", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        Text(path.isEmpty ? "尚未选择文件夹" : path).font(.caption).lineLimit(2)
                        Spacer()
                        if editing == nil {
                            Button("选择文件夹") { chooseCodexFolder { path = $0.path; if name.isEmpty { name = $0.lastPathComponent } } }
                        }
                    }
                    if let error = desktop.projectsError { Text(error).font(.caption).foregroundColor(.orange) }
                    HStack {
                        Spacer()
                        Button("取消") { showEditor = false }.disabled(desktop.projectsBusy)
                        Button("保存") {
                            if let editing {
                                desktop.renameProject(editing, name: name.trimmingCharacters(in: .whitespacesAndNewlines)) { showEditor = false }
                            } else {
                                desktop.addProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines), path: path, key: key) { showEditor = false }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty || desktop.projectsBusy)
                    }
                }.padding(24).frame(width: 520)
            }
            .alert("移除 Codex 项目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("移除", role: .destructive) { if let project = deleting { desktop.deleteProject(project) }; deleting = nil }
            } message: { Text("这会更新本机 Codex 项目列表，不删除磁盘上的文件夹。") }
    }
}

struct CodexReviewView: View {
    @ObservedObject var chat: AgentChatModel
    @ObservedObject private var review = CodexReviewModel.shared
    @ObservedObject private var execution = CodexReviewModel.shared.execution
    var openThread: (String) -> Void
    @State private var cwd = ""
    @State private var kind = "uncommittedChanges"
    @State private var argument = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CodexPageHeader(title: "代码审查")
            Text("使用 Codex 审查本机项目，结果保存在独立会话中。只读运行；开始审查会消耗模型额度。")
                .font(.caption).foregroundColor(TapSkin.secondaryInk)
            HStack {
                Text(cwd.isEmpty ? "选择项目文件夹" : cwd).font(.callout).lineLimit(2)
                Spacer()
                Button("选择文件夹") { chooseCodexFolder { cwd = $0.path } }.disabled(review.busy)
            }
            Picker("审查范围", selection: $kind) {
                Text("未提交更改").tag("uncommittedChanges")
                Text("相对分支").tag("baseBranch")
                Text("指定提交").tag("commit")
            }.pickerStyle(.segmented).disabled(review.busy)
            if kind != "uncommittedChanges" {
                TextField(kind == "baseBranch" ? "基准分支，例如 main" : "Commit SHA", text: $argument)
                    .textFieldStyle(.roundedBorder).disabled(review.busy)
            }
            HStack {
                if review.busy {
                    ProgressView().controlSize(.small)
                    Text("正在审查…").font(.caption)
                    Button("停止") { review.stop() }
                } else {
                    Button("开始审查") {
                        var task = CodexAutomation()
                        task.name = "代码审查"; task.cwd = cwd; task.prompt = "审查项目代码，报告可复现的问题。"
                        task.model = chat.codexContext?.model ?? CodexWorkspaceModel.shared.settings.model
                        task.provider = chat.codexContext?.provider ?? CodexWorkspaceModel.shared.settings.provider
                        var target: [String: JSONValue] = ["type": .string(kind)]
                        if kind != "uncommittedChanges" {
                            target[kind == "baseBranch" ? "branch" : "sha"] = .string(argument.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        review.start(task, target: .object(target))
                    }.disabled(cwd.isEmpty || (kind != "uncommittedChanges" && argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("codex-review-start")
                }
                Spacer()
                if let id = execution.threadID, !review.busy {
                    Button("打开审查会话") { openThread(id) }.disabled(chat.isRunning)
                }
            }
            if let error = review.error { Text(error).font(.caption).foregroundColor(.orange).textSelection(.enabled) }
            Divider()
            ScrollView {
                Text(execution.output.isEmpty ? "审查结果将在这里显示。" : execution.output)
                    .font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(32).onAppear {
            if cwd.isEmpty { cwd = chat.codexContext?.cwd ?? AgentBackendCoordinator.codexConfiguration().workingDirectory }
        }
    }
}
