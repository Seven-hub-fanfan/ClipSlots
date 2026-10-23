import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI
import ClipSlotsKit

enum AppPermission: String, CaseIterable, Identifiable {
    case accessibility, screenCapture
    var id: String { rawValue }
    var title: String { self == .accessibility ? "辅助功能" : "屏幕录制" }
    var detail: String {
        self == .accessibility ? "用于获取所选内容、模拟复制与粘贴" : "用于截图并设为槽位缩略图"
    }
    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_"
            + (self == .accessibility ? "Accessibility" : "ScreenCapture"))
    }
}

/// Only preflight APIs determine the displayed status. Request results, elapsed
/// time and dragging the app are never treated as proof of a system grant.
struct PermissionBackend {
    var preflight: (AppPermission) -> Bool
    var requestScreenCapture: () async -> Void
    var openSettings: (AppPermission) -> Bool
    var reset: (AppPermission) async throws -> Void = { try await PermissionRepairCoordinator.reset($0) }
    var requestAccessibility: () -> Void = {}

    static let system = PermissionBackend(
        preflight: { $0 == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess() },
        requestScreenCapture: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = CGRequestScreenCaptureAccess()
                    continuation.resume()
                }
            }
        },
        openSettings: {
            ($0.settingsURL.map { NSWorkspace.shared.open($0) } ?? false)
                || NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
        },
        requestAccessibility: {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    )
}

@MainActor
final class PermissionCenterModel: ObservableObject {
    static let shared = PermissionCenterModel()
    @Published private(set) var authorized: Set<AppPermission> = []
    @Published private(set) var requestingScreenCapture = false
    @Published private(set) var settingsPermission: AppPermission?
    @Published private(set) var error: String?
    @Published private(set) var repairing: AppPermission?
    @Published private(set) var repairNotice: String?
    private let backend: PermissionBackend
    private var didRequestScreenCapture = false
    private var interaction = UUID()
    private var repairTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var monitoringUsers = 0
    var onRefresh: (() -> Void)?

    init(backend: PermissionBackend = .system) {
        self.backend = backend
        refresh()
    }

    func refresh() {
        let next = Set(AppPermission.allCases.filter { backend.preflight($0) })
        if next != authorized { authorized = next }
        onRefresh?()
    }

    func startMonitoring() {
        monitoringUsers += 1
        guard monitoringUsers == 1 else { return }
        refresh()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        let polling = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Poll only while our UI or System Settings is in use.
                let front = NSWorkspace.shared.frontmostApplication
                guard front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    || front?.bundleIdentifier == "com.apple.systempreferences" else { return }
                self?.refresh()
            }
        }
        polling.tolerance = 0.2
        RunLoop.main.add(polling, forMode: .common)
        timer = polling
    }

    func stopMonitoring() {
        monitoringUsers = max(0, monitoringUsers - 1)
        guard monitoringUsers == 0 else { return }
        timer?.invalidate()
        timer = nil
        if let observer = observers.first { NotificationCenter.default.removeObserver(observer) }
        if observers.count > 1 { NSWorkspace.shared.notificationCenter.removeObserver(observers[1]) }
        observers.removeAll()
    }

    func authorize(_ permission: AppPermission) {
        refresh()
        guard repairing == nil, !authorized.contains(permission) else { return }
        guard permission != .screenCapture || !requestingScreenCapture else { return }
        interaction = UUID()
        beginAuthorization(permission)
    }

    private func beginAuthorization(_ permission: AppPermission, afterRepair: Bool = false) {
        settingsPermission = permission
        if afterRepair && permission == .accessibility { backend.requestAccessibility() }
        error = backend.openSettings(permission) ? nil : "未能打开系统设置，请在「隐私与安全性」中打开\(permission.title)。"
        onRefresh?()
        // Accessibility can be added directly with the real app-file drag.
        // The screen request may block on native UI: await it away from the
        // main queue, once per process, without opening Settings again later.
        guard permission == .screenCapture, !didRequestScreenCapture else { return }
        didRequestScreenCapture = true
        requestingScreenCapture = true
        Task {
            await backend.requestScreenCapture()
            requestingScreenCapture = false
            refresh()
        }
    }

    func repair(_ permission: AppPermission) {
        refresh()
        guard repairing == nil, !requestingScreenCapture, !authorized.contains(permission) else { return }
        let token = UUID()
        interaction = token
        repairing = permission
        settingsPermission = nil
        error = nil
        repairNotice = "正在清除\(permission.title)的旧记录…"
        onRefresh?()
        repairTask = Task {
            do {
                try await backend.reset(permission)
                // A successful reset allows exactly one new screen request,
                // even when the old native request had previously been denied.
                if permission == .screenCapture { didRequestScreenCapture = false }
                guard interaction == token, !Task.isCancelled else {
                    repairing = nil
                    return
                }
                repairing = nil
                repairNotice = "旧记录已清除，请在系统中重新允许\(permission.title)。"
                refresh()
                if !authorized.contains(permission) { beginAuthorization(permission, afterRepair: true) }
            } catch {
                repairing = nil
                guard interaction == token, !Task.isCancelled else { return }
                repairNotice = nil
                self.error = error.localizedDescription
                onRefresh?()
            }
            repairTask = nil
        }
    }

    func stopGuiding() {
        interaction = UUID()
        repairTask?.cancel()
        settingsPermission = nil
        error = nil
        repairNotice = nil
        onRefresh?()
    }
}

@MainActor
enum PermissionCenter {
    static let model = PermissionCenterModel.shared
    static let cardSize = CGSize(width: 480, height: 526)
    static let helperSize = CGSize(width: 430, height: 156)
    private(set) static var panel: NSPanel?
    private(set) static var helper: NSPanel?
    private static var helperPermission: AppPermission?
    private static var dismissedHelperPermission: AppPermission?
    static var draggingApplication = false
    private static weak var pressedApplicationCard: PermissionFileDragView?

    static func beginApplicationPress(_ view: PermissionFileDragView) {
        pressedApplicationCard = view
    }

    static func endApplicationPress(_ view: PermissionFileDragView) {
        if pressedApplicationCard === view { pressedApplicationCard = nil }
    }

    static func present(for permission: AppPermission? = nil, afterUpdate: Bool = false) {
        model.refresh()
        if let existing = panel {
            (existing.contentView as? NSHostingView<PermissionCenterCard>)?.rootView =
                PermissionCenterCard(model: model, purpose: permission, afterUpdate: afterUpdate, onClose: dismiss)
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let card = PermissionCenterCard(model: model, purpose: permission, afterUpdate: afterUpdate,
                                        onClose: dismiss)
        let window = PermissionPanel(contentRect: NSRect(origin: .zero, size: cardSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        configure(window, identifier: "clipslots-permission-center", hidesOnDeactivate: false)
        window.contentView = NSHostingView(rootView: card)
        window.center()
        panel = window
        model.onRefresh = { updateHelper() }
        model.startMonitoring()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        guard let existing = panel else { return }
        panel = nil
        existing.orderOut(nil)
        hideHelper()
        model.stopGuiding()
        model.stopMonitoring()
        model.onRefresh = nil
        dismissedHelperPermission = nil
    }

    static func authorize(_ permission: AppPermission) {
        if panel == nil { present(for: permission) }
        dismissedHelperPermission = nil
        model.authorize(permission)
    }

    static func repair(_ permission: AppPermission) {
        if panel == nil { present(for: permission) }
        dismissedHelperPermission = nil
        model.repair(permission)
    }

    static func revealApplication() {
        guard let url = PermissionApplicationFile.currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func configure(_ window: NSPanel, identifier: String, hidesOnDeactivate: Bool) {
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = hidesOnDeactivate
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    private static func hideHelper() {
        helper?.orderOut(nil)
        helper = nil
        helperPermission = nil
    }

    private static func updateHelper() {
        let front = NSWorkspace.shared.frontmostApplication
        let screens = NSScreen.screens
        updateHelper(using: model, frontPID: front?.processIdentifier,
            frontBundleID: front?.bundleIdentifier,
            settingsFrame: PermissionHelperGeometry.settingsFrame(
                pid: front?.processIdentifier, desktopTop: screens.first?.frame.maxY ?? 0),
            visibleFrames: screens.map(\.visibleFrame))
    }

    private static func updateHelper(using state: PermissionCenterModel, frontPID: pid_t?,
                                     frontBundleID: String?, settingsFrame: CGRect?,
                                     visibleFrames: [CGRect]) {
        // Freeze from mouse-down, including the movement below the native
        // drag threshold. Polling must not move the card out from under a press.
        guard !draggingApplication, pressedApplicationCard == nil else { return }
        if frontPID == ProcessInfo.processInfo.processIdentifier {
            if panel?.isVisible == false { panel?.orderFront(nil) }
        } else {
            panel?.orderOut(nil)
        }
        guard panel != nil, let permission = state.settingsPermission ?? state.repairing,
              !state.authorized.contains(permission),
              dismissedHelperPermission != permission else { hideHelper(); return }
        guard frontBundleID == "com.apple.systempreferences" else {
            helper?.orderOut(nil)
            return
        }
        if helperPermission != permission {
            hideHelper()
            let window = PermissionHelperPanel(contentRect: NSRect(origin: .zero, size: helperSize),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(window, identifier: "clipslots-permission-drag-helper", hidesOnDeactivate: false)
            window.isMovableByWindowBackground = false
            window.isMovable = false
            window.contentView = NSHostingView(rootView: PermissionDragHelper(
                model: state, permission: permission,
                onClose: {
                    dismissedHelperPermission = permission
                    state.stopGuiding()
                    hideHelper()
                }, onRepair: { state.repair($0) }))
            helper = window
            helperPermission = permission
        }
        guard let helper else { return }
        guard let frame = PermissionHelperGeometry.guideFrame(size: helperSize,
            settings: settingsFrame, visibleFrames: visibleFrames) else {
            helper.orderOut(nil)
            return
        }
        // Settings always gets the actual drag card. The large status panel
        // must never suppress the only file-drag source on a wide display.
        if helper.frame != frame {
            // Avoid an in-flight docking animation continuing after mouse-down.
            helper.setFrame(frame, display: true)
        }
        if !helper.isVisible { helper.orderFrontRegardless() }
    }

    #if DEBUG
    static func updateHelperForTesting(using state: PermissionCenterModel, settingsFrame: CGRect?,
                                       visibleFrames: [CGRect], frontBundleID: String) {
        updateHelper(using: state, frontPID: nil, frontBundleID: frontBundleID,
                     settingsFrame: settingsFrame, visibleFrames: visibleFrames)
    }
    #endif
}

private final class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { PermissionCenter.dismiss() }
}

private final class PermissionHelperPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

enum PermissionApplicationFile {
    static var currentURL: URL? { validated(Bundle.main.bundleURL) }
    static func validated(_ url: URL) -> URL? {
        var directory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              directory.boolValue,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
        else { return nil }
        return url
    }
    static func pasteboardWriter(for url: URL) -> NSPasteboardWriting? {
        guard let app = validated(url) else { return nil }
        return app as NSURL
    }
}

enum PermissionHelperGeometry {
    static func companionFrame(size: CGSize, settings: CGRect, visible: CGRect) -> CGRect? {
        guard visible.width >= size.width + 16, visible.height >= size.height + 16 else { return nil }
        let left = min(settings.minX - size.width - 16, visible.maxX - size.width - 8)
        let right = max(settings.maxX + 16, visible.minX + 8)
        let y = min(max(settings.midY - size.height / 2, visible.minY + 8), visible.maxY - size.height - 8)
        for x in [left, right] {
            let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if visible.contains(candidate), !candidate.intersects(settings) { return candidate }
        }
        return nil
    }

    static func guideFrame(size: CGSize, settings: CGRect?, visibleFrames: [CGRect]) -> CGRect? {
        guard let settings else { return nil }
        let screens = visibleFrames.sorted {
            let left = $0.intersection(settings), right = $1.intersection(settings)
            return left.width * left.height > right.width * right.height
        }
        for screen in screens {
            if let candidate = frame(size: size, settings: settings, visible: screen) { return candidate }
        }
        return nil
    }

    static func frame(size: CGSize, settings: CGRect?, visible: CGRect) -> CGRect? {
        guard let settings else { return nil }
        if let side = companionFrame(size: size, settings: settings, visible: visible),
           visible.contains(side), !side.intersects(settings) { return side }
        let x = min(max(settings.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        for y in [settings.minY - size.height - 12, settings.maxY + 12] {
            let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if visible.contains(candidate), !candidate.intersects(settings) { return candidate }
        }
        // Full-screen/narrow Settings: hide the helper rather than obscure
        // permission switches. The app retains the same explicit repair entry.
        return nil
    }

    static func settingsFrame(pid: pid_t?, desktopTop: CGFloat) -> CGRect? {
        guard let pid, let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Public window bounds remain available when screen capture is denied;
        // no AX UI traversal or permission request is needed for placement.
        return windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let data = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: data),
                  bounds.width > 300, bounds.height > 200 else { return nil }
            return CGRect(x: bounds.minX, y: desktopTop - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
}

struct PermissionCenterCard: View {
    @ObservedObject var model: PermissionCenterModel
    var purpose: AppPermission? = nil
    var afterUpdate = false
    var onClose: () -> Void
    var onAuthorize: (AppPermission) -> Void = { PermissionCenter.authorize($0) }
    var onRepair: (AppPermission) -> Void = { PermissionCenter.repair($0) }
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppSkin.defaultsKey) private var skin = AppSkin.fallback.rawValue
    private var surface: Color { scheme == .dark ? Color(white: 0.12) : .white }
    private var ink: Color { scheme == .dark ? .white : Color(white: 0.12) }
    private var description: String {
        if afterUpdate { return "应用已更新，请检查以下权限。\n辅助功能旧记录会在需要时自动清除，随后由你在系统中确认。" }
        if purpose == .accessibility { return "获取所选内容与模拟复制粘贴，需要辅助功能权限。\n授权后，请重新执行刚才的操作。" }
        if purpose == .screenCapture { return "截图设为缩略图，需要屏幕录制权限。\n授权后，请重新点击截图；macOS 可能要求重新打开应用。" }
        return "使用复制粘贴与截图功能，需要授予对应的权限。\n你可以按需开启，授权状态会自动更新。"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13)).frame(width: 28, height: 28)
                }.buttonStyle(.plain).help("关闭").accessibilityLabel("关闭权限面板")
                    .accessibilityIdentifier("permission-close").keyboardShortcut(.cancelAction)
            }.padding(.top, 12).padding(.trailing, 12)
            HStack(spacing: 18) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 46, height: 46)
                Image(systemName: "link").font(.system(size: 17)).foregroundColor(.secondary)
                Image(systemName: "desktopcomputer").font(.system(size: 29))
                    .foregroundColor(AppTheme.chromeAccentInk).frame(width: 50, height: 50)
                    .background(ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }.accessibilityHidden(true).padding(.top, 4)
            Text("连接 ClipSlots").font(.system(size: 21, weight: .semibold)).padding(.top, 18)
            Text("系统权限").font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 6)
            Text(description).font(.system(size: 12)).lineSpacing(5).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 18)
            PermissionRows(model: model, onAuthorize: onAuthorize, onRepair: onRepair)
                .padding(.top, 16)
            PermissionApplicationDragSection(model: model).padding(.top, 12)
            HStack(spacing: 6) {
                if let error = model.error {
                    Text(error).foregroundColor(.red)
                } else if let notice = model.repairNotice {
                    Text(notice).foregroundColor(.secondary)
                } else {
                    Text(model.authorized.count == 2 ? "权限已就绪，可继续使用。" : "授权后自动更新 · 可在设置中随时查看")
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("重新检查权限").accessibilityLabel("重新检查权限")
                    .accessibilityIdentifier("permission-refresh")
            }.font(.system(size: 10.5)).padding(.top, 12)
            Spacer(minLength: 14)
        }
        .padding(.horizontal, 24).frame(width: PermissionCenter.cardSize.width,
                                       height: PermissionCenter.cardSize.height)
        .foregroundColor(ink)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ink.opacity(0.08), lineWidth: 1))
    }
}

struct PermissionRows: View {
    @ObservedObject var model: PermissionCenterModel
    var onAuthorize: (AppPermission) -> Void = { PermissionCenter.authorize($0) }
    var onRepair: (AppPermission) -> Void = { PermissionCenter.repair($0) }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            ForEach(AppPermission.allCases) { permission in
                if permission == .screenCapture { Divider() }
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20)).foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Color(white: 0.58), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(permission.title).font(.system(size: 12, weight: .semibold))
                        Text(permission.detail).font(.system(size: 11)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if model.authorized.contains(permission) {
                        HStack(spacing: 6) {
                            Text("已授权")
                            Circle().fill(Color(red: 0.16, green: 0.65, blue: 0.49)).frame(width: 5, height: 5)
                        }.font(.system(size: 11, weight: .medium))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(permission.title)，已授权")
                            .accessibilityIdentifier("permission-status-\(permission.rawValue)")
                    } else {
                        VStack(spacing: 5) {
                            Button { onAuthorize(permission) } label: {
                                HStack(spacing: 5) {
                                    Text(model.repairing == permission ? "修复中…" :
                                        model.requestingScreenCapture && permission == .screenCapture ? "等待授权" : "去授权")
                                    Image(systemName: "arrow.up.right.square")
                                }.font(.system(size: 11, weight: .medium))
                                    .foregroundColor(scheme == .dark ? .black : .white)
                                    .padding(.horizontal, 10).frame(height: 27)
                                    .background(scheme == .dark ? Color(white: 0.92) : Color(white: 0.17),
                                                in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                                .disabled(model.repairing != nil || permission == .screenCapture && model.requestingScreenCapture)
                                .accessibilityLabel("\(permission.title)，未授权，打开系统设置")
                                .accessibilityIdentifier("permission-authorize-\(permission.rawValue)")
                            Button("修复此项授权") { onRepair(permission) }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary)
                                .disabled(model.repairing != nil || model.requestingScreenCapture)
                                .help("清除 ClipSlots 此项授权记录并重新申请；需要系统确认。")
                                .accessibilityLabel("修复\(permission.title)：清除 ClipSlots 此项记录并重新申请，需要系统确认")
                                .accessibilityIdentifier("permission-repair-\(permission.rawValue)")
                        }
                    }
                }.padding(.horizontal, 16).frame(minHeight: 72)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct PermissionSettingsSection: View {
    @ObservedObject private var model = PermissionCenterModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("系统权限").font(.system(size: 18, weight: .semibold))
            Text("复制粘贴与截图按需使用以下权限，状态以 macOS 当前进程的授权为准。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            PermissionRows(model: model)
            PermissionApplicationDragSection(model: model)
            Text("开关已开启但功能不可用时，可修复此项授权。修复会清除 ClipSlots 此项现有记录并重新申请，需要系统确认。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            if let message = model.error ?? model.repairNotice {
                Text(message).font(.system(size: 11)).foregroundColor(model.error == nil ? .secondary : .red)
            }
            Button("打开权限面板") { PermissionCenter.present() }
                .accessibilityIdentifier("permission-center-open")
            Text("文件与目录访问")
                .font(.system(size: 13, weight: .semibold)).padding(.top, 6)
            Text("导入文件时通过系统选择器选择。Agent 工作目录可在会话中的「添加本地目录」里选择、重新授权或移除；写入操作仍由你确认。")
                .font(.system(size: 12)).foregroundColor(.secondary).lineSpacing(4)
            Text("安装 CLI、更新应用等操作，仅在需要写入受保护位置时由 macOS 请求管理员授权。")
                .font(.system(size: 12)).foregroundColor(.secondary).lineSpacing(4)
        }
        .onAppear { model.startMonitoring() }
        .onDisappear { model.stopMonitoring() }
    }
}

struct PermissionDragHelper: View {
    @ObservedObject var model: PermissionCenterModel
    var permission: AppPermission
    var onClose: () -> Void
    var onRepair: (AppPermission) -> Void = { PermissionCenter.repair($0) }
    @AppStorage(AppSkin.defaultsKey) private var skin = AppSkin.fallback.rawValue
    private var accent: Color {
        AppSkin(rawValue: skin) == .minimal ? AppTheme.minimalControlInk : TapSkin.accent
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines").font(.system(size: 20, weight: .bold))
                    .foregroundColor(accent)
                Text(model.repairing == permission ? "正在自动清除「\(permission.title)」旧记录" :
                    model.repairNotice != nil ? "已清除旧记录，请开启「\(permission.title)」" :
                    "拖入系统列表，开启「\(permission.title)」")
                    .font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("关闭拖动引导").accessibilityLabel("关闭拖动引导")
                    .accessibilityIdentifier("permission-helper-close")
            }
            if let url = PermissionApplicationFile.currentURL {
                PermissionAppDragView(url: url, enabled: model.repairing == nil).frame(height: 39)
            } else {
                Text("请从访达中拖入当前运行的 ClipSlots.app").font(.system(size: 12))
            }
            HStack {
                Button(model.repairing == permission ? "正在清除旧记录…" : "清除旧记录并重新授权") {
                    onRepair(permission)
                }.buttonStyle(.plain).font(.system(size: 11))
                    .foregroundColor(accent)
                    .disabled(model.repairing != nil || model.requestingScreenCapture
                              || model.authorized.contains(permission))
                    .help("仅清除 ClipSlots 此项权限记录，然后重新申请；需要系统确认。")
                    .accessibilityLabel("清除 ClipSlots 的\(permission.title)旧记录并重新授权，需要系统确认")
                    .accessibilityIdentifier("permission-helper-repair-\(permission.rawValue)")
                Spacer()
                Button("在访达中显示") { PermissionCenter.revealApplication() }
                    .buttonStyle(.plain).font(.system(size: 10)).accessibilityIdentifier("permission-reveal-app")
            }
            Text(model.error ?? model.repairNotice ?? "开关已开启但无效时，可清除旧记录；仍需系统确认。")
                .font(.system(size: 10)).foregroundColor(model.error == nil ? .secondary : .red)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).frame(width: PermissionCenter.helperSize.width, height: PermissionCenter.helperSize.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.13), lineWidth: 1))
    }
}

struct PermissionApplicationDragSection: View {
    @ObservedObject var model: PermissionCenterModel
    var body: some View {
        if model.authorized.count < AppPermission.allCases.count,
           let url = PermissionApplicationFile.currentURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("按住下方应用卡片，拖入系统权限列表")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                PermissionAppDragView(url: url, enabled: model.repairing == nil).frame(height: 39)
            }
        }
    }
}

struct PermissionAppDragView: NSViewRepresentable {
    var url: URL
    var enabled = true
    func makeNSView(context: Context) -> PermissionFileDragView {
        let view = PermissionFileDragView(url: url)
        view.dragEnabled = enabled
        return view
    }
    func updateNSView(_ view: PermissionFileDragView, context: Context) { view.dragEnabled = enabled }
}

/// A real file URL on NSPasteboard. A SwiftUI text drag only adds text to Settings
/// and cannot register the application in the privacy list.
final class PermissionFileDragView: NSView, NSDraggingSource {
    let url: URL
    var dragEnabled = true {
        didSet {
            if !dragEnabled { endPress() }
            setAccessibilityEnabled(dragEnabled)
            needsDisplay = true
        }
    }
    private var down: NSPoint?
    private let icon: NSImage
    init(url: URL) {
        self.url = url
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("拖动 ClipSlots 应用到系统权限列表；也可在访达中显示")
        setAccessibilityIdentifier("permission-app-drag")
        toolTip = url.path
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endPress() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func endPress() {
        down = nil
        PermissionCenter.endApplicationPress(self)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.withAlphaComponent(0.75).setFill()
        rounded.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        rounded.stroke()
        icon.draw(in: NSRect(x: 10, y: 7, width: 25, height: 25),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ("ClipSlots" as NSString).draw(at: NSPoint(x: 44, y: 11), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        ((dragEnabled ? "（按住拖入系统列表）" : "（正在清除旧记录…）") as NSString).draw(at: NSPoint(x: 108, y: 12), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
    override func mouseDown(with event: NSEvent) {
        guard dragEnabled else { return }
        down = convert(event.locationInWindow, from: nil)
        PermissionCenter.beginApplicationPress(self)
    }
    override func mouseUp(with event: NSEvent) {
        endPress()
        PermissionCenter.model.refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, let start = down,
              let writer = PermissionApplicationFile.pasteboardWriter(for: url) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds, contents: image)
        PermissionCenter.draggingApplication = true
        endPress()
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        PermissionCenter.draggingApplication = false
        PermissionCenter.model.refresh()
    }
    override func accessibilityPerformPress() -> Bool {
        guard dragEnabled else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
