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

        // 1) 删除槽位数据（home 目录，无需鉴权）
        if deleteData {
            try? fm.removeItem(at: ClipSlotsPaths.dataRoot)
        }

        // 2) 删除各 Agent skill 目录（home 目录，无需鉴权）
        if uninstallSkills {
            skillManager.removeAllSkillDirectoriesSilently()
        }

        // 3) CLI 需要写 /usr/local/bin，可能需要管理员权限
        if uninstallCLI {
            runPrivilegedCLIRemoval { [weak self] in
                self?.finishByTrashingApp()
            }
        } else {
            finishByTrashingApp()
        }
    }

    // MARK: - CLI 移除（系统鉴权弹窗）

    private func runPrivilegedCLIRemoval(completion: @escaping () -> Void) {
        let target = CLIInstallManager.targetPath
        let shellCommand = "rm -f '\(target)'"
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo)
            // 无论成功、失败或用户取消鉴权，都继续把 App 移入废纸篓并退出。
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    // MARK: - 移入废纸篓并退出

    private func finishByTrashingApp() {
        // 使用运行中 App 的真实 bundle 路径（正常安装位置为 /Applications/ClipSlots.app）。
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appURL]) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
