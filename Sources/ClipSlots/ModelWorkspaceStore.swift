import SwiftUI
import ClipSlotsKit
import AppKit

/// Owned independently; neither pointer movement nor Agent tokens publish here.
@MainActor
final class ModelWorkspaceStore: ObservableObject {
    static let shared = ModelWorkspaceStore()
    @Published var document = ModelWorkspaceDocument()
    @Published var loaded = false
    @Published var message: String?
    @Published var drafts: [ModelQuestion] = []
    @Published var generatingQuestions = false
    @Published var refreshingNews = false
    @Published var selectedRunID: String?
    @Published var cliCapabilities: [GenerationCapability] = []
    @Published var discoveringCLI = false
    private let repository: ModelWorkspaceRepository
    private let service: ModelEvaluationService
    private var expectedRevision: String?
    private var writeTask: Task<Void, Never>?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var activeModels: [String: Int] = [:]
    private var writable = true
    private var loading = false
    init(repository: ModelWorkspaceRepository = ModelWorkspaceRepository(),
         service: ModelEvaluationService = ModelEvaluationService()) {
        self.repository = repository; self.service = service
    }
    var profiles: [ModelProfile] { document.profiles.filter(\.enabled) }
    var canWrite: Bool { writable && loaded }
    func canvasProfile(for node: CanvasNode) -> ModelProfile? {
        guard let id = node.modelProfileID else { return nil }
        let purpose: ModelPurpose = node.kind == .video ? .canvasVideo : node.kind == .audio ? .canvasAudio : .canvasImage
        let profile = id == "__default__" ? defaultProfile(purpose) : profiles.first { $0.id == id }
        return profile.flatMap { !$0.isCLI && $0.kind == purpose.kind ? $0 : nil }
    }
    func evaluationCell(_ id: String) -> ModelEvaluationCell? {
        guard let (r, c) = locate(id) else { return nil }
        return document.runs[r].cells[c]
    }
    func beginCanvas(question: ModelQuestion, profile: ModelProfile) async -> String? {
        var bank = ModelQuestionBank(); bank.name = "画布 · \(profile.name)"; bank.questions = [question]
        guard let runID = await enqueue(bank: bank, profiles: [profile], scheduling: false),
              let cell = document.runs.first(where: { $0.id == runID })?.cells.first else { return nil }
        return cell.id
    }
    func resumeCanvas(_ id: String) async {
        guard let cell = evaluationCell(id) else { return }
        if cell.state == .queued { schedule() }
        else if cell.state == .polling || (cell.state == .unknown && cell.taskID != nil) {
            changeCell(id) { $0.state = .queued }
            await persist(); schedule()
        }
    }
    func defaultProfile(_ purpose: ModelPurpose) -> ModelProfile? {
        guard let id = document.defaults[purpose.rawValue] else { return nil }
        return profiles.first { $0.id == id && $0.kind == purpose.kind }
    }
    func load() async {
        guard !loaded, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let saved = try await repository.load()
            document = saved
            let exists = FileManager.default.fileExists(atPath: await repository.root.appendingPathComponent("workspace.json").path)
            expectedRevision = exists ? saved.revision : nil
            // A terminated POST remains unknown. Confirmed task IDs remain resumable.
            for r in document.runs.indices {
                for c in document.runs[r].cells.indices where document.runs[r].cells[c].state == .running {
                    document.runs[r].cells[c].state = .unknown
                    document.runs[r].cells[c].detail = "上次运行中断，提交状态未知，请核对原服务。"
                }
            }
            loaded = true
            if !document.legacyImported {
                var profile = ModelProfile()
                profile.id = "legacy-agent-deepseek"; profile.name = "已有 Agent API"
                profile.model = UserDefaults.standard.string(forKey: AgentPreferences.modelKey) ?? AgentConfig.defaultModel
                profile.endpoint = UserDefaults.standard.string(forKey: AgentPreferences.endpointKey) ?? AgentConfig.defaultEndpoint.absoluteString
                profile.legacyKeyAccount = AgentKeychain.account
                if (try? profile.validate()) != nil {
                    document.profiles.append(profile)
                    // Migration preserves existing Agent selection, including Tika.
                }
                document.legacyImported = true
            }
            if document != saved { await persist() }
            ModelConfigurationBridge.update(document)
        } catch { writable = false; message = error.localizedDescription }
    }
    /// Serialize writes but do not replace newer UI mutations with an older snapshot.
    func persist() async {
        guard writable, loaded else { return }
        let previous = writeTask
        let task = Task { @MainActor in
            await previous?.value
            guard writable else { return }
            let snapshot = document
            do {
                let saved = try await repository.save(snapshot, expectedRevision: expectedRevision)
                expectedRevision = saved.revision
                document.revision = saved.revision
            } catch { writable = false; message = error.localizedDescription }
        }
        writeTask = task; await task.value
    }
    func saveProfile(_ profile: ModelProfile, key: String) async -> Bool {
        guard canWrite else { return false }
        do {
            try profile.validate()
            let purposes = ModelPurpose.allCases.filter { document.defaults[$0.rawValue] == profile.id }
            guard purposes.allSatisfy({ profile.enabled && !profile.isCLI && profile.kind == $0.kind
                && (![ModelPurpose.agent, .questions].contains($0) || profile.contract == .chatCompletions) }) else {
                throw ModelWorkspaceError.invalid("此模型仍关联默认用途，请先调整默认用途再停用或改变类型。")
            }
            if !key.isEmpty {
                let store = AgentKeychain(service: profile.keyService, account: profile.keyAccount)
                try await Task.detached { try store.writeAPIKey(key) }.value
            }
            var value = profile; value.revision = UUID().uuidString
            if let index = document.profiles.firstIndex(where: { $0.id == profile.id }) { document.profiles[index] = value }
            else { document.profiles.append(value) }
            await persist()
            ModelConfigurationBridge.update(document)
            return writable
        } catch { message = error.localizedDescription; return false }
    }
    func setDefault(_ purpose: ModelPurpose, id: String) async {
        guard canWrite, id.isEmpty || profiles.contains(where: { $0.id == id && $0.kind == purpose.kind
            && !$0.isCLI && !([ModelPurpose.agent, .questions].contains(purpose) && $0.contract != .chatCompletions) }) else { return }
        document.defaults[purpose.rawValue] = id.isEmpty ? nil : id
        await persist(); ModelConfigurationBridge.update(document)
    }
    func removeProfile(_ id: String) async {
        guard canWrite else { return }
        guard !document.defaults.values.contains(id),
              !document.runs.contains(where: { run in run.models.contains(where: { $0.id == id }) && run.cells.contains(where: { $0.state.active }) }) else {
            message = "此模型仍被默认用途或未完成任务引用，请先调整。"; return
        }
        document.profiles.removeAll { $0.id == id }; await persist()
        ModelConfigurationBridge.update(document)
    }
    func key(for profile: ModelProfile) async throws -> String? {
        guard profile.requiresKey, !profile.isCLI else { return nil }
        return try await AgentCredentialAccess.readAPIKey(from: AgentKeychain(service: profile.keyService, account: profile.keyAccount))
    }
    func bindBank(name: String, groupIDs: [String], kind: ModelKind) async {
        guard canWrite else { return }
        guard !groupIDs.isEmpty else { message = "请选择槽位组。"; return }
        var bank = ModelQuestionBank(); bank.name = name.isEmpty ? "槽位题库" : name; bank.groupIDs = groupIDs
        document.banks.append(bank); await synchronizeBank(bank.id, kind: kind)
    }
    func synchronizeBank(_ id: String, kind: ModelKind? = nil) async {
        guard canWrite else { return }
        guard let index = document.banks.firstIndex(where: { $0.id == id }) else { return }
        let bank = document.banks[index]
        do {
            let snapshots = try await Task.detached { () -> [(String, Int, SlotContent)] in
                let storage = SpecialSlotStorage.shared
                let valid = Set(storage.loadIndex().specialSlots.map(\.id))
                var snapshots: [(String, Int, SlotContent)] = []
                for groupID in bank.groupIDs {
                    guard valid.contains(groupID) else { throw ModelWorkspaceError.invalid("题库绑定的槽位组已不存在。") }
                    for slot in 1...10 {
                        guard let content = storage.getOrUnknown(slot, in: groupID) else { throw ModelWorkspaceError.unreadable }
                        snapshots.append((groupID, slot, content))
                    }
                }
                return snapshots
            }.value
            guard let live = document.banks.firstIndex(where: { $0.id == id }) else { return }
            var questions = document.banks[live].questions
            for (group, slot, content) in snapshots {
                let revision = BatchGenerationSource.revision(of: content)
                if let q = questions.firstIndex(where: { $0.groupID == group && $0.slot == slot }) {
                    let dirty = questions[q].prompt != questions[q].syncedPrompt
                    if questions[q].slotRevision != revision {
                        if dirty { questions[q].conflict = true; continue }
                        if content.isEmpty { questions.remove(at: q); continue }
                        questions[q].prompt = content.plainText ?? ""
                        questions[q].syncedPrompt = questions[q].prompt
                        questions[q].slotRevision = revision
                        questions[q].references = Self.references(content)
                        questions[q].conflict = false
                    }
                } else if !content.isEmpty {
                    var q = ModelQuestion(); q.groupID = group; q.slot = slot
                    q.kind = kind ?? questions.first?.kind ?? .llm
                    q.prompt = content.plainText ?? ""
                    q.title = content.label ?? "槽位 \(slot)"
                    q.syncedPrompt = q.prompt; q.slotRevision = revision; q.references = Self.references(content)
                    q.dimensions = Self.defaultDimensions(q.kind)
                    questions.append(q)
                }
            }
            document.banks[live].questions = questions; touchBank(live); await persist()
        } catch { message = error.localizedDescription }
    }
    static func defaultDimensions(_ kind: ModelKind) -> [ModelDimension] {
        switch kind { case .llm: return [.response]; case .image: return [.response, .beauty]
        case .video: return [.response, .beauty, .motion]; case .audio: return [.response, .audio] }
    }
    private static func references(_ content: SlotContent) -> [ModelReference] {
        content.attachments.compactMap { attachment in
            (attachment.storageFileURL?.path ?? attachment.storagePath ?? attachment.path)
                .map { ModelReference(path: $0, name: attachment.name) }
        }
    }
    private func touchBank(_ index: Int) {
        document.banks[index].revision = UUID().uuidString; document.banks[index].updatedAt = Date()
    }
    func updateBank(_ bank: ModelQuestionBank) async {
        guard canWrite, let b = document.banks.firstIndex(where: { $0.id == bank.id }),
              bank.weights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              bank.weights.values.contains(where: { $0 > 0 }) else { return }
        document.banks[b].name = bank.name
        document.banks[b].weights = bank.weights
        document.banks[b].groupIDs = bank.groupIDs
        document.banks[b].questions.removeAll { $0.groupID.map { !bank.groupIDs.contains($0) } ?? false }
        touchBank(b); await synchronizeBank(bank.id)
    }
    func editQuestion(_ question: ModelQuestion, bankID: String, store: SlotStoreObservable) async -> Bool {
        guard canWrite else { return false }
        guard let b = document.banks.firstIndex(where: { $0.id == bankID }) else { return false }
        var saved = question
        do {
            if let group = question.groupID, let slot = question.slot, let revision = question.slotRevision {
                let content = try store.writeModelQuestion(groupID: group, slot: slot, expectedRevision: revision, text: question.prompt)
                saved.slotRevision = BatchGenerationSource.revision(of: content)
                saved.syncedPrompt = question.prompt; saved.conflict = false
            }
            if let q = document.banks[b].questions.firstIndex(where: { $0.id == question.id }) { document.banks[b].questions[q] = saved }
            else { document.banks[b].questions.append(saved) }
            touchBank(b); await persist(); return writable
        } catch { message = error.localizedDescription; return false }
    }
    func generateQuestions(topic: String, kind: ModelKind, count: Int) async {
        guard !generatingQuestions, let profile = defaultProfile(.questions) else {
            message = "请在配置中心选择默认出题 LLM。"; return
        }
        generatingQuestions = true; defer { generatingQuestions = false }
        do {
            drafts = try await service.generateQuestions(profile: profile, key: key(for: profile),
                topic: topic, kind: kind, count: count, dimensions: Self.defaultDimensions(kind))
        } catch { message = error.localizedDescription }
    }
    func saveDrafts(bankID: String, store: SlotStoreObservable) async {
        guard canWrite else { return }
        guard let b = document.banks.firstIndex(where: { $0.id == bankID }) else { return }
        // Save reviewed drafts one by one; occupied targets are never overwritten.
        while let draft = drafts.first {
            do {
                let groups = document.banks[b].groupIDs
                let target = try await Task.detached { () -> (String, Int, String) in
                    for group in groups {
                        for slot in 1...10 {
                            guard let content = SpecialSlotStorage.shared.getOrUnknown(slot, in: group) else { throw ModelWorkspaceError.unreadable }
                            if content.isEmpty { return (group, slot, BatchGenerationSource.revision(of: content)) }
                        }
                    }
                    throw ModelWorkspaceError.invalid("绑定槽位已满，请添加槽位组后继续保存；剩余草稿已保留。")
                }.value
                var question = draft; question.groupID = target.0; question.slot = target.1; question.slotRevision = target.2
                guard await editQuestion(question, bankID: bankID, store: store) else { return }
                drafts.removeFirst()
            } catch { message = error.localizedDescription; return }
        }
    }
    func start(bankID: String, selectedIDs: Set<String>, questionIDs: Set<String>? = nil) async {
        guard var bank = document.banks.first(where: { $0.id == bankID }) else { return }
        if let questionIDs { bank.questions.removeAll { !questionIDs.contains($0.id) } }
        _ = await enqueue(bank: bank, profiles: profiles.filter { selectedIDs.contains($0.id) }, scheduling: true)
    }
    private func enqueue(bank: ModelQuestionBank, profiles: [ModelProfile], scheduling: Bool) async -> String? {
        guard canWrite else { return nil }
        do {
            var run = try ModelEvaluationRun(bank: bank, models: profiles)
            let runID = run.id
            run.bank = try await Task.detached {
                var snapshot = bank
                let root = ClipSlotsPaths.dataRoot.appendingPathComponent("models/inputs/" + runID)
                for q in snapshot.questions.indices {
                    for ref in snapshot.questions[q].references.indices {
                        let original = snapshot.questions[q].references[ref]
                        guard original.isCurrent else { throw GenerationAdapterError.inputChanged }
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        let ext = URL(fileURLWithPath: original.name ?? original.path).pathExtension
                        let dest = root.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: original.path), to: dest)
                        guard original.isCurrent else { throw GenerationAdapterError.inputChanged }
                        snapshot.questions[q].references[ref] = .init(path: dest.path, name: original.name)
                    }
                }
                return snapshot
            }.value
            document.runs.append(run); selectedRunID = run.id; await persist()
            if writable && scheduling { schedule() }
            return writable ? run.id : nil
        } catch { message = error.localizedDescription; return nil }
    }
    private func locate(_ cellID: String) -> (Int, Int)? {
        for r in document.runs.indices {
            if let c = document.runs[r].cells.firstIndex(where: { $0.id == cellID }) { return (r, c) }
        }
        return nil
    }
    private func changeCell(_ id: String, _ change: (inout ModelEvaluationCell) -> Void) {
        guard let (r, c) = locate(id) else { return }; change(&document.runs[r].cells[c])
    }
    private func schedule() {
        guard writable else { return }
        for run in document.runs where !run.cancelled {
            for cell in run.cells where cell.state == .queued && tasks[cell.id] == nil {
                guard tasks.count < 4, let profile = run.models.first(where: { $0.id == cell.modelID }),
                      activeModels[profile.id, default: 0] < profile.concurrency,
                      let question = run.bank.questions.first(where: { $0.id == cell.questionID }) else { continue }
                activeModels[profile.id, default: 0] += 1
                changeCell(cell.id) { $0.state = .running; $0.startedAt = Date(); $0.attempt += 1 }
                tasks[cell.id] = Task { [weak self] in
                    guard let self else { return }
                    await self.execute(cell: cell, profile: profile, question: question)
                    tasks[cell.id] = nil; activeModels[profile.id, default: 1] -= 1
                    schedule()
                }
            }
        }
    }
    private func execute(cell: ModelEvaluationCell, profile: ModelProfile, question: ModelQuestion) async {
        await persist()
        guard writable else { return }
        do {
            let output: ModelEvaluationOutput?
            if profile.isCLI { output = try await executeCLI(cell: cell, profile: profile, question: question) }
            else {
                let key = try await key(for: profile)
                if let id = cell.taskID { output = try await poll(cell: cell, profile: profile, key: key, taskID: id) }
                else {
                    output = try await service.submit(question: question, profile: profile, key: key) { [weak self] id in
                        try await self?.confirm(cellID: cell.id, taskID: id)
                    }
                    if output == nil, let (r, c) = locate(cell.id), let id = document.runs[r].cells[c].taskID {
                        let resolved = try await poll(cell: cell, profile: profile, key: key, taskID: id)
                        finish(cell.id, output: resolved); await persist(); return
                    }
                }
            }
            finish(cell.id, output: output)
        } catch {
            changeCell(cell.id) { current in
                if case ModelWorkspaceError.remoteFailed = error {
                    current.state = .failed; current.terminalRemoteFailure = true
                    current.detail = error.localizedDescription; current.completedAt = Date()
                } else if current.taskID != nil || current.cliTask != nil {
                    current.state = .polling; current.detail = "查询暂停，可继续原任务。" + error.localizedDescription
                } else if case ModelWorkspaceError.submissionUnknown = error {
                    current.state = .unknown; current.detail = error.localizedDescription
                } else if case GenerationAdapterError.submissionUnknown = error {
                    current.state = .unknown; current.detail = error.localizedDescription
                } else {
                    current.state = error is CancellationError ? .cancelled : .failed
                    current.detail = error.localizedDescription; current.completedAt = Date()
                }
            }
        }
        await persist()
    }
    private func finish(_ id: String, output: ModelEvaluationOutput?) {
        guard let output else { return }
        changeCell(id) { $0.state = .succeeded; $0.text = output.text; $0.mediaURLs = output.urls
            $0.localMediaPaths = output.paths; $0.detail = ""; $0.completedAt = Date() }
    }
    private func confirm(cellID: String, taskID: String) async throws {
        changeCell(cellID) { $0.taskID = taskID; $0.state = .polling }; await persist()
        guard writable else { throw ModelWorkspaceError.unreadable }
    }
    private func poll(cell: ModelEvaluationCell, profile: ModelProfile, key: String?, taskID: String) async throws -> ModelEvaluationOutput? {
        let deadline = Date().addingTimeInterval(profile.kind == .video ? 1800 : 600)
        while Date() < deadline {
            try Task.checkCancellation()
            if let output = try await service.query(profile: profile, key: key, taskID: taskID) { return output }
            try await Task.sleep(for: .seconds(3))
        }
        throw ModelWorkspaceError.invalid("查询超时。")
    }
    func cancel(_ runID: String) async {
        guard let r = document.runs.firstIndex(where: { $0.id == runID }) else { return }
        document.runs[r].cancelled = true
        for c in document.runs[r].cells.indices {
            let cell = document.runs[r].cells[c]
            if cell.state == .queued { document.runs[r].cells[c].state = .cancelled }
            tasks[cell.id]?.cancel()
        }
        message = "已停止新请求和本地查询；已提交任务可能仍在远端运行。"
        await persist()
    }
    func retry(_ cellID: String) async {
        guard let (r, c) = locate(cellID), tasks[cellID] == nil else { return }
        let cell = document.runs[r].cells[c]
        guard [.failed, .cancelled, .polling].contains(cell.state) else {
            message = "成功或提交未知的单元不会重复提交。"; return
        }
        document.runs[r].cancelled = false; document.runs[r].cells[c].state = .queued
        if cell.terminalRemoteFailure {
            document.runs[r].cells[c].taskID = nil; document.runs[r].cells[c].cliTask = nil
            document.runs[r].cells[c].terminalRemoteFailure = false
        }
        await persist(); schedule()
    }
    func score(_ cellID: String, scores: [String: Double]) async {
        guard let (r, c) = locate(cellID), document.runs[r].cells[c].state == .succeeded,
              let question = document.runs[r].bank.questions.first(where: { $0.id == document.runs[r].cells[c].questionID }) else { return }
        let keys = Set(question.applicableDimensions.map(\.rawValue))
        guard Set(scores.keys) == keys, scores.values.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else {
            message = "请为所有适用维度填写 0–100 分。"; return
        }
        changeCell(cellID) { $0.scores = scores; $0.scoredAt = Date(); $0.scoreSource = "人工" }
        await persist()
    }
    func refreshNews(force: Bool = false) async {
        guard canWrite, !refreshingNews, force || document.newsRefreshedAt.map({ !Calendar.current.isDateInToday($0) }) ?? true else { return }
        refreshingNews = true; defer { refreshingNews = false }
        let result = await ModelNewsService().refresh(sources: document.newsSources)
        let retained = document.news.filter { !result.successfulSources.contains($0.sourceID) }
        var seen = Set<String>()
        document.news = (result.items + retained).filter { seen.insert($0.url).inserted }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        document.newsErrors = result.errors
        if !result.successfulSources.isEmpty { document.newsRefreshedAt = Date() }
        await persist()
    }
    private func provider(_ profile: ModelProfile) throws -> any GenerationProvider {
        guard let context = profile.cliContext else { throw GenerationAdapterError.providerMismatch }
        if context.provider == .byteartist { return try ByteArtistRuntime().adapter }
        return try CrateGenerationAdapter(context: context, directory: ClipSlotsPaths.dataRoot.appendingPathComponent("models/cli")) { invocation in
            let chain = LocalToolchain()
            guard let path = chain.resolve(.crate) else { throw GenerationAdapterError.processNotStarted }
            return try await GenerationProcessBudget.shared.withPermit {
                try FileManager.default.createDirectory(at: invocation.directory, withIntermediateDirectories: true)
                return try await ToolProcess.run(path, invocation.arguments, environment: invocation.environment,
                    directory: invocation.directory, timeout: invocation.timeout, outputLimit: 4_194_304, captureStoppedOutput: invocation.submitting)
            }
        }
    }
    func discoverCLI(_ id: GenerationProviderID) async {
        guard !discoveringCLI else { return }
        discoveringCLI = true; defer { discoveringCLI = false }
        do {
            var p = ModelProfile(); p.cliContext = id == .crate ? .crate : .byteartist
            let adapter = try provider(p); try await adapter.preflight()
            cliCapabilities = try await adapter.discover()
            if cliCapabilities.isEmpty { message = "尚无已发现能力，请在环境检测或 BA 能力库加载配置。"; }
        } catch { message = error.localizedDescription }
    }
    func importCapability(_ capability: GenerationCapability) async {
        guard let kind = ModelKind(rawValue: capability.kind == .text ? "llm" : capability.kind.rawValue) else { return }
        var p = ModelProfile(); p.id = capability.context.provider.rawValue + ":" + capability.id + ":" + kind.rawValue
        p.name = capability.title; p.model = capability.id; p.kind = kind; p.requiresKey = false
        p.cliContext = capability.context; p.cliCapabilityID = capability.id
        p.cliInputSchema = capability.inputSchema; p.cliOutputBindings = capability.outputBindings
        let fields = capability.inputSchema["properties"]?.objectValue ?? [:]
        for (key, rule) in fields { if let value = rule["default"] { p.parameters[key] = value } }
        p.cliPromptKey = fields.keys.first(where: { ["prompt", "提示词", "正向提示词"].contains($0) }) ?? "prompt"
        _ = await saveProfile(p, key: "")
    }
    private func executeCLI(cell: ModelEvaluationCell, profile: ModelProfile, question: ModelQuestion) async throws -> ModelEvaluationOutput? {
        let adapter = try provider(profile)
        let handle: GenerationTaskHandle
        if let task = cell.cliTask { handle = task }
        else {
            try await adapter.preflight()
            guard let capability = try await adapter.discover().first(where: {
                $0.id == profile.cliCapabilityID && ($0.kind == .text ? profile.kind == .llm : $0.kind.rawValue == profile.kind.rawValue)
            }),
                  capability.inputSchema == profile.cliInputSchema else { throw GenerationAdapterError.capabilityChanged }
            var values = profile.parameters; values[profile.cliPromptKey] = .string(question.prompt)
            if !question.references.isEmpty {
                guard profile.cliContext?.provider == .crate else {
                    throw ModelWorkspaceError.invalid("BA 参考文件需要在参数中显式绑定上传字段。")
                }
                values[profile.kind == .image ? "images" : "reference_images"] = .array(question.references.map { .string($0.path) })
            }
            let request = try await adapter.prepare(.init(values: values), capability: capability)
            let submission = try await adapter.submit(request)
            handle = submission.task
            changeCell(cell.id) { $0.cliTask = handle; $0.taskID = handle.taskID; $0.state = .polling }
            await persist()
        }
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline {
            try Task.checkCancellation()
            let observation = try await adapter.query(handle)
            switch observation.status {
            case .succeeded:
                return .init(text: observation.artifacts.filter { $0.kind == .text }.compactMap { $0.value.stringValue }.joined(separator: "\n"),
                    urls: observation.artifacts.compactMap { $0.remoteURL?.absoluteString })
            case .failed: throw ModelWorkspaceError.remoteFailed
            case .outputMismatch: throw ModelWorkspaceError.invalid(observation.detail ?? "CLI 输出字段未确认。")
            default: break
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw GenerationAdapterError.timeout
    }
}

/// Read by Agent/backend and canvas selectors without subscribing their trees.
enum ModelConfigurationBridge {
    private static let lock = NSLock()
    private static var profiles: [ModelProfile] = []
    private static var defaults: [String: String] = [:]
    static func update(_ document: ModelWorkspaceDocument) {
        lock.lock(); profiles = document.profiles; defaults = document.defaults; lock.unlock()
        AgentBackendCoordinator.broadcastChange()
    }
    static func profile(_ purpose: ModelPurpose) -> ModelProfile? {
        lock.lock(); defer { lock.unlock() }
        return profiles.first { $0.id == defaults[purpose.rawValue] && $0.enabled && $0.kind == purpose.kind }
    }
    static func agentProfiles() -> [ModelProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles.filter { $0.enabled && !$0.isCLI && $0.kind == .llm && $0.contract == .chatCompletions }
    }
    static func hasDefault(_ purpose: ModelPurpose) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults[purpose.rawValue] != nil
    }
}
