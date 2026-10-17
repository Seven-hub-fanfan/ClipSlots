import SwiftUI
import ClipSlotsKit

@MainActor
final class EnvironmentSetupManager: ObservableObject {
    static let shared = EnvironmentSetupManager()
    @Published private(set) var statuses: [LocalTool: LocalToolStatus] = [:]
    @Published private(set) var auth: [LocalTool: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    private let installer = LocalToolchainInstaller()
    private var operation: Task<Void, Never>?
    private var customTikaPath: String {
        UserDefaults.standard.string(forKey: TikaBackendPreferences.tikaCLIPathKey) ?? "tikacli"
    }

    func check() {
        guard !busy else { return }
        start {
            self.message = "正在检测本机环境…"
            await self.refresh()
            try Task.checkCancellation()
            self.message = "检测完成"
        }
    }

    private func refresh() async {
        let chain = LocalToolchain()
        for tool in LocalTool.allCases {
            if Task.isCancelled { return }
            statuses[tool] = await chain.detect(tool, customPath: tool == .tika ? customTikaPath : nil)
        }
    }

    func install(includeREA: Bool = false) {
        guard !busy else { return }
        start {
            do {
                try await self.installer.install(includeREA ? [.crate, .ba, .tika, .rea] : [.crate, .ba, .tika]) { text in
                    await MainActor.run { self.message = text }
                }
            } catch {
                CrateGenerationService.shared.invalidateEnvironment()
                await self.refresh()
                throw error
            }
            CrateGenerationService.shared.invalidateEnvironment()
            CrateModelCatalogStore.shared.reload()
            await self.refresh()
            if self.statuses[.tika]?.ready == false, self.customTikaPath != "tikacli" {
                self.message = "默认环境已配置；Tika 自定义路径不可用，可在 Agent 设置中点「默认」。"
            } else {
                self.message = "安装完成；需要登录时，点击对应的「浏览器登录」。"
            }
        }
    }

    func login(_ tool: LocalTool) {
        guard !busy, tool == .crate || tool == .tika || tool == .ba else { return }
        start {
            let chain = LocalToolchain()
            guard let path = chain.resolve(tool, customPath: tool == .tika ? self.customTikaPath : nil),
                  self.statuses[tool]?.ready == true else {
                throw ToolProcess.Failure.failed("请先安装 \(tool.title)。")
            }
            self.message = "请在浏览器完成 \(tool.title) 登录，正在等待授权…"
            if tool == .crate {
                guard let driver = chain.crateLoginDriver() else {
                    throw ToolProcess.Failure.failed("Crate 登录组件缺失，请重新安装 / 修复。")
                }
                let login = try await ToolProcess.run(driver, ["--site", "i18n-tt", "auth", "login"],
                                                       environment: chain.environment(), timeout: 330)
                guard login.status == 0 else {
                    throw ToolProcess.Failure.failed("浏览器授权未完成，请重试。")
                }
            }
            let args = tool == .ba ? ["--output", "ndjson", "auth", "login", "--no-qrcode", "-c", "cn", "--as", "default"]
                : tool == .tika ? ["auth", "login", "--timeout", "300000", "--json"] : ["auth", "login"]
            let result = try await ToolProcess.run(path, args, environment: chain.environment(), timeout: 330,
                onStandardOutputLine: { line in
                    guard tool == .ba, let value = try? JSONValue.decode(jsonText: line),
                          value["event"]?.stringValue == "auth_login_url",
                          let raw = value["verification_url"]?.stringValue,
                          let url = URL(string: raw), url.scheme == "https",
                          url.host != nil, url.user == nil, url.password == nil else { return }
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                })
            guard result.status == 0 else {
                throw ToolProcess.Failure.failed("登录未完成，请重试并在浏览器中授权。")
            }
            let statusArgs = tool == .ba ? ["--output", "json", "auth", "status", "-c", "cn", "--as", "default"]
                : ["auth", "status", "--json"]
            let status = try await ToolProcess.run(path, statusArgs,
                                                   environment: chain.environment(), timeout: 30)
            guard status.status == 0, LocalToolchain.authenticated(status.stdout, tool: tool) else {
                throw ToolProcess.Failure.failed("登录状态尚未生效，请重试。")
            }
            self.auth[tool] = "已登录"
            self.message = "\(tool.title) 登录成功"
            if tool == .crate { CrateModelCatalogStore.shared.reload() }
        }
    }

    func cancel() {
        message = "正在取消…"
        operation?.cancel()
    }

    private func start(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        isError = false
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { message = "已取消；已验证完成的组件可以继续使用。" }
            catch { isError = true; message = error.localizedDescription }
        }
    }
}

struct EnvironmentSetupView: View {
    @ObservedObject private var manager = EnvironmentSetupManager.shared
    @Environment(\.dismiss) private var dismiss
    var includeREA = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("环境检测与安装", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .accessibilityIdentifier("environment-close")
            }
            Text("自动检测并补齐 Crate、BA 生成与 Tika 对话所需环境，全程无需打开终端。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            Divider()
            ForEach(LocalTool.allCases.filter { $0 != .rea || includeREA }) { tool in
                row(tool)
            }
            Divider()
            if manager.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(manager.message).font(.system(size: 12))
                    Spacer()
                    Button("取消") { manager.cancel() }
                }
            } else if !manager.message.isEmpty {
                Text(manager.message).font(.system(size: 12))
                    .foregroundColor(manager.isError ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新检测") { manager.check() }
                    .accessibilityIdentifier("environment-check")
                Spacer()
                Button("一键安装 / 修复") { manager.install(includeREA: includeREA) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("environment-install")
            }.disabled(manager.busy)
            Text("使用官方源，优先复用可用环境。缺失组件安装到 ClipSlots 私有目录，无需管理员权限。账号授权由浏览器完成；REA 运行组件按需下载。")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 550)
        .background(AppTheme.windowBackground)
        .task { if !manager.busy { manager.check() } }
    }

    private func row(_ tool: LocalTool) -> some View {
        let status = manager.statuses[tool]
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: status?.ready == true ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(status?.ready == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title).font(.system(size: 13, weight: .semibold))
                Text(status?.ready == true ? "\(status?.version ?? "") · 可用" : status?.issue ?? "等待检测")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if let path = status?.path {
                    Text(path).font(.system(size: 9)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path)
                }
            }
            Spacer(minLength: 8)
            if tool == .crate || tool == .tika || tool == .ba {
                VStack(spacing: 4) {
                    Button("浏览器登录") { manager.login(tool) }
                        .disabled(manager.busy || status?.ready != true)
                        .accessibilityIdentifier("environment-login-\(tool.rawValue)")
                    if let auth = manager.auth[tool] {
                        Text(auth).font(.system(size: 10)).foregroundColor(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("environment-\(tool.rawValue)")
    }
}
