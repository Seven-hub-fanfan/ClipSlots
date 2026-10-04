import SwiftUI
import ClipSlotsKit

/// Legacy canvas chats have no reliable project attribution. Preserve access
/// without silently injecting them into a newly scoped project conversation.
struct LegacyCanvasHistoryView: View {
    @ObservedObject var model: AgentChatModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("旧版画布记录").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("历史记录和草稿已保留，可阅读或复制。新会话按画布项目独立保存。")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button { context.addSelection(to: model) } label: {
                    Label("引用选中素材", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("agent-add-canvas-reference")
                .disabled(model.isRunning)
                Spacer()
                Text("\(model.draftReferences.count)/3").foregroundColor(.secondary)
            }
            Text("仅发送所选正文与附件名称 · 结果确认后应用")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(model.draftReferences) { ref in
                HStack(alignment: .top, spacing: 6) {
                    DisclosureGroup {
                        Text(ref.text.isEmpty ? "无正文" : ref.text)
                            .lineLimit(8).textSelection(.enabled)
                        if !ref.attachmentNames.isEmpty {
                            Text("附件名称：" + ref.attachmentNames.joined(separator: "、"))
                                .foregroundColor(.secondary)
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
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .sheet(isPresented: Binding(get: { context.preview != nil },
                                    set: { if !$0 { context.dismissPreview() } })) {
            CanvasAgentPreviewView(context: context, conversationID: model.selectedConversationID)
        }
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
