import Foundation

public enum GenerationProcessBudget {
    public static let shared = AsyncWorkLimiter(limit: 4,
        currentLimit: { ResourceBudget.shared.decodeConcurrency * 2 })
}

public struct ByteArtistRuntime: Sendable {
    public let adapter: ByteArtistGenerationAdapter
    public init(root: URL = ClipSlotsPaths.dataRoot.appendingPathComponent("byteartist"),
                executor: GenerationCLIExecutor? = nil) throws {
        adapter = try ByteArtistGenerationAdapter(root: root, executor: executor ?? { invocation in
            let chain = LocalToolchain()
            guard let path = chain.resolve(.ba) else {
                throw GenerationAdapterError.invalidConfiguration("请在「环境检测」中安装 ByteArtist CLI。")
            }
            return try await GenerationProcessBudget.shared.withPermit {
                do {
                    try FileManager.default.createDirectory(at: invocation.directory, withIntermediateDirectories: true)
                    return try await ToolProcess.run(path, invocation.arguments, environment: invocation.environment,
                        directory: invocation.directory, timeout: invocation.timeout, outputLimit: 4_194_304,
                        captureStoppedOutput: invocation.submitting)
                } catch is CancellationError { throw CancellationError() }
                catch ToolProcess.Failure.timeout { throw GenerationAdapterError.timeout }
                catch { throw GenerationAdapterError.processNotStarted }
            }
        })
    }

    public func prepare(configuration: ByteArtistCanvasConfiguration, capability: GenerationCapability,
                        prompt: String, images: [String], firstFrame: String?, lastFrame: String?) async throws -> PreparedGenerationRequest {
        let bound = GenerationCapability(context: capability.context, id: capability.id, title: capability.title,
            revision: capability.revision, kind: capability.kind, inputSchema: capability.inputSchema,
            outputBindings: configuration.draft.outputBindings, metadata: capability.metadata,
            referencePath: capability.referencePath)
        let input = try configuration.input(capability: bound, prompt: prompt, images: images,
                                            firstFrame: firstFrame, lastFrame: lastFrame)
        return try await adapter.prepare(input, capability: bound)
    }

    public func submit(_ request: PreparedGenerationRequest, recording: GenerationRunContext,
                       history: GenerationRunStore = .shared) async throws -> GenerationSubmission {
        for file in request.inputFiles {
            if let captured = recording.resourceFileVersions[file.path], captured != file.version {
                throw GenerationAdapterError.inputChanged
            }
        }
        let record = GenerationRequestRecord(request, resourceIDs: recording.resourceIDs)
        let attempt = try history.beginAttempt(context: recording, requested: record, effective: record)
        do {
            let result = try await adapter.submit(request)
            // A history write failure must never discard an accepted remote identity.
            try? history.finishAttempt(context: recording, attemptID: attempt, status: .accepted,
                taskID: result.task.taskID, detail: result.detail, taskHandle: result.task)
            return result
        } catch {
            let unknown: Bool
            if case GenerationAdapterError.submissionUnknown = error { unknown = true } else { unknown = false }
            try? history.finishAttempt(context: recording, attemptID: attempt,
                status: unknown ? .unknown : .rejected,
                detail: unknown ? "BA 提交结果未知，请核对原平台任务。" : "任务未提交或被明确拒绝。")
            throw error
        }
    }

    public func wait(_ task: GenerationTaskHandle, timeout: TimeInterval,
                     interval: TimeInterval = 3,
                     progress: @escaping @Sendable (GenerationObservation) async -> Void) async throws -> GenerationObservation {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let observation = try await adapter.query(task)
            await progress(observation)
            switch observation.status {
            case .succeeded, .failed, .outputMismatch: return observation
            case .queued, .running, .unknown: break
            }
            try await Task.sleep(for: .seconds(max(0.01, min(10, interval))))
        }
        throw GenerationAdapterError.timeout
    }
}
