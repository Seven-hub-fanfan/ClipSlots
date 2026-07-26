import Foundation
import SwiftUI
import AppKit
import ClipSlotsKit

// v2.9.46: 从设置页「命令行工具」的卸载区域一键卸载 ClipSlots。
//
// 卸载流程（按勾选项依次执行）：
//   1. 删除槽位数据（App 数据目录 ~/.local/share/clipslots，位于 home，无需鉴权）；
//   2. 卸载所有 Agent Skill（删除各 Agent skill 目录，位于 home，无需鉴权）；
//   3. 卸载 CLI（删除 /usr/local/bin/clipslots，写 /usr/local/bin 可能需要管理员权限，
//      因此走 macOS 系统鉴权弹窗）；
//   4. 用 NSWorkspace 把 App bundle（通常为 /Applications/ClipSlots.app）移入废纸篓；
//   5. NSApp.terminate(nil) 退出。
@MainActor
final class AppUninstaller: ObservableObject {

    @Published var isBusy = false

    private let fm = FileManager.default

    /// 执行卸载。`skillManager` 复用设置页已有的实例以删除 Agent skill 目录。
    func performUninstall(deleteData: Bool,
                          uninstallCLI: Bool,
                          uninstallSkills: Bool,
                          skillManager: AgentSkillInstallManager) {
        isBusy = true

        // P1-4 (v2.10.6): 调整卸载顺序——把「可能弹出且可取消的管理员鉴权」提到不可逆删除之前。
        // 旧流程先删数据 / Skill，再走 CLI 的管理员鉴权，用户在鉴权弹窗点「取消」时会留下
        // 「数据已删、App 未卸载」的半损坏状态。现在：先做需要鉴权的 CLI 移除，鉴权成功后
        // 才执行删数据 / 删 Skill / 移废纸篓；用户取消鉴权则一切原样，isBusy 复位可重试。
        let destructiveCleanupThenTrash: () -> Void = { [weak self] in
            guard let self = self else { return }
            // 1) 删除槽位数据（home 目录，无需鉴权）
            if deleteData {
                try? self.fm.removeItem(at: ClipSlotsPaths.dataRoot)
            }
            // 2) 删除各 Agent skill 目录（home 目录，无需鉴权）
            if uninstallSkills {
                skillManager.removeAllSkillDirectoriesSilently()
            }
            // 3) 移入废纸篓并退出
            self.finishByTrashingApp()
        }

        if uninstallCLI {
            // 先鉴权：只有管理员鉴权通过（未取消）后，才在 completion 里执行删数据 / Skill。
            runPrivilegedCLIRemoval(completion: destructiveCleanupThenTrash)
        } else {
            // 无需鉴权的分支：没有可取消的中途步骤，直接删数据 / Skill 再 trash。
            destructiveCleanupThenTrash()
        }
    }

    // MARK: - CLI 移除（系统鉴权弹窗）

    private func runPrivilegedCLIRemoval(completion: @escaping () -> Void) {
        let target = CLIInstallManager.targetPath
        // v2.10.3 (P2): safely single-quote the path (handles embedded quotes) so the
        // shell command can't be broken/injected by an unusual install path.
        let quotedTarget = "'" + target.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shellCommand = "rm -f \(quotedTarget)"
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        // P1-1 (v2.10.5): NSAppleScript 非线程安全，必须在主线程构造并执行——与
        // CLIInstallManager.runPrivileged（v2.10.4 P0-2 修复）保持一致。此前放在后台
        // 队列执行是同一崩溃反模式；且卸载路径更危险：崩溃发生在步骤1/2 已删除用户数据
        // 之后，会留下「数据已删、App 未卸载」的半损坏状态。
        DispatchQueue.main.async { [weak self] in
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&errorInfo)
            // P2-7: 鉴权失败/取消时复位 isBusy 让用户可重试，不继续 trash App。
            if errorInfo != nil {
                self?.isBusy = false
                return
            }
            completion()
        }
    }

    // MARK: - 移入废纸篓并退出

    private func finishByTrashingApp() {
        // 使用运行中 App 的真实 bundle 路径（正常安装位置为 /Applications/ClipSlots.app）。
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appURL]) { [weak self] _, error in
            DispatchQueue.main.async {
                // P2-7: 移入废纸篓失败时复位 isBusy 让用户可重试，不退出。
                if error != nil {
                    self?.isBusy = false
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
