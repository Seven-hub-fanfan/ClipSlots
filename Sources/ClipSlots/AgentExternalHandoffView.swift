import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor
public struct AgentExternalHandoffView: View {
    public let context: AgentExternalProjectContext
    private let onClose: () -> Void
    private let onResult: (AgentExternalHandoffResult) -> Void
    private let opener: AgentExternalHandoffOpening
    @StateObject private var session: AgentExternalHandoffSession
    @State private var error: String?
    @State private var launchTask: Task<Void, Never>?

    public init(context: AgentExternalProjectContext, catalog: AgentExternalProviderCatalog = .localDefaults,
                preferences: AgentExternalHandoffPreferences? = nil,
                opener: AgentExternalHandoffOpening? = nil,
                onClose: @escaping () -> Void, onResult: @escaping (AgentExternalHandoffResult) -> Void = { _ in }) {
        self.context = context; self.opener = opener ?? AgentExternalWorkspaceOpener()
        self.onClose = onClose; self.onResult = onResult
        _session = StateObject(wrappedValue: AgentExternalHandoffSession(
            catalog: catalog, context: context, preferences: preferences ?? AgentExternalHandoffPreferences()))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("外部 Agent", systemImage: "arrow.up.forward.app").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("关闭") {
                    launchTask?.cancel(); session.close(); onClose()
                }.accessibilityIdentifier("agent-external-close")
            }
            Text("项目：\(context.projectTitle) · \(context.scope.projectID) / \(context.scope.canvasID)")
                .font(.caption).textSelection(.enabled)
            if session.providers.isEmpty {
                Text("暂无可用客户端，可复制项目提示词。")
                    .foregroundStyle(.secondary)
            } else {
                Picker("客户端", selection: Binding(get: { session.selectedProviderID ?? "" }, set: { session.select($0); error = nil })) {
                    ForEach(session.providers) { provider in Text(provider.name).tag(provider.id) }
                }.disabled(session.isExecuting).accessibilityIdentifier("agent-external-provider")
            }
            if let provider = session.selectedProvider {
                if let plan = try? AgentExternalHandoffCoordinator.prepare(provider: provider, context: context) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(plan.targets.enumerated()), id: \.offset) { _, target in
                            Text("\(target.kind == .desktop ? "桌面" : "网页")：\(target.url?.absoluteString ?? target.bundleID ?? "不可用")")
                                .lineLimit(2).truncationMode(.middle)
                            Text(target.promptTransport == .clipboard ? "提示词将复制，需手动粘贴" : "提示词通过链接交接，接收状态未确认")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("连接说明") {
                    Text(provider.connectionInstructions).font(.caption).foregroundStyle(.secondary)
                }
            }
            switch context.mcpReadiness {
            case .unavailable(let reason):
                Label("项目只读 MCP：\(reason)", systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary)
            case .ready:
                Text("项目只读 MCP 已就绪，需在客户端连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("项目提示词与 MCP 配置") {
                ScrollView {
                    Text((try? context.prompt()) ?? "项目配置无效，请检查文档链接和 CLI 路径。")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 100, maxHeight: 220)
            }
            if let result = session.result {
                Text(statusText(result)).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("agent-external-result")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(session.isExecuting ? "正在打开…" : "打开客户端") {
                    error = nil
                    launchTask = Task {
                        do {
                            if let result = try await session.launch(context: context, using: opener) { onResult(result) }
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(session.selectedProvider == nil || session.isExecuting)
                    .accessibilityIdentifier("agent-external-open")
                Button("仅复制提示词") {
                    do {
                        if let result = try session.copy(context: context, using: opener) { onResult(result) }
                    } catch { self.error = error.localizedDescription }
                }.disabled(session.isExecuting).accessibilityIdentifier("agent-external-copy")
            }
        }
        .font(.system(size: 12)).foregroundStyle(TapSkin.ink).tint(TapSkin.accent)
        .buttonStyle(.bordered).controlSize(.small)
        .padding(12).frame(minWidth: 380, idealWidth: 520, maxWidth: 680)
        .background(TapSkin.chromeFill)
        .onAppear { session.present() }
        .onDisappear { launchTask?.cancel(); session.close() }
        .onChange(of: context) { _ in launchTask?.cancel(); session.update(context: context); error = nil }
    }

    private func statusText(_ result: AgentExternalHandoffResult) -> String {
        switch result.status {
        case .openedDesktop, .openedWeb:
            return result.promptCopied ? "已打开客户端并复制提示词，尚未发送。" : "已打开提示词链接，接收状态未确认。"
        case .copiedOnly: return "已复制提示词，尚未发送。"
        case .unsupported: return result.promptCopied ? "客户端不可用，提示词已复制。" : "客户端不可用。"
        case .failed: return result.promptCopied ? "打开失败，提示词已复制。" : "交接失败，请重试。"
        }
    }
}

@MainActor
public final class AgentExternalWorkspaceOpener: AgentExternalHandoffOpening {
    public init() {}
    public func applicationAvailable(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
    public func openApplication(bundleID: String) async -> AgentExternalOpenOutcome {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .unsupported }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, error in
                if app != nil { continuation.resume(returning: .opened) }
                else { continuation.resume(returning: .failed(error?.localizedDescription ?? "客户端启动失败。")) }
            }
        }
    }
    public func openURL(_ url: URL) async -> AgentExternalOpenOutcome {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" || ["claude", "chatgpt", "cursor", "trae"].contains(scheme),
              url.user == nil, url.password == nil else { return .unsupported }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return .unsupported }
        return NSWorkspace.shared.open(url) ? .opened : .failed("系统未能打开链接。")
    }
    public func copyPrompt(_ prompt: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(prompt, forType: .string)
    }
}
