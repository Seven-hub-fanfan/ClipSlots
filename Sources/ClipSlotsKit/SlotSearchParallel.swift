import Foundation

/// Bounded synchronous work with ordered results. Only the calling thread polls
/// the caller's cancellation closure: Task.isCancelled on a GCD worker would
/// inspect no Swift task and silently lose cancellation.
public enum SlotSearchParallel {
    public static func map<Value>(count: Int, isCancelled: () -> Bool,
                                  body: (Int, () -> Bool) -> Value) -> [Value]? {
        guard !isCancelled() else { return nil }
        guard count > 0 else { return [] }
        let scheduling = ResourceBudget.shared.schedulingSnapshot
        let constrained = scheduling.pressure != .normal || scheduling.background || scheduling.lowPower
        let workers = min(count, constrained ? 2 : min(8, ProcessInfo.processInfo.activeProcessorCount))
        if workers <= 1 {
            return withoutActuallyEscaping(isCancelled) { cancelled in
                var result: [Value] = []
                for index in 0..<count {
                    guard !cancelled() else { return nil }
                    result.append(body(index, cancelled))
                }
                return cancelled() ? nil : result
            }
        }
        return withoutActuallyEscaping(body) { work in
            let state = SearchParallelState<Value>(count: count, workers: workers, work: work)
            for _ in 0..<workers {
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { state.finish() }
                    while let index = state.take() {
                        autoreleasepool { state.perform(at: index) }
                    }
                }
            }
            // Drain every worker even after cancellation; no callback or borrowed
            // closure can outlive this method or contaminate the next query.
            while true {
                if isCancelled() { state.cancel() }
                if state.waitForWorkers() { break }
            }
            return isCancelled() ? nil : state.result()
        }
    }
}

private final class SearchParallelState<Value> {
    private let condition = NSCondition()
    private var next = 0
    private var remaining: Int
    private var stopped = false
    private var values: [Value?]
    private var work: ((Int, () -> Bool) -> Value)?

    init(count: Int, workers: Int, work: @escaping (Int, () -> Bool) -> Value) {
        values = Array(repeating: nil, count: count)
        remaining = workers
        self.work = work
    }
    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopped
    }
    func cancel() {
        condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
    }
    func take() -> Int? {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, next < values.count else { return nil }
        defer { next += 1 }
        return next
    }
    func perform(at index: Int) {
        condition.lock()
        let work = self.work
        condition.unlock()
        guard let work else { return }
        let value = work(index, { self.isCancelled })
        condition.lock(); values[index] = .some(value); condition.unlock()
    }
    func finish() {
        condition.lock()
        remaining -= 1
        // GCD blocks capture only state. Release the borrowed closure after every
        // perform() invocation returned, BEFORE waking the caller. Waiting merely
        // for task counters left a race with GCD releasing its block capture.
        if remaining == 0 { work = nil }
        condition.broadcast()
        condition.unlock()
    }
    func waitForWorkers() -> Bool {
        condition.lock(); defer { condition.unlock() }
        if remaining > 0 { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
        return remaining == 0
    }
    func result() -> [Value]? {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, remaining == 0 else { return nil }
        var result: [Value] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let value else { return nil }
            result.append(value)
        }
        return result
    }
}
