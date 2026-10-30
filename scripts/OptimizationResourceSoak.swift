import Foundation
import Darwin
import ClipSlotsKit

/// Release Kit workload. It measures storage/cache stability, not GUI frame rate.
@main
struct OptimizationResourceSoak {
    static func memory() throws -> (rss: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
        return (info.resident_size, info.phys_footprint)
    }
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let mode = CommandLine.arguments[2]
        guard (root.path.hasPrefix("/private/tmp/clipslots-resource-soak-") ||
               root.path.hasPrefix("/tmp/clipslots-resource-soak-")),
              root.resolvingSymlinksInPath().path == root.path,
              ["mixed", "idle"].contains(mode),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("isolated.marker").path),
              ClipSlotsPaths.dataRoot.standardizedFileURL.path == root.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let storage = SlotStorage(slotsDir: root.appendingPathComponent("fixture-slots"))
        let cache = ResourceCache<Data>(category: .canvasThumb, countLimit: 256)
        let body = Data(String(repeating: "正文稳定性🙂", count: 16_384).utf8)
        for slot in 1...10 {
            let content = SlotContent(items: [[PasteboardItem(type: "public.utf8-plain-text", data: body)]])
            guard storage.set(slot, content: content) else { throw CocoaError(.fileWriteUnknown) }
        }
        storage.finishPendingWritesBeforeMovingDirectory()
        let samples = root.appendingPathComponent("samples.jsonl")
        FileManager.default.createFile(atPath: samples.path, contents: nil)
        let output = try FileHandle(forWritingTo: samples)
        defer { try? output.close() }
        let start = ProcessInfo.processInfo.systemUptime
        var previousTime = start
        var previousCPU = cpu()
        var iteration = 0
        var pressureChecks = 0
        while ProcessInfo.processInfo.systemUptime - start < 3_600 {
            autoreleasepool {
                if mode == "mixed" {
                    let slot = iteration % 10 + 1
                    var content = storage.get(slot)
                    content.updatedAt += 1
                    if !storage.set(slot, content: content) { fatalError("isolated workload write failed") }
                    for key in 0..<16 {
                        cache.setObject(Data(repeating: UInt8(iteration % 251), count: 512 * 1024),
                                        forKey: key, cost: 512 * 1024)
                    }
                    if iteration % 60 == 0 {
                        ResourceBudget.shared.setPressure(.critical)
                        if cache.totalCost > ResourceBudget.shared.bytes(for: .canvasThumb) {
                            fatalError("cache remained over critical allowance")
                        }
                        ResourceBudget.shared.setPressure(.normal)
                        pressureChecks += 1
                    }
                }
            }
            let memory = try memory()
            let now = ProcessInfo.processInfo.systemUptime
            let currentCPU = cpu()
            let sample: [String: Any] = [
                "elapsedSeconds": now - start, "sampleGapSeconds": now - previousTime,
                "cpuPercentSingleCore": (currentCPU - previousCPU) / max(0.000001, now - previousTime) * 100,
                "rssBytes": memory.rss, "physicalFootprintBytes": memory.footprint,
                "cacheChargedBytes": cache.totalCost, "iteration": iteration,
                "mode": mode, "gui": false, "providerRequests": 0
            ]
            try output.write(contentsOf: JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]))
            try output.write(contentsOf: Data([10]))
            previousTime = now; previousCPU = currentCPU; iteration += 1
            // A bounded cadence is part of this workload, not a hardware FPS measurement.
            Thread.sleep(forTimeInterval: max(0, start + Double(iteration) - ProcessInfo.processInfo.systemUptime))
        }
        for slot in 1...10 {
            guard storage.get(slot).items.first?.first?.data == body else { throw CocoaError(.fileReadCorruptFile) }
        }
        storage.finishPendingWritesBeforeMovingDirectory()
        try output.synchronize()
        let report: [String: Any] = [
            "scope": "Release Kit cache/storage; headless; hardware/GUI acceptance still pending",
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "samples": iteration, "pressureChecks": pressureChecks,
            "dataBytesPreserved": true, "providerRequests": 0, "gui": false,
            "failures": [String]()
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("workload.json"), options: .atomic)
    }
}
