import Foundation
import ClipSlotsKit

enum LaunchDefaults {
    static let appliedBuildKey = "launch.defaults.appliedBuild"

    static func applyForUpdate(defaults: UserDefaults = .standard, build: String? = nil) {
        let version = build ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? AppVersion.fallback
        guard defaults.string(forKey: appliedBuildKey) != version else { return }
        defaults.set(AppSkin.minimal.rawValue, forKey: AppSkin.defaultsKey)
        defaults.set(ThemeMode.light.rawValue, forKey: AppearanceDefaults.key)
        defaults.set(AgentBackendKind.deepseek.rawValue, forKey: AgentBackendScope.sidebar.preferenceKey)
        defaults.set(AgentBackendKind.deepseek.rawValue, forKey: AgentBackendScope.workspace.preferenceKey)
        defaults.set(AgentConfig.defaultModel, forKey: AgentPreferences.modelKey)
        defaults.set(version, forKey: appliedBuildKey)
    }
}
