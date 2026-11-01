import Foundation

/// Invalidation and the final synchronous write share a lock. A scope change
/// cannot race between the validity check and a binding's disk mutation.
public final class AgentMarketOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true

    public init() {}

    public func invalidate() {
        lock.lock()
        current = false
        lock.unlock()
    }

    public var isCurrent: Bool {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func withCurrent<Value>(_ body: () throws -> Value) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard current, !Task.isCancelled else { throw CancellationError() }
        return try body()
    }
}
