import Foundation
import ClipSlotsKit

/// Read by Agent/backend and canvas selectors without subscribing their trees.
/// Keep this bridge independent of the workspace view/store so focused backend
/// integration tests compile the same production implementation.
enum ModelConfigurationBridge {
    private static let lock = NSLock()
    private static var profiles: [ModelProfile] = []
    private static var defaults: [String: String] = [:]
    static func update(_ document: ModelWorkspaceDocument) {
        lock.lock(); profiles = document.profiles.compactMap { try? ModelHubResolver.resolve($0, services: document.services ?? []) }; defaults = document.defaults; lock.unlock()
        AgentBackendCoordinator.broadcastChange()
    }
    static func profile(_ purpose: ModelPurpose) -> ModelProfile? {
        lock.lock(); defer { lock.unlock() }
        return profiles.first { $0.id == defaults[purpose.rawValue] && $0.enabled && $0.kind == purpose.kind }
    }
    static func agentProfiles() -> [ModelProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles.filter { $0.enabled && !$0.isCLI && $0.kind == .llm && $0.contract.isText }
    }
    static func hasDefault(_ purpose: ModelPurpose) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults[purpose.rawValue] != nil
    }
}
