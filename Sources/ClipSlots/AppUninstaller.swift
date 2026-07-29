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

        // P1-4 (v2.10.6): 把「可能弹出且可取消的管理员鉴权」提到不可逆删除之前——用户在
        // 鉴权弹窗点「取消」时一切原样、isBusy 复位可重试。
        // P2-15 (v2.10.9): 进一步把「移 App 入废纸篓」也提到删数据/Skill 之前。旧流程先删
        // 数据/Skill 再 trash，一旦 trash 失败就会留下「数据已删、App 还在」的半损坏状态。
        // 现在顺序为：（可选）CLI 鉴权移除 → App 移入废纸篓 → 成功后才删数据/Skill → 退出；
        // trash 失败则明确报错、数据原样保留、isBusy 复位可重试。
        let trashThenCleanup: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.trashAppThenDeleteData(deleteData: deleteData,
                                        uninstallSkills: uninstallSkills,
                                        skillManager: skillManager)
        }

        if uninstallCLI {
            // 先鉴权：只有管理员鉴权通过（未取消）后，才在 completion 里 trash + 删数据/Skill。
            runPrivilegedCLIRemoval(completion: trashThenCleanup)
        } else {
            // 无需鉴权的分支：没有可取消的中途步骤，直接 trash + 删数据/Skill。
            trashThenCleanup()
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

        // P0-2 (v2.10.30): 改用后台 Process 启动 /usr/bin/osascript 执行授权脚本，替代旧的
        // `DispatchQueue.main.async { NSAppleScript ... }`（在主线程执行 NSAppleScript，授权弹窗期间会
        // 冻结主 run loop → 界面假死）。osascript 是独立进程，没有 NSAppleScript 的主线程限制：后台
        // run + waitUntilExit，结束后回主线程——鉴权失败/取消（非零退出）复位 isBusy 让用户可重试且不
        // 继续 trash App；成功才调用 completion。（历史注释「NSAppleScript 必须在主线程执行」已随切换失效。）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var status: Int32 = -1
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScript]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                // 授权脚本无输出，先读 stderr 到 EOF 再读 stdout，避免管道缓冲区风险。
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                status = proc.terminationStatus
            } catch {
                status = -1
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // P2-7: 鉴权失败/取消时复位 isBusy 让用户可重试，不继续 trash App。
                if status != 0 {
                    self.isBusy = false
                    return
                }
                completion()
            }
        }
    }

    // MARK: - 移入废纸篓（先） → 删数据/Skill（后） → 退出

    // P2-15 (v2.10.9): 先 trash App bundle，成功后才做不可逆的数据/Skill 删除，最后退出。
    private func trashAppThenDeleteData(deleteData: Bool,
                                        uninstallSkills: Bool,
                                        skillManager: AgentSkillInstallManager) {
        // 使用运行中 App 的真实 bundle 路径（正常安装位置为 /Applications/ClipSlots.app）。
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appURL]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil {
                    // P2-15 (v2.10.9): trash 失败——此时尚未删除任何数据，明确报错并复位 isBusy
                    // 让用户可重试；数据/Skill 原样保留，不再继续删除，也不退出。
                    self.isBusy = false
                    let alert = NSAlert()
                    alert.messageText = "卸载失败"
                    alert.informativeText = "无法将 ClipSlots.app 移入废纸篓，已中止卸载，您的槽位数据与 Agent Skill 未被删除。请手动将 App 拖入废纸篓后重试。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好的")
                    alert.runModal()
                    return
                }
                // App 已入废纸篓，再执行不可逆的删除。
                // 1) 删除槽位数据（home 目录，无需鉴权）
                if deleteData {
                    try? self.fm.removeItem(at: ClipSlotsPaths.dataRoot)
                }
                // 2) 删除各 Agent skill 目录（home 目录，无需鉴权）
                if uninstallSkills {
                    skillManager.removeAllSkillDirectoriesSilently()
                }
                // 3) 退出。
                NSApp.terminate(nil)
            }
        }
    }
}
