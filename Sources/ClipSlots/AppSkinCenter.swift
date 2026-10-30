import Foundation
import ClipSlotsKit

/// 历史风格设置的兼容入口。界面仅使用简洁外观，无需重建视图或提交编辑器。
enum AppSkinCenter {
    static let current: AppSkin = AppSkin.load(from: .standard)
    static let didChangeNotification = Notification.Name("ClipSlotsAppSkinDidChange")

    static func apply(_ skin: AppSkin) {
        skin.store(in: .standard)
    }

    static func syncFromDefaults() {
        _ = AppSkin.load(from: .standard)
    }
}
