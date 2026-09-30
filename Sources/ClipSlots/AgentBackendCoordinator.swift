import Foundation
import SwiftUI
import ClipSlotsKit

// MARK: - Agent 后端协调器
//
// v2.17.7 起 ClipSlots 有两个 AI 后端：DeepSeek（默认）与 Tika。这个文件是**唯一**的构造入口，
// 保证：
//   - UI 与 AgentChatModel 都从这里拿 backend，不各自读 UserDefaults 重复解析；
//   - "切后端偏好保存 → 立刻生效"由 `applyPreferencesChange()` 广播 Notification 完成；
//   - 用户从来没配过 Tika 时，coordinator 会自动 fallback 到 DeepSeek，UI 也无感。
//
// 存的偏好走 @AppStorage 的三个键：
//   - `agent.backend.kind`   ("deepseek" / "tika")
//   - `agent.tika.agentId`
//   - `agent.tika.cliPath`   (默认 "tikacli")
// 详见 `TikaBackendPreferences`（Kit 层的常量，跨 App/Kit 复用一份）。

enum AgentBackendCoordinator {

    /// 读取当前 App 偏好，构造对应后端。**幂等**：连调多次会拿到不同实例但配置一致；
    /// AgentChatModel 每次切换会 keep 一个引用直到下次切换。
    static func currentBackend() -> any AgentBackend {
        let defaults = UserDefaults.standard
        let kindRaw = defaults.string(forKey: TikaBackendPreferences.backendKindKey) ?? AgentBackendKind.deepseek.rawValue
        let kind = AgentBackendKind(rawValue: kindRaw) ?? .deepseek

        switch kind {
        case .deepseek:
            return AgentService()
        case .tika:
            let cliPath = defaults.string(forKey: TikaBackendPreferences.tikaCLIPathKey)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "tikacli"
            let agentId = defaults.string(forKey: TikaBackendPreferences.tikaAgentIdKey)
                .flatMap { $0.isEmpty ? nil : $0 }
            let supplementalPrompt = defaults.string(forKey: TikaBackendPreferences.tikaSystemPromptKey) ?? ""
            let config = TikaBackendConfig(cliPath: cliPath,
                                           agentId: agentId,
                                           supplementalSystemPrompt: supplementalPrompt)
            return TikaCLIService(config: config)
        }
    }

    /// 当前配置下的后端类型。UI 可以拿它决定"要不要展示 Tika 分段"。
    static var currentKind: AgentBackendKind {
        let raw = UserDefaults.standard.string(forKey: TikaBackendPreferences.backendKindKey) ?? AgentBackendKind.deepseek.rawValue
        return AgentBackendKind(rawValue: raw) ?? .deepseek
    }

    /// 通知名。AgentConfigView 保存偏好后 post，AgentSessionStore 里的 model 收到后 setBackend。
    static let backendChangedNotification = Notification.Name("com.clipslots.agent.backendChanged")

    static func broadcastChange() {
        NotificationCenter.default.post(name: backendChangedNotification, object: nil)
    }
}
