import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipSlotsKit

@MainActor
public struct AgentArtifactPanel: View {
    public let record: AgentArtifactRecord
    public let actions: [AgentArtifactAppToolAction]
    private let allowsDelete: Bool
    private let onAction: (AgentArtifactPanelAction) -> Void
    private let onClose: () -> Void
    private let onPreviewState: (AgentArtifactResourceState) -> Void
    @State private var showSource = false
    @State private var notice: String?
    @State private var exportedURL: URL?
    @State private var pendingLink: URL?
    @State private var previewState: AgentArtifactResourceState = .missing
    @State private var generation = UUID()

    public init(record: AgentArtifactRecord, actions: [AgentArtifactAppToolAction] = [],
                allowsDelete: Bool = false, onAction: @escaping (AgentArtifactPanelAction) -> Void,
                onClose: @escaping () -> Void,
                onPreviewState: @escaping (AgentArtifactResourceState) -> Void = { _ in }) {
        self.record = record; self.actions = actions; self.allowsDelete = allowsDelete
        self.onAction = onAction; self.onClose = onClose
        self.onPreviewState = onPreviewState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.system(size: 13, weight: .semibold))
                    Text("\(record.key.path) · 修订 \(record.revision)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
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
            if let notice { Text(notice).font(.caption).textSelection(.enabled) }
        }
        .font(.system(size: 12)).foregroundStyle(TapSkin.ink)
        .tint(TapSkin.accent).buttonStyle(.bordered).controlSize(.small)
        .padding(12).frame(minWidth: 360, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TapSkin.chromeFill)
        .onChange(of: record) { _ in
            generation = UUID(); notice = nil; pendingLink = nil; exportedURL = nil; previewState = .missing
        }
        .onDisappear { generation = UUID() }
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
                AgentArtifactHTMLPreview(source: source, onState: {
                    previewState = $0
                    onPreviewState($0)
                }, onLink: { pendingLink = $0 })
                    .frame(minHeight: 200, idealHeight: 360)
                    .accessibilityIdentifier("agent-artifact-html-preview")
                if case .loading = previewState { ProgressView("正在载入预览…").controlSize(.small) }
                if case .error(let message) = previewState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
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
