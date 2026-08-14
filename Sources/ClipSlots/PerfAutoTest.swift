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
    /// v2.10.93: resize 扫掠轴向（w / h / both）。
    private static let resizeAxis: String =
        (ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_RESIZE_AXIS"] ?? "both").lowercased()

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
        // v2.10.93: 场景选择。`CLIPSLOTS_PERF_AUTOTEST_SCENARIO` 支持逗号分隔的
        // `group` / `settings` / `resize` / `theme`；未设置时保持 v2.10.91 的默认行为
        // （切组 + 开关设置），以免破坏既有取数脚本。
        let scenarioRaw = ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_AUTOTEST_SCENARIO"]
        let scenarios: Set<String> = {
            guard let scenarioRaw, !scenarioRaw.isEmpty else { return ["group", "settings"] }
            return Set(scenarioRaw.lowercased().components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }()

        let groups = store.currentPageSlotGroups
        NSLog("[Perf] autotest 开始：当前页共 \(groups.count) 组，rounds=\(rounds)，场景=\(scenarios.sorted().joined(separator: "+"))")

        // (标签, 动作, 该步等待时长)。resize 扫掠自身要跑 2*frames 帧，必须给足时长，否则
        // endPhase 会在扫掠还没跑完时就结算，数据不完整。
        var steps: [(String, () -> Void, TimeInterval)] = []

        if scenarios.contains("group") || scenarios.contains("settings") {
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
            for round in 1...max(1, rounds) {
                if scenarios.contains("group") {
                    for id in ids {
                        let name = groups.first { $0.id == id }?.name ?? id
                        steps.append(("切组#r\(round)-\(name)", { store.switchSpecialSlot(id: id) }, settle))
                    }
                }
                if scenarios.contains("settings") {
                    steps.append(("设置打开#r\(round)", {
                        NotificationCenter.default.post(name: .openInAppSettings, object: nil)
                    }, settle))
                    steps.append(("设置关闭#r\(round)", {
                        NotificationCenter.default.post(name: .closeInAppSettings, object: nil)
                    }, settle))
                }
            }
        }

        if scenarios.contains("shot") {
            // 视觉留证：把主窗口内容渲染成 PNG（深色 → 浅色 → 深色各一张）。
            // 用 NSView.cacheDisplay 在进程内截图，不依赖屏幕/Space/截屏权限，
            // 因此适合用来做「改动前 vs 改动后」的像素级对照。
            let dir = ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_SHOT_DIR"] ?? "/tmp/cs-perf/shots"
            let tag = ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_SHOT_TAG"] ?? "run"
            // 先把窗口尺寸归一到固定值，否则不同次运行会用各自记住的窗口尺寸，截图无法逐像素对照。
            steps.append(("窗口归一", {
                if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    w.setContentSize(NSSize(width: 1380, height: 700))
                }
            }, 1.2))
            steps.append(("截图-深", { Self.snapshotWindow(to: "\(dir)/\(tag)-dark.png") }, 1.0))
            steps.append(("切浅色", {
                UserDefaults.standard.set(ThemeMode.light.rawValue, forKey: "appearanceMode")
            }, 1.6))
            steps.append(("截图-浅", { Self.snapshotWindow(to: "\(dir)/\(tag)-light.png") }, 1.0))
            steps.append(("回深色", {
                UserDefaults.standard.set(ThemeMode.dark.rawValue, forKey: "appearanceMode")
            }, 1.6))
            steps.append(("截图-窄", {
                if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    var f = w.frame; f.size.width = 760; f.size.height = 620
                    w.setFrame(f, display: true)
                }
            }, 1.2))
            steps.append(("截图-窄2", { Self.snapshotWindow(to: "\(dir)/\(tag)-narrow.png") }, 1.0))
        }

        if scenarios.contains("themeshot") {
            // 切主题瞬间连拍：把「卡颜色」从主观描述变成可看的证据——
            // 在 16ms / 60ms / 140ms / 320ms / 700ms 各拍一张，肉眼即可看出哪一块区域晚变色。
            let dir = ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_SHOT_DIR"] ?? "/tmp/cs-perf/shots"
            let tag = ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_SHOT_TAG"] ?? "run"
            steps.append(("主题连拍", {
                Self.snapshotWindow(to: "\(dir)/\(tag)-t000.png")
                UserDefaults.standard.set(ThemeMode.light.rawValue, forKey: "appearanceMode")
                for (idx, delay) in [0.016, 0.06, 0.14, 0.32, 0.70].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        Self.snapshotWindow(to: "\(dir)/\(tag)-t\(String(format: "%03d", Int(delay * 1000)))-\(idx).png")
                    }
                }
            }, 2.0))
            steps.append(("回深色", {
                UserDefaults.standard.set(ThemeMode.dark.rawValue, forKey: "appearanceMode")
            }, 1.6))
        }

        if scenarios.contains("resizestep") {
            // ★ 真正有判别力的指标：**单次布局 pass 的耗时**。
            // 60Hz 连续扫掠会让主线程永久饱和（每帧成本 > 帧间隔），测出来的数只是「饱和」，
            // 无法归因也无法比较优化前后。改为离散步进：每 320ms 只改一次窗口尺寸，
            // 并把 setFrame(display: true) 这一次**同步**布局 + 显示的耗时单独计时。
            // 「能不能跟上鼠标」等价于「这个数是否 < 16ms」。
            for round in 1...max(1, rounds) {
                steps.append(("单帧布局#r\(round)", { [weak self] in self?.measureResizeSteps() }, 6.0))
            }
        }

        if scenarios.contains("resize") {
            // 两档拖拽速度：慢（6pt/帧 ≈ 360pt/s）与快（24pt/帧 ≈ 1440pt/s，接近用户所说「鼠标一快就跟不上」）。
            for round in 1...max(1, rounds) {
                steps.append(("resize慢#r\(round)", { [weak self] in self?.driveResizeSweep(deltaPerFrame: 6, frames: 60) }, 2.5))
                steps.append(("resize快#r\(round)", { [weak self] in self?.driveResizeSweep(deltaPerFrame: 24, frames: 40) }, 2.0))
            }
        }

        if scenarios.contains("theme") {
            for round in 1...max(1, rounds) {
                steps.append(("切主题→浅#r\(round)", {
                    UserDefaults.standard.set(ThemeMode.light.rawValue, forKey: "appearanceMode")
                }, settle))
                steps.append(("切主题→深#r\(round)", {
                    UserDefaults.standard.set(ThemeMode.dark.rawValue, forKey: "appearanceMode")
                }, settle))
            }
        }

        guard !steps.isEmpty else {
            NSLog("[Perf] autotest 中止：场景为空")
            finish()
            return
        }
        run(steps: steps, index: 0)
    }

    /// v2.10.93: 程序化模拟一次「拖拽窗口边缘缩放」。
    ///
    /// 为什么这样测：真实 live resize 由 AppKit 的鼠标跟踪循环驱动，Agent 无法用鼠标复现。但对 App 而言，
    /// 每一帧真正发生的事情是「窗口 contentView 尺寸变了 → SwiftUI 重新布局 + 重新合成」，这一点用
    /// `setFrame` 逐帧驱动是等价的；而 `willStartLiveResize` / `didEndLiveResize` 两个通知本就是
    /// `LiveResizeMonitor` 的唯一输入，手动补发即可让被测代码走与真实拖拽完全相同的分支。
    /// 先放大 frames 帧再原路缩回，避免窗口越跑越大跑出屏幕。
    private func driveResizeSweep(deltaPerFrame: CGFloat, frames: Int) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
            NSLog("[Perf] resize sweep 跳过：找不到主窗口")
            return
        }
        let base = window.frame
        // 先把窗口缩到一个足够小的起点，保证放大过程不会撞到屏幕边界（撞到就不再变尺寸，等于没测）。
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? base
        let growth = deltaPerFrame * CGFloat(frames)
        let startWidth = min(max(760, visible.width - growth - 40), base.width)
        let startHeight = min(max(600, visible.height - growth - 40), base.height)
        let start = NSRect(x: visible.minX + 20, y: visible.minY + 20, width: startWidth, height: startHeight)
        window.setFrame(start, display: true)

        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        var i = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
            i += 1
            let phaseUp = i <= frames
            let step = phaseUp ? CGFloat(i) : CGFloat(2 * frames - i)
            var f = start
            // 轴向可选：CLIPSLOTS_PERF_RESIZE_AXIS=w 只改宽、=h 只改高、缺省两轴一起改。
            // 用于区分「宽度变化」与「高度变化」各自触发多少重新布局——两者在 SwiftUI 里走的
            // 是完全不同的布局提案路径（宽度影响列宽，高度影响 ScrollView 视口与卡片纵向提案）。
            if Self.resizeAxis != "h" { f.size.width = start.width + step * deltaPerFrame }
            if Self.resizeAxis != "w" { f.size.height = start.height + step * deltaPerFrame * 0.6 }
            window.setFrame(f, display: true)
            if i >= 2 * frames {
                t.invalidate()
                NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
    }

    /// v2.10.93: 进程内窗口截图（NSView.cacheDisplay），用于改动前后的视觉对照。
    static func snapshotWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let view = window.contentView else { return }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? data.write(to: url)
        NSLog("[Perf] 截图已保存 \(path) size=\(Int(bounds.width))x\(Int(bounds.height))")
    }

    /// v2.10.93: 离散步进测「单次窗口尺寸变化引发的同步布局」耗时。
    /// 每步之间留 320ms 空档，确保上一次布局与合成彻底落地，测到的是干净的单次成本。
    private func measureResizeSteps(count: Int = 12, delta: CGFloat = 40) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let start = NSRect(x: visible.minX + 20, y: visible.minY + 20,
                           width: min(900, visible.width - 80), height: min(700, visible.height - 80))
        window.setFrame(start, display: true)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        var costs: [Double] = []
        var i = 0
        func step() {
            i += 1
            var f = start
            if Self.resizeAxis != "h" { f.size.width = start.width + CGFloat(i) * delta }
            if Self.resizeAxis != "w" { f.size.height = start.height + CGFloat(i) * delta * 0.5 }
            let t0 = CFAbsoluteTimeGetCurrent()
            window.setFrame(f, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            costs.append(ms)
            NSLog("[Perf] resizeStep #\(i) w=\(Int(f.size.width)) 单次布局+显示=\(PerfMonitor.f(ms))ms")
            if i >= count {
                NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
                let sorted = costs.sorted()
                let median = sorted[sorted.count / 2]
                let avg = costs.reduce(0, +) / Double(costs.count)
                NSLog("[Perf] ★ resizeStep 汇总 n=\(costs.count) 中位=\(PerfMonitor.f(median))ms "
                      + "均值=\(PerfMonitor.f(avg))ms 最小=\(PerfMonitor.f(sorted.first ?? 0))ms "
                      + "最大=\(PerfMonitor.f(sorted.last ?? 0))ms （<16ms 才跟得上鼠标）")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step() }
    }

    private func run(steps: [(String, () -> Void, TimeInterval)], index: Int) {
        guard index < steps.count else {
            PerfMonitor.shared.dumpSummary(title: "AUTOTEST SUMMARY")
            finish()
            return
        }
        let (label, action, stepSettle) = steps[index]
        PerfMonitor.shared.beginPhase(label)
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + stepSettle) { [weak self] in
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
