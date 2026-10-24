import Foundation

/// Identity history permits guidance after a verified identity migration.
/// Upgrades never reset permissions, including previously saved repair intent.
/// Finder replacement, rollback and reinstall are observed on the next launch.
final class PermissionUpgradeState {
    static let shared = PermissionUpgradeState()
    private let defaults: UserDefaults
    private let snapshotKey = "PermissionUpgrade.identity.v1"
    private let pendingKey = "PermissionUpgrade.pendingIdentity.v1"
    private let shownKey = "PermissionUpgrade.shownRequirement.v1"
    private let repairEligibilityKey = "PermissionUpgrade.repairEligibility.v1"
    private let attemptedRepairKey = "PermissionUpgrade.attemptedAXRepair.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clearLegacyRepairIntent()
    }

    var previous: AppCodeIdentity? { decode(snapshotKey) }
    var pending: AppCodeIdentity? { decode(pendingKey) }

    @discardableResult
    func observe(_ current: AppCodeIdentity, satisfiesPrevious: Bool) -> CodeIdentityInspector.Transition {
        let transition = CodeIdentityInspector.transition(
            from: previous, to: current, satisfiesPrevious: satisfiesPrevious)
        clearLegacyRepairIntent()
        if transition == .migration || transition == .rejected {
            save(current, key: pendingKey)
        } else if let pending, pending.bundleID != current.bundleID
                    || pending.requirement != current.requirement {
            defaults.removeObject(forKey: pendingKey)
        }
        save(current, key: snapshotKey)
        return transition
    }

    func recordInstalled(from old: AppCodeIdentity, to new: AppCodeIdentity,
                         transition: CodeIdentityInspector.Transition) {
        clearLegacyRepairIntent()
        save(old, key: snapshotKey)
        if transition == .migration {
            save(new, key: pendingKey)
        } else {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    func completeIfReady(_ ready: Bool) {
        clearLegacyRepairIntent()
        if ready {
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: shownKey)
        }
    }

    private func clearLegacyRepairIntent() {
        defaults.removeObject(forKey: repairEligibilityKey)
        defaults.removeObject(forKey: attemptedRepairKey)
    }

    /// Migration guidance is shown once per identity. A declined optional
    /// permission does not cause an upgrade popup on every subsequent launch.
    func consumeMigrationGuidance() -> Bool {
        guard let pending, defaults.data(forKey: shownKey) != pending.requirement else { return false }
        defaults.set(pending.requirement, forKey: shownKey)
        return true
    }

    private func decode(_ key: String) -> AppCodeIdentity? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppCodeIdentity.self, from: $0) }
    }
    private func save(_ value: AppCodeIdentity, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
