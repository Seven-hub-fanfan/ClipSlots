import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - 屏幕录制权限引导（v2.11.0）
//
// 背景：设置槽位缩略图的「截图」入口会 spawn `/usr/sbin/screencapture -i`。在 macOS 10.15+ 上
// TCC 归因到**发起进程**（也就是 ClipSlots），首次使用会弹系统的「ClipSlots 想要录制此电脑的
// 屏幕」授权弹窗。该系统弹窗是普通层级窗口，实测经常被 ClipSlots 主窗口压在后面，用户得手动
// 把窗口拖开才能找到它 —— 一个「点了截图什么都没发生」的死胡同。
//
// 处理方式与「辅助功能」引导保持一致（见 AccessibilityPermissionGuide）：
//   1. 截图**前**先 `CGPreflightScreenCaptureAccess()` 预检，未授权就根本不去触发系统弹窗；
//   2. 改为弹我们自己的引导面板，`level = .screenSaver` 保证它浮在 App 所有窗口之上
//      （主窗口 .normal / 轮盘与浮层 .floating / 附件面板 .popUpMenu 全部盖不住它）；
//   3. 面板上「打开系统设置」直跳「隐私与安全性 → 屏幕录制」，顺带调一次
//      `CGRequestScreenCaptureAccess()` 把 App 注册进该列表，避免用户到了设置页找不到条目。
//
// 刻意**不**用 `NSApp.runModal`：原因见 AccessibilityPermissionGuide 里 MODAL-STALL 的长注释
// （嵌套 run loop 会让整个 App 的主队列异步工作停摆）。这里同样用非模态 NSPanel + 静态持有。

/// 屏幕录制权限的**线程无关**查询/申请入口（可在后台线程调用）。
enum ScreenRecordingPermission {

    /// 当前进程是否已获得屏幕录制授权。不会弹任何系统 UI。
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// 向系统申请授权。副作用是把本 App 注册进「屏幕录制」列表；若状态未决定会弹系统弹窗。
    /// 只在用户主动点「打开系统设置」时调用 —— 此时用户已经知道要去哪儿，弹窗被盖住也无所谓。
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

@MainActor
enum ScreenRecordingPermissionGuide {

    /// 「隐私与安全性 → 屏幕录制」设置页。
    private static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    private static let prefPanePath = "/System/Library/PreferencePanes/Security.prefPane"

    /// 非模态展示期间持有面板，防止 `present()` 返回后被释放。关闭时置 nil。
    private static var guidePanel: NSPanel?

    static func openScreenRecordingSettings() {
        if let url = URL(string: settingsURLString), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: prefPanePath))
    }

    /// 弹出置顶引导面板。已在展示则只前置，不重复创建（幂等，可被多个截图入口安全调用）。
    static func present() {
        if let existing = guidePanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let card = ScreenRecordingGuideCard(
            onOpenSettings: {
                dismiss()
                // 先 request 再跳转：确保 ClipSlots 一定出现在屏幕录制列表里（未申请过的 App
                // 不会自动列出）。request 可能阻塞在系统弹窗上，派到后台。
                DispatchQueue.global(qos: .userInitiated).async {
                    ScreenRecordingPermission.request()
                    DispatchQueue.main.async { openScreenRecordingSettings() }
                }
            },
            onDismiss: { dismiss() }
        )

        let hosting = NSHostingView(rootView: card)
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: fitting.width > 0 ? fitting.width : 428,
            height: fitting.height > 0 ? fitting.height : 460
        )

        let panel = TopmostGuidePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        // 关键：必须盖过 App 内所有窗口 —— 轮盘/浮动提示是 .floating(3)、附件次级面板是
        // .popUpMenu(101)，.modalPanel(8) 挡不住后者，所以取 .screenSaver。
        panel.level = .screenSaver
        // 引导面板要跨 Space 跟随，且不能因为 App 失活就消失（用户可能正切到系统设置对照操作）。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.center()
        guidePanel = panel
        // 面板是主动响应用户操作弹出的，需要激活 App 才能拿到键盘焦点（回车 = 打开设置）。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// 关闭并释放（幂等）。
    static func dismiss() {
        guard let panel = guidePanel else { return }
        guidePanel = nil
        panel.orderOut(nil)
    }
}

/// borderless + nonactivating 的 NSPanel 默认 `canBecomeKey == false`，
/// 不显式放开的话按钮的键盘默认动作（回车）会失效。
private final class TopmostGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 引导卡片

private struct ScreenRecordingGuideCard: View {
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)

            VStack(spacing: 8) {
                Text("需要开启「屏幕录制」权限")
                    .font(.system(size: 21, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("ClipSlots 需要此权限才能截图并设为槽位缩略图。截图内容只会写入本机的槽位数据，不会上传。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                stepRow(number: 1, text: "前往「系统设置 → 隐私与安全性 → 屏幕录制」")
                stepRow(number: 2, text: "在列表中打开 ClipSlots 的开关（如无条目，点「+」添加 /Applications/ClipSlots.app）")
                stepRow(number: 3, text: "回到 ClipSlots 重新点一次「截图设为缩略图」")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)

            Text("macOS 可能要求退出并重新打开 ClipSlots 后权限才生效。")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Button(action: onOpenSettings) {
                    Text("打开系统设置")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button(action: onDismiss) {
                    Text("稍后再说")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
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
