import Foundation

/// This is the request sent to the local CLI, not an assertion about undocumented server defaults.
public struct GenerationRequestRecord: Codable, Equatable {
    public var kind: String
    public var model: String
    public var prompt: String
    public var ratio: String
    public var count: Int
    public var resolution: String?
    public var width: Int?
    public var height: Int?
    public var duration: Int?
    public var generateAudio: Bool?
    public var seed: Int?
    public var firstFrame: String?
    public var lastFrame: String?
    public var references: [String]
    public var provider: GenerationProviderContext?
    public var providerInputs: [String: JSONValue]?

    public init(_ request: PreparedGenerationRequest, resourceIDs: [String: String]) {
        kind = request.capability.kind.rawValue; model = request.capability.id
        prompt = ""; ratio = ""; count = 1
        provider = request.capability.context
        let files = Set(request.inputFiles.map(\.path))
        references = request.inputFiles.map { resourceIDs[$0.path] ?? "local-file" }
        providerInputs = request.input.values.mapValues { value in
            guard let text = value.stringValue, files.contains(text) else { return value }
            return .string(resourceIDs[text] ?? "local-file")
        }
    }

    public init(_ request: CrateImageRequest, resourceIDs: [String: String]) {
        kind = "image"; model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = request.prompt
        ratio = request.ratio.trimmingCharacters(in: .whitespacesAndNewlines)
        count = request.count; seed = request.seed
        resolution = request.resolution; width = request.width; height = request.height
        references = request.imagePaths.filter { !$0.isEmpty }.map { resourceIDs[$0] ?? "unavailable" }
    }

    public init(_ request: CrateVideoRequest, resourceIDs: [String: String]) {
        kind = "video"; model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = request.prompt
        ratio = request.ratio.trimmingCharacters(in: .whitespacesAndNewlines)
        count = 1; seed = request.seed
        resolution = request.resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        duration = request.duration; generateAudio = request.generateAudio
        firstFrame = request.firstFramePath.flatMap { $0.isEmpty ? nil : (resourceIDs[$0] ?? "unavailable") }
        lastFrame = request.lastFramePath.flatMap { $0.isEmpty ? nil : (resourceIDs[$0] ?? "unavailable") }
        references = (request.referenceImagePaths + request.imagePaths).filter { !$0.isEmpty }
            .map { resourceIDs[$0] ?? "unavailable" }
    }

    public func droppedParameters(comparedTo requested: Self) -> [String] {
        var result: [String] = []
        if requested.seed != nil && seed == nil { result.append("seed") }
        if !requested.ratio.isEmpty && ratio.isEmpty { result.append("ratio") }
        if requested.resolution?.isEmpty == false && resolution?.isEmpty != false { result.append("resolution") }
        if requested.width != nil && width == nil { result.append("width") }
        if requested.height != nil && height == nil { result.append("height") }
        if requested.duration != nil && duration == nil { result.append("duration") }
        if requested.generateAudio != nil && generateAudio == nil { result.append("generate_audio") }
        return result
    }
}

public struct GenerationRunContext {
    public var runID: UUID
    public var snapshotID: UUID
    public var projectID: String
    public var nodeID: String
    public var nodeCreatedAt: Date
    public var graphRevision: String
    public var resources: [CanvasWorkflowMedia]
    public var configuredNode: CanvasNode?
    /// local path -> opaque identity; never persisted
    public var resourceIDs: [String: String]
    public var resourceFileVersions: [String: String]
    public init(snapshot: CanvasWorkflowSnapshot, node: CanvasNode, resourceIDs: [String: String]) {
        runID = UUID(); snapshotID = snapshot.snapshotID; projectID = snapshot.projectID
        nodeID = node.id; nodeCreatedAt = node.createdAt; graphRevision = snapshot.graphRevision
        configuredNode = snapshot.nodes.first { $0.id == node.id }?.configuration
        resources = snapshot.nodes.flatMap(\.media); self.resourceIDs = resourceIDs
        resourceFileVersions = resourceIDs.keys.reduce(into: [:]) { $0[$1] = Self.fileVersion($1) }
    }
    public static func fileVersion(_ path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        return "\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? "")|\(attributes[.systemFileNumber] ?? 0)"
    }
    public func inputsAreCurrent(_ request: GenerationRequestRecord) -> Bool {
        let required = Set(request.references + [request.firstFrame, request.lastFrame].compactMap { $0 })
        let files = resourceIDs.filter { required.contains($0.value) }
        return Set(files.values) == required && files.allSatisfy {
            let current = Self.fileVersion($0.key)
            return current != "missing" && resourceFileVersions[$0.key] == current
        }
    }
}

public struct GenerationRun: Codable, Equatable, Identifiable {
    public enum AttemptStatus: String, Codable { case submitting, rejected, accepted, unknown }
    public struct Attempt: Codable, Equatable, Identifiable {
        public var id: UUID
        public var startedAt: Date
        public var effectiveRequest: GenerationRequestRecord
        public var droppedParameters: [String]
        public var status: AttemptStatus
        public var taskID: String?
        public var returnedSeed: Int?
        public var detail: String?
        public var taskHandle: GenerationTaskHandle?
    }
    public var id: UUID
    public var snapshotID: UUID
    public var projectID: String
    public var nodeID: String
    public var nodeCreatedAt: Date
    public var graphRevision: String
    public var startedAt: Date
    public var requestedRequest: GenerationRequestRecord
    public var configuredNode: CanvasNode?
    public var resources: [CanvasWorkflowMedia]
    public var attempts: [Attempt]
    public var outcome: String
    public var outputAttachmentIDs: [String]
    public var diagnostic: GenerationTaskDiagnostic?
    public var requiresSubmissionReconciliation: Bool {
        attempts.contains { $0.status == .unknown || $0.status == .submitting }
    }
}

/// Separate immutable identities per run/attempt. Atomic replacement keeps every observed transition.
/// Missing history stays missing; task recovery only updates a record that already owns that task.
public final class GenerationRunStore: @unchecked Sendable {
    public static let shared = GenerationRunStore()
    private let root: URL
    private let lock = NSRecursiveLock()
    public init(root: URL = ClipSlotsPaths.dataRoot) {
        self.root = root.appendingPathComponent("generation-runs", isDirectory: true)
    }
    private func directory(_ project: String) -> URL {
        root.appendingPathComponent(CanvasWorkflowSnapshot.digest(Data(project.utf8)), isDirectory: true)
    }
    private func url(project: String, id: UUID) -> URL {
        directory(project).appendingPathComponent(id.uuidString + ".json")
    }
    private func save(_ run: GenerationRun) throws {
        try FileManager.default.createDirectory(at: directory(run.projectID), withIntermediateDirectories: true)
        try CanvasWorkflowSnapshot.jsonData(run).write(to: url(project: run.projectID, id: run.id), options: .atomic)
    }
    public func load(project: String, id: UUID) -> GenerationRun? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(project: project, id: id)),
              let run = try? JSONDecoder().decode(GenerationRun.self, from: data),
              run.projectID == project, run.id == id else { return nil }
        return run
    }
    public func runs(project: String) -> [GenerationRun] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(project),
            includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            return load(project: project, id: id)
        }.sorted { $0.startedAt > $1.startedAt }
    }
    public func latest(project: String, node: CanvasNode) -> GenerationRun? {
        runs(project: project).first { $0.nodeID == node.id && $0.nodeCreatedAt == node.createdAt }
    }

    @discardableResult
    public func beginAttempt(context: GenerationRunContext, requested: GenerationRequestRecord,
                             effective: GenerationRequestRecord) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        // Include catalog filtering that happened before the CLI boundary.
        var original = requested
        if requested.provider == nil, requested.kind == "video", let node = context.configuredNode {
            original.resolution = node.resolution
            original.duration = node.duration
            original.generateAudio = node.generateAudio
        }
        var run = load(project: context.projectID, id: context.runID) ?? GenerationRun(
            id: context.runID, snapshotID: context.snapshotID, projectID: context.projectID,
            nodeID: context.nodeID, nodeCreatedAt: context.nodeCreatedAt, graphRevision: context.graphRevision,
            startedAt: Date(), requestedRequest: original, configuredNode: context.configuredNode, resources: context.resources,
            attempts: [], outcome: "submitting", outputAttachmentIDs: [])
        let id = UUID()
        run.attempts.append(.init(id: id, startedAt: Date(), effectiveRequest: effective,
            droppedParameters: effective.droppedParameters(comparedTo: run.requestedRequest), status: .submitting))
        try save(run)
        return id
    }
    public func finishAttempt(context: GenerationRunContext, attemptID: UUID,
                              status: GenerationRun.AttemptStatus, taskID: String? = nil,
                              seed: Int? = nil, detail: String? = nil,
                              taskHandle: GenerationTaskHandle? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard var run = load(project: context.projectID, id: context.runID),
              let index = run.attempts.firstIndex(where: { $0.id == attemptID }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        run.attempts[index].status = status; run.attempts[index].taskID = taskID
        run.attempts[index].returnedSeed = seed; run.attempts[index].detail = detail
        run.attempts[index].taskHandle = taskHandle
        run.outcome = status.rawValue
        try save(run)
    }
    public func updateTask(project: String, taskID: String, outcome: String, outputIDs: [String] = [],
                           provider: GenerationProviderContext = .crate,
                           diagnostic: GenerationTaskDiagnostic? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard var run = runs(project: project).first(where: { run in
            run.attempts.contains { $0.taskID == taskID &&
                ($0.taskHandle?.context ?? $0.effectiveRequest.provider ?? .crate) == provider }
        }) else { return }
        run.outcome = outcome
        if let diagnostic { run.diagnostic = diagnostic }
        if !outputIDs.isEmpty { run.outputAttachmentIDs = outputIDs }
        try save(run)
    }
}
