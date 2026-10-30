import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipSlotsKit

@MainActor
public struct AgentArtifactPanel: View {
    public let record: AgentArtifactRecord
    public let actions: [AgentArtifactAppToolAction]
    private let pageIdentity: AgentArtifactPageIdentity?
    private let allowsDelete: Bool
    private let onAction: (AgentArtifactPanelAction) -> Void
    private let onClose: () -> Void
    private let onPreviewState: (AgentArtifactResourceState) -> Void
    private let onRequest: ((String, String, JSONValue) async throws -> JSONValue)?
    private let replies: [AgentAppReplySnapshot]
    private let onRecoverReply: ((String, AgentAppReplyRecoveryAction) async throws -> Void)?
    @State private var showSource = false
    @State private var notice: String?
    @State private var exportedURL: URL?
    @State private var pendingLink: URL?
    @State private var previewState: AgentArtifactResourceState = .missing
    @State private var generation = UUID()
    @State private var recoveringReply: String?
    @State private var pageWidgetState: JSONValue?
    @State private var pageStateLoaded = false
    @State private var expanded = false
    @State private var expansionDismissed = false
    @State private var inlineHeight: Double = 360
    @State private var resolvedPresentation: AgentArtifactPresentationPolicy?
    @State private var previewReload = UUID()
    private var pageResourceLoader = AgentArtifactPageResources.loader
    private var pageResourceEndpoint: AgentArtifactPageResourceEndpoint? = .production
    private var presentationURI: String? {
        guard record.hasCurrentContent, let pageIdentity,
              pageIdentity.key == record.key, pageIdentity.revision == record.revision,
              record.pageProjectionConversationID == pageIdentity.conversationID else { return nil }
        return record.pageResourceURI
    }
    private var presentationPolicy: AgentArtifactPresentationPolicy {
        resolvedPresentation ?? .sourceDefault(resourceURI: presentationURI)
    }
    private var pageProjection: AgentArtifactPageData? {
        guard record.hasCurrentContent,
              let pageIdentity, pageIdentity.key == record.key, pageIdentity.revision == record.revision,
              record.pageProjectionConversationID == pageIdentity.conversationID else { return nil }
        return record.pageProjection
    }

    public init(record: AgentArtifactRecord, actions: [AgentArtifactAppToolAction] = [],
                conversationID: UUID? = nil,
                pageIdentity: AgentArtifactPageIdentity? = nil,
                allowsDelete: Bool = false, onAction: @escaping (AgentArtifactPanelAction) -> Void,
                onClose: @escaping () -> Void,
                onPreviewState: @escaping (AgentArtifactResourceState) -> Void = { _ in },
                onRequest: ((String, String, JSONValue) async throws -> JSONValue)? = nil,
                replies: [AgentAppReplySnapshot] = [],
                onRecoverReply: ((String, AgentAppReplyRecoveryAction) async throws -> Void)? = nil) {
        self.record = record; self.actions = actions
        self.pageIdentity = pageIdentity ?? conversationID.map {
            .init(key: record.key, conversationID: $0, revision: record.revision)
        }
        self.allowsDelete = allowsDelete
        self.onAction = onAction; self.onClose = onClose
        self.onPreviewState = onPreviewState
        self.onRequest = onRequest
        self.replies = replies; self.onRecoverReply = onRecoverReply
    }

    func observingReplies(_ handler: @escaping (String, String) throws -> AgentArtifactReplyObservation,
                         conversationActive: Bool) -> Self {
        var copy = self
        copy.replyObservation = handler
        copy.activeConversation = conversationActive
        return copy
    }

    /// Isolated fixtures supply loopback transport or explicitly exercise the original local HTML path.
    func loadingPageResources(using loader: AgentArtifactPageResourceLoader = .init(),
                              endpoint: AgentArtifactPageResourceEndpoint?) -> Self {
        var copy = self
        copy.pageResourceLoader = loader; copy.pageResourceEndpoint = endpoint
        return copy
    }

    private var replyObservation: ((String, String) throws -> AgentArtifactReplyObservation)?
    private var activeConversation: Bool?

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.system(size: 13, weight: .semibold))
                    Text("\(record.key.path) · 修订 \(record.revision)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if record.kind == .html, !showSource, presentationPolicy.allowExpanded {
                    Button(expanded ? "收起" : "展开") {
                        expanded.toggle(); expansionDismissed = true
                    }.accessibilityIdentifier("agent-artifact-expand")
                }
                Button("关闭", action: onClose).accessibilityIdentifier("agent-artifact-close")
            }
            Text("项目 / 画布：\(record.key.scope.projectID) / \(record.key.scope.canvasID)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            resourceStatus
            if record.isDeleted {
                Text("已从本地删除。").font(.caption).foregroundStyle(TapSkin.secondaryInk)
            } else if let bytes = record.content {
                if let revision = record.contentRevision, revision != record.revision {
                    Text("显示修订 \(revision) 的缓存，最新内容待加载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                contentPreview(bytes)
                HStack {
                    Button("导出…", action: export)
                        .accessibilityIdentifier("agent-artifact-export")
                    Button(record.text == nil ? "复制产物路径" : "复制正文", action: copy)
                        .accessibilityIdentifier("agent-artifact-copy")
                    AgentArtifactNativeShareButton(content: bytes, path: record.key.path) { notice = $0 }
                        .frame(width: 72, height: 24)
                        .accessibilityIdentifier("agent-artifact-share")
                    if record.kind == .html {
                        Toggle("源码", isOn: $showSource).toggleStyle(.checkbox)
                    }
                    if let exportedURL {
                        Button("在访达显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                            notice = "已在访达显示导出文件。"
                        }
                    }
                }
            } else {
                Text("暂无正文。").foregroundStyle(.secondary)
                Button("重新加载") { onAction(.retry(record.key)) }
            }
            if let pendingLink {
                HStack {
                    Text(pendingLink.absoluteString).font(.caption).lineLimit(2).textSelection(.enabled)
                    Button("打开链接") { onAction(.openExternalURL(pendingLink)); self.pendingLink = nil }
                    Button("取消") { self.pendingLink = nil }
                }
            }
            if !record.isDeleted {
                HStack {
                    ForEach(actions) { action in
                        Button(action.label) {
                            onAction(.appTool(.init(key: record.key, revision: record.revision, action: action)))
                        }.disabled(!record.hasCurrentContent)
                    }
                    if allowsDelete {
                        Button("删除本地产物") { onAction(.delete(record.key, revision: record.revision)) }
                    }
                }
            }
            replyRecovery
            if let notice { Text(notice).font(.caption).textSelection(.enabled) }
        }
        .font(.system(size: 12)).foregroundStyle(TapSkin.ink)
        .tint(TapSkin.accent).buttonStyle(.bordered).controlSize(.small)
        .padding(12).frame(minWidth: 360, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TapSkin.chromeFill)
        .onChange(of: record) { _ in
            generation = UUID(); recoveringReply = nil
            notice = nil; pendingLink = nil; exportedURL = nil; previewState = .missing
        }
        .onChange(of: pageIdentity) { _ in
            generation = UUID(); recoveringReply = nil
            notice = nil; pendingLink = nil; exportedURL = nil; previewState = .missing
            expanded = false; expansionDismissed = false; inlineHeight = 360
            resolvedPresentation = nil
        }
        .onChange(of: presentationURI) { _ in
            expanded = false; expansionDismissed = false; inlineHeight = 360
            resolvedPresentation = nil
        }
        .onChange(of: showSource) { value in
            if value { expanded = false; expansionDismissed = true }
        }
        .onDisappear { generation = UUID(); recoveringReply = nil; expanded = false }
    }

    @ViewBuilder
    private var replyRecovery: some View {
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(replies, id: \.submission.replyID) { reply in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(replyLabel(reply)).font(.caption)
                        Text(reply.submission.replyID).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            if reply.attempt > 0 {
                                AgentArtifactReplyRecoveryButton(title: "核对接受结果", identifier: "agent-app-reply-reconcile") {
                                    recover(reply, .reconcile)
                                }
                            }
                            if reply.receipt != nil {
                                AgentArtifactReplyRecoveryButton(title: "接管原运行", identifier: "agent-app-reply-attach") {
                                    recover(reply, .attach)
                                }
                            } else {
                                AgentArtifactReplyRecoveryButton(title: reply.attempt == 0 ? "发送已保存回复" : "重试原回复",
                                    identifier: "agent-app-reply-retry") {
                                    recover(reply, .retry(expectedAttempt: reply.attempt))
                                }
                            }
                            if recoveringReply == reply.submission.replyID { ProgressView().controlSize(.small) }
                        }.disabled(onRecoverReply == nil || recoveringReply != nil
                            || reply.submission.origin != record.appReplyOrigin)
                    }
                }
            }
        }
    }

    private func replyLabel(_ reply: AgentAppReplySnapshot) -> String {
        switch reply.state {
        case .saved: return "回复已保存，尚未提交。"
        case .unknown: return "接受结果待核对；重试沿用原回复身份。"
        case .rejected: return "回复被拒绝，原回复已保留。"
        case .accepted:
            switch reply.receipt?.phase {
            case "completed": return "回复已接受，原运行已完成。"
            case "failed": return "回复已接受，原运行业务失败。"
            case "cancelled": return "回复已接受，原运行已取消。"
            case "waiting_suspended": return "回复已接受，原运行已暂停；接管后可显式续接。"
            default: return "回复已接受，执行状态待核对。"
            }
        }
    }

    private func recover(_ reply: AgentAppReplySnapshot, _ action: AgentAppReplyRecoveryAction) {
        guard let onRecoverReply, recoveringReply == nil else { return }
        let ticket = generation
        recoveringReply = reply.submission.replyID
        Task { @MainActor in
            defer { if generation == ticket { recoveringReply = nil } }
            do {
                try await onRecoverReply(reply.submission.replyID, action)
                if generation == ticket { notice = "原回复状态已更新。" }
            } catch {
                if generation == ticket { notice = "操作未完成，原回复已保留；请先核对接受结果。" }
            }
        }
    }

    @ViewBuilder
    private var resourceStatus: some View {
        switch record.resourceState {
        case .loading: HStack { ProgressView().controlSize(.small); Text("正在加载修订 \(record.revision)…").font(.caption) }
        case .error(let message):
            HStack {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("重试") { onAction(.retry(record.key)) }
            }
        case .missing:
            HStack {
                Text("最新正文待加载。").font(.caption).foregroundStyle(.secondary)
                if record.content != nil { Button("加载") { onAction(.retry(record.key)) } }
            }
        case .ready: Text("已加载").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func contentPreview(_ bytes: Data) -> some View {
        if bytes.count > 64 * 1024 * 1024 {
            Text("产物过大，无法预览。").foregroundStyle(.red)
        } else if record.kind == .html, !showSource, let source = record.text {
            VStack(alignment: .leading, spacing: 4) {
                if pageProjection != nil, !pageStateLoaded,
                   pageResourceEndpoint == nil || presentationURI == nil {
                    ProgressView("正在载入预览…").controlSize(.small)
                } else {
                    AgentArtifactHTMLPreview(source: source, onState: {
                    previewState = $0
                    onPreviewState($0)
                    if $0 == .ready, presentationPolicy.allowExpanded, presentationPolicy.autoExpandOnReady,
                       !expansionDismissed { expanded = true }
                }, onLink: { pendingLink = $0 }, actions: record.hasCurrentContent ? actions : [], onTool: { action in
                    guard record.hasCurrentContent else { return }
                    onAction(.appTool(.init(key: record.key, revision: record.revision, action: action)))
                }, onRequest: record.hasCurrentContent ? onRequest : nil,
                    identity: pageIdentity, pageProjection: pageProjection,
                    initialWidgetState: pageWidgetState,
                    onReplyEvents: replyObservation,
                    conversationRunActive: activeConversation,
                    presentationExpanded: presentationPolicy.allowExpanded ? expanded : nil,
                    onSizeChanged: { inlineHeight = presentationPolicy.inlineHeight($0) },
                    onCollapse: { expanded = false; expansionDismissed = true },
                    presentationResourceURI: presentationURI,
                    pageResourceURI: pageResourceEndpoint == nil ? nil : presentationURI,
                    pageResourceLoader: pageResourceLoader,
                    pageResourceEndpoint: pageResourceEndpoint ?? .production,
                    onTemplate: {
                        resolvedPresentation = $0.presentation
                        inlineHeight = $0.presentation.inlineHeight(inlineHeight)
                        if !$0.presentation.allowExpanded { expanded = false }
                    })
                    .id(PreviewIdentity(key: record.key, revision: record.revision, page: pageIdentity, reload: previewReload))
                    .frame(minHeight: expanded ? 520 : inlineHeight,
                           idealHeight: expanded ? 680 : inlineHeight,
                           maxHeight: expanded ? .infinity : inlineHeight)
                    .accessibilityIdentifier("agent-artifact-html-preview")
                }
                if case .loading = previewState { ProgressView("正在载入预览…").controlSize(.small) }
                if case .error(let message) = previewState {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Button("重新加载预览") { previewReload = UUID() }
                }
            }
            .task(id: pageIdentity) {
                pageWidgetState = nil; pageStateLoaded = false
                // The mounted remote coordinator owns the one state read and its deadline.
                if pageResourceEndpoint != nil, presentationURI != nil {
                    pageStateLoaded = true
                    return
                }
                let state = try? await onRequest?("get_state", "", [:])
                guard !Task.isCancelled else { return }
                pageWidgetState = state?.objectValue == nil ? nil : state
                pageStateLoaded = true
            }
        } else if record.kind == .image || record.kind == .audio || record.kind == .video {
            AgentArtifactMediaPreview(content: bytes, kind: record.kind, path: record.key.path)
                .frame(minHeight: 160, idealHeight: 300)
        } else if let text = record.text {
            ScrollView {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(minHeight: 160, idealHeight: 300)
                .accessibilityIdentifier("agent-artifact-text-preview")
        } else {
            Text("二进制文件 · \(bytes.count) 字节，可导出查看。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private struct PreviewIdentity: Hashable {
        let key: AgentArtifactKey
        let revision: UInt64
        let page: AgentArtifactPageIdentity?
        let reload: UUID
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(record.text ?? record.key.path, forType: .string)
        notice = copied ? (record.text == nil ? "已复制产物相对路径。" : "已复制正文。") : "复制失败。"
    }

    private func export() {
        guard let content = record.content, content.count <= 64 * 1024 * 1024, !record.isDeleted else { return }
        let panel = NSSavePanel()
        panel.title = "导出产物"
        panel.nameFieldStringValue = (record.key.path as NSString).lastPathComponent
        panel.canCreateDirectories = true
        let ext = (record.key.path as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        let ticket = generation
        panel.begin { response in
            guard response == .OK, let url = panel.url, ticket == generation else { return }
            do {
                try content.write(to: url, options: [.atomic])
                exportedURL = url
                notice = "已导出到本地。"
            } catch { notice = "导出失败：\(error.localizedDescription)" }
        }
    }
}

/// Native target/action and accessibility identity remain available after a page failure.
private struct AgentArtifactReplyRecoveryButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setButtonType(.momentaryPushIn)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.action = {}
        button.target = nil
    }
    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func press() { action() }
    }
}
