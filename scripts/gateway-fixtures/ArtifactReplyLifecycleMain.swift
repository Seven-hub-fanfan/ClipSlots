import Foundation
import ClipSlotsKit

@main
struct ArtifactReplyLifecycleMain {
    @MainActor
    static func main() async throws {
        var passed = 0, failures: [String] = []
        func check(_ valid: Bool, _ name: String) {
            if valid { passed += 1 } else { failures.append(name) }
        }
        let authority: JSONValue = ["schemaVersion": 1,
            "binding": ["sessionID": "session", "projectID": "project", "canvasID": "canvas"],
            "originRunID": "original", "artifactID": "page", "path": "apps/page.html",
            "artifactRevision": 1, "manifestRevision": .string(String(repeating: "a", count: 64)),
            "actions": ["previs_reply"]]
        let origin = try AgentAppReplyOrigin(endpoint: URL(string: "https://fixture.invalid/v1")!,
            authority: JSONDecoder().decode(AgentAppReplyAuthority.self, from: JSONEncoder().encode(authority)))
        func collect(_ observation: AgentArtifactReplyObservation) async -> [String] {
            var values: [String] = []
            for await event in observation.events {
                switch event {
                case .conversationActive(let active): values.append(active ? "active" : "inactive")
                case .running: values.append("running")
                case .completion(let outcome): values.append(outcome)
                }
            }
            return values
        }
        for (phase, outcome) in [("completed", "applied"), ("failed", "failed"),
            ("waiting_question", "waiting"), ("waiting_confirmation", "waiting"),
            ("waiting_suspended", "waiting"), ("blocked", "unknown"), ("unknown", "unknown"),
            ("cancelled", "unknown")] {
            let lifecycle = AgentArtifactReplyLifecycle(origin: origin, runID: "reply", epoch: UUID())
            let observation = lifecycle.observe { true }
            lifecycle.activate()
            lifecycle.receiveActivity(runID: "foreign")
            lifecycle.receivePhase("completed", runID: "foreign")
            lifecycle.receiveActivity(runID: "reply")
            lifecycle.receivePhase(phase, runID: "reply")
            lifecycle.finish()
            let expected = ["active", "running", outcome, "inactive"]
            check(await collect(observation) == expected, "phase \(phase) uses exact source outcome")
            lifecycle.receiveActivity(runID: "reply")
            lifecycle.receivePhase("completed", runID: "reply")
            lifecycle.finish()
            check(await collect(lifecycle.observe { true }) == expected, "phase \(phase) late activity cannot overwrite completion")
        }
        let readback = AgentArtifactReplyLifecycle(origin: origin, runID: "reply", epoch: UUID())
        readback.receivePhase("streaming", runID: "reply")
        readback.finish()
        check(await collect(readback.observe { true }) == ["unknown"], "readback streaming does not create stream activity or success")
        let disposed = AgentArtifactReplyLifecycle(origin: origin, runID: "reply", epoch: UUID())
        let disposedObservation = disposed.observe { true }
        disposed.dispose()
        disposed.receiveActivity(runID: "reply")
        disposed.finish()
        check(await collect(disposedObservation).isEmpty, "disposed lifecycle emits no invented terminal")

        let started = ProcessInfo.processInfo.systemUptime
        let pressure = AgentArtifactReplyLifecycle(origin: origin, runID: "reply", epoch: UUID())
        let observations = (0..<128).map { _ in pressure.observe { true } }
        pressure.activate()
        for _ in 0..<20_000 { pressure.receiveActivity(runID: "reply") }
        pressure.receivePhase("completed", runID: "reply")
        pressure.finish()
        for (index, observation) in observations.enumerated() {
            check(await collect(observation) == ["active", "running", "applied", "inactive"],
                  "pressure observer \(index) receives bounded exactly-once lifecycle")
        }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let submission = try AgentAppReplySubmission(origin: origin,
            replyJSON: #"{"reply_id":"55b901e4-0ed9-400f-8a55-562fdf17f233","action":"previs_reply","payload":{"text":"e\u0301"}}"#)
        let promise = AgentArtifactReplySubmissionPromise(submission: submission, epoch: UUID())
        var waiting = 0
        let tasks = (0..<128).map { _ in Task { @MainActor in
            waiting += 1
            return try await promise.value()
        }}
        while waiting < 128 { await Task.yield() }
        tasks[0].cancel()
        await Task.yield()
        let envelope: JSONValue = ["reply_id": .string(submission.replyID), "run_id": "reply", "deduped": false]
        promise.resolve(.success(envelope))
        for (index, task) in tasks.enumerated() {
            do {
                let value = try await task.value
                check(index != 0 && value == envelope, "promise waiter \(index) reuses original result")
            }
            catch { check(index == 0 && error is CancellationError, "cancelled promise waiter does not cancel peers") }
        }
        check(try await promise.value() == envelope, "accepted result remains cached")
        promise.resolve(.failure(AgentAppReplyError.unknown))
        check(try await promise.value() == envelope, "late failure cannot replace original accepted result")
        let unknown = AgentArtifactReplySubmissionPromise(submission: submission, epoch: UUID())
        unknown.resolve(.failure(AgentAppReplyError.unknown))
        do { _ = try await unknown.value(); check(false, "unknown must propagate") }
        catch { check(error as? AgentAppReplyError == .unknown, "unknown result remains unknown") }
        let result: [String: Any] = ["passed": passed, "failures": failures,
            "activityPressure": 20_000, "simultaneousObservers": 128, "pendingReplyWaiters": 128,
            "pressureElapsedMS": elapsedMS, "actualNativeLifecycle": true,
            "actualWebKit": false, "remoteProviderRequests": 0, "goalComplete": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
