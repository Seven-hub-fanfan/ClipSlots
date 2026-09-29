import SwiftUI
import ClipSlotsKit

/// 生成操作保持屏幕字号；提示词编辑和媒体预览可以同时进行。
struct CanvasNodeComposer<Controls: View>: View {
    let node: CanvasNode
    let text: String
    let editing: Bool
    let inputCount: Int
    var inputSummary: String? = nil
    var inputDetail: String = ""
    let referenceNodes: [CanvasNode]
    let slotImageCounts: [String: Int]
    let onReference: (CanvasNode) -> Void
    let onBegin: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let onInputs: () -> Void
    let onRecover: (() -> Void)?
    var onRestart: (() -> Void)? = nil
    @ViewBuilder let controls: () -> Controls
    @State private var draft = ""
    @State private var showingError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ForEach(Array(referenceNodes.prefix(4))) { reference in
                    Button { onReference(reference) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: reference.kind.symbolName)
                            if reference.kind == .slot {
                                let count = slotImageCounts[reference.id] ?? 0
                                Text(count > 0 ? "槽位 · \(count) 图" : "槽位")
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(TapSkin.nodeAccent(reference.kind).opacity(0.12)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看引用\(reference.kind == .slot ? "槽位" : (reference.kind == .text ? "文本" : (reference.kind == .image ? "图片" : "视频")))")
                }
                if referenceNodes.count > 4 {
                    Text("+\(referenceNodes.count - 4)").font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
                }
                Button(action: onInputs) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(TapSkin.subtleFill))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(TapSkin.border))
                }
                .buttonStyle(.plain)
                .help("添加参考文件")
                if inputCount > 0 || inputSummary != nil {
                    Text(inputSummary ?? "\(inputCount) 张参考图")
                        .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
                        .help(inputDetail)
                }
                Spacer()
                if case .failed(let reason) = node.state {
                    Button("错误详情") { showingError = true }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.orange)
                        .popover(isPresented: $showingError) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("生成失败").font(.headline)
                                ScrollView { Text(reason).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 200)
                                Text(node.taskId == nil ? "检查提示词、参考文件及模型设置后重试。" : "任务已提交，可先继续查询结果；重新生成会提交新任务。")
                                    .font(.caption).foregroundColor(.secondary)
                                Button("复制诊断信息") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("ClipSlots \(AppVersion.current)\n模型：\(node.model)\n任务：\(node.taskId ?? "未提交")\n\(reason)", forType: .string)
                                }
                            }.padding(16).frame(width: 360)
                        }
                }
                if let onRecover {
                    Button("取回结果", action: onRecover)
                        .buttonStyle(.plain).font(.system(size: 11))
                }
                if let onRestart {
                    Button("重新生成", action: onRestart)
                        .buttonStyle(.plain).font(.system(size: 11))
                        .help("使用当前参数提交新任务")
                }
            }
            CanvasPromptEditor(text: $draft, font: .systemFont(ofSize: 13),
                               onCommit: { onCommit(draft) },
                               onCancel: { draft = text; onCancel() },
                               onBlur: { onCommit(draft) },
                               autoFocus: editing,
                               placeholder: node.kind == .text ? "描述画面想法，优化为生图提示词" : "描述任何你想要生成的内容",
                               onFocus: { if !editing { onBegin() } })
            .frame(height: 82)
            controls()
        }
        .padding(16)
        .foregroundColor(TapSkin.chromeInk)
        .background(TapSkin.cardEmptyFill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(TapSkin.border, lineWidth: 1))
        .onAppear { draft = text }
        .onChange(of: text) { if !editing { draft = $0 } }
    }
}

extension CanvasWorkspaceView {
    func videoInputSummary(_ node: CanvasNode) -> (title: String, detail: String)? {
        guard node.kind == .video else { return nil }
        let inputs = resolveEdgeInputs(for: node)
        let own = inputImagePaths(for: node)
        let model = modelCatalog.videoModels.first { $0.id == node.model }
        let frames = CanvasEdgeInputs.videoFrames(edgeInputs: inputs, slotImages: own, model: model)
        let used = Set([frames.first, frames.last].compactMap { $0 } + frames.references)
        let all = CanvasEdgeInputs.imageReferences(edgeInputs: inputs, slotImages: own)
        let excluded = all.filter { !used.contains($0) }.count
        let roles = [
            frames.first == nil ? nil : "首帧 1",
            frames.last == nil ? nil : "尾帧 1",
            frames.references.isEmpty ? nil : "参考 \(frames.references.count)"
        ].compactMap { $0 }.joined(separator: " · ")
        let title = (roles.isEmpty ? "无图片入参" : roles) + (excluded > 0 ? " · \(excluded) 图未使用" : "")
        let detail = (roles.isEmpty ? "无图片入参" : roles)
            + (excluded > 0 ? "。当前模型的互斥规则或数量限制排除了 \(excluded) 张图片。" : "。")
            + "点击连线可调整首帧、尾帧或参考图角色。"
            + (model == nil ? "模型目录尚未加载，暂保留全部图位。" : "")
        return (title, detail)
    }
    var canvasContentViewport: CGRect {
        CGRect(x: sidebarWidth + 12, y: 58,
               width: max(100, viewSize.width - sidebarWidth - 24),
               height: max(100, viewSize.height - 124))
    }

    var visibleNodes: [CanvasNode] {
        canvas.nodes.filter {
            editingNodeId == $0.id || draggingIds.contains($0.id) ||
                CanvasInteractionGeometry.isVisible(screenFrame(of: $0),
                                                    viewport: CGRect(origin: .zero, size: viewSize))
        }
    }

    var composerFrame: CGRect? {
        guard let node = canvas.soleSelectedNode, node.kind != .slot,
              addMenu == nil, linkDrag == nil, draggingNodeId == nil, inputFilesNodeId == nil else { return nil }
        let size = CGSize(width: min(max(640, min(900, screenFrame(of: node).width + 48)), canvasContentViewport.width), height: 204)
        return CGRect(origin: CanvasInteractionGeometry.panelOrigin(node: screenFrame(of: node),
                       panel: size, viewport: canvasContentViewport), size: size)
    }

    @ViewBuilder var composerOverlay: some View {
        if let node = canvas.soleSelectedNode, let frame = composerFrame {
            let isComposing = node.kind == .text ? composingNodeId == node.id : editingNodeId == node.id
            let references = canvas.incomingEdges(of: node.id).compactMap { canvas.node(id: $0.fromNodeId) }
            let slotCounts = Dictionary(references.filter { $0.kind == .slot }.map {
                ($0.id, Set(slotReferenceImagePaths(for: $0)).count)
            }, uniquingKeysWith: { first, _ in first })
            CanvasRenderBoundary(key: .init(
                node: node, selected: true, editing: isComposing,
                hovered: false, textVisible: true, slotRevision: canvas.slotRevision,
                contentRevision: store.canvasSlotRevision, currentGroup: store.currentSpecialSlotId,
                currentContentId: node.groupId == store.currentSpecialSlotId ? store.slots[node.slot]?.contentId : nil,
                path: videoInputSummary(node)?.detail ?? ""
            )) {
                CanvasNodeComposer(node: node, text: node.kind == .text ? node.textGenerationPrompt : liveText(for: node),
                               editing: isComposing,
                               inputCount: CanvasEdgeInputs.imageReferences(edgeInputs: resolveEdgeInputs(for: node),
                                                                           slotImages: inputImagePaths(for: node)).count,
                               inputSummary: videoInputSummary(node)?.title,
                               inputDetail: videoInputSummary(node)?.detail ?? "",
                               referenceNodes: references, slotImageCounts: slotCounts,
                               onReference: { reference in
                                   endInlineEditing()
                                   canvas.select(id: reference.id, additive: false)
                                   if !canvasContentViewport.intersects(screenFrame(of: reference)) { _ = handleKeyAction(.fitSelection) }
                               },
                               onBegin: {
                                   if node.kind == .text {
                                       editingNodeId = nil
                                       composingNodeId = node.id
                                   } else { beginEdit(node) }
                               },
                               onCommit: {
                                   if node.kind == .text {
                                       canvas.setTextGenerationPrompt(id: node.id, text: $0)
                                       composingNodeId = nil
                                   } else { commitEdit(node, text: $0) }
                               },
                               onCancel: { editingNodeId = nil; composingNodeId = nil },
                               onInputs: { openInputFiles(node) },
                               onRecover: node.taskId == nil || node.needsGenerationRecovery ? nil : { _ = recoverGeneration(node) },
                               onRestart: node.needsGenerationRecovery ? { _ = startGeneration(node, restarting: true) } : nil) {
                    nodeActions(node)
                }
            }
            .equatable()
            .id("\(canvas.activeProjectId):\(node.id):\(node.createdAt)")
            .frame(width: frame.width)
            .fixedSize(horizontal: false, vertical: true)
            .canvasControlRegion("composer")
            .offset(x: frame.minX, y: frame.minY)
            .zIndex(40)
        }
    }

    func nodeActions(_ node: CanvasNode) -> some View {
        CanvasNodeActionBar(node: node, canvas: canvas, catalog: CrateModelCatalogStore.shared,
                            upstreamCount: canvas.incomingEdges(of: node.id).count,
                            onRun: {
                                inputRouter.anchorView?.window?.makeFirstResponder(nil)
                                if let latest = canvas.node(id: node.id) {
                                    if latest.kind == .text { startTextGeneration(latest) }
                                    else { startGeneration(latest) }
                                }
                            },
                            onSpawnDownstream: { spawnDownstream(from: node) },
                            onRevealAsset: { revealAsset($0) },
                            canArchive: canArchiveToLibrary(node),
                            onArchive: { archiveNodeToLibrary(node) },
                            onOpenFullscreen: previewableMedia(of: node).map { media in
                                { openFullscreen(node, attachment: media) }
                            },
                            onCopyText: copyTextAction(for: node))
    }
}
