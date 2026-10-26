import Foundation

/// Limits expensive local processes without limiting remote asynchronous jobs.
public actor AsyncWorkLimiter {
    private let limit: Int
    private let currentLimit: (@Sendable () -> Int)?
    private var occupied = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>, Int)] = []
    public init(limit: Int, currentLimit: (@Sendable () -> Int)? = nil) {
        self.limit = max(1, limit); self.currentLimit = currentLimit
    }
    private var effectiveLimit: Int { max(1, min(limit, currentLimit?() ?? limit)) }

    private func acquire(priority: Int) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if occupied < effectiveLimit { occupied += 1; continuation.resume() }
                else {
                    let index = waiters.firstIndex { $0.2 < priority } ?? waiters.count
                    waiters.insert((id, continuation, priority), at: index)
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        occupied -= 1
        while occupied < effectiveLimit, !waiters.isEmpty {
            occupied += 1
            waiters.removeFirst().1.resume()
        }
    }
    public func withPermit<T>(priority: Int = 0, _ body: () async throws -> T) async throws -> T {
        try await acquire(priority: priority)
        do {
            try Task.checkCancellation()
            let value = try await body()
            release()
            return value
        } catch { release(); throw error }
    }
}
