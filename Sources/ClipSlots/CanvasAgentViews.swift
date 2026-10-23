import SwiftUI
import ClipSlotsKit

/// Legacy canvas chats have no reliable project attribution. Preserve access
/// without silently injecting them into a newly scoped project conversation.
struct LegacyCanvasHistoryView: View {
    @ObservedObject var model: AgentChatModel
    var title = "旧版画布记录"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("历史记录和草稿已保留，可阅读或复制。编辑页和画布页的新会话按项目共用。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    history(model.messages, draft: model.draft)
                    ForEach(model.recentConversations) { saved in
                        Divider()
                        Text(saved.title).font(.headline)
                        history(saved.messages, draft: saved.draft)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(24).frame(width: 600, height: 520)
    }
    private func history(_ messages: [AgentMessage], draft: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(messages.filter { $0.role == .user || $0.role == .assistant }) { message in
                Text((message.role == .user ? "我：" : "Agent：") + message.content)
            }
            if !draft.isEmpty { Text("未发送草稿：" + draft) }
            if messages.isEmpty && draft.isEmpty { Text("暂无记录").foregroundColor(.secondary) }
        }
    }
}

struct CanvasAgentComposer: View {
    @ObservedObject var model: AgentChatModel
    @ObservedObject var context: CanvasAgentContext
    @State private var showWorkflowSkills = false

    var body: some View {
        WorkspaceContentBoundary {
        VStack(alignment: .leading, spacing: 7) {
            WorkspaceContentBoundary {
            ForEach(context.pendingGraphPreviews.filter {
                $0.conversationID == model.selectedConversationID
            }) { preview in
                Button("预览画布变更 · \(preview.mutation.changes.count) 个节点 · \(preview.mutation.groupChanges.count) 个编组") {
                    context.presentMutation(preview, conversationID: model.selectedConversationID)
                }.accessibilityIdentifier("agent-canvas-sync-preview")
            }
            ForEach(model.draftReferences) { ref in
                HStack(alignment: .top, spacing: 6) {
                    DisclosureGroup {
                        Text(ref.text.isEmpty ? "无正文" : ref.text)
                            .lineLimit(8).textSelection(.enabled)
                        if !ref.attachmentNames.isEmpty {
                            Text("附件名称：" + ref.attachmentNames.joined(separator: "、"))
                                .foregroundColor(.secondary)
                        }
                        if let images = ref.images, !images.isEmpty {
                            HStack {
                                ForEach(images) { image in
                                    if let data = image.imageSnapshot, let preview = NSImage(data: data) {
                                        Image(nsImage: preview).resizable().scaledToFit().frame(width: 44, height: 44)
                                    }
                                }
                                Text("已读取 \(images.count) 张图片")
                            }
                        }
                    } label: { Text(ref.title).lineLimit(1) }
                    Button { context.locate(ref) } label: { Image(systemName: "scope") }
                        .help("定位引用节点")
                    Button { model.draftReferences.removeAll { $0.id == ref.id } } label: {
                        Image(systemName: "xmark")
                    }.help("移除本轮引用")
                }
            }
            if let error = context.error {
                Text(error).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            }
        }
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .sheet(isPresented: Binding(get: { context.preview != nil },
                                    set: { if !$0 { context.dismissPreview() } })) {
            CanvasAgentPreviewView(context: context, conversationID: model.selectedConversationID)
        }
        .sheet(item: $context.skillDraft) { source in
            WorkflowSkillEditor(draft: source.skill, context: context, source: source)
        }
        .sheet(isPresented: Binding(get: { context.graphPreview != nil },
                                    set: { if !$0 { context.graphPreview = nil } })) {
            AgentCanvasMutationPreview(context: context, conversationID: model.selectedConversationID)
        }
        .sheet(isPresented: $showWorkflowSkills) {
            WorkflowSkillLibraryView(model: model, context: context)
        }
    }
}

struct CanvasAgentCoverageView: View {
    let turn: CanvasAgentTurn
    let receipts: [CanvasReadReceipt]
    @ObservedObject var context: CanvasAgentContext

    private var deliveredIDs: Set<String> {
        Set(turn.directory.map(\.id) + receipts.flatMap(\.nodeIDs))
    }
    private var bodyIDs: Set<String> {
        Set(receipts.filter { $0.field == "body" }.flatMap(\.nodeIDs))
    }
    private var completeBodies: Int {
        bodyIDs.filter { id in
            CanvasReadReceipt.isComplete(receipts.filter { $0.field == "body" && $0.subject == id })
        }.count
    }
    private var completeEdges: Bool {
        CanvasReadReceipt.isComplete(receipts.filter { $0.field == "edges" && $0.subject.hasPrefix("all:") })
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text("固定于 \(turn.capturedAt.formatted(date: .omitted, time: .shortened)) · 重试沿用此快照")
                Text("目录 \(deliveredIDs.count)/\(turn.nodeCount) · 工具完整正文 \(completeBodies) · 部分正文 \(bodyIDs.count - completeBodies)")
                Text(completeEdges ? "全图连线已交付：\(turn.edgeCount) 条" : "连线：\(receipts.filter { $0.field == "edges" }.count) 次分页读取")
                Text("图片、视频和音轨尚未读取内容。").foregroundColor(.secondary)
                if !turn.supportsTools {
                    Text("当前后端不支持全图工具；切换 DeepSeek 后可重试。").foregroundColor(.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(deliveredIDs.sorted(), id: \.self) { id in
                            HStack(spacing: 6) {
                                Text(turn.directory.first { $0.id == id }?.title
                                     ?? receipts.lazy.compactMap { $0.nodeTitles?[id] }.first ?? id)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                let fields = Set(receipts.filter { $0.nodeIDs.contains(id) }.map(\.field))
                                Text(fields.contains("body") ? "正文" : "目录").foregroundColor(.secondary)
                                Button { context.locate(nodeID: id, turn: turn) } label: {
                                    Image(systemName: "scope")
                                }.help("定位来源节点").buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }.padding(.top, 5)
        } label: {
            Label("画布资料", systemImage: "square.stack.3d.up")
        }
        .font(.system(size: 11))
        .foregroundColor(TapSkin.secondaryInk)
        .padding(.vertical, 4)
        .padding(.top, 8)
        .accessibilityIdentifier("agent-canvas-coverage")
    }
}

struct CanvasAgentPreviewView: View {
    @ObservedObject var context: CanvasAgentContext
    let conversationID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preview = context.preview {
                HStack {
                    Text("文字预览").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("关闭") { context.dismissPreview() }
                }
                Text("应用到：\(preview.target.title)").font(.headline)
                Text("替换这个槽位的正文；附件、标签和封面保留。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                DisclosureGroup("原正文 · \(preview.before.plainText.count) 字") {
                    ScrollView {
                        Text(preview.before.plainText.isEmpty ? "无正文" : preview.before.plainText)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 100)
                }
                Text("待应用正文 · \(preview.text.count) 字").font(.system(size: 12, weight: .medium))
                TextEditor(text: Binding(get: { context.preview?.text ?? "" },
                                         set: { context.preview?.text = $0 }))
                    .font(.system(size: 14)).frame(minHeight: 180)
                    .disabled(preview.appliedHistoryID != nil)
                    .accessibilityIdentifier("agent-canvas-preview-text")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.25)))
                if let error = context.error {
                    Text(error).foregroundColor(.orange).font(.system(size: 12))
                }
                if let status = context.status {
                    Text(status).foregroundColor(.secondary).font(.system(size: 12))
                }
                HStack {
                    Button("定位目标") { context.locate(preview.target) }
                    Spacer()
                    if preview.appliedHistoryID != nil {
                        Button("撤销本次应用") { context.undoApplied() }
                            .accessibilityIdentifier("agent-canvas-undo")
                    } else {
                        Button("确认应用") { context.apply(conversationID: conversationID) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("agent-canvas-apply")
                    }
                }
            }
        }
        .padding(24).frame(width: 580, height: 530)
        .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xfafafa, 0x161616))
    }
}
