import Foundation

// v2.9.9: 统一版本号来源。
// 单一事实来源为 Info.plist 的 CFBundleShortVersionString（构建时注入），
// 避免多处硬编码导致版本号不一致。若读取失败（极少数场景）回退到编译期常量。
enum AppVersion {
    /// 编译期回退值，仅在无法从 Bundle 读取时使用。发布流水线会同步更新 Info.plist。
    static let fallback = "2.9.45"

    /// 当前运行版本，动态读取自 Bundle.main。
    static var current: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        return fallback
    }
}
