import Foundation

public actor ModelRequestBudget {
    public static let shared = ModelRequestBudget()
    private var active: [String: [UUID: Int]] = [:]
    public func withPermit<T: Sendable>(profile: ModelProfile, operation: @Sendable () async throws -> T) async throws -> T {
        let group = profile.serviceID ?? profile.id
        let limit = profile.serviceConcurrency ?? profile.concurrency
        while true {
            try Task.checkCancellation()
            let values = active[group] ?? [:]
            if values.count < min(limit, values.values.min() ?? limit) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let token = UUID(); active[group, default: [:]][token] = limit
        defer { active[group]?[token] = nil }
        return try await operation()
    }
}
