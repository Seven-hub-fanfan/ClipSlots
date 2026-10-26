#if DEBUG
import Foundation

public enum SlotSearchDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["CLIPSLOTS_SEARCH_TIMING"] == "1"
    private static let lock = NSLock()
    private static var totals: [String: Double] = [:]
    public static var now: Double { enabled ? ProcessInfo.processInfo.systemUptime : 0 }
    public static func record(_ name: String, since start: Double) {
        guard enabled else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        lock.lock()
        totals[name, default: 0] += elapsed
        lock.unlock()
    }
    public static func take() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        let result = totals
        totals.removeAll()
        return result
    }
}
#endif
