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
        // v2.9.22: 弹窗说明文字排版优化——精简文案、加大字号与行间距，改用 accessoryView
        //（NSAlert.informativeText 无法控制行距），减轻密集压迫感（不改触发/跳转逻辑）。
        alert.accessoryView = makeGuideAccessoryView()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "本次已知晓")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    /// v2.9.22: 用带段落行距、稍大字号的富文本承载说明，视觉更透气。
    private static func makeGuideAccessoryView() -> NSView {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 10

        let text = """
        ClipSlots 需要此权限来注册全局快捷键、模拟复制与粘贴。

        点击「打开设置」后：
        1. 在「隐私与安全性 → 辅助功能」中打开 ClipSlots 的开关
        2. 若列表里没有，点「+」添加 /Applications/ClipSlots.app

        无需重启即可生效；每次更新 App 后可能需要重新勾选。
        """

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = attributed
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.preferredMaxLayoutWidth = 360
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 168)
        return label
    }
}
