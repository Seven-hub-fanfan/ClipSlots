import Foundation
import ClipSlotsKit

private final class BlockedCredentialStore: AgentSecretStore, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    func readAPIKey() -> String? {
        started.signal()
        guard release.wait(timeout: .now() + 5) == .success else { return nil }
        completed.signal()
        return "synthetic-credential"
    }
    func writeAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

func runAgentCredentialWaitTests(_ t: TestRunner) {
    for cancellation in [false, true] {
        let store = BlockedCredentialStore()
        let transport = AgentScriptedTransport(steps: [])
        let service = AgentService(transport: transport, secretStore: store,
                                   credentialTimeout: cancellation ? 5 : 0.1)
        let events = SmokeEventLog()
        let start = Date()
        let error: AgentError? = smokeAwait {
            let task = Task.detached { () -> AgentError? in
                do {
                    _ = try await service.run(history: [.init(role: .user, content: "create nodes")],
                        config: AgentConfig(), tools: nil) { events.append($0) }
                    return nil
                } catch { return error as? AgentError }
            }
            if store.started.wait(timeout: .now() + 2) != .success {
                task.cancel()
                store.release.signal()
                return .invalidResponse("fixture did not start")
            }
            if cancellation { task.cancel() }
            return await task.value
        }
        t.equal(error, cancellation ? .cancelled : .credential(.authorizationTimedOut),
                "credential wait reports cancellation or authorization deadline")
        t.check(Date().timeIntervalSince(start) < 1,
                "credential waiter completes while the Security operation remains blocked")
        t.equal(events.kinds, ["credentialWaiting"],
                "credential wait never claims it has connected or started tools")
        t.check(transport.capturedRequests.isEmpty,
                "no HTTP request is sent before credential acquisition succeeds")
        store.release.signal()
        t.check(store.completed.wait(timeout: .now() + 2) == .success, "fixture Security operation completes")
        t.check(transport.capturedRequests.isEmpty,
                "late authorization cannot restart a stopped or expired model run")
    }
    let transport = AgentScriptedTransport(steps: [])
    let service = AgentService(transport: transport,
                               secretStore: AgentInMemorySecretStore(key: "synthetic"))
    let cancelled: Bool = smokeAwait {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try await service.run(history: [.init(role: .user, content: "cancelled")],
                                      config: AgentConfig(), tools: nil) { _ in }
            return false
        } catch is CancellationError { return true }
        catch { return false }
    }
    t.check(cancelled && transport.capturedRequests.isEmpty,
            "pre-cancelled model run cannot send a request")
    t.check(AgentError.credential(.authorizationTimedOut).errorDescription?.contains("尚未发送请求") == true,
            "authorization timeout distinguishes credentials from a network failure")
}
