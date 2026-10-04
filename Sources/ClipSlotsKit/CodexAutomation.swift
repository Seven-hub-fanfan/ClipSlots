import Foundation

/// ClipSlots-owned schedules. Never edits the desktop app's private automation database.
public struct CodexAutomation: Codable, Identifiable, Equatable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case once, daily, weekly
        public var title: String {
            switch self { case .once: return "仅一次"; case .daily: return "每天"; case .weekly: return "每周" }
        }
    }
    public var id = UUID()
    public var name = ""
    public var prompt = ""
    public var cwd = ""
    public var model = ""
    public var provider: String?
    public var effort: String?
    public var frequency: Frequency = .daily
    public var nextRun = Date().addingTimeInterval(3600)
    public var timeZoneID = TimeZone.current.identifier
    public var enabled = true
    public init() {}

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexServerError("请填写任务名称和指令。")
        }
        var directory: ObjCBool = false
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &directory),
              directory.boolValue else { throw CodexServerError("请选择存在的项目文件夹。") }
        guard nextRun.timeIntervalSince1970.isFinite, TimeZone(identifier: timeZoneID) != nil else {
            throw CodexServerError("任务时间或时区无效。")
        }
    }

    public mutating func advance(after now: Date) {
        guard frequency != .once else { enabled = false; return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        var parts = calendar.dateComponents([.hour, .minute, .second], from: nextRun)
        if frequency == .weekly { parts.weekday = calendar.component(.weekday, from: nextRun) }
        nextRun = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime,
                                    repeatedTimePolicy: .first) ?? now.addingTimeInterval(86400)
    }
}

public struct CodexAutomationRun: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, completed, failed, interrupted
        public var title: String {
            switch self {
            case .running: return "执行中"; case .completed: return "已完成"
            case .failed: return "失败"; case .interrupted: return "已中断"
            }
        }
    }
    public var id = UUID()
    public var automationID: UUID
    public var name: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status = .running
    public var threadID: String?
    public var output = ""
}

/// Main-actor ownership plus atomic persistence: a run is claimed on disk before inference.
@MainActor
public final class CodexAutomationStore {
    public struct State: Codable, Equatable {
        public var tasks: [CodexAutomation] = []
        public var runs: [CodexAutomationRun] = []
    }
    public private(set) var state = State()
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        }
        var recovered = state
        for index in recovered.runs.indices where recovered.runs[index].status == .running {
            recovered.runs[index].status = .interrupted
            recovered.runs[index].finishedAt = Date()
            recovered.runs[index].output += "\n应用在执行期间退出；请核对结果后手动重试。"
        }
        if recovered != state { try commit(recovered) }
    }
    private func commit(_ next: State) throws {
        let bytes = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        state = next
    }
    public func save(_ task: CodexAutomation) throws {
        try task.validate()
        var next = state
        if let i = next.tasks.firstIndex(where: { $0.id == task.id }) { next.tasks[i] = task }
        else { next.tasks.append(task) }
        try commit(next)
    }
    public func remove(_ id: UUID) throws {
        guard !state.runs.contains(where: { $0.automationID == id && $0.status == .running }) else {
            throw CodexServerError("请先停止执行，再删除任务。")
        }
        var next = state
        next.tasks.removeAll { $0.id == id }
        try commit(next)
    }
    public func claim(_ id: UUID, now: Date, scheduled: Bool) throws -> CodexAutomationRun? {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }),
              !state.runs.contains(where: { $0.status == .running }),
              !scheduled || (state.tasks[index].enabled && state.tasks[index].nextRun <= now) else { return nil }
        var next = state
        let run = CodexAutomationRun(automationID: id, name: next.tasks[index].name, startedAt: now)
        if scheduled { next.tasks[index].advance(after: now) }
        next.runs.insert(run, at: 0)
        next.runs = Array(next.runs.prefix(200))
        try commit(next)
        return run
    }
    public func updateRun(_ id: UUID, threadID: String? = nil, status: CodexAutomationRun.Status? = nil,
                          output: String? = nil) throws {
        guard let index = state.runs.firstIndex(where: { $0.id == id }) else { return }
        var next = state
        if let threadID { next.runs[index].threadID = threadID }
        if let status {
            next.runs[index].status = status
            if status != .running { next.runs[index].finishedAt = Date() }
        }
        if let output { next.runs[index].output = String(output.prefix(100_000)) }
        try commit(next)
    }
}
