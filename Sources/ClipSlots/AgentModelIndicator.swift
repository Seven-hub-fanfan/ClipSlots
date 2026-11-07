import SwiftUI
import ClipSlotsKit

struct AgentModelPresentation: Equatable {
    let name: String
    let backend: AgentBackendKind
    var icon: String {
        name.lowercased().contains("deepseek") ? "deepseek" : backend == .gateway ? "cpu" : "circle.hexagongrid"
    }
    static func current(scope: AgentBackendScope, defaults: UserDefaults = .standard) -> Self {
        let backend = AgentBackendCoordinator.kind(for: scope, defaults: defaults)
        let name: String
        switch backend {
        case .tika: name = "Tika Agent"
        case .gateway:
            name = defaults.string(forKey: AgentGatewayPreferences.modelKey) ?? AgentGatewayPreferences.defaultModel
        case .deepseek:
            name = AgentBackendCoordinator.directProfile(for: scope, defaults: defaults)?.model
                ?? defaults.string(forKey: AgentPreferences.modelKey) ?? AgentConfig.defaultModel
        }
        return .init(name: name, backend: backend)
    }
}

/// Both editors use the sidebar's model identity and artwork rules.
struct AgentModelIndicator: View {
    let presentation: AgentModelPresentation
    var body: some View {
        Group {
            if presentation.icon == "deepseek" {
                AgentBrandIcon(identifier: "deepseek", size: 19)
            } else {
                Image(systemName: presentation.icon).font(.system(size: 14))
            }
        }.foregroundColor(TapSkin.ink)
    }
}
