import Foundation
import ClipSlotsKit

/// A reset removes a decision; it never grants a permission. This entry point
/// is called only by the explicit, per-permission repair action.
enum PermissionRepairCoordinator {
    static let bundleIdentifier = "com.clipslots.app"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func arguments(for permission: AppPermission, bundleID: String) throws -> [String] {
        guard bundleID == bundleIdentifier else {
            throw Failure(message: "此副本不是正式安装的 ClipSlots，未清除任何授权。")
        }
        return ["reset", permission == .accessibility ? "Accessibility" : "ScreenCapture", bundleID]
    }

    static func reset(_ permission: AppPermission) async throws {
        let bundle = Bundle.main
        let arguments = try arguments(for: permission, bundleID: bundle.bundleIdentifier ?? "")
        guard PermissionApplicationFile.currentURL?.resolvingSymlinksInPath().path
                == "/Applications/ClipSlots.app" else {
            throw Failure(message: "请先将 ClipSlots 安装到「应用程序」，再修复此项授权。")
        }
        do {
            let output = try await ToolProcess.run("/usr/bin/tccutil", arguments,
                                                   timeout: 12, outputLimit: 16_384)
            guard output.status == 0, !output.stopped else {
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: "未能清除\(permission.title)记录（退出码 \(output.status)）。"
                    + (detail.isEmpty ? "请在系统设置中检查此项权限。" : String(detail.prefix(220))))
            }
        } catch ToolProcess.Failure.timeout {
            throw Failure(message: "清除\(permission.title)记录超时。请检查系统设置后手动重试。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(message: error.localizedDescription)
        }
    }
}
