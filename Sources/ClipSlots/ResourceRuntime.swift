import AppKit
import ClipSlotsKit

/// Lifecycle coordination lives outside AppDelegate and never touches generation jobs.
final class ResourceRuntime {
    static let shared = ResourceRuntime()
    private var observers: [NSObjectProtocol] = []
    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private func refresh() {
        // An inactive but visible canvas still needs responsive previews.
        ResourceBudget.shared.setActivity(background: NSApp.isHidden,
                                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
