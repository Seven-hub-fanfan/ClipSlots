import Foundation

/// Opt-in attribution for the isolated, silent workspace fixture.
enum WorkspaceMountTrace {
    private static let enabled = ProcessInfo.processInfo.environment["CLIPSLOTS_WORKSPACE_MOTION_PROBE"] != nil
    private(set) static var events = [[String: Any]]()
    private(set) static var phase = "idle"

    static func mark(_ name: String, cost: Double? = nil) {
        guard enabled else { return }
        phase = name
        var event: [String: Any] = ["phase": name, "uptime": ProcessInfo.processInfo.systemUptime]
        if let cost { event["synchronous_ms"] = cost * 1000 }
        events.append(event)
    }

    static func measure<T>(_ name: String, _ work: () -> T) -> T {
        guard enabled else { return work() }
        let begin = ProcessInfo.processInfo.systemUptime
        let result = work()
        mark(name, cost: ProcessInfo.processInfo.systemUptime - begin)
        return result
    }
}
