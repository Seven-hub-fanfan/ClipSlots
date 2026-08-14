import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - v2.10.91 (perf 第四轮) 交互自测驱动
//
// 为什么需要它：优化「切组」「打开设置」这两个转场必须有可复现的取数手段，而这两个动作原本只能靠
// 鼠标手动触发。用 CGEvent 合成点击需要辅助功能授权且坐标脆弱（依赖窗口位置/DPI），因此改为在 App
// 内部按同一条代码路径**程序化驱动**：切组走 `store.switchSpecialSlot(id:)`（与点击组标签完全同一入口），
// 开/关设置走 `.openInAppSettings` / `.closeInAppSettings` 通知（前者就是 Cmd+, 用的那条通知，后者
// 等价于点面板外侧的关闭）。每一步之间留出足够的 settle 时间，让转场动画与后台读盘全部落地。
//
// 开关：环境变量 `CLIPSLOTS_PERF_AUTOTEST=1`（同时需要 `CLIPSLOTS_PERF_LOG=1` 才有数据）。
// 可选 `CLIPSLOTS_PERF_AUTOTEST_ROUNDS`（默认 3 轮）、`CLIPSLOTS_PERF_AUTOTEST_KEEP=1`（跑完不退出）。
// 建议配合 `CLIPSLOTS_DATA_DIR` 指向一份用于压测的数据副本，避免动到真实库。
@MainActor
final class PerfAutoTest {
    static let shared = PerfAutoTest()

    static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        guard let v = env["CLIPSLOTS_PERF_AUTOTEST"] else { return false }
        return v == "1" || v.lowercased() == "true"
    }()

    private var started = false

    /// 每一步之间的等待时间（秒）。要覆盖：切组遮罩 80ms 延迟 + 后台读盘 + 0.16s 淡入 + 缩略图解码。
    private let settle: TimeInterval = 1.6
    private var rounds: Int {
        let env = ProcessInfo.processInfo.environment
        return Int(env["CLIPSLOTS_PERF_AUTOTEST_ROUNDS"] ?? "") ?? 3
    }
    private var keepAlive: Bool {
        ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_AUTOTEST_KEEP"] == "1"
    }

    /// 自测入口不依赖视图 onAppear：由 SlotStoreObservable.init 在启动时调用。
    /// 若窗口因所在 Space 被全屏应用占据等原因没有出现，onAppear 不会触发，取数就会空转。
    func startAtLaunch(store: SlotStoreObservable) {
        guard Self.isEnabled else { return }
        DispatchQueue.main.async { [weak self] in self?.start(store: store) }
    }

    /// 诊断用：把主 store 的每一次 objectWillChange 连同调用栈打出来，用于定位「一次交互里到底是谁在
    /// 反复发通知」。只在 CLIPSLOTS_PERF_PUBLISH_LOG=1 时挂载。
    private var publishSink: Any?
    private func attachPublishLoggerIfNeeded(store: SlotStoreObservable) {
        guard ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_PUBLISH_LOG"] == "1" else { return }
        publishSink = store.objectWillChange.sink { _ in
            let syms = Thread.callStackSymbols.dropFirst(2).prefix(6)
                .map { $0.components(separatedBy: " ").dropFirst(3).joined(separator: " ") }
                .joined(separator: " <- ")
            NSLog("[Perf] publish: \(syms)")
        }
    }

    func start(store: SlotStoreObservable) {
        guard Self.isEnabled, !started else { return }
        started = true
        PerfMonitor.shared.start()
        attachPublishLoggerIfNeeded(store: store)
        // 强制把本进程与主窗口带到前台，确保真的有渲染发生（否则测不到重绘/合成成本）。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let wins = NSApp.windows
            NSLog("[Perf] autotest windows=\(wins.count) titles=\(wins.map { $0.title })")
            if let w = wins.first(where: { $0.canBecomeMain }) {
                w.setIsVisible(true)
                w.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        // 启动后先让首帧、缩略图首轮解码、权限引导等全部落地，再开始取数。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.buildAndRun(store: store)
        }
    }

    private func buildAndRun(store: SlotStoreObservable) {
        let groups = store.currentPageSlotGroups
        NSLog("[Perf] autotest 开始：当前页共 \(groups.count) 组，rounds=\(rounds)")
        guard groups.count >= 2 else {
            NSLog("[Perf] autotest 中止：当前页槽位组不足 2 个，无法测切组")
            finish()
            return
        }
        // 切组序列：在当前页的组之间轮转（最多取 5 组，够覆盖 A→B→C→…→A 的往返命中/未命中两种情况）。
        // 起点旋转到「当前组之后的那一组」，保证每一步都是真实切换（switchSpecialSlot 对同组会早返回）。
        var ids = groups.prefix(5).map { $0.id }
        if let cur = ids.firstIndex(of: store.currentSpecialSlotId) {
            ids = Array(ids[(cur + 1)...]) + Array(ids[...cur])
        }
        var steps: [(String, () -> Void)] = []
        for round in 1...max(1, rounds) {
            for id in ids {
                let name = groups.first { $0.id == id }?.name ?? id
                steps.append(("切组#r\(round)-\(name)", { store.switchSpecialSlot(id: id) }))
            }
            steps.append(("设置打开#r\(round)", {
                NotificationCenter.default.post(name: .openInAppSettings, object: nil)
            }))
            steps.append(("设置关闭#r\(round)", {
                NotificationCenter.default.post(name: .closeInAppSettings, object: nil)
            }))
        }
        run(steps: steps, index: 0)
    }

    private func run(steps: [(String, () -> Void)], index: Int) {
        guard index < steps.count else {
            PerfMonitor.shared.dumpSummary(title: "AUTOTEST SUMMARY")
            finish()
            return
        }
        let (label, action) = steps[index]
        PerfMonitor.shared.beginPhase(label)
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            PerfMonitor.shared.endPhase()
            // 阶段之间留一小段空闲，避免上一阶段的尾巴（0.16s 淡入 / 缩略图回调）算进下一阶段。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.run(steps: steps, index: index + 1)
            }
        }
    }

    private func finish() {
        guard !keepAlive else {
            NSLog("[Perf] autotest 完成（KEEP=1，进程保留）")
            return
        }
        NSLog("[Perf] autotest 完成，退出")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
            exit(0)
        }
    }
}

extension Notification.Name {
    /// v2.10.91: 仅供 PerfAutoTest 程序化关闭设置覆盖层使用（等价于点击面板外侧遮罩）。
    /// 正式运行时没有任何地方 post 它，因此对生产行为零影响。
    static let closeInAppSettings = Notification.Name("com.clipslots.closeInAppSettings")
}
