import Foundation

/// Identity history permits one AX repair after a verified identity migration.
/// Effective grants remain authoritative and are never reset automatically.
/// Finder replacement, rollback and reinstall are observed on the next launch.
final class PermissionUpgradeState {
    static let shared = PermissionUpgradeState()
    private let defaults: UserDefaults
    private let snapshotKey = "PermissionUpgrade.identity.v1"
    private let pendingKey = "PermissionUpgrade.pendingIdentity.v1"
    private let shownKey = "PermissionUpgrade.shownRequirement.v1"
    private let repairEligibilityKey = "PermissionUpgrade.repairEligibility.v1"
    private let attemptedRepairKey = "PermissionUpgrade.attemptedAXRepair.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var previous: AppCodeIdentity? { decode(snapshotKey) }
    var pending: AppCodeIdentity? { decode(pendingKey) }

    @discardableResult
    func observe(_ current: AppCodeIdentity, satisfiesPrevious: Bool) -> CodeIdentityInspector.Transition {
        let transition = CodeIdentityInspector.transition(
            from: previous, to: current, satisfiesPrevious: satisfiesPrevious)
        if transition == .migration || transition == .rejected {
            save(current, key: pendingKey)
            if transition == .migration {
                defaults.set(current.requirement, forKey: repairEligibilityKey)
            } else { defaults.removeObject(forKey: repairEligibilityKey) }
        } else if let pending, pending.bundleID != current.bundleID
                    || pending.requirement != current.requirement {
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: repairEligibilityKey)
        }
        save(current, key: snapshotKey)
        return transition
    }

    func recordInstalled(from old: AppCodeIdentity, to new: AppCodeIdentity,
                         transition: CodeIdentityInspector.Transition) {
        save(old, key: snapshotKey)
        if transition == .migration {
            save(new, key: pendingKey)
            defaults.set(new.requirement, forKey: repairEligibilityKey)
        } else {
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: repairEligibilityKey)
        }
    }

    func completeIfReady(_ ready: Bool) {
        if ready {
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: shownKey)
            defaults.removeObject(forKey: repairEligibilityKey)
        }
    }

    /// Consume before running the subprocess so activation, failures and restarts
    /// cannot repeatedly clear the user's newly granted or declined permission.
    func consumeAutomaticAccessibilityRepair(isAuthorized: Bool) -> Bool {
        guard !isAuthorized, let pending,
              pending.bundleID == PermissionRepairCoordinator.bundleIdentifier,
              pending.path == "/Applications/ClipSlots.app",
              defaults.data(forKey: repairEligibilityKey) == pending.requirement,
              defaults.data(forKey: attemptedRepairKey) != pending.requirement else { return false }
        defaults.set(pending.requirement, forKey: attemptedRepairKey)
        return true
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
