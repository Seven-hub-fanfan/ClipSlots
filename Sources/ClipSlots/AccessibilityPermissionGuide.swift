import Foundation
import AppKit

// v2.9.8: 方案 Y — Accessibility permission guidance on launch.
//
// Every launch we check `AXIsProcessTrusted()`. If the app is NOT trusted
// (permission revoked or never granted — which frequently happens after an
// app update because macOS ties the grant to the binary), we:
//   1. open the system Accessibility settings pane, and
//   2. show a clear in-app guide alert telling the user exactly what to do
//      (find ClipSlots → enable the checkbox).
//
// This removes the pain of users hunting through System Settings after every
// update wondering why hotkeys stopped working.
@MainActor
enum AccessibilityPermissionGuide {

    /// System Preferences / Settings Accessibility pane.
    private static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let prefPanePath = "/System/Library/PreferencePanes/Security.prefPane"

    /// v2.9.9: 保证一个进程生命周期内只引导一次。ContentView 的 onAppear 可能重复触发
    /// （窗口重建 / 场景切换），若不加此守卫会重复弹窗骚扰用户。
    private static var didGuide = false

    /// Call once on app launch (from the App scene onAppear).
    static func checkAndGuideOnLaunch() {
        guard !didGuide else { return }
        didGuide = true
        // Small delay so the main window is on screen before the alert appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !AXIsProcessTrusted() else { return }
            // v2.9.9: 先弹说明 alert，由用户主动点「打开设置」再跳转，避免一启动就被弹到系统设置。
            presentGuideAlert()
        }
    }

    /// Open the Accessibility settings page. Prefer the modern URL scheme, fall
    /// back to opening the Security preference pane directly.
    static func openAccessibilitySettings() {
        if let url = URL(string: settingsURLString), NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: prefPanePath))
    }

    private static func presentGuideAlert() {
        let alert = NSAlert()
        alert.messageText = "需要开启「辅助功能」权限"
        alert.informativeText = """
        ClipSlots 需要「辅助功能」权限才能注册全局快捷键、模拟复制/粘贴。

        点击下方「打开设置」后，请按以下步骤操作：

        1. 在「隐私与安全性 → 辅助功能」列表中找到 ClipSlots
        2. 打开 ClipSlots 右侧的开关（勾选启用）
        3. 若列表里没有 ClipSlots，点击「+」手动添加 /Applications/ClipSlots.app
        4. 完成后无需重启，快捷键即可恢复使用

        （每次更新 App 后，macOS 可能会重置该权限，需重新勾选。）
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "本次已知晓")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
