import AppKit
import ApplicationServices
import Foundation

@MainActor
enum AccessibilityPermissionGuide {
    private static var didGuide = false

    static func checkAndGuideOnLaunch() {
        guard !didGuide, !PerfAutoTest.isEnabled else { return }
        didGuide = true
        let legacyAfterUpdate = UserDefaults.standard.bool(
            forKey: UserPreferenceKeys.pendingAccessibilityReauthAfterUpdate)
        UserDefaults.standard.set(false, forKey: UserPreferenceKeys.pendingAccessibilityReauthAfterUpdate)
        let url = Bundle.main.bundleURL
        let previous = PermissionUpgradeState.shared.previous
        Task {
            let inspection = await Task.detached(priority: .utility) {
                guard let current = try? CodeIdentityInspector.inspect(url) else { return nil as (AppCodeIdentity, Bool)? }
                return (current, previous.map { CodeIdentityInspector.satisfies($0, at: url) } ?? false)
            }.value
            var afterUpdate = legacyAfterUpdate
            if let (current, satisfiesPrevious) = inspection {
                PermissionUpgradeState.shared.observe(current, satisfiesPrevious: satisfiesPrevious)
                afterUpdate = afterUpdate || PermissionUpgradeState.shared.consumeMigrationGuidance()
            }
            try? await Task.sleep(for: .milliseconds(800))
            let model = PermissionCenter.model
            model.refresh()
            PermissionUpgradeState.shared.completeIfReady(model.authorized.count == AppPermission.allCases.count)
            if afterUpdate {
                guard let missing = AppPermission.allCases.first(where: { !model.authorized.contains($0) }) else { return }
                PermissionCenter.present(for: missing, afterUpdate: true)
            } else if !model.authorized.contains(.accessibility) {
                PermissionCenter.present(for: .accessibility)
            }
        }
    }

    static func present() {
        guard !AXIsProcessTrusted() else { return }
        PermissionCenter.present(for: .accessibility)
    }

    static func openAccessibilitySettings() {
        PermissionCenter.authorize(.accessibility)
    }
}
