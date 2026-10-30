import Foundation
import ClipSlotsKit

enum AgentArtifactReplyRunEvent: Sendable {
    case conversationActive(Bool)
    case running
    case completion(String)
}

@MainActor
struct AgentArtifactReplyObservation {
    let events: AsyncStream<AgentArtifactReplyRunEvent>
    let isCurrent: () -> Bool
}

/// One native submission owns HTTP; concurrent RPC callers wait for the same immutable reply.
@MainActor
final class AgentArtifactReplySubmissionPromise {
    let submission: AgentAppReplySubmission
    let epoch: UUID
    private var result: Result<JSONValue, Error>?
    private var waiters: [UUID: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]

    init(submission: AgentAppReplySubmission, epoch: UUID) {
        self.submission = submission; self.epoch = epoch
    }

    func value() async throws -> JSONValue {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let id = UUID()
        let stream = AsyncThrowingStream<JSONValue, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            waiters[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.waiters.removeValue(forKey: id) }
            }
        }
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        return value
    }

    func resolve(_ result: Result<JSONValue, Error>) {
        guard self.result == nil else { return }
        self.result = result
        for waiter in waiters.values {
            switch result {
            case .success(let value): waiter.yield(value); waiter.finish()
            case .failure(let error): waiter.finish(throwing: error)
            }
        }
        waiters.removeAll()
    }
}

/// Native equivalent of the source running/completion promises. Acceptance is not activity.
@MainActor
final class AgentArtifactReplyLifecycle {
    let origin: AgentAppReplyOrigin
    let runID: String
    let epoch: UUID
    private var phase: String?
    private var history: [AgentArtifactReplyRunEvent] = []
    private var observers: [UUID: AsyncStream<AgentArtifactReplyRunEvent>.Continuation] = [:]
    private var active = false
    private var activitySeen = false
    private var completed = false

    init(origin: AgentAppReplyOrigin, runID: String, epoch: UUID) {
        self.origin = origin; self.runID = runID; self.epoch = epoch
    }

    func activate() {
        guard !completed, !active else { return }
        active = true
        emit(.conversationActive(true))
    }

    func receiveActivity(runID: String) {
        guard runID == self.runID, !completed, !activitySeen else { return }
        activitySeen = true
        emit(.running)
    }

    func receivePhase(_ phase: String, runID: String) {
        guard runID == self.runID, !completed else { return }
        self.phase = phase
    }

    func finish() {
        guard !completed else { return }
        completed = true
        let outcome: String
        switch phase {
        case "completed": outcome = "applied"
        case "failed": outcome = "failed"
        case "waiting_question", "waiting_confirmation", "waiting_suspended": outcome = "waiting"
        default: outcome = "unknown"
        }
        emit(.completion(outcome))
        if active { active = false; emit(.conversationActive(false)) }
        observers.values.forEach { $0.finish() }
        observers.removeAll()
    }

    func observe(isCurrent: @escaping () -> Bool) -> AgentArtifactReplyObservation {
        let id = UUID()
        let stream = AsyncStream<AgentArtifactReplyRunEvent>(bufferingPolicy: .bufferingNewest(4)) { continuation in
            history.forEach { continuation.yield($0) }
            if completed { continuation.finish() }
            else {
                observers[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { @MainActor in self?.observers.removeValue(forKey: id) }
                }
            }
        }
        return .init(events: stream, isCurrent: isCurrent)
    }

    func dispose() {
        observers.values.forEach { $0.finish() }
        observers.removeAll()
        completed = true
    }

    private func emit(_ event: AgentArtifactReplyRunEvent) {
        history.append(event)
        observers.values.forEach { $0.yield(event) }
    }
}
