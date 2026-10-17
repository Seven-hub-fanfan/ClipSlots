import SwiftUI
import AppKit
import ClipSlotsKit

struct REAPluginView: View {
    @ObservedObject private var environment = EnvironmentSetupManager.shared
    @State private var selection: URL?
    @State private var mode = REAIntegration.Analysis.inspect
    @State private var result = ""
    @State private var error: String?
    @State private var report: URL?
    @State private var task: Task<Void, Never>?
    @State private var showingEnvironment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地分析").font(.system(size: 13, weight: .semibold))
            Text("选择文件或应用，识别结构与后续分析入口；JavaScript / Electron 模式可提取模块和交互线索。结果保存在本机。")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("分析方式", selection: $mode) {
                ForEach(REAIntegration.Analysis.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode)
                }
            }.disabled(task != nil)
            HStack {
                Button("选择文件或目录") { choose() }
                    .disabled(task != nil)
                Text(selection?.lastPathComponent ?? "尚未选择")
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            HStack {
                if task != nil {
                    ProgressView().controlSize(.small)
                    Text("正在分析…").font(.system(size: 11))
                    Button("取消") { task?.cancel() }
                } else if environment.statuses[.rea]?.ready != true {
                    Button("启用 REA · 自动配置") { showingEnvironment = true }
                        .accessibilityIdentifier("rea-setup")
                } else {
                    Button("开始分析") { analyze() }.disabled(selection == nil)
                        .accessibilityIdentifier("rea-analyze")
                }
                Spacer()
                if let report {
                    Button("打开报告") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.orange) }
            if !result.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(String(result.prefix(16000)))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).padding(10)
                }
                .frame(height: 180)
                .background(AppTheme.searchFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if result.count > 16000 {
                    Text("此处显示摘要，完整结果请打开报告。").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Text("原生深度反编译需额外配置 Hopper / Ghidra 等分析器。REA：MIT 开源许可。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .sheet(isPresented: $showingEnvironment) { EnvironmentSetupView(includeREA: true) }
        .onDisappear { task?.cancel() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "选择"
        if panel.runModal() == .OK {
            selection = panel.url
            result = ""; error = nil; report = nil
        }
    }

    private func analyze() {
        guard let selection else { return }
        error = nil
        result = ""
        report = nil
        let mode = mode
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let text = try await REAIntegration.analyze(selection, mode: mode)
                try Task.checkCancellation()
                let root = ClipSlotsPaths.dataRoot.appendingPathComponent("rea-reports")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("REA-\(UUID().uuidString).json")
                try Data(text.utf8).write(to: file, options: .atomic)
                report = file
                result = text
            } catch is CancellationError { error = "已取消分析。" }
            catch { self.error = error.localizedDescription }
        }
    }
}
