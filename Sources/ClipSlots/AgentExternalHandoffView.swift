import SwiftUI
import AppKit
import ClipSlotsKit

struct AgentHandoffLayout {
    let size: CGSize
    let sidebarWidth: CGFloat
    var compact: Bool { size.width < 820 }
    var heroHeight: CGFloat { min(260, size.height * 0.44) }
    var providerNameWidth: CGFloat { sidebarWidth - 24 - 24 - 18 - 10 }
    func fitsPreviousSelectionBadge(name: String) -> Bool {
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        return !compact && width + 10 + 52 <= providerNameWidth
    }
    init(available: CGSize) {
        size = CGSize(width: min(960, max(640, available.width - 48)),
                      height: min(600, max(420, available.height - 72)))
        sidebarWidth = size.width < 820 ? 204 : 248
    }
}

struct AgentBrandIcon: View {
    let identifier: String
    let size: CGFloat
    var body: some View {
        if let url = AgentBrandResources.iconURL(for: identifier), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable().renderingMode(AgentBrandResources.usesTemplateRendering(for: identifier) ? .template : .original)
                .interpolation(.high).scaledToFit().frame(width: size, height: size)
                .foregroundStyle(TapSkin.ink).accessibilityHidden(true)
        }
    }
}

private struct AgentHandoffButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 36)
            .foregroundStyle(primary ? TapSkin.tone(0xffffff, 0x171717) : TapSkin.ink)
            .background(primary ? TapSkin.tone(0x202020, 0xf1f1f1) : TapSkin.tone(0xececec, 0x242424),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
public struct AgentExternalHandoffView: View {
    public let context: AgentExternalProjectContext
    private let layout: AgentHandoffLayout
    private let onClose: () -> Void
    private let onResult: (AgentExternalHandoffResult) -> Void
    private let opener: AgentExternalHandoffOpening
    @StateObject private var session: AgentExternalHandoffSession
    @State private var error: String?
    @State private var launchTask: Task<Void, Never>?
    @State private var showConfiguration = false
    @State private var hoveredProvider: String?
    @State private var previousSelection: String?
    @State private var configurationCopied = false

    public init(context: AgentExternalProjectContext, catalog: AgentExternalProviderCatalog = .localDefaults,
                preferences: AgentExternalHandoffPreferences? = nil,
                opener: AgentExternalHandoffOpening? = nil,
                availableSize: CGSize = CGSize(width: 1008, height: 672),
                onClose: @escaping () -> Void, onResult: @escaping (AgentExternalHandoffResult) -> Void = { _ in }) {
        self.context = context; self.opener = opener ?? AgentExternalWorkspaceOpener()
        self.layout = AgentHandoffLayout(available: availableSize)
        self.onClose = onClose; self.onResult = onResult
        _session = StateObject(wrappedValue: AgentExternalHandoffSession(
            catalog: catalog, context: context, preferences: preferences ?? AgentExternalHandoffPreferences()))
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Text("在 Agent 中打开")
                    .font(.system(size: 18, weight: .semibold)).padding(.horizontal, 10)
                VStack(spacing: 2) {
                    ForEach(session.providers) { provider in
                        Button {
                            select(provider.id)
                        } label: {
                            HStack(spacing: 10) {
                                AgentBrandIcon(identifier: provider.id, size: 18)
                                Text(provider.name).lineLimit(1).layoutPriority(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("agent-external-provider-name-\(provider.id)")
                                if previousSelection == provider.id && layout.fitsPreviousSelectionBadge(name: provider.name) {
                                    Text("上次选择").font(.system(size: 10))
                                        .foregroundStyle(TapSkin.secondaryInk)
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(TapSkin.tone(0xe2e2e2, 0x333333), in: Capsule())
                                }
                            }
                            .foregroundStyle(session.selectedProviderID == provider.id && !showConfiguration
                                             ? TapSkin.ink : TapSkin.secondaryInk)
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(rowFill(provider.id),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain).disabled(session.isExecuting)
                        .onHover { hoveredProvider = $0 ? provider.id : nil }
                        .accessibilityIdentifier("agent-external-provider-\(provider.id)")
                        .accessibilityLabel(provider.name)
                        .accessibilityValue(session.selectedProviderID == provider.id && !showConfiguration ? "已选择" : "")
                    }
                    Button {
                        showConfiguration = true; error = nil
                    } label: {
                        Label("更多 Agent", systemImage: "square.grid.2x2")
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(rowFill("more"), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain)
                        .foregroundStyle(TapSkin.secondaryInk)
                        .onHover { hoveredProvider = $0 ? "more" : nil }
                        .accessibilityIdentifier("agent-external-more")
                }
                Spacer(minLength: 0)
                Button { showConfiguration.toggle(); error = nil } label: {
                    HStack(spacing: 6) {
                        Text("了解 ClipSlots MCP")
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                    }
                }
                .font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk).buttonStyle(.plain)
                .padding(.horizontal, 10).accessibilityIdentifier("agent-external-mcp-help")
            }
            .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 20)
            .frame(width: layout.sidebarWidth).frame(maxHeight: .infinity)
            .background(TapSkin.tone(0xf5f5f5, 0x121212))
            .overlay(alignment: .trailing) { Rectangle().fill(TapSkin.tone(0xe9e9e9, 0x242424)).frame(width: 1) }

            VStack(alignment: .leading, spacing: 0) {
                if showConfiguration {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("连接 ClipSlots MCP").font(.system(size: 18, weight: .semibold))
                            Text("将配置添加到客户端的 mcpServers，再重启客户端。连接后可读取「\(context.projectTitle)」的画布与产物。")
                                .foregroundStyle(TapSkin.secondaryInk).lineSpacing(6)
                            Text(session.mcpConfigurationText ?? "配置无效")
                                .font(.system(size: 11, design: .monospaced))
                                .accessibilityIdentifier("agent-external-mcp-configuration")
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(TapSkin.tone(0xf2f2f2, 0x111111),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(context.liveLease == nil
                                 ? "当前连接提供固定画布快照和本地最新产物的只读访问。"
                                 : "画布和槽位操作遵循当前审批模式；自动生成模式下安全操作自动执行，删除与结构变更预览仍需确认。支持撤销，连接有效期 30 分钟。")
                                .font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk).lineSpacing(5)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(32).padding(.top, 16)
                    }
                } else {
                    ZStack {
                        TapSkin.tone(0xf1f1f1, 0x030303)
                        RadialGradient(colors: [TapSkin.tone(0xffffff, 0x242424), .clear],
                                       center: .center, startRadius: 0, endRadius: 160)
                        HStack(spacing: layout.compact ? 44 : 64) {
                            Image(nsImage: NSApp.applicationIconImage).resizable()
                                .interpolation(.high).scaledToFit().frame(width: 76, height: 76)
                                .accessibilityHidden(true)
                            AgentBrandIcon(identifier: session.selectedProviderID ?? "", size: 76)
                        }
                    }
                    .frame(height: layout.heroHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(16)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("在 \(session.selectedProvider?.name ?? "Agent") 里继续这个项目")
                                .font(.system(size: 18, weight: .semibold))
                                .accessibilityIdentifier("agent-external-title")
                            Text("打开 \(session.selectedProvider?.name ?? "客户端") 并复制项目提示词，通过 MCP 连接 ClipSlots，继续当前项目。首次使用时，请先在客户端添加 ClipSlots MCP 配置。")
                                .foregroundStyle(TapSkin.secondaryInk).lineSpacing(6)
                            Text(context.projectTitle).font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk)
                            if case .unavailable(let reason) = context.mcpReadiness {
                                Text(reason).foregroundStyle(TapSkin.secondaryInk)
                            }
                            if let result = session.result {
                                Text(statusText(result)).foregroundStyle(TapSkin.secondaryInk)
                                    .accessibilityIdentifier("agent-external-result")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 16)
                    }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                        .textSelection(.enabled).padding(.horizontal, 32).padding(.bottom, 8)
                }
                footer.padding(.horizontal, layout.compact ? 20 : 32).padding(.bottom, 22).padding(.top, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button {
                        launchTask?.cancel(); session.close(); onClose()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .regular))
                            .foregroundStyle(TapSkin.secondaryInk).frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(18)
                    .accessibilityLabel("关闭").accessibilityIdentifier("agent-external-close")
                }
        }
        .font(.system(size: 14)).foregroundStyle(TapSkin.ink).tint(TapSkin.ink)
        .frame(width: layout.size.width, height: layout.size.height)
        .background(TapSkin.tone(0xffffff, 0x191919))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(TapSkin.tone(0xdedede, 0x303030), lineWidth: 1))
        .background(AgentHandoffSheetSurface())
        .onAppear { session.present(); previousSelection = session.selectedProviderID }
        .onDisappear { launchTask?.cancel(); session.close() }
        .onChange(of: context) { _ in
            launchTask?.cancel()
            session.update(context: context)
            configurationCopied = false
            error = nil
        }
    }

    private func select(_ identifier: String) {
        session.select(identifier); error = nil; showConfiguration = false
    }

    private func rowFill(_ identifier: String) -> Color {
        if (identifier == "more" && showConfiguration)
            || (session.selectedProviderID == identifier && !showConfiguration) {
            return TapSkin.tone(0xe8e8e8, 0x272727)
        }
        return hoveredProvider == identifier ? TapSkin.tone(0xeeeeee, 0x202020) : .clear
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if showConfiguration {
                Button {
                    do {
                        configurationCopied = try session.copyMCPConfiguration(context: context, using: opener)
                        error = configurationCopied ? nil : "无法复制，请手动选择配置。"
                    } catch { self.error = error.localizedDescription }
                } label: {
                    Label(configurationCopied ? "已复制 MCP 配置" : "复制 MCP 配置",
                          systemImage: configurationCopied ? "checkmark" : "square.on.square")
                }
                .buttonStyle(AgentHandoffButtonStyle(primary: true))
                .accessibilityIdentifier("agent-external-copy-mcp")
            } else {
                Button {
                    do {
                        if let result = try session.copy(context: context, using: opener) { onResult(result) }
                    } catch { self.error = error.localizedDescription }
                } label: {
                    Label(layout.compact ? "复制提示词" : "没有打开？复制提示词", systemImage: "square.on.square")
                }
                .buttonStyle(AgentHandoffButtonStyle()).disabled(session.isExecuting)
                .accessibilityIdentifier("agent-external-copy")
                Button {
                    error = nil
                    launchTask = Task {
                        do {
                            if let result = try await session.launch(context: context, using: opener) { onResult(result) }
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(session.isExecuting ? "正在打开…" : "在 \(session.selectedProvider?.name ?? "Agent") 打开")
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .buttonStyle(AgentHandoffButtonStyle(primary: true))
                .disabled(session.selectedProvider == nil || session.isExecuting)
                .accessibilityIdentifier("agent-external-open")
            }
        }
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

/// The handoff owns the single continuous outline; AppKit only hosts its sheet.
struct AgentHandoffSheetSurface: NSViewRepresentable {
    final class SurfaceView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSheet()
            DispatchQueue.main.async { [weak self] in self?.configureSheet() }
        }
        func configureSheet() {
            guard let window, window.sheetParent != nil else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.styleMask = [.borderless]
            window.hasShadow = true
            window.invalidateShadow()
        }
    }
    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) {
        DispatchQueue.main.async { [weak view] in view?.configureSheet() }
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
        guard scheme == "https" || AgentExternalProviderCatalog.desktopSchemes.contains(scheme),
              url.user == nil, url.password == nil else { return .unsupported }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return .unsupported }
        return NSWorkspace.shared.open(url) ? .opened : .failed("系统未能打开链接。")
    }
    public func copyPrompt(_ prompt: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(prompt, forType: .string)
    }
}
