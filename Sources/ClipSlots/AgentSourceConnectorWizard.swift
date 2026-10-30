import SwiftUI
import AppKit
import ClipSlotsKit

private struct ConnectorBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 196
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct AgentSourceConnectorWizard: View {
    let item: AgentMarketItem
    @ObservedObject var sync: AgentMarketSyncStore
    let onClose: () -> Void
    var availableWidth: CGFloat = 680
    var availableHeight: CGFloat = 800
    var onSizeChange: ((CGSize) -> Void)?
    @State private var values: [String: String] = [:]
    @State private var bodyHeight: CGFloat = 196
    @State private var busy = false
    @State private var closing = false
    @State private var error: String?
    @State private var notified: String?
    private var auth: AgentConnectorSession? { sync.sourceAuth }
    private var connectorName: String {
        item.raw["connectors"]?.arrayValue?.first?["display_name"]?.stringValue ?? item.title
    }
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 40, height: 40)
                    Text("•••").foregroundStyle(TapSkin.secondaryInk)
                    MarketArtwork(item: item, sync: sync).frame(width: 40, height: 40)
                }
                VStack(spacing: 4) {
                    Text(auth?.stage == "create_app" ? "第 1/2 步：创建\(connectorName)应用" :
                            auth?.stage == "authorize" ? "第 2/2 步：授权访问\(connectorName)" : "连接 \(connectorName)")
                        .font(.system(size: 18, weight: .semibold)).frame(minHeight: 28)
                    Text("由创作平台提供").font(.system(size: 14)).foregroundStyle(TapSkin.secondaryInk)
                        .frame(height: 20)
                }
            }.frame(maxWidth: .infinity).overlay(alignment: .topTrailing) {
                Button { close() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).accessibilityIdentifier("market-connector-close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if auth?.stage == "create_app" || auth?.kind == "redirect" {
                        risk("应用可能带来更高风险", "创作平台 内置数据保护，但攻击者仍可能通过 创作平台 访问该应用中的数据，或通过该应用获取 创作平台 中的数据。")
                        Divider().padding(.horizontal, 16)
                        risk("与此应用共享的数据", "添加此应用即表示你授权它访问你访问网站时通常共享的基本信息，例如你的 IP 地址和大致位置。")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                    if let code = auth?.raw["user_code"]?.stringValue {
                        HStack { Text(code).font(.system(size: 20, weight: .semibold, design: .monospaced)); Spacer()
                            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) } }
                    }
                    ForEach(Array((auth?.fields ?? []).enumerated()), id: \.offset) { _, field in
                        let key = field["name"]?.stringValue ?? ""
                        Text((field["label"]?.stringValue ?? key) + (field["required"]?.boolValue == true ? " *" : ""))
                        let binding = Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
                        if field["secret"]?.boolValue == true {
                            SecureField(field["placeholder"]?.stringValue ?? "", text: binding).textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("market-connector-field-" + key)
                        } else { TextField(field["placeholder"]?.stringValue ?? "", text: binding).textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("market-connector-field-" + key) }
                        if let help = field["help_text"]?.stringValue { Text(help).font(.system(size: 12)).foregroundStyle(TapSkin.secondaryInk) }
                        if let text = field["help_url"]?.stringValue, let url = URL(string: text), url.scheme == "https" {
                            Link("帮助", destination: url).font(.system(size: 12))
                        }
                    }
                    if auth?.kind == "external_approval" {
                        Text("等待管理员批准").foregroundStyle(TapSkin.secondaryInk)
                    } else if auth?.status == "pending" && auth?.externalURL == nil && auth?.fields.isEmpty == true {
                        HStack { ProgressView().controlSize(.small); Text("正在检查连接状态…") }
                    }
                    if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("market-connector-error") }
                    if auth?.status == "error" || auth?.status == "expired" {
                        Text(auth?.status == "expired" ? "授权已过期" : "连接失败").foregroundStyle(.orange)
                    }
                    }.padding(auth?.stage == "create_app" || auth?.kind == "redirect" ? 0 : 16)
                }.font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(TapSkin.tone(0xe7e7e9, 0x333333)))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ConnectorBodyHeight.self, value: geometry.size.height)
                    })
            }.frame(height: min(bodyHeight, min(360, availableHeight * 0.45)))
                .onPreferenceChange(ConnectorBodyHeight.self) { bodyHeight = $0 }
            HStack(spacing: 12) {
                Button("取消") {
                    closing = true
                    act { try await sync.cancelSourceConnection(reset: auth?.stage == "create_app"); values = [:]; onClose() }
                }.buttonStyle(ConnectorButtonStyle(primary: false)).accessibilityIdentifier("market-connector-cancel")
                if auth?.status == "error" || auth?.status == "expired" {
                    Button("重试") { act { values = [:]; try await sync.startSourceConnection(item, fresh: true) } }
                        .buttonStyle(ConnectorButtonStyle(primary: true))
                        .accessibilityIdentifier("market-connector-retry")
                } else if auth?.fields.isEmpty == false {
                    Button("连接") { act { try await sync.submitSourceConnection(values); values = [:] } }
                        .buttonStyle(ConnectorButtonStyle(primary: true)).accessibilityIdentifier("market-connector-submit")
                } else if let url = auth?.externalURL {
                    Button("在 \(connectorName) 中继续") { NSWorkspace.shared.open(url) }
                        .buttonStyle(ConnectorButtonStyle(primary: true)).accessibilityIdentifier("market-connector-continue")
                } else if auth == nil {
                    Button("开始连接") { act { try await sync.startSourceConnection(item) } }
                        .buttonStyle(ConnectorButtonStyle(primary: true))
                }
            }.disabled(busy)
        }.padding(24).frame(width: availableWidth).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(TapSkin.ink).background(TapSkin.tone(0xfafafa, 0x171717))
            .background(GeometryReader { geometry in
                Color.clear.onAppear { onSizeChange?(geometry.size) }
                    .onChange(of: geometry.size) { onSizeChange?($0) }
            })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("market-connector-wizard")
            .onExitCommand { close() }
            .onChange(of: auth?.id) { _ in values = [:]; notified = nil }
            .task(id: auth?.id) {
                guard !closing else { return }
                if auth == nil {
                    do { try await sync.startSourceConnection(item) } catch { self.error = error.localizedDescription }
                }
                var delay: Double = 2
                while !Task.isCancelled, !closing, let session = auth {
                    if session.status == "authenticated" {
                        if notified != session.id {
                            notified = session.id; values = [:]; await sync.refreshManagement()
                            // Cloud consent and the local MCP grant have separate origins.
                            sync.connectingItem = item; close()
                        }
                        break
                    }
                    if session.terminal { break }
                    do {
                        try await Task.sleep(for: .seconds(session.kind == "external_approval" ? delay : session.interval))
                        try await sync.pollSourceConnection()
                        delay = min(30, delay * 1.5)
                    } catch is CancellationError { break }
                    catch { self.error = error.localizedDescription; break }
                }
            }
            .onDisappear { closing = true; values = [:] }
    }
    private func risk(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).foregroundStyle(TapSkin.secondaryInk).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }
    private func act(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch { closing = false; self.error = error.localizedDescription } }
    }
    private func close() { closing = true; values = [:]; onClose() }
}

struct ConnectorButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(primary ? TapSkin.tone(0xffffff, 0x171717) : TapSkin.ink)
            .background(primary ? TapSkin.ink : TapSkin.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct AgentConnectorPrompt: View {
    @ObservedObject var sync: AgentMarketSyncStore
    let onConnect: () -> Void
    var body: some View {
        if let item = sync.connectionPrompt {
            HStack(spacing: 10) {
                MarketArtwork(item: item, sync: sync).frame(width: 24, height: 24)
                Text("连接 \(item.title)").font(.system(size: 12))
                Spacer()
                Button("稍后  esc") { sync.connectionPrompt = nil }.keyboardShortcut(.escape, modifiers: [])
                Button("连接  ↵", action: onConnect).keyboardShortcut(.return, modifiers: [])
                    .accessibilityIdentifier("market-composer-connect")
            }.padding(12).background(TapSkin.tone(0xf0f0f2, 0x252525), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("market-composer-connection-prompt")
        }
    }
}
