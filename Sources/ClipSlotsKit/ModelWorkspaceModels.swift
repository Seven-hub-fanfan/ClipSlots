import Foundation

public enum ModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case llm, image, video, audio
    public var id: String { rawValue }
    public var title: String {
        switch self { case .llm: return "LLM"; case .image: return "图像"; case .video: return "视频"; case .audio: return "音频" }
    }
}

public enum ModelDimension: String, Codable, CaseIterable, Identifiable, Sendable {
    case response, beauty, reference, consistency, motion, audio
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .response: return "响应效果"; case .beauty: return "画面美感"
        case .reference: return "参考效果"; case .consistency: return "保持效果"
        case .motion: return "运动效果"; case .audio: return "音频效果"
        }
    }
}

public enum ModelPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case agent, questions, canvasImage, canvasVideo, canvasAudio
    public var id: String { rawValue }
    public var title: String {
        switch self { case .agent: return "Agent LLM"; case .questions: return "出题 LLM"
        case .canvasImage: return "画布图像"; case .canvasVideo: return "画布视频"; case .canvasAudio: return "画布音频" }
    }
    public var kind: ModelKind {
        switch self { case .agent, .questions: return .llm; case .canvasImage: return .image
        case .canvasVideo: return .video; case .canvasAudio: return .audio }
    }
}

/// Paths are explicit dotted keys (array indices are numeric); no heuristic output walk.
public struct ModelAsyncContract: Codable, Equatable, Sendable {
    public var queryURL = ""
    public var taskIDPath = "id"
    public var statusPath = "status"
    public var outputPath = "output.url"
    public var successValues = ["succeeded", "completed"]
    public var failureValues = ["failed", "cancelled"]
    public init() {}
}

public enum ModelAPIContract: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions, imageGenerations, asyncMedia
    public var id: String { rawValue }
    public var title: String {
        switch self { case .chatCompletions: return "Chat Completions"; case .imageGenerations: return "Images Generations"
        case .asyncMedia: return "异步媒体任务" }
    }
}

public struct ModelProfile: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var revision = UUID().uuidString
    public var name = ""
    /// Complete request URL, not an implicitly expanded base URL.
    public var endpoint = ""
    public var model = ""
    public var kind: ModelKind = .llm
    public var contract: ModelAPIContract = .chatCompletions
    public var authHeader = "Authorization"
    public var authPrefix = "Bearer "
    public var requiresKey = true
    public var legacyKeyAccount: String?
    public var supportsImages = false
    public var supportsAudio = false
    public var enabled = true
    public var timeout: Double = 120
    public var concurrency = 2
    public var parameters: [String: JSONValue] = [:]
    public var asynchronous = ModelAsyncContract()
    /// Explicit JSON field for base64 reference inputs in custom async contracts.
    public var referenceInputField: String?
    /// CLI profiles keep a frozen context and capability identity.
    public var cliContext: GenerationProviderContext?
    public var cliCapabilityID: String?
    public var cliInputSchema: JSONValue?
    public var cliOutputBindings: [GenerationOutputBinding] = []
    public var cliPromptKey = "prompt"
    public init() {}
    public var keyAccount: String { legacyKeyAccount ?? id }
    public var isCLI: Bool { cliContext != nil }
    public var keyService: String { legacyKeyAccount == nil ? "com.clipslots.models" : AgentKeychain.service }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...14).contains(concurrency), (5...1800).contains(timeout) else {
            throw ModelWorkspaceError.invalid("请填写名称、模型标识，并检查超时和并发。")
        }
        func containsCredential(_ value: JSONValue) -> Bool {
            if let object = value.objectValue {
                return object.contains { key, value in
                    ["api_key", "apikey", "authorization", "access_token", "token", "secret", "password"].contains(key.lowercased())
                        || containsCredential(value)
                }
            }
            return value.arrayValue?.contains(where: containsCredential) ?? false
        }
        guard !containsCredential(.object(parameters)) else {
            throw ModelWorkspaceError.invalid("认证信息只能保存到钥匙串，不能写入默认参数。")
        }
        if isCLI {
            guard cliCapabilityID != nil, cliInputSchema != nil else { throw ModelWorkspaceError.invalid("请先发现 CLI 能力。") }
            return
        }
        try Self.validateURL(endpoint)
        guard !authHeader.isEmpty, !authHeader.contains("\r"), !authHeader.contains("\n"),
              !authPrefix.contains("\r"), !authPrefix.contains("\n") else { throw ModelWorkspaceError.invalid("认证字段不合法。") }
        guard contract == .asyncMedia || (contract == .chatCompletions && kind == .llm)
                || (contract == .imageGenerations && kind == .image) else {
            throw ModelWorkspaceError.invalid("接口契约与输出类型不匹配。")
        }
        if contract == .asyncMedia {
            guard asynchronous.queryURL.contains("{id}"), !asynchronous.taskIDPath.isEmpty,
                  !asynchronous.statusPath.isEmpty, !asynchronous.outputPath.isEmpty,
                  !asynchronous.successValues.isEmpty, !asynchronous.failureValues.isEmpty else {
                throw ModelWorkspaceError.invalid("请配置异步查询地址及返回字段路径。")
            }
            try Self.validateURL(asynchronous.queryURL.replacingOccurrences(of: "{id}", with: "test"))
        }
        if let field = referenceInputField {
            guard contract == .asyncMedia, !field.isEmpty,
                  !["model", "prompt", "api_key", "authorization", "token", "secret"].contains(field.lowercased()) else {
                throw ModelWorkspaceError.invalid("参考输入字段仅适用于异步契约，且不能覆盖模型、题干或认证字段。")
            }
        }
    }
    public static func validateURL(_ text: String) throws {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
            throw ModelWorkspaceError.invalid("需要完整的 HTTP(S) 接口地址；认证请使用密钥字段。")
        }
    }
}

public struct ModelReference: Codable, Equatable, Sendable {
    public var path: String
    public var version: String
    public var name: String?
    public init(path: String, name: String? = nil) { self.path = path; self.name = name; version = GenerationRunContext.fileVersion(path) }
    public var isCurrent: Bool { version != "missing" && version == GenerationRunContext.fileVersion(path) }
}

public struct ModelQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title = ""
    public var prompt = ""
    public var criteria = ""
    public var kind: ModelKind = .llm
    public var tags = ""
    public var dimensions: [ModelDimension] = [.response]
    public var references: [ModelReference] = []
    public var groupID: String?
    public var slot: Int?
    public var syncedPrompt: String?
    public var slotRevision: String?
    public var conflict = false
    public init() {}
    public var applicableDimensions: [ModelDimension] {
        dimensions.filter {
            switch $0 {
            case .response: return true
            case .beauty: return kind == .image || kind == .video
            case .reference: return !references.isEmpty
            case .consistency: return true
            case .motion: return kind == .video
            case .audio: return kind == .audio || kind == .video
            }
        }
    }
}

public struct ModelQuestionBank: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name = ""
    public var revision = UUID().uuidString
    public var groupIDs: [String] = []
    public var questions: [ModelQuestion] = []
    public var weights: [String: Double] = [:]
    public var updatedAt = Date()
    public init() {}
}

public enum ModelCellState: String, Codable, Sendable {
    case queued, running, polling, succeeded, failed, cancelled, unknown
    public var title: String {
        switch self { case .queued: return "排队"; case .running: return "运行中"; case .polling: return "等待远端"
        case .succeeded: return "成功"; case .failed: return "失败"; case .cancelled: return "取消"; case .unknown: return "提交未知" }
    }
    public var active: Bool { self == .queued || self == .running || self == .polling }
}

public struct ModelEvaluationCell: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var questionID: String
    public var modelID: String
    public var state: ModelCellState = .queued
    public var text = ""
    public var mediaURLs: [String] = []
    public var localMediaPaths: [String] = []
    public var taskID: String?
    public var cliTask: GenerationTaskHandle?
    public var detail = ""
    public var startedAt: Date?
    public var completedAt: Date?
    public var scores: [String: Double] = [:]
    public var scoreSource = "人工"
    public var scoredAt: Date?
    public var attempt = 0
    public var terminalRemoteFailure = false
    public init(questionID: String, modelID: String) { self.questionID = questionID; self.modelID = modelID }
}

public struct ModelEvaluationRun: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var bank: ModelQuestionBank
    public var models: [ModelProfile]
    public var cells: [ModelEvaluationCell]
    public var createdAt = Date()
    public var cancelled = false
    public init(bank: ModelQuestionBank, models: [ModelProfile]) throws {
        guard (1...14).contains(models.count), Set(models.map(\.id)).count == models.count else {
            throw ModelWorkspaceError.invalid("一次请选择 1–14 个不同模型。")
        }
        guard !bank.questions.isEmpty else { throw ModelWorkspaceError.invalid("题库没有有效题目。") }
        for profile in models { try profile.validate() }
        guard bank.questions.allSatisfy({ !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.conflict && $0.references.allSatisfy(\.isCurrent) }) else {
            throw ModelWorkspaceError.invalid("题目为空、素材缺失或存在同步冲突，请先修复题库。")
        }
        guard models.allSatisfy({ p in bank.questions.contains(where: { $0.kind == p.kind }) }) else {
            throw ModelWorkspaceError.invalid("所选模型在题库中没有同类型题目。")
        }
        title = bank.name; self.bank = bank; self.models = models
        cells = bank.questions.flatMap { q in models.filter { $0.kind == q.kind }.map { ModelEvaluationCell(questionID: q.id, modelID: $0.id) } }
    }
}

public struct ModelNewsSource: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var url: String
    public var enabled = true
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct ModelNewsItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { url }
    public var title: String
    public var url: String
    public var sourceID: String
    public var sourceName: String
    public var summary: String
    public var publishedAt: Date?
    public var fetchedAt: Date
}

public struct ModelWorkspaceDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision = UUID().uuidString
    public var profiles: [ModelProfile] = []
    public var defaults: [String: String] = [:]
    public var banks: [ModelQuestionBank] = []
    public var runs: [ModelEvaluationRun] = []
    public var newsSources: [ModelNewsSource] = [
        .init(name: "OpenAI", url: "https://openai.com/news/rss.xml"),
        .init(name: "Google AI", url: "https://blog.google/innovation-and-ai/technology/ai/rss/"),
        .init(name: "Hugging Face", url: "https://huggingface.co/blog/feed.xml")
    ]
    public var news: [ModelNewsItem] = []
    public var newsRefreshedAt: Date?
    public var newsErrors: [String: String] = [:]
    public var legacyImported = false
    public init() {}
}

public enum ModelWorkspaceError: LocalizedError {
    case invalid(String), conflict, unreadable, submissionUnknown, http(Int), response, credential, remoteFailed
    public var errorDescription: String? {
        switch self { case .invalid(let s): return s
        case .conflict: return "数据已被另一窗口修改，请重新载入后再保存。"
        case .unreadable: return "模型数据无法读取，已停止写入以保护原文件。"
        case .submissionUnknown: return "提交状态未知，请到原服务核对；不会自动重复提交。"
        case .http(let code): return "接口返回 HTTP \(code)。"
        case .response: return "返回内容不符合所配置的接口契约。"
        case .credential: return "缺少可用密钥，请在配置中心保存认证。"
        case .remoteFailed: return "远端任务已明确失败，可主动重试新的请求。"
        }
    }
}

/// Independent actor and lock: canvas gestures never wait on model/news storage.
public actor ModelWorkspaceRepository {
    public let root: URL
    private let lock: StorageLock
    public init(root: URL = ClipSlotsPaths.dataRoot.appendingPathComponent("models", isDirectory: true)) {
        self.root = root
        lock = StorageLock(lockURL: root.appendingPathComponent(".lock"))
    }
    private var file: URL { root.appendingPathComponent("workspace.json") }
    private func read() throws -> ModelWorkspaceDocument {
        guard FileManager.default.fileExists(atPath: file.path) else { return ModelWorkspaceDocument() }
        do {
            let document = try JSONDecoder().decode(ModelWorkspaceDocument.self, from: Data(contentsOf: file))
            guard document.schemaVersion == 1 else { throw ModelWorkspaceError.unreadable }
            return document
        } catch { throw ModelWorkspaceError.unreadable }
    }
    public func load() throws -> ModelWorkspaceDocument { try read() }
    public func save(_ document: ModelWorkspaceDocument, expectedRevision: String?) throws -> ModelWorkspaceDocument {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try lock.withLock(timeout: 0.5) {
            guard !lock.isDegraded else { throw ModelWorkspaceError.unreadable }
            if FileManager.default.fileExists(atPath: file.path) {
                guard try read().revision == expectedRevision else { throw ModelWorkspaceError.conflict }
            } else if expectedRevision != nil { throw ModelWorkspaceError.conflict }
            var next = document; next.revision = UUID().uuidString
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: file, options: .atomic)
            return next
        }
    }
}

public struct ModelRankingEntry: Identifiable, Sendable {
    public var id: String { model.id + dimensionKey }
    public var model: ModelProfile
    public var samples: Int
    public var scores: [String: Double]
    public var total: Double
    public var dimensionKey: String
    public var updatedAt: Date
}

public enum ModelRanking {
    /// A selected run fixes bank version, rubric, model revision and sample set.
    public static func entries(run: ModelEvaluationRun, kind: ModelKind) -> [ModelRankingEntry] {
        var output: [ModelRankingEntry] = []
        for model in run.models where model.kind == kind {
            var groups: [String: [(ModelEvaluationCell, [ModelDimension])]] = [:]
            for cell in run.cells where cell.modelID == model.id && cell.state == .succeeded && cell.scoredAt != nil {
                guard let q = run.bank.questions.first(where: { $0.id == cell.questionID }) else { continue }
                let dims = q.applicableDimensions
                guard !dims.isEmpty, dims.allSatisfy({ cell.scores[$0.rawValue].map { $0.isFinite && (0...100).contains($0) } == true }) else { continue }
                let key = dims.map(\.rawValue).sorted().joined(separator: ",") + "|" + cell.scoreSource
                groups[key, default: []].append((cell, dims))
            }
            for (key, values) in groups {
                var means: [String: Double] = [:]
                for dimension in values[0].1 {
                    means[dimension.rawValue] = values.reduce(0) { $0 + ($1.0.scores[dimension.rawValue] ?? 0) } / Double(values.count)
                }
                let weighted = means.map { (score: $0.value, weight: max(0, run.bank.weights[$0.key] ?? 1)) }
                let denominator = weighted.reduce(0) { $0 + $1.weight }
                guard denominator > 0 else { continue }
                output.append(.init(model: model, samples: values.count, scores: means,
                    total: weighted.reduce(0) { $0 + $1.score * $1.weight } / denominator,
                    dimensionKey: key + "|" + values.map { $0.0.questionID }.sorted().joined(separator: ","),
                    updatedAt: values.compactMap { $0.0.scoredAt }.max() ?? run.createdAt))
            }
        }
        return output.sorted { $0.dimensionKey == $1.dimensionKey ? $0.total > $1.total : $0.dimensionKey < $1.dimensionKey }
    }
}
