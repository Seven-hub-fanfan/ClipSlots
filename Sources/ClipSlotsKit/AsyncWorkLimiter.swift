import Foundation

/// Limits expensive local processes without limiting remote asynchronous jobs.
public actor AsyncWorkLimiter {
    private let limit: Int
    private var occupied = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init(limit: Int) { self.limit = max(1, limit) }

    private func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if occupied < limit { occupied += 1; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { occupied -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
    public func withPermit<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await body()
            release()
            return value
        } catch { release(); throw error }
    }
}
