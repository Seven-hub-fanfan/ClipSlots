// Standalone: swiftc -parse-as-library Sources/ClipSlotsKit/AgentKeychain.swift
// Tests/AgentKeychainRegression/main.swift -o .dbg/keychain-regression
// Deterministic concurrency and Security status tests; never touch a real credential.
import Foundation
import Security

private final class SecurityFixture {
    private let lock = NSLock()
    var value: Data? = Data("synthetic-old".utf8)
    var readStatus: OSStatus = errSecSuccess
    var writeStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var readStarted: DispatchSemaphore?
    var releaseRead: DispatchSemaphore?
    var mutationStarted: DispatchSemaphore?
    private(set) var reads = 0
    private(set) var updates = 0
    private(set) var adds = 0
    private(set) var deletes = 0

    var operations: AgentKeychain.Operations {
        .init(read: { _ in
            self.lock.lock()
            self.reads += 1
            let result = (self.readStatus, self.value)
            let started = self.readStarted
            let release = self.releaseRead
            self.lock.unlock()
            started?.signal()
            if let release {
                precondition(release.wait(timeout: .now() + 5) == .success, "read gate timed out")
            }
            return result
        }, update: { _, attributes in
            self.lock.lock()
            defer { self.lock.unlock() }
            self.updates += 1
            self.mutationStarted?.signal()
            guard self.writeStatus == errSecSuccess else { return self.writeStatus }
            guard self.value != nil else { return errSecItemNotFound }
            self.value = (attributes as NSDictionary)[kSecValueData] as? Data
            return errSecSuccess
        }, add: { attributes in
            self.lock.lock()
            defer { self.lock.unlock() }
            self.adds += 1
            guard self.writeStatus == errSecSuccess else { return self.writeStatus }
            self.value = (attributes as NSDictionary)[kSecValueData] as? Data
            return errSecSuccess
        }, delete: { _ in
            self.lock.lock()
            defer { self.lock.unlock() }
            self.deletes += 1
            self.mutationStarted?.signal()
            guard self.deleteStatus == errSecSuccess else { return self.deleteStatus }
            self.value = nil
            return errSecSuccess
        })
    }

    func store() -> AgentKeychain {
        AgentKeychain(service: "com.clipslots.test.synthetic", account: "synthetic", operations: operations)
    }
}

@main
private enum KeychainRegression {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func concurrentReads(_ store: AgentKeychain, expected: String?) {
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let lock = NSLock()
        var matches = 0
        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let match = store.readAPIKey() == expected
                lock.lock()
                if match { matches += 1 }
                lock.unlock()
                group.leave()
            }
        }
        for _ in 0..<12 { start.signal() }
        check(group.wait(timeout: .now() + 5) == .success, "concurrent reads timed out")
        check(matches == 12, "callers did not share the same result")
    }

    static func main() async throws {
        let success = SecurityFixture()
        let store = success.store()
        concurrentReads(store, expected: "synthetic-old")
        check(success.reads == 1, "cold reads must request Security once")
        _ = store.keyState(retryAfterFailure: true)
        check(success.reads == 1, "retry must preserve a successful authorization")
        store.invalidateCache()
        concurrentReads(store, expected: "synthetic-old")
        check(success.reads == 2, "invalidation must allow exactly one fresh read")
        try store.writeAPIKey("  synthetic-new\n")
        check(store.readAPIKey() == "synthetic-new", "write did not update cache")
        check(success.reads == 2 && success.adds == 0, "update must preserve the existing item")
        let updates = success.updates
        try store.writeAPIKey("synthetic-new")
        check(success.updates == updates, "saving an unchanged cached key must not authorize another update")
        try store.writeAPIKey(" \n")
        check(store.readAPIKey() == nil && success.deletes == 1, "blank write must delete without deadlock")

        let absent = SecurityFixture()
        absent.value = nil
        absent.readStatus = errSecItemNotFound
        let missingStore = absent.store()
        concurrentReads(missingStore, expected: nil)
        check(absent.reads == 1 && missingStore.keyState().error == nil, "missing item must cache absence")
        try missingStore.writeAPIKey("synthetic-added")
        check(absent.adds == 1 && missingStore.readAPIKey() == "synthetic-added", "add must seed the cache")

        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            let denied = SecurityFixture()
            denied.readStatus = status
            let deniedStore = denied.store()
            concurrentReads(deniedStore, expected: nil)
            check(denied.reads == 1, "denied concurrent readers must not repeat authorization")
            check(deniedStore.keyState().error == .osStatus(status), "authorization failure must remain visible")
            denied.readStatus = errSecSuccess
            check(deniedStore.readAPIKey() == nil && denied.reads == 1, "automatic refresh must not retry")
            check(deniedStore.keyState(retryAfterFailure: true).hasKey, "explicit retry must recover")
            check(denied.reads == 2 && deniedStore.keyState().error == nil, "successful retry must clear failure")
        }

        let invalid = SecurityFixture()
        invalid.value = Data([0xFF])
        let invalidStore = invalid.store()
        check(invalidStore.keyState().error == .encodingFailed, "invalid data must not look like a missing key")

        let failedMutation = SecurityFixture()
        let mutationStore = failedMutation.store()
        _ = mutationStore.readAPIKey()
        failedMutation.writeStatus = errSecAuthFailed
        do {
            try mutationStore.writeAPIKey("synthetic-rejected")
            preconditionFailure("failed update was accepted")
        } catch {
            check(mutationStore.readAPIKey() == "synthetic-old", "failed update poisoned the cache")
        }
        failedMutation.deleteStatus = errSecAuthFailed
        do {
            try mutationStore.deleteAPIKey()
            preconditionFailure("failed deletion was accepted")
        } catch {
            check(mutationStore.readAPIKey() == "synthetic-old", "failed deletion poisoned the cache")
        }

        // Hold a read inside Security while another thread writes/deletes/invalidates.
        // Mutations must wait and the late read must never restore the old cached value.
        for action in ["write", "delete", "invalidate"] {
            let fixture = SecurityFixture()
            fixture.readStarted = DispatchSemaphore(value: 0)
            fixture.releaseRead = DispatchSemaphore(value: 0)
            fixture.mutationStarted = DispatchSemaphore(value: 0)
            let racingStore = fixture.store()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                _ = racingStore.readAPIKey()
                group.leave()
            }
            check(fixture.readStarted!.wait(timeout: .now() + 5) == .success, "read never entered Security")
            let mutationAttempted = DispatchSemaphore(value: 0)
            let mutationDone = DispatchSemaphore(value: 0)
            group.enter()
            DispatchQueue.global().async {
                mutationAttempted.signal()
                switch action {
                case "write": try! racingStore.writeAPIKey("synthetic-after")
                case "delete": try! racingStore.deleteAPIKey()
                default: racingStore.invalidateCache()
                }
                mutationDone.signal()
                group.leave()
            }
            check(mutationAttempted.wait(timeout: .now() + 5) == .success, "mutation was not scheduled")
            check(mutationDone.wait(timeout: .now() + 0.1) == .timedOut, "mutation overtook an active read")
            check(fixture.mutationStarted!.wait(timeout: .now()) == .timedOut, "Security operations overlapped")
            fixture.releaseRead!.signal()
            check(group.wait(timeout: .now() + 5) == .success, "read/mutation deadlock")
            fixture.readStarted = nil
            fixture.releaseRead = nil
            switch action {
            case "write": check(racingStore.readAPIKey() == "synthetic-after", "late read overwrote a write")
            case "delete": check(racingStore.readAPIKey() == nil, "late read resurrected a deleted key")
            default:
                fixture.value = Data("synthetic-external".utf8)
                check(racingStore.readAPIKey() == "synthetic-external", "late read undid cache invalidation")
                check(fixture.reads == 2, "invalidation must cause one fresh read")
            }
        }

        for reason in ["timeout", "cancel", "state-timeout", "state-cancel"] {
            let fixture = SecurityFixture()
            fixture.readStarted = DispatchSemaphore(value: 0)
            fixture.releaseRead = DispatchSemaphore(value: 0)
            let waitingStore = fixture.store()
            let began = Date()
            let task = Task.detached { () -> AgentKeychainError? in
                if reason.hasPrefix("state") {
                    return await waitingStore.keyStateAsync(timeout: reason == "state-timeout" ? 0.1 : 5).error
                }
                do {
                    _ = try await AgentCredentialAccess.readAPIKey(from: waitingStore,
                        timeout: reason == "timeout" ? 0.1 : 5)
                    return nil
                } catch is CancellationError { return .readCancelled }
                catch { return error as? AgentKeychainError }
            }
            check(fixture.readStarted!.wait(timeout: .now() + 2) == .success, "async read never entered Security")
            if reason.contains("cancel") { task.cancel() }
            let error = await task.value
            check(error == (reason.contains("cancel") ? .readCancelled : .authorizationTimedOut),
                  "blocked credential read lost cancellation/deadline")
            check(Date().timeIntervalSince(began) < 1, "waiter did not return before Security completed")
            check(fixture.reads == 1, "bounded wait must not repeat Security requests")
            fixture.releaseRead!.signal()
            let key = try await AgentCredentialAccess.readAPIKey(from: waitingStore, timeout: 2)
            check(key == "synthetic-old" && fixture.reads == 1, "late authorization must populate the existing cache")
            try waitingStore.writeAPIKey("synthetic-after-wait")
            check(waitingStore.readAPIKey() == "synthetic-after-wait", "late completion overwrote a newer key")
        }

        let denied = SecurityFixture()
        denied.readStatus = errSecAuthFailed
        do {
            _ = try await AgentCredentialAccess.readAPIKey(from: denied.store())
            preconditionFailure("denied async read looked like a missing key")
        } catch {
            check(error as? AgentKeychainError == .osStatus(errSecAuthFailed), "async read must retain Security failure")
        }
        let preCancelled = SecurityFixture()
        let neverStarted = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AgentCredentialAccess.readAPIKey(from: preCancelled.store())
        }
        do {
            _ = try await neverStarted.value
            preconditionFailure("cancelled task started a read")
        } catch {
            check(error is CancellationError && preCancelled.reads == 0, "pre-cancellation must not touch Security")
        }
        print("AgentKeychain regression: \(checks) checks passed (synthetic credentials only)")
    }
}
