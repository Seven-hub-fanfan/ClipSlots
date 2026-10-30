import SwiftUI
import ClipSlotsKit

struct AgentReplicaControls: View {
    @ObservedObject var model: AgentChatModel
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.canResumeGateway {
                HStack(spacing: 8) {
                    Label(model.isControllingRun ? "正在核查远端状态…" : "原运行可续接",
                          systemImage: "arrow.clockwise")
                    Spacer()
                    Button("续接运行") { model.resumeGateway() }
                        .disabled(model.isControllingRun || (model.isRunning && model.runPhase != .waiting))
                        .accessibilityIdentifier("agent-gateway-resume")
                }
            }
            if !model.artifacts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.artifacts) { record in
                            Button { model.selectedArtifact = record } label: {
                                Label(record.title, systemImage: record.kind == .html ? "doc.richtext" : "doc")
                                    .lineLimit(1)
                            }.accessibilityIdentifier("agent-artifact-\(record.key.path)")
                        }
                    }
                }
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 6)
        .sheet(item: $model.selectedArtifact, onDismiss: {
            model.artifactPanelDismissed()
            onDismiss()
        }) { record in
            let identity = model.artifactPageIdentity(key: record.key, revision: record.revision)
            AgentArtifactPanel(record: record,
                actions: record.text != nil && model.canvasContext != nil && model.accessMode != .allDirectoriesReadOnly
                    ? [.init(id: "canvas-text", label: "预览并填入选中节点", toolName: "preview_canvas_text")] : [],
                pageIdentity: identity,
                onAction: { model.handleArtifactAction($0, identity: identity) },
                onClose: { model.dismissArtifact(identity: identity) },
                onRequest: { operation, name, arguments in
                    try await model.artifactRequest(identity: identity, operation: operation, name: name, arguments: arguments)
                }, replies: model.appReplies(for: record), onRecoverReply: { replyID, action in
                    _ = try await model.recoverArtifactAppReply(identity: identity, replyID: replyID, action: action)
                })
                .observingReplies({ replyID, runID in
                    try model.artifactReplyObservation(identity: identity, replyID: replyID, runID: runID)
                }, conversationActive: model.artifactConversationRunActive)
                .id(identity)
                .frame(width: 640, height: 580)
                .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xfafafa, 0x161616))
        }
    }
}

struct AgentCanvasMutationPreview: View {
    @ObservedObject var context: CanvasAgentContext
    let conversationID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("画布变更预览").font(.headline)
                Spacer()
                Button("关闭") { context.graphPreview = nil }
            }
            if let preview = context.graphPreview {
                let mutation = preview.mutation
                Text("\(mutation.changes.count) 个节点 · \(mutation.groupChanges.count) 个编组 · 新增 \(mutation.addedEdges.count) 条连线 · 移除 \(mutation.removedEdges.count) 条连线")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(mutation.changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.after?.id ?? change.before?.id ?? "").font(.system(size: 12, weight: .medium))
                                if let before = change.before { details(before, prefix: "原配置") }
                                if let after = change.after { details(after, prefix: "新配置") }
                                else { Text("移除此节点").foregroundColor(.orange) }
                            }
                            Divider()
                        }
                        ForEach(Array(mutation.groupChanges.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("编组 · " + (change.after?.name ?? change.before?.name ?? ""))
                                    .font(.system(size: 12, weight: .medium))
                                Text(change.after?.id ?? change.before?.id ?? "").font(.system(size: 11))
                                if let after = change.after,
                                   let resolved = preview.plan.document.groups.first(where: { $0.id == after.id }) {
                                    Text("来源：\(resolved.provenance.rawValue) · 父容器：\(resolved.parentGroupID ?? "无")")
                                    Text("直接成员：\(resolved.nodeIDs.count) · 全部成员：\(CanvasGroupHierarchy.memberIDs(resolved.id, groups: preview.plan.document.groups).count)")
                                    if let frame = resolved.containerFrame {
                                        Text("世界边界：\(Double(frame.minX)), \(Double(frame.minY)) · \(Double(frame.width)) × \(Double(frame.height))")
                                    }
                                } else { Text("解除容器，保留显式快照中的节点与连线。").foregroundColor(.orange) }
                            }.font(.system(size: 11)).foregroundColor(.secondary)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !preview.plan.preservedLocalPositions.isEmpty {
                    Text("保留 \(preview.plan.preservedLocalPositions.count) 个节点的本地拖动位置。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                if !preview.plan.preservedLocalGroupPositions.isEmpty {
                    Text("保留 \(preview.plan.preservedLocalGroupPositions.count) 个编组的本地位置。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                if mutation.groupChanges.contains(where: { $0.after?.provenance == .server }) {
                    Text("服务端容器在实际尺寸就绪后单独记录本地布局；嵌套 server 子组不重复布局。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let error = context.error { Text(error).font(.system(size: 12)).foregroundColor(.orange) }
                if let status = context.status { Text(status).font(.system(size: 12)).foregroundColor(.secondary) }
                HStack {
                    Spacer()
                    Button(preview.isApplied ? "已应用" : "确认同步到画布") {
                        context.applyMutation(conversationID: conversationID)
                    }
                    .disabled(preview.isApplied)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("agent-canvas-sync-confirm")
                }
            }
        }
        .padding(22).frame(width: 580, height: 500)
        .foregroundColor(TapSkin.ink).background(TapSkin.tone(0xfafafa, 0x161616))
    }

    private func details(_ node: CanvasNode, prefix: String) -> some View {
        Text("\(prefix)：\(node.groupId) · 槽位 \(node.slot)\n位置 \(coordinate(node.x)), \(coordinate(node.y)) · 尺寸 \(coordinate(node.width)) × \(coordinate(node.height))")
            .font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
    }

    private func coordinate(_ value: CGFloat) -> String { String(format: "%.0f", Double(value)) }
}
