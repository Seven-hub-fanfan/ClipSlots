import Foundation
import ClipSlotsKit

// UPD-LOOP (v2.10.92): 自动更新的「幂等护栏」偏好键 + 安装闸门实现。
//
// 为什么单独成文件：这两个键与既有业务偏好（拨杆 / 提示 / 游标）无关，它们属于**更新安全**
// 范畴，集中在一处便于审计「哪些状态能阻止一次安装」。键名沿用 `UserPreferenceKeys`
// 命名空间（extension），读写口径与全仓一致。
extension UserPreferenceKeys {

    /// 最近一次**已尝试安装**的目标版本（原始 tag，可能带 `v` 前缀）。
    ///
    /// 安装入口在真正挂载 / 替换 bundle 之前写入该键，并在下一次安装请求时据此拒绝对
    /// **同一目标版本**的重复安装。这样即便版本比对逻辑将来又出错（把相等误判为「有新版」），
    /// 也无法形成「装完重启 → 又判定要更新 → 再装」的无限重装循环：第二次就会被挡住。
    static let lastAttemptedUpdateVersion = "lastAttemptedUpdateVersion"

    /// 自动下载 / 安装总闸（止血用）。为 true 时安装入口直接拒绝执行。
    ///
    /// 线上若再出现异常重装，用户无需等新版本，一条命令即可立刻止血：
    ///     defaults write com.clipslots.app disableAutoUpdateInstall -bool true
    /// 恢复：
    ///     defaults write com.clipslots.app disableAutoUpdateInstall -bool false
    static let disableAutoUpdateInstall = "disableAutoUpdateInstall"
}

/// UPD-LOOP (v2.10.92): 把 `ClipSlotsKit.UpdateVersion.installGuard`（纯判定）与
/// `UserDefaults`（副作用）粘起来的薄封装。纯逻辑全部在 Kit 里、可被 smoke 测试覆盖；
/// 这里只负责读写偏好与打日志。
///
/// nonisolated / 静态方法：`UpdateInstaller` 在后台串行队列上调用它。
enum UpdateInstallGuardStore {

    /// 安装前置检查。返回 `.proceed` 时调用方才可继续安装。
    static func evaluate(targetTag: String, runningVersion: String) -> UpdateVersion.InstallGuard {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: UserPreferenceKeys.lastAttemptedUpdateVersion)
        let disabled = defaults.bool(forKey: UserPreferenceKeys.disableAutoUpdateInstall)
        return UpdateVersion.installGuard(targetTag: targetTag,
                                         runningVersion: runningVersion,
                                         lastAttemptedTag: last,
                                         autoInstallDisabled: disabled)
    }

    /// 记录「本次已尝试安装的目标版本」。必须在真正开始替换 bundle **之前**调用，
    /// 这样即使安装中途崩溃 / 装完重启后又被误判为需要更新，也已经留下去重依据。
    static func recordAttempt(targetTag: String) {
        UserDefaults.standard.set(targetTag, forKey: UserPreferenceKeys.lastAttemptedUpdateVersion)
        NSLog("[ClipSlots][Update] 已记录本次安装目标版本=\(targetTag)（同一版本不会重复安装）")
    }

    /// ★ UPD-LOOP-FIX (v2.10.92): 安装**失败**时清除去重记录，允许用户对同一版本重试。
    ///
    /// 为什么必须有这个：`recordAttempt` 是在动 bundle 之前写的，若不在失败路径清掉，一次偶发失败
    /// （hdiutil 挂载失败 / 版本校验中止 / 磁盘空间不足 / 授权被取消）就会把该版本**永久拉黑**，
    /// 之后合法更新永远被 `.skipAlreadyAttempted` 挡住 —— 那是把「同版本重装循环」修成了
    /// 「更新彻底堵死」，比原问题更糟。
    ///
    /// 防循环并不依赖这条记录：安装成功后运行版本就变了，`.skipSameAsRunning` 已经是硬闸门；
    /// `.skipAlreadyAttempted` 只负责挡「装完重启后立刻又被喂进同一目标」这种瞬时重复。
    static func clearAttempt(reason: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: UserPreferenceKeys.lastAttemptedUpdateVersion) != nil else { return }
        defaults.removeObject(forKey: UserPreferenceKeys.lastAttemptedUpdateVersion)
        NSLog("[ClipSlots][Update] 安装未完成，已清除去重记录以允许重试（原因：\(reason)）")
    }
}
