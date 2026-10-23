#if DEBUG
import AppKit

@MainActor
func runCanvasDisplayClockRegression(check: (Bool, String) -> Void) async {
    let clock = CanvasDisplayClock.shared
    let observations = DisplayClockThreadObservations()
    var keeperTicks = 0
    let keeper = clock.subscribe {
        keeperTicks += 1
        observations.record()
    }
    defer { clock.unsubscribe(keeper) }
    let resumed = await withTaskGroup(of: Int.self, returning: Int.self) { group in
        for _ in 0..<64 {
            group.addTask {
                await clock.nextFrame()
                return 1
            }
        }
        var count = 0
        for await value in group { count += value }
        return count
    }
    check(resumed == 64, "display clock resumes 64 background next-frame callers exactly once")
    let mutations = await withTaskGroup(of: Int.self, returning: Int.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for index in 0..<250 {
                    let token = clock.subscribe { observations.record() }
                    clock.unsubscribe(token)
                    if index % 25 == 0 { await clock.nextFrame() }
                }
                return 250
            }
        }
        var count = 0
        for await value in group { count += value }
        return count
    }
    check(mutations == 2000 && keeperTicks > 1,
          "display clock safely handles 2000 concurrent subscriptions during live delivery")
    check(observations.allOnMain && observations.count > 0,
          "display clock callbacks always run on the main thread")
    var once = 0
    var oneShot: UUID?
    oneShot = clock.subscribe {
        once += 1
        if let oneShot { clock.unsubscribe(oneShot) }
    }
    await clock.nextFrame()
    await clock.nextFrame()
    if let oneShot { clock.unsubscribe(oneShot) }
    check(once == 1, "display clock self-unsubscription prevents another delivery")
}

private final class DisplayClockThreadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var mainOnly = true
    var count: Int { lock.lock(); defer { lock.unlock() }; return callbacks }
    var allOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainOnly }
    func record() {
        lock.lock()
        callbacks += 1
        mainOnly = mainOnly && Thread.isMainThread
        lock.unlock()
    }
}
#endif
