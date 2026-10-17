import SwiftUI
import ClipSlotsKit

/// 生成操作保持屏幕字号；提示词编辑和媒体预览可以同时进行。
struct CanvasNodeComposer<Controls: View>: View {
    private typealias TapSkin = CanvasSkin
    let node: CanvasNode
    let text: String
    let editing: Bool
    let inputCount: Int
    var inputSummary: String? = nil
    var inputDetail: String = ""
    let referenceNodes: [CanvasNode]
    let referenceMedia: [String: SlotContent.SlotAttachment]
    let inputAttachments: [SlotContent.SlotAttachment]
    let slotImageCounts: [String: Int]
    let onReference: (CanvasNode) -> Void
    let onInputPreview: (SlotContent.SlotAttachment) -> Void
    let onBegin: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let onInputs: () -> Void
    let onManageInputs: () -> Void
    let onRecover: (() -> Void)?
    var onRestart: (() -> Void)? = nil
    @ViewBuilder let controls: () -> Controls
    @State private var draft = ""
    @State private var showingError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onInputs) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(TapSkin.subtleFill))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(TapSkin.border))
                }
                .buttonStyle(.plain)
                .help("添加参考文件")
                .accessibilityLabel("添加参考文件")
                .canvasControlRegion("composer-add-input")
                if !referenceNodes.isEmpty || !inputAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(referenceNodes) { reference in
                                Button { onReference(reference) } label: {
                                    HStack(spacing: 4) {
                                        if let media = referenceMedia[reference.id] {
                                            CanvasAttachmentPreviewImage(attachment: media, maxPixel: 80)
                                                .frame(width: 32, height: 32)
                                                .background(TapSkin.subtleFill)
                                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                                .overlay(alignment: .bottomTrailing) {
                                                    if media.canvasIsVideoLike {
                                                        Image(systemName: "play.fill")
                                                            .font(.system(size: 7))
                                                            .foregroundColor(.white)
                                                            .padding(3)
                                                            .background(Circle().fill(.black.opacity(0.6)))
                                                            .padding(2)
                                                    }
                                                }
                                                .canvasControlRegion("composer-reference-media-\(reference.id)-\(media.id.uuidString)")
                                        } else {
                                            Image(systemName: reference.kind.symbolName)
                                                .frame(width: 32, height: 32)
                                        }
                                        if reference.kind == .slot {
                                            let count = slotImageCounts[reference.id] ?? 0
                                            Text(count > 0 ? "槽位 · \(count) 图" : "槽位")
                                                .padding(.trailing, 8)
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .background(RoundedRectangle(cornerRadius: 7).fill(TapSkin.nodeAccent(reference.kind).opacity(0.12)))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(TapSkin.border))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("查看引用\(reference.kind == .slot ? "槽位" : (reference.kind == .text ? "文本" : (reference.kind == .image ? "图片" : "视频")))")
                                .accessibilityLabel("连接的\(reference.kind.displayName)")
                                .canvasControlRegion("composer-reference-\(reference.id)")
                            }
                            ForEach(inputAttachments) { attachment in
                                Button { onInputPreview(attachment) } label: {
                                    CanvasAttachmentPreviewImage(attachment: attachment, maxPixel: 80)
                                        .frame(width: 32, height: 32)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(TapSkin.subtleFill))
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(TapSkin.border))
                                }
                                .buttonStyle(.plain)
                                .help("入参：\(attachment.name)")
                                .accessibilityLabel("参考文件 \(attachment.name)")
                                .canvasControlRegion("composer-input-\(attachment.id.uuidString)")
                            }
                        }
                    }.frame(height: 32)
                }
                if inputCount > 0 || inputSummary != nil {
                    Text(inputSummary ?? "\(inputCount) 张参考图")
                        .font(.system(size: 11)).foregroundColor(TapSkin.chromeInkDim)
                        .lineLimit(1)
                        .help(inputDetail)
                }
                Button(action: onManageInputs) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
                .help("管理入参文件")
                .accessibilityLabel("管理入参文件")
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
                                    let source = node.generationTask?.context.provider == .byteartist
                                        ? "BA 工作流：" + (node.generationTask?.capabilityID ?? node.byteArtist.workflowID)
                                        : "Crate 模型：" + node.model
                                    let diagnostic = node.generationDiagnostic
                                    NSPasteboard.general.setString("ClipSlots \(AppVersion.current)\n\(source)\n任务：\(node.taskId ?? "未提交")\n阶段：\(diagnostic?.stage ?? "")\n远端状态：\(diagnostic?.rawStatus ?? "")\nrequest_id：\(diagnostic?.requestID ?? "")\nlog_id：\(diagnostic?.logID ?? "")\n\(reason)", forType: .string)
                                }
                            }.padding(16).frame(width: 360)
                        }
                }
                if let diagnostic = node.generationDiagnostic,
                   case .idle = node.state, node.generationTask?.context.provider == .byteartist {
                    Text(diagnostic.message ?? diagnostic.stageLabel)
                        .font(.system(size: 10)).foregroundColor(TapSkin.chromeInkDim).lineLimit(2)
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
            .tapCursor(.iBeam)
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
               height: max(100, viewSize.height - (footerControlsStacked ? 176 : 124)))
    }

    var footerControlsStacked: Bool { viewSize.width - sidebarWidth < 553 }
    var navigationChromeFrame: CGRect {
        CGRect(x: sidebarWidth + 14, y: viewSize.height - 56, width: 337, height: 40)
    }
    var footerToolbarFrame: CGRect {
        let left = sidebarWidth
        let preferred = left + (viewSize.width - left) / 2
        let center = footerControlsStacked ? viewSize.width - 14 - 88
            : min(viewSize.width - 14 - 88, max(preferred, navigationChromeFrame.maxX + 12 + 88))
        return CGRect(x: center - 88, y: viewSize.height - 56 - (footerControlsStacked ? 52 : 0),
                      width: 176, height: 40)
    }

    var visibleNodes: [CanvasNode] {
        canvas.nodes.filter {
            !canvas.piledMemberIDs.contains($0.id) && (editingNodeId == $0.id || draggingIds.contains($0.id) ||
                CanvasInteractionGeometry.isVisible(screenFrame(of: $0),
                                                    viewport: CGRect(origin: .zero, size: viewSize)))
        }
    }

    var composerFrame: CGRect? {
        guard let node = canvas.soleSelectedNode, node.kind != .slot, !node.isMediaSource,
              addMenu == nil, linkDrag == nil, draggingNodeId == nil, inputFilesNodeId == nil else { return nil }
        let height = node.kind == .text ? textComposerHeight : 204
        let size = CGSize(width: min(max(640, min(900, screenFrame(of: node).width + 48)), canvasContentViewport.width), height: height)
        return CGRect(origin: CanvasInteractionGeometry.panelOrigin(node: screenFrame(of: node),
                       panel: size, viewport: canvasContentViewport), size: size)
    }

    @ViewBuilder var composerOverlay: some View {
        if let node = canvas.soleSelectedNode, let frame = composerFrame {
            let isComposing = node.kind == .text ? composingNodeId == node.id : editingNodeId == node.id
            let edges = canvas.incomingEdges(of: node.id).filter { $0.fromNodeId != node.generationSourceID }
            let references = edges.compactMap { canvas.node(id: $0.fromNodeId) }
            CanvasRenderBoundary(key: .init(
                node: node, selected: true, editing: isComposing,
                hovered: false, textVisible: true, slotRevision: canvas.slotRevision,
                contentRevision: store.canvasSlotRevision, currentGroup: store.currentSpecialSlotId,
                currentContentId: node.groupId == store.currentSpecialSlotId ? store.slots[node.slot]?.contentId : nil,
                path: videoInputSummary(node)?.detail ?? "",
                referenceNodes: references, referenceEdges: edges
            )) {
                // 沿用主卡片的媒体选择与缩略图缓存；上游身份变化才重读内容。
                let media = Dictionary(references.compactMap { reference in
                    reference.kind == .text ? nil : previewableMedia(of: reference).map { (reference.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
                let slotCounts = Dictionary(references.filter { $0.kind == .slot }.map {
                    ($0.id, Set(slotReferenceImagePaths(for: $0)).count)
                }, uniquingKeysWith: { first, _ in first })
                if node.kind == .text {
                    CanvasTextComposer(document: store.canvasTextDocument(groupID: node.groupId, slot: node.slot),
                        node: node, editing: isComposing,
                        maximumEditorHeight: max(112, min(280, canvasContentViewport.height - 160)),
                        onBegin: { editingNodeId = nil; composingNodeId = node.id },
                        onEnd: { composingNodeId = nil },
                        onPolish: {
                            inputRouter.anchorView?.window?.makeFirstResponder(nil)
                            startTextGeneration(node)
                        },
                        onStop: { canvas.stopGeneration(node) },
                        onHeightChange: { textComposerHeight = $0 })
                } else {
                CanvasNodeComposer(node: node, text: liveText(for: node),
                               editing: isComposing,
                               inputCount: CanvasEdgeInputs.imageReferences(edgeInputs: resolveEdgeInputs(for: node),
                                                                           slotImages: inputImagePaths(for: node)).count,
                               inputSummary: videoInputSummary(node)?.title,
                               inputDetail: videoInputSummary(node)?.detail ?? "",
                               referenceNodes: references, referenceMedia: media,
                               inputAttachments: inputAttachments(for: node),
                               slotImageCounts: slotCounts,
                               onReference: { reference in
                                   endInlineEditing()
                                   canvas.select(id: reference.id, additive: false)
                                   if !canvasContentViewport.intersects(screenFrame(of: reference)) { _ = handleKeyAction(.fitSelection) }
                               },
                               onInputPreview: { attachment in
                                   if attachment.canvasIsImageLike || attachment.canvasIsVideoLike {
                                       openFullscreen(node, attachment: attachment)
                                   } else { openInputFiles(node) }
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
                               onInputs: { addInputFiles(node) },
                               onManageInputs: { openInputFiles(node) },
                               onRecover: node.taskId == nil || node.needsGenerationRecovery ? nil : { _ = recoverGeneration(node) },
                               onRestart: node.needsGenerationRecovery ? { _ = startGeneration(node, restarting: true) } : nil) {
                    nodeActions(node)
                }
                }
            }
            .equatable()
            .id("\(canvas.activeProjectId):\(node.id):\(node.createdAt)")
            .frame(width: frame.width)
            .fixedSize(horizontal: false, vertical: true)
            .canvasControlRegion("composer")
            .offset(x: frame.minX, y: frame.minY)
            // A generation panel owns its visible rectangle, including areas
            // overlapping media cards. Pointer/focus routing uses the same rule.
            .zIndex(40)
        }
    }

    func nodeActions(_ node: CanvasNode) -> some View {
        CanvasNodeActionBar(node: node, canvas: canvas, catalog: CrateModelCatalogStore.shared,
                            upstreamCount: canvas.incomingEdges(of: node.id).count,
                            onRun: {
                                inputRouter.anchorView?.window?.makeFirstResponder(nil)
                                if let latest = canvas.node(id: node.id) {
                                    generateAdjacentResults(latest)
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
