import Foundation
import ClipSlotsKit

/// One bounded batch across windows. Every independent item owns its request,
/// output and journal identity; UI/disk updates remain serialized on the main actor.
@MainActor
final class BatchGenerationController: ObservableObject {
    static let shared = BatchGenerationController()
    @Published private(set) var groups: [BatchGenerationGroup] = []
    @Published private(set) var batches: [BatchGeneration] = []
    @Published private(set) var isLoading = false
    @Published private(set) var runningID: UUID?
    @Published private(set) var isRecovering = false
    @Published private(set) var activeCount = 0
    @Published private(set) var peakActiveCount = 0
    @Published var error: String?
    private let storage: BatchGenerationStorage
    private var task: Task<Void, Never>?
    private var loadToken = UUID()
    private var historyLoaded = false

    init(storage: BatchGenerationStorage = .init()) { self.storage = storage }

    func loadLibrary(store: SlotStoreObservable) async {
        let token = UUID(); loadToken = token
        isLoading = true; error = nil
        let library = store.specialStorage, capacity = store.config.slots, disk = storage
        let needsHistory = !historyLoaded
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([BatchGenerationGroup], [BatchGeneration]), Error> in
            Result {
                let groups = try library.batchGenerationGroups(slotCount: capacity)
                var batches = needsHistory ? try disk.loadAll() : []
                for i in batches.indices {
                    batches[i].reconcile(runs: GenerationRunStore.shared.runs(project: batches[i].projectID))
                    try disk.save(batches[i])
                }
                return (groups, batches)
            }
        }.value
        guard token == loadToken else { return }
        isLoading = false
        switch result {
        case .success(let (groups, history)):
            self.groups = groups
            if needsHistory { batches = history; historyLoaded = true }
        case .failure(let failure):
            groups = []
            error = "读取批量任务失败：\(failure.localizedDescription)"
        }
    }

    func plan(projectID: String, selected: Set<String>, configuration: CanvasNode,
              model: CrateModelCatalog.ModelInfo?) -> BatchGeneration {
        var batch = BatchGeneration(projectID: projectID, groups: groups, selected: selected, configuration: configuration)
        for i in batch.items.indices where batch.items[i].status == .pending {
            let item = batch.items[i], fact = item.source.facts(node: item.node)
            let plan = CanvasWorkflowResolver.resolve(fact, all: [item.node.id: fact], edges: [], model: model)
            if let reason = plan.blockingReasons.first {
                batch.items[i].status = .skipped; batch.items[i].detail = reason
            }
        }
        return batch
    }

    @discardableResult
    func start(_ batch: BatchGeneration, store: SlotStoreObservable,
               model: CrateModelCatalog.ModelInfo?) -> Bool {
        guard historyLoaded, !isLoading, runningID == nil, !batches.contains(where: { $0.id == batch.id }),
              batch.items.contains(where: { $0.status == .pending }) else { return false }
        let prepared: BatchGeneration
        do { prepared = try storage.create(batch) }
        catch { self.error = "任务尚未提交：无法保存批次"; return false }
        batches.insert(prepared, at: 0)
        launch(prepared.id, store: store, model: model, recoveryOnly: false)
        return true
    }

    func stop(_ id: UUID) {
        guard runningID == id else { return }
        // Stop in memory even when the disk is full; a journal error must not authorize
        // the remaining submissions. Restart reconciliation handles the stale journal.
        task?.cancel()
        do {
            try edit(id) { $0.stopRequested = true }
        } catch { self.error = "停止状态未能保存：\(error.localizedDescription)" }
    }

    func canRetry(_ id: UUID, itemID: UUID) -> Bool {
        guard !isLoading, !isRecovering, runningID == nil || runningID == id,
              runningID == nil || batch(id)?.stopRequested != true,
              let batch = batch(id), let item = batch.items.first(where: { $0.id == itemID }),
              item.canRetry else { return false }
        return GenerationRunStore.shared.load(project: batch.projectID, id: item.runID)?
            .requiresSubmissionReconciliation != true
    }

    @discardableResult
    func retry(_ id: UUID, itemID: UUID, store: SlotStoreObservable,
               model: CrateModelCatalog.ModelInfo?) -> Bool {
        guard canRetry(id, itemID: itemID) else { return false }
        do {
            try edit(id) { batch in
                guard let index = batch.items.firstIndex(where: { $0.id == itemID }) else { return }
                batch.items[index].prepareRetry()
                batch.stopRequested = false
            }
        } catch { self.error = "无法重新生成：\(error.localizedDescription)"; return false }
        if runningID == nil { launch(id, store: store, model: model, recoveryOnly: false) }
        return true
    }

    func recover(_ id: UUID, itemID: UUID? = nil, store: SlotStoreObservable) {
        guard runningID == nil, !isLoading, let batch = batch(id),
              batch.items.contains(where: { $0.canRecover && (itemID == nil || $0.id == itemID) }) else { return }
        do { try edit(id) { $0.stopRequested = false } }
        catch { self.error = "无法恢复：\(error.localizedDescription)"; return }
        launch(id, store: store, model: nil, recoveryOnly: true, recoveryItemID: itemID)
    }

    func batch(_ id: UUID) -> BatchGeneration? { batches.first { $0.id == id } }

    private func edit(_ id: UUID, _ change: (inout BatchGeneration) -> Void) throws {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var copy = batches[index]
        change(&copy)
        try storage.save(copy)
        batches[index] = copy
    }

    private func editItem(_ id: UUID, _ itemID: UUID, _ change: (inout BatchGeneration.Item) -> Void) throws {
        try edit(id) { batch in
            if let index = batch.items.firstIndex(where: { $0.id == itemID }) { change(&batch.items[index]) }
        }
    }

    private func launch(_ id: UUID, store: SlotStoreObservable,
                        model: CrateModelCatalog.ModelInfo?, recoveryOnly: Bool, recoveryItemID: UUID? = nil) {
        runningID = id; isRecovering = recoveryOnly; error = nil; activeCount = 0; peakActiveCount = 0
        task = Task { @MainActor in
            defer { runningID = nil; isRecovering = false; task = nil; activeCount = 0 }
            guard let initial = batch(id) else { return }
            do {
                try await CrateGenerationService.shared.preflight()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var scheduled = Set<UUID>(), inFlight = 0
                    func enqueue(_ item: BatchGeneration.Item) {
                        scheduled.insert(item.runID); inFlight += 1
                        group.addTask { @MainActor in
                            guard !Task.isCancelled, self.batch(id)?.stopRequested != true else { return }
                            self.activeCount += 1
                            self.peakActiveCount = max(self.peakActiveCount, self.activeCount)
                            defer { self.activeCount -= 1 }
                            try await self.execute(item, batchID: id, projectID: initial.projectID,
                                                   store: store, model: model, recoveryOnly: recoveryOnly)
                        }
                    }
                    @MainActor func fillWindow() {
                        guard !Task.isCancelled, let latest = batch(id), !latest.stopRequested else { return }
                        let eligible = latest.items.filter {
                            !scheduled.contains($0.runID) && (recoveryOnly
                                ? $0.canRecover && (recoveryItemID == nil || $0.id == recoveryItemID)
                                : $0.status == .pending)
                        }
                        for item in eligible.prefix(max(0, latest.effectiveConcurrency - inFlight)) { enqueue(item) }
                    }
                    fillWindow()
                    while try await group.next() != nil {
                        inFlight -= 1
                        if Task.isCancelled || batch(id)?.stopRequested == true { group.cancelAll(); continue }
                        fillWindow()
                    }
                }
            } catch {
                self.error = message(error)
            }
            do {
                try edit(id) { batch in
                    for i in batch.items.indices where batch.items[i].status == .pending {
                        batch.items[i].status = .stopped
                        batch.items[i].detail = "尚未提交"
                    }
                }
            } catch { self.error = "批次状态保存失败。已记录的任务可在重新打开后核对。" }
        }
    }

    private func execute(_ initial: BatchGeneration.Item, batchID: UUID, projectID: String,
                         store: SlotStoreObservable, model: CrateModelCatalog.ModelInfo?,
                         recoveryOnly: Bool) async throws {
        var item = initial
        let service = CrateGenerationService.shared
        do {
            if !recoveryOnly {
                let library = store.specialStorage, source = item.source
                let current = try await Task.detached(priority: .userInitiated) {
                    try library.batchSourceIsCurrent(source)
                }.value
                guard current, store.batchVisibleSourceIsCurrent(source) else {
                    try editItem(batchID, item.id) { $0.status = .skipped; $0.detail = "来源已修改、移动或删除，请重新选择" }
                    return
                }
                try Task.checkCancellation()
                guard batch(batchID)?.stopRequested != true else { throw CancellationError() }
                let fact = source.facts(node: item.node)
                let plan = CanvasWorkflowResolver.resolve(fact, all: [item.node.id: fact], edges: [], model: model)
                guard plan.blockingReasons.isEmpty else {
                    try editItem(batchID, item.id) { $0.status = .skipped; $0.detail = plan.blockingReasons.joined(separator: "；") }
                    return
                }
                let snapshot = CanvasWorkflowSnapshot(projectID: projectID, facts: [fact], edges: [],
                                                      selectionIDs: [item.node.id], models: model.map { [$0] } ?? [])
                var recording = GenerationRunContext(snapshot: snapshot, node: item.node,
                    resourceIDs: Dictionary(source.references.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a }))
                recording.runID = item.runID
                recording.resourceFileVersions = Dictionary(source.references.map { ($0.path, $0.version) },
                                                             uniquingKeysWith: { a, _ in a })
                try editItem(batchID, item.id) { $0.status = .submitting; $0.detail = nil }
                if let request = plan.videoRequest {
                    let submission = try await service.submit(request, recording: recording)
                    item.taskID = submission.result.taskId
                    item.detail = submission.droppedParameters.isEmpty ? nil : "使用模型默认值：\(submission.droppedParameters.joined(separator: "、"))"
                } else if let request = plan.imageRequest {
                    let submission = try await service.submit(request, recording: recording)
                    item.taskID = submission.result.taskId
                    item.detail = submission.droppedRatio ? "模型未接受所选比例，使用默认比例" : nil
                }
                // Persist returned identity even when Stop was clicked during submit.
                try editItem(batchID, item.id) { $0.taskID = item.taskID; $0.status = .tracking; $0.detail = item.detail }
            }
            guard let taskID = item.taskID else { return }
            try Task.checkCancellation()
            try editItem(batchID, item.id) { $0.status = .tracking }
            let file: URL
            if let path = item.localFile, FileManager.default.fileExists(atPath: path) {
                file = URL(fileURLWithPath: path)
            } else {
                let urls = try await service.waitForCompletion(taskId: taskID,
                    timeout: item.node.kind == .video ? CrateGeneration.videoPollTimeout : CrateGeneration.pollTimeout,
                    recordingProject: projectID) { [weak self] progress in
                        Task { @MainActor in self?.progress(progress, batchID: batchID, itemID: initial.id, runID: initial.runID) }
                    }
                try Task.checkCancellation()
                guard let first = urls.first else {
                    throw CrateGenerationService.ServiceError.taskFailed(reason: "任务完成但没有产物")
                }
                let downloaded = try await service.download(urlString: first, taskId: taskID, index: 0,
                    fallbackExtension: item.node.kind == .video ? "mp4" : "jpg")
                defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                let disk = storage
                file = try await Task.detached(priority: .utility) {
                    try disk.keepOutput(downloaded, batchID: batchID, itemID: initial.id)
                }.value
                try editItem(batchID, item.id) { $0.localFile = file.path; $0.status = .retained }
            }
            try Task.checkCancellation()
            try editItem(batchID, item.id) { $0.status = .succeeded; $0.detail = item.detail }
            try GenerationRunStore.shared.updateTask(project: projectID, taskID: taskID, outcome: "succeeded")
        } catch {
            let run = GenerationRunStore.shared.load(project: projectID, id: item.runID)
            let known = item.taskID ?? run?.attempts.reversed().compactMap(\.taskID).first
            let rejectedBeforeSubmission: Bool
            switch error {
            case CrateGenerationService.ServiceError.request, CrateGenerationService.ServiceError.inputChanged:
                rejectedBeforeSubmission = true
            default: rejectedBeforeSubmission = false
            }
            try editItem(batchID, item.id) {
                $0.taskID = known
                if case CrateGenerationService.ServiceError.taskFailed = error {
                    $0.remoteFailureConfirmed = true
                }
                if $0.localFile != nil { $0.status = .retained }
                else if known != nil { $0.status = error is CancellationError ? .stopped : .failed }
                else if error is CancellationError, run?.requiresSubmissionReconciliation != true { $0.status = .stopped }
                else if run?.attempts.last?.status == .rejected { $0.status = .failed }
                else if rejectedBeforeSubmission, run?.requiresSubmissionReconciliation != true { $0.status = .failed }
                else if run?.requiresSubmissionReconciliation == true || $0.status == .submitting {
                    $0.status = .unknown
                } else { $0.status = error is CancellationError ? .stopped : .failed }
                $0.detail = $0.status == .unknown ? "提交结果未知，请在 Crate 核对；不会自动重提" : message(error)
            }
            if known == nil && run?.requiresSubmissionReconciliation == true {
                try edit(batchID) { $0.stopRequested = true }
            }
            if CrateGenerationService.isRateLimit(error) {
                try edit(batchID) { $0.stopRequested = true }
                self.error = "服务端持续限流，已暂停后续提交。可降低并发后新建批次；已提交任务可取回。"
            }
            // Global authentication/storage failures must not trigger a string of submissions.
            if case CrateGenerationService.ServiceError.notAuthenticated = error { throw error }
        }
    }

    private func progress(_ value: CrateTaskProgress, batchID: UUID, itemID: UUID, runID: UUID) {
        guard runningID == batchID, let item = batch(batchID)?.items.first(where: { $0.id == itemID }),
              item.runID == runID, item.status == .tracking else { return }
        let detail: String
        switch value {
        case .queued(let ahead): detail = ahead > 0 ? "排队中，前方 \(ahead) 个任务" : "排队中"
        case .running: detail = "正在生成"
        case .succeeded, .failed: return
        }
        guard item.detail != detail else { return }
        do { try editItem(batchID, itemID) { $0.detail = detail } }
        catch { self.error = "进度未能保存"; task?.cancel() }
    }

    private func message(_ error: Error) -> String {
        if error is CancellationError { return "已停止本地跟踪；已提交任务仍可继续查询" }
        if let error = error as? CrateGenerationService.ServiceError { return error.userMessage }
        if case AgentCanvasError.conflict = error { return "槽位正文或素材已变化" }
        return error.localizedDescription
    }
}
