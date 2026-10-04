import SwiftUI
import ClipSlotsKit

@MainActor
final class CodexTaskExecution: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var threadID: String?
    @Published private(set) var running = false
    private var completed = ""

    func perform(_ task: CodexAutomation, review: JSONValue? = nil,
                 configuration: CodexServerConfiguration? = nil,
                 onThread: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        running = true
        output = ""; completed = ""; threadID = nil
        defer { running = false }
        try task.validate()
        var runtime = configuration ?? AgentBackendCoordinator.codexConfiguration()
        runtime.workingDirectory = task.cwd
        runtime.modelProvider = task.provider
        runtime.sandbox = "read-only"
        runtime.interactiveRequests = false
        runtime.bridgeExecutable = nil
        runtime.bridgeSkillSlugs = []
        let service = CodexAgentService(configuration: runtime, reviewTarget: review)
        var config = AgentConfig(model: task.model)
        config.reasoningEffort = task.effort
        _ = try await service.run(history: [AgentMessage(role: .user, content: task.prompt)],
                                  config: config, tools: nil) { [weak self] event in
            await self?.consume(event, onThread: onThread)
        }
    }

    private func consume(_ event: AgentRunEvent, onThread: @MainActor (String) -> Void) {
        switch event {
        case .sessionStarted(let id): threadID = id; onThread(id)
        case .contentDelta(let text): output = String((output + text).suffix(100_000))
        case .assistantCompleted(let message):
            if !message.content.isEmpty {
                completed = String((completed + message.content + "\n\n").suffix(100_000))
                output = completed
            }
        case .note(let text): completed += text + "\n"; output = completed
        default: break
        }
    }
}

@MainActor
final class CodexAutomationModel: ObservableObject {
    static let shared = CodexAutomationModel()
    @Published private(set) var tasks: [CodexAutomation] = []
    @Published private(set) var runs: [CodexAutomationRun] = []
    @Published var error: String?
    @Published private(set) var activeID: UUID?
    let execution = CodexTaskExecution()
    private var store: CodexAutomationStore?
    private let configuration: CodexServerConfiguration?
    private var timer: Timer?
    private var worker: Task<Void, Never>?

    init(store: CodexAutomationStore? = nil, configuration: CodexServerConfiguration? = nil) {
        self.store = store
        self.configuration = configuration
        reload()
    }

    func start() {
        guard store == nil, ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] != "1" else { return }
        do {
            store = try CodexAutomationStore(url: ClipSlotsPaths.dataRoot.appendingPathComponent("automations/tasks.json"))
            reload()
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            tick()
        } catch { self.error = "任务存储读取失败，调度未启动：\(error.localizedDescription)" }
    }

    private func reload() {
        tasks = store?.state.tasks ?? []
        runs = store?.state.runs ?? []
    }
    @discardableResult
    func save(_ task: CodexAutomation) -> Bool {
        do {
            guard let store else { throw CodexServerError("任务存储尚未就绪。") }
            try store.save(task); reload(); error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func delete(_ id: UUID) {
        do { try store?.remove(id); reload() } catch { self.error = error.localizedDescription }
    }
    func toggle(_ task: CodexAutomation) {
        var value = task
        value.enabled.toggle()
        if value.enabled && value.nextRun < Date() {
            if value.frequency == .once { value.nextRun = Date().addingTimeInterval(60) }
            else { value.advance(after: Date()) }
        }
        save(value)
    }
    func tick(now: Date = Date()) {
        guard worker == nil, let task = tasks.filter({ $0.enabled && $0.nextRun <= now })
            .sorted(by: { $0.nextRun < $1.nextRun }).first else { return }
        run(task, scheduled: true, now: now)
    }
    func run(_ task: CodexAutomation, scheduled: Bool = false, now: Date = Date()) {
        guard worker == nil, let store else { return }
        do {
            guard let record = try store.claim(task.id, now: now, scheduled: scheduled) else { return }
            reload(); activeID = task.id; error = nil
            worker = Task {
                defer { worker = nil; activeID = nil; reload() }
                do {
                    try await execution.perform(task, configuration: configuration) { [weak self] id in
                        do { try store.updateRun(record.id, threadID: id); self?.reload() }
                        catch { self?.error = error.localizedDescription }
                    }
                    try store.updateRun(record.id, status: .completed, output: execution.output)
                } catch {
                    let status: CodexAutomationRun.Status = error is CancellationError ? .interrupted : .failed
                    do {
                        try store.updateRun(record.id, status: status,
                            output: execution.output + "\n" + (error is CancellationError ? "任务已停止。" : error.localizedDescription))
                    } catch { self.error = "保存执行结果失败：\(error.localizedDescription)" }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop() { worker?.cancel() }
}

@MainActor
final class CodexReviewModel: ObservableObject {
    static let shared = CodexReviewModel()
    let execution = CodexTaskExecution()
    @Published var error: String?
    @Published private(set) var busy = false
    private var worker: Task<Void, Never>?
    func start(_ task: CodexAutomation, target: JSONValue) {
        guard !busy else { return }
        busy = true; error = nil
        worker = Task {
            defer { busy = false; worker = nil }
            do { try await execution.perform(task, review: target) }
            catch { self.error = error is CancellationError ? "审查已停止。" : error.localizedDescription }
        }
    }
    func stop() { worker?.cancel() }
}
