import Foundation

public enum REAIntegration {
    public static var iconURL: URL? {
        let relative = "ClipSlots_ClipSlotsKit.bundle/Resources/rea-original.svg"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(relative),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(relative),
            Bundle.main.bundleURL.appendingPathComponent(relative)
        ].compactMap { $0 }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return url }
        #if DEBUG
        return Bundle.module.url(forResource: "rea-original", withExtension: "svg", subdirectory: "Resources")
        #else
        return nil
        #endif
    }

    public enum Analysis: String, CaseIterable, Sendable {
        case inspect, javascript
        public var title: String { self == .inspect ? "识别文件 / 应用" : "分析 JavaScript / Electron" }
        var command: String { self == .inspect ? "inspect-artifact" : "analyze-javascript-application" }
    }

    public static func analyze(_ path: URL, mode: Analysis,
                               toolchain: LocalToolchain = LocalToolchain()) async throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ToolProcess.Failure.failed("所选文件已移动或不存在，请重新选择。")
        }
        guard let binary = toolchain.resolve(.rea) else {
            throw ToolProcess.Failure.failed("请先启用 REA 运行组件。")
        }
        let output = try await ToolProcess.run(binary,
            [mode.command, path.path, "--format", "json"],
            environment: toolchain.environment(), timeout: 180, outputLimit: 8_388_608)
        guard output.stdout.utf8.count < 8_388_608 else {
            throw ToolProcess.Failure.failed("分析结果过大，请选择更小的目录或单个文件。")
        }
        guard output.status == 0, !output.stdout.isEmpty,
              let data = output.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            throw ToolProcess.Failure.failed("REA 未完成分析。请确认文件类型和访问权限；原生深度反编译需另行配置分析器。")
        }
        return String(decoding: formatted, as: UTF8.self)
    }
}
