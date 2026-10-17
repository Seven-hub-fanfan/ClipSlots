import CoreGraphics

/// Background screenshot paths use the real process preflight directly.
enum ScreenRecordingPermission {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }
}

@MainActor
enum ScreenRecordingPermissionGuide {
    static func openScreenRecordingSettings() { PermissionCenter.authorize(.screenCapture) }
    static func present() { PermissionCenter.present(for: .screenCapture) }
    static func dismiss() { PermissionCenter.dismiss() }
}
