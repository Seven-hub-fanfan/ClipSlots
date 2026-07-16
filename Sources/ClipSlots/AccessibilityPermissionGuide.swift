import Foundation
import AppKit
import SwiftUI

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

    // v2.9.25: 权限弹窗彻底视觉重做——用自定义 SwiftUI 磁玻璃面板替换 NSAlert：
    // 顶部 48pt+ 大图标、加大加粗标题、宽松行距副文本、数字圆圈步骤列表、
    // 蓝色填充主按钮 +「本次已知晓」文字次要按钮、16pt+ 圆角与充裕内边距。
    private static func presentGuideAlert() {
        var didOpenSettings = false

        let card = AccessibilityGuideCard(
            onOpenSettings: {
                didOpenSettings = true
                NSApp.stopModal()
            },
            onDismiss: {
                NSApp.stopModal()
            }
        )

        let hosting = NSHostingView(rootView: card)
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: fitting.width > 0 ? fitting.width : 428,
            height: fitting.height > 0 ? fitting.height : 480
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        if didOpenSettings {
            openAccessibilitySettings()
        }
    }
}

// MARK: - v2.9.25 Custom permission guide card

private struct AccessibilityGuideCard: View {
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)

            VStack(spacing: 8) {
                Text("需要开启「辅助功能」权限")
                    .font(.system(size: 21, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("ClipSlots 需要此权限来注册全局快捷键、模拟复制与粘贴。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                stepRow(number: 1, text: "在「隐私与安全性 → 辅助功能」中打开 ClipSlots 的开关")
                stepRow(number: 2, text: "若列表里没有，点「+」添加 /Applications/ClipSlots.app")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)

            Text("无需重启即可生效；每次更新 App 后可能需要重新勾选。")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Button(action: onOpenSettings) {
                    Text("打开设置")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button(action: onDismiss) {
                    Text("本次已知晓")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 372)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // v2.9.25 hotfix: 阴影从 radius 26 / opacity 0.28 收敛到 radius 10 / opacity 0.15，
        // 避免浅色模式下大面积扩散产生灰色"脏边"，保持轻盈克制的投影。
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(24)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
