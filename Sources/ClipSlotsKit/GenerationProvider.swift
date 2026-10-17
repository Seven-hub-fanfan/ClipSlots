import Foundation

public enum GenerationProviderID: String, Codable, CaseIterable, Sendable {
    case crate, byteartist
}

/// Part of the task identity, never inferred from a later UI selection.
public struct GenerationProviderContext: Codable, Equatable, Sendable {
    public let provider: GenerationProviderID
    public let endpoint: URL
    public let controlPlane: String
    public let accountAlias: String

    public init(provider: GenerationProviderID, endpoint: URL,
                controlPlane: String, accountAlias: String = "default") throws {
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              !controlPlane.isEmpty, !accountAlias.isEmpty,
              !accountAlias.hasPrefix("-"), !controlPlane.hasPrefix("-"),
              !accountAlias.contains("\0"), !controlPlane.contains("\0") else {
            throw GenerationAdapterError.invalidConfiguration("生成来源的地址、区域或账号不合法。")
        }
        self.provider = provider
        self.endpoint = endpoint
        self.controlPlane = controlPlane
        self.accountAlias = accountAlias
    }

    public static var crate: Self {
        // These literal values satisfy the validated initializer.
        Self(uncheckedProvider: .crate, endpoint: URL(string: "https://crate.tiktok-row.net/api")!,
             controlPlane: "i18n-tt", accountAlias: "default")
    }
    public static var byteartist: Self {
        Self(uncheckedProvider: .byteartist, endpoint: URL(string: "https://byteartist-api.bytedance.net")!,
             controlPlane: "cn", accountAlias: "default")
    }
    private init(uncheckedProvider: GenerationProviderID, endpoint: URL, controlPlane: String, accountAlias: String) {
        self.provider = uncheckedProvider; self.endpoint = endpoint
        self.controlPlane = controlPlane; self.accountAlias = accountAlias
    }

    enum CodingKeys: String, CodingKey { case provider, endpoint, controlPlane, accountAlias }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: c.decode(GenerationProviderID.self, forKey: .provider),
                      endpoint: c.decode(URL.self, forKey: .endpoint),
                      controlPlane: c.decode(String.self, forKey: .controlPlane),
                      accountAlias: c.decode(String.self, forKey: .accountAlias))
    }
}

public enum GenerationArtifactKind: String, Codable, Sendable {
    case image, video, audio, text, data
}

public enum GenerationJSONPathComponent: Codable, Equatable, Sendable {
    case key(String), index(Int), each
}

/// Explicit mappings supplied by the host after verifying a workflow output contract.
/// No arbitrary object walk or filename heuristic guesses where a media URL lives.
public struct GenerationOutputBinding: Codable, Equatable, Sendable {
    public let name: String
    public let kind: GenerationArtifactKind
    public let path: [GenerationJSONPathComponent]
    public init(name: String, kind: GenerationArtifactKind, path: [GenerationJSONPathComponent]) {
        self.name = name; self.kind = kind; self.path = path
    }
}

public struct GenerationCapability: Equatable, Sendable {
    public let context: GenerationProviderContext
    public let id: String
    public let title: String
    public let revision: String
    public let kind: GenerationArtifactKind
    public let inputSchema: JSONValue
    public let outputBindings: [GenerationOutputBinding]
    /// Provider-specific source metadata; never contains credentials.
    public let metadata: JSONValue
    public let referencePath: String?

    public init(context: GenerationProviderContext, id: String, title: String,
                revision: String, kind: GenerationArtifactKind, inputSchema: JSONValue,
                outputBindings: [GenerationOutputBinding] = [], metadata: JSONValue = .object([:]),
                referencePath: String? = nil) {
        self.context = context; self.id = id; self.title = title; self.revision = revision
        self.kind = kind; self.inputSchema = inputSchema; self.outputBindings = outputBindings
        self.metadata = metadata; self.referencePath = referencePath
    }
}

public struct GenerationInput: Equatable, Sendable {
    public let values: [String: JSONValue]
    /// Output count within one provider task, not the canvas batch item count.
    public let outputCount: Int
    public init(values: [String: JSONValue], outputCount: Int = 1) {
        self.values = values; self.outputCount = outputCount
    }
}

public struct GenerationInputFile: Equatable, Sendable {
    public let path: String
    public let version: String
    public init(path: String, version: String) { self.path = path; self.version = version }
    public var isCurrent: Bool { version != "missing" && GenerationRunContext.fileVersion(path) == version }
}

/// Constructed by a provider only after validation. No public raw-argv initializer.
public struct PreparedGenerationRequest: Sendable {
    public let capability: GenerationCapability
    public let input: GenerationInput
    public let inputFiles: [GenerationInputFile]
    let arguments: [String]
    let referenceVersion: String?
    init(capability: GenerationCapability, input: GenerationInput, inputFiles: [GenerationInputFile],
         arguments: [String], referenceVersion: String? = nil) {
        self.capability = capability; self.input = input; self.inputFiles = inputFiles
        self.arguments = arguments; self.referenceVersion = referenceVersion
    }
}

public struct GenerationTaskHandle: Codable, Equatable, Sendable {
    public let context: GenerationProviderContext
    public let taskID: String
    public let capabilityID: String
    public let capabilityRevision: String
    public let kind: GenerationArtifactKind
    public let outputBindings: [GenerationOutputBinding]
    public let cliVersion: String?
    public let seed: Int?

    public init(context: GenerationProviderContext, taskID: String, capabilityID: String,
                capabilityRevision: String = "", kind: GenerationArtifactKind,
                outputBindings: [GenerationOutputBinding] = [], cliVersion: String? = nil,
                seed: Int? = nil) throws {
        try GenerationWire.validateIdentifier(taskID)
        self.context = context; self.taskID = taskID; self.capabilityID = capabilityID
        self.capabilityRevision = capabilityRevision; self.kind = kind
        self.outputBindings = outputBindings; self.cliVersion = cliVersion; self.seed = seed
    }

    enum CodingKeys: String, CodingKey {
        case context, taskID, taskId, capabilityID, capabilityRevision, kind, outputBindings, cliVersion, seed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .taskID) ?? c.decode(String.self, forKey: .taskId)
        try self.init(context: c.decodeIfPresent(GenerationProviderContext.self, forKey: .context) ?? .crate,
            taskID: id, capabilityID: c.decodeIfPresent(String.self, forKey: .capabilityID) ?? "",
            capabilityRevision: c.decodeIfPresent(String.self, forKey: .capabilityRevision) ?? "",
            kind: c.decodeIfPresent(GenerationArtifactKind.self, forKey: .kind) ?? .image,
            outputBindings: c.decodeIfPresent([GenerationOutputBinding].self, forKey: .outputBindings) ?? [],
            cliVersion: c.decodeIfPresent(String.self, forKey: .cliVersion),
            seed: c.decodeIfPresent(Int.self, forKey: .seed))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(context, forKey: .context); try c.encode(taskID, forKey: .taskID)
        try c.encode(capabilityID, forKey: .capabilityID); try c.encode(capabilityRevision, forKey: .capabilityRevision)
        try c.encode(kind, forKey: .kind); try c.encode(outputBindings, forKey: .outputBindings)
        try c.encodeIfPresent(cliVersion, forKey: .cliVersion); try c.encodeIfPresent(seed, forKey: .seed)
    }
}

public enum GenerationStatus: Equatable, Sendable {
    case queued(ahead: Int?), running, succeeded, failed, outputMismatch, unknown(String)
}

public struct GenerationArtifact: Equatable, Sendable {
    public let name: String
    public let kind: GenerationArtifactKind
    public let value: JSONValue
    public var remoteURL: URL? {
        guard [.image, .video, .audio].contains(kind), let string = value.stringValue else { return nil }
        return GenerationWire.mediaURL(string)
    }
}

public struct GenerationObservation: Equatable, Sendable {
    public let task: GenerationTaskHandle
    public let status: GenerationStatus
    public let rawStatus: String
    public let artifacts: [GenerationArtifact]
    public let rawOutput: JSONValue?
    public let detail: String?
    public let diagnostic: GenerationTaskDiagnostic?
    public init(task: GenerationTaskHandle, status: GenerationStatus, rawStatus: String,
                artifacts: [GenerationArtifact] = [], rawOutput: JSONValue? = nil, detail: String? = nil,
                diagnostic: GenerationTaskDiagnostic? = nil) {
        self.task = task; self.status = status; self.rawStatus = rawStatus
        self.artifacts = artifacts; self.rawOutput = rawOutput; self.detail = detail
        self.diagnostic = diagnostic
    }
}

public struct GenerationSubmission: Equatable, Sendable {
    public let task: GenerationTaskHandle
    public let needsQuery: Bool
    public let detail: String?
    public init(task: GenerationTaskHandle, needsQuery: Bool = false, detail: String? = nil) {
        self.task = task; self.needsQuery = needsQuery; self.detail = detail
    }
}

public enum GenerationAdapterError: LocalizedError, Equatable {
    case invalidConfiguration(String), invalidInput(String), unsupportedSchema(String)
    case providerMismatch, capabilityChanged, inputChanged, authenticationRequired
    case commandFailed(code: String, phase: String?)
    case invalidResponse, processNotStarted, timeout
    /// No confirmed ID: never automatically retry or fail over to another provider.
    case submissionUnknown(GenerationProviderID)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let s), .invalidInput(let s), .unsupportedSchema(let s): return s
        case .providerMismatch: return "生成请求与所选后端、区域或账号不匹配。"
        case .capabilityChanged: return "能力说明已变化，请重新准备生成参数。"
        case .inputChanged: return "参考素材已变化或无法读取，请重新准备生成参数。"
        case .authenticationRequired: return "生成来源尚未登录或无有效授权。"
        case .commandFailed(let code, let phase): return "生成工具返回错误 \(code)\(phase.map { "（\($0)）" } ?? "")。"
        case .invalidResponse: return "生成工具返回的数据不符合当前接口契约。"
        case .processNotStarted: return "生成工具未能启动，任务尚未提交。"
        case .timeout: return "本地查询超时，已提交任务仍可继续取回。"
        case .submissionUnknown(let p): return "\(p.rawValue) 提交结果未知，请核对原平台任务；不会自动重提。"
        }
    }
}

public protocol GenerationProvider: Sendable {
    var context: GenerationProviderContext { get }
    func preflight() async throws
    func discover() async throws -> [GenerationCapability]
    func prepare(_ input: GenerationInput, capability: GenerationCapability) async throws -> PreparedGenerationRequest
    func submit(_ request: PreparedGenerationRequest) async throws -> GenerationSubmission
    func query(_ task: GenerationTaskHandle) async throws -> GenerationObservation
}

/// A selected provider is never used as a fallback for an existing task.
public struct GenerationProviderRegistry: Sendable {
    private let providers: [any GenerationProvider]
    public init(_ providers: [any GenerationProvider]) throws {
        for (i, provider) in providers.enumerated() where providers.prefix(i).contains(where: { $0.context == provider.context }) {
            throw GenerationAdapterError.invalidConfiguration("同一生成来源上下文重复注册。")
        }
        self.providers = providers
    }
    public func provider(for context: GenerationProviderContext) throws -> any GenerationProvider {
        guard let provider = providers.first(where: { $0.context == context }) else {
            throw GenerationAdapterError.providerMismatch
        }
        return provider
    }
    public func query(_ task: GenerationTaskHandle) async throws -> GenerationObservation {
        try await provider(for: task.context).query(task)
    }
}
