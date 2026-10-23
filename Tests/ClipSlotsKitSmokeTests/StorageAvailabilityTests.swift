import Foundation
import ClipSlotsKit

func runStorageAvailabilityTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = StorageLock(lockURL: root.appendingPathComponent("lock"))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        try? lock.withLock {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        finished.signal()
    }
    t.check(entered.wait(timeout: .now() + 2) == .success, "busy lock fixture entered")
    var mutated = false
    let start = ProcessInfo.processInfo.systemUptime
    let denied = (try? lock.withLockIfAvailable { mutated = true; return true }) == nil
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    release.signal()
    t.check(finished.wait(timeout: .now() + 2) == .success, "busy lock fixture released")
    t.check(denied && !mutated && elapsed < 0.1, "busy in-process lock declines before mutation without waiting")
    let nested = try? lock.withLockIfAvailable {
        try lock.withLock { try lock.withLockIfAvailable { 42 } }
    }
    t.check(nested == 42, "available transaction preserves recursive locking")
    enum Failure: Error { case fixture }
    do { try lock.withLockIfAvailable { throw Failure.fixture } } catch {}
    t.check((try? lock.withLockIfAvailable { 7 }) == 7, "throwing transaction releases lock")

    let marker = root.appendingPathComponent("held")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import fcntl,pathlib,sys,time; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(3)",
                         root.appendingPathComponent("lock").path, marker.path]
    do {
        try process.run()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        t.check(FileManager.default.fileExists(atPath: marker.path), "external lock fixture entered")
        let started = ProcessInfo.processInfo.systemUptime
        mutated = false
        let refused = (try? lock.withLockIfAvailable { mutated = true; return true }) == nil
        t.check(refused && !mutated && ProcessInfo.processInfo.systemUptime - started < 0.1,
                "external lock declines before mutation without waiting")
        process.terminate()
        process.waitUntilExit()
        t.check((try? lock.withLockIfAvailable { 9 }) == 9, "external lock release permits next transaction")
    } catch { t.check(false, "external lock fixture: \(error)") }
}
