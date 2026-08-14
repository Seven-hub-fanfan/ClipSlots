import Foundation
import AppKit
import SwiftUI

// MARK: - v2.10.91 (perf 第四轮 · 先测量再改) 主线程卡顿检测器
//
// 前三轮（v2.10.87~90）都是「看代码猜热点 → 改 → 问用户感觉如何」。收益越来越低，且出现过负优化
// （v2.10.88 的 .compositingGroup() 在 v2.10.90 被撤回）。本文件提供把「感觉卡」变成可测数字的最小
// 工具集，默认完全关闭（isEnabled 为 false 时所有入口都是一次布尔判断 + 立即 return），可长期保留：
//
//   1) 主线程卡顿采样：在主 runloop 挂一个 4ms 的高频 Timer（.common 模式，tolerance 0）。主线程一旦
//      被同步工作/大面积重绘占住，Timer 就无法按时回调，回调间隔减去期望间隔即为「主线程被占住的时长」
//      （stall）。这是与用户「掉帧/不丝滑」感知最直接相关的量：一次 >33ms 的 stall 就意味着至少丢一帧。
//   2) 交互阶段标签（PerfPhase）：切组 / 设置打开 / 设置关闭等入口打点，把 stall 归因到具体阶段，
//      并在阶段结束时输出「阶段总时长 / stall 次数分档 / 最大 stall / 累计 stall」。
//   3) 视图 body 求值计数：`.perfCount("X")` 这个 no-op 修饰器在每次 body 求值时自增计数。SwiftUI 的
//      性能问题几乎都是「谁在不该重算的时候重算了」，这个计数比任何猜测都直接。
//   4) 同步区间计时：`PerfMonitor.measure("label") { ... }` 给关键路径（切组同步段、读盘提交点、
//      设置面板 onAppear）加耗时打点。
//
// 开关：环境变量 `CLIPSLOTS_PERF_LOG=1`，或 UserDefaults 键 `clipslots.perfLog`。正式用户两者都没有，
// 因此零开销。
enum PerfPhase {
    /// 当前交互阶段标签（"切组" / "设置打开" / ...）。仅用于日志归因。
    static var current: String {
        get { PerfMonitor.shared.currentPhaseName }
        set { PerfMonitor.shared.beginPhase(newValue) }
    }
}

final class PerfMonitor {
    static let shared = PerfMonitor()

    /// 总开关。环境变量优先，其次 UserDefaults。只解析一次。
    static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let v = env["CLIPSLOTS_PERF_LOG"], v == "1" || v.lowercased() == "true" { return true }
        return UserDefaults.standard.bool(forKey: "clipslots.perfLog")
    }()

    // MARK: 采样参数

    /// 采样间隔。4ms 远小于 16.7ms 一帧，能分辨出「掉一帧」级别的停顿。
    private static let sampleInterval: TimeInterval = 0.004
    /// 记入日志的最小 stall（低于此值属正常调度抖动）。
    private static let logThreshold: Double = 20
    /// 分档阈值（ms）。
    private static let bucketMinor: Double = 8
    private static let bucketFrame: Double = 20
    private static let bucketTwoFrames: Double = 33
    private static let bucketSevere: Double = 100

    // MARK: 状态

    private let lock = NSLock()
    private var timer: Timer?
    private var lastFire: CFAbsoluteTime = 0

    private var bodyCounts: [String: Int] = [:]
    private var currentPhase: PhaseStats?
    private var aggregates: [String: Aggregate] = [:]
    private var aggregateOrder: [String] = []

    struct PhaseStats {
        let name: String
        let startedAt: CFAbsoluteTime
        let bodyBaseline: [String: Int]
        var stalls: [Double] = []
    }

    struct Aggregate {
        var runs: Int = 0
        var totalDuration: Double = 0
        var stallCount: Int = 0          // > logThreshold
        var severeCount: Int = 0         // > bucketSevere
        var maxStall: Double = 0
        var totalStall: Double = 0
        var worstSingleRunStall: Double = 0
        var bodyCounts: [String: Int] = [:]
    }

    var currentPhaseName: String {
        lock.lock(); defer { lock.unlock() }
        return currentPhase?.name ?? "idle"
    }

    // MARK: - 生命周期

    /// 启动采样。多次调用安全。
    func start() {
        guard Self.isEnabled else { return }
        guard timer == nil else { return }
        NSLog("[Perf] monitor start interval=\(Self.f(Self.sampleInterval * 1000))ms "
              + "thresholds=\(Self.f(Self.bucketFrame))/\(Self.f(Self.bucketTwoFrames))/\(Self.f(Self.bucketSevere))ms")
        lastFire = CFAbsoluteTimeGetCurrent()
        let t = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let now = CFAbsoluteTimeGetCurrent()
        let delta = now - lastFire
        lastFire = now
        let stallMs = (delta - Self.sampleInterval) * 1000
        guard stallMs > Self.bucketMinor else { return }
        lock.lock()
        currentPhase?.stalls.append(stallMs)
        let phaseName = currentPhase?.name ?? "idle"
        lock.unlock()
        if stallMs > Self.logThreshold {
            let tag = stallMs > Self.bucketSevere ? "SEVERE"
                : (stallMs > Self.bucketTwoFrames ? "HITCH2F" : "HITCH1F")
            NSLog("[Perf] \(tag) stall=\(Self.f(stallMs))ms phase=\(phaseName)")
        }
    }

    // MARK: - 阶段

    func beginPhase(_ name: String) {
        guard Self.isEnabled else { return }
        lock.lock()
        let baseline = bodyCounts
        currentPhase = PhaseStats(name: name, startedAt: CFAbsoluteTimeGetCurrent(), bodyBaseline: baseline)
        lock.unlock()
        NSLog("[Perf] ==> phase BEGIN \(name)")
    }

    /// 结束当前阶段并输出该阶段的卡顿与 body 求值统计。
    func endPhase() {
        guard Self.isEnabled else { return }
        lock.lock()
        guard let phase = currentPhase else { lock.unlock(); return }
        currentPhase = nil
        let duration = (CFAbsoluteTimeGetCurrent() - phase.startedAt) * 1000
        let stalls = phase.stalls
        var bodyDelta: [String: Int] = [:]
        for (k, v) in bodyCounts {
            let d = v - (phase.bodyBaseline[k] ?? 0)
            if d > 0 { bodyDelta[k] = d }
        }
        // 聚合
        let base = phase.name.components(separatedBy: "#").first ?? phase.name
        var agg = aggregates[base] ?? Aggregate()
        if aggregates[base] == nil { aggregateOrder.append(base) }
        agg.runs += 1
        agg.totalDuration += duration
        let over = stalls.filter { $0 > Self.logThreshold }
        agg.stallCount += over.count
        agg.severeCount += stalls.filter { $0 > Self.bucketSevere }.count
        agg.maxStall = max(agg.maxStall, stalls.max() ?? 0)
        let runTotal = over.reduce(0, +)
        agg.totalStall += runTotal
        agg.worstSingleRunStall = max(agg.worstSingleRunStall, runTotal)
        for (k, v) in bodyDelta { agg.bodyCounts[k, default: 0] += v }
        aggregates[base] = agg
        lock.unlock()

        let over20 = stalls.filter { $0 > Self.bucketFrame }
        let over33 = stalls.filter { $0 > Self.bucketTwoFrames }
        let bodyDesc = bodyDelta.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        NSLog("[Perf] <== phase END \(phase.name) dur=\(Self.f(duration))ms "
              + "stalls>20ms=\(over20.count) >33ms=\(over33.count) "
              + "max=\(Self.f(stalls.max() ?? 0))ms sum=\(Self.f(over20.reduce(0, +)))ms "
              + "| body: \(bodyDesc.isEmpty ? "-" : bodyDesc)")
    }

    // MARK: - body 求值计数

    /// 逐次 body 求值日志开关（CLIPSLOTS_PERF_BODY_LOG=1）。用于把「一次交互里到底发生了几次
    /// 整树更新、分别在什么时刻」和其它日志（切组各分段、通知投递）对齐排查。
    private static let verboseBody: Bool = ProcessInfo.processInfo.environment["CLIPSLOTS_PERF_BODY_LOG"] == "1"

    func countBody(_ label: String) {
        guard Self.isEnabled else { return }
        lock.lock()
        bodyCounts[label, default: 0] += 1
        let n = bodyCounts[label] ?? 0
        lock.unlock()
        if Self.verboseBody, label == "ContentView.body" || label == "SettingsView.body" {
            NSLog("[Perf] body \(label) #\(n) phase=\(currentPhaseName)")
        }
    }

    // MARK: - 同步区间计时

    @discardableResult
    static func measure<T>(_ label: String, _ work: () -> T) -> T {
        guard isEnabled else { return work() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = work()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 1 {
            NSLog("[Perf] span \(label) = \(f(ms))ms phase=\(shared.currentPhaseName)")
        }
        return r
    }

    /// 手动区间：返回起始时间戳，配合 `end(_:since:)`。
    static func begin() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    static func end(_ label: String, since t0: CFAbsoluteTime) {
        guard isEnabled else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 1 {
            NSLog("[Perf] span \(label) = \(f(ms))ms phase=\(shared.currentPhaseName)")
        }
    }

    // MARK: - 汇总

    /// 输出所有阶段的聚合数据。自测脚本跑完后调用。
    func dumpSummary(title: String = "SUMMARY") {
        guard Self.isEnabled else { return }
        lock.lock()
        let order = aggregateOrder
        let snapshot = aggregates
        lock.unlock()
        NSLog("[Perf] ======== \(title) ========")
        for name in order {
            guard let a = snapshot[name] else { continue }
            let runs = Double(max(1, a.runs))
            let bodyDesc = a.bodyCounts.sorted { $0.value > $1.value }
                .map { "\($0.key)=\(Self.f(Double($0.value) / runs))" }
                .joined(separator: " ")
            NSLog("[Perf] \(name) runs=\(a.runs) | 卡顿>20ms 共\(a.stallCount)次(次均\(Self.f(Double(a.stallCount) / runs))) "
                  + "| 严重>100ms \(a.severeCount)次 | 最大单次停顿 \(Self.f(a.maxStall))ms "
                  + "| 每次交互累计停顿 均值\(Self.f(a.totalStall / runs))ms 最差\(Self.f(a.worstSingleRunStall))ms "
                  + "| body/次: \(bodyDesc.isEmpty ? "-" : bodyDesc)")
        }
        NSLog("[Perf] ======== END \(title) ========")
    }

    /// 一位小数格式化（避免 NSLog 变参在 Swift 下的类型坑）。
    static func f(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}

// MARK: - View 侧的零成本计数入口

extension View {
    /// 在每次 body 求值时给 `label` 计数。isEnabled 为 false 时只是一次布尔判断 + 返回 self，
    /// 不插入任何视图节点（返回类型仍是 Self，不改变视图树结构，因此不可能影响布局/动画）。
    @inline(__always)
    func perfCount(_ label: String) -> Self {
        if PerfMonitor.isEnabled { PerfMonitor.shared.countBody(label) }
        return self
    }
}
