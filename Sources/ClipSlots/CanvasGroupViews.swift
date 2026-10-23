import SwiftUI
import ClipSlotsKit

struct CanvasGroupMeasuredNode: Equatable {
    let projectID: String
    let createdAt: Date
    let size: CGSize
}

struct CanvasGroupMeasurementPreference: PreferenceKey {
    static var defaultValue: [String: CanvasGroupMeasuredNode] = [:]
    static func reduce(value: inout [String: CanvasGroupMeasuredNode],
                       nextValue: () -> [String: CanvasGroupMeasuredNode]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct CanvasGroupNodeMeasurement: View {
    let node: CanvasNode
    let projectID: String
    let layoutScale: CGFloat
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CanvasGroupMeasurementPreference.self,
                value: [node.id: CanvasGroupMeasuredNode(projectID: projectID, createdAt: node.createdAt,
                    size: CGSize(width: proxy.size.width / max(layoutScale, 0.01),
                                 height: proxy.size.height / max(layoutScale, 0.01)))])
        }.allowsHitTesting(false)
    }
}

struct CanvasGroupWorkflowDraft: Identifiable {
    let id = UUID()
    let skill: WorkflowSkill
    let context: CanvasAgentContext
    let original: WorkflowSkill?
    let onSaved: () -> Void
}

struct CanvasGroupToolbar: View {
    let group: CanvasNodeGroup
    let running: Bool
    let canRun: Bool
    let canDownload: Bool
    let color: (CanvasGroupColor?) -> Void
    let layout: (CanvasGroupLayoutType) -> Void
    let run: () -> Void
    let save: () -> Void
    let ungroup: () -> Void
    let download: () -> Void
    let duplicate: () -> Void
    @State private var showingColors = false
    @State private var showingLayouts = false
    var body: some View {
        HStack(spacing: 0) {
            Button { showingColors.toggle() } label: { glyph("paintpalette", "背景色") }
                .buttonStyle(.plain)
                .canvasParameterPopover(isPresented: $showingColors) {
                    HStack(spacing: 8) {
                        Button { color(nil); showingColors = false } label: {
                            Image(systemName: "nosign").frame(width: 26, height: 26)
                        }.buttonStyle(.plain).help("透明背景")
                        ForEach(CanvasGroupColor.allCases, id: \.self) { value in
                            Button { color(value); showingColors = false } label: {
                                Circle().fill(TapSkin.tone(value.swatch, value.swatch))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(group.color == value ? CanvasSkin.ink : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).help(value.title)
                        }
                    }.padding(14).background(CanvasSkin.chromeFill)
                }
                .accessibilityIdentifier("canvas-group-color")
            Button { showingLayouts.toggle() } label: { glyph("rectangle.3.group", "布局") }
                .buttonStyle(.plain)
                .canvasParameterPopover(isPresented: $showingLayouts) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("方格布局") { layout(.grid); showingLayouts = false }
                            .accessibilityIdentifier("canvas-group-layout-grid")
                        Text("按行列整理，适合并列展示").font(.system(size: 10)).foregroundColor(.secondary)
                        Divider()
                        Button("横向布局") { layout(.horizontal); showingLayouts = false }
                            .accessibilityIdentifier("canvas-group-layout-horizontal")
                        Text("按连线方向排布，适合生成流程").font(.system(size: 10)).foregroundColor(.secondary)
                    }.padding(14).background(CanvasSkin.chromeFill)
                }
                .accessibilityIdentifier("canvas-group-layout")
            separator
            action(running ? "stop.fill" : "play.fill", running ? "停止运行" : "运行全部",
                   enabled: running || canRun, run)
            action("square.stack.3d.up", group.workflowSkillID == nil ? "保存工作流" : "更新工作流", save)
            separator
            action("plus.square.on.square", "创建副本", duplicate)
            action("square.dashed", "解除编组", ungroup)
            action("arrow.down.to.line", "批量下载", enabled: canDownload, download)
        }
        .padding(.horizontal, 6).frame(height: 64)
        .background(CanvasSkin.chromeFill, in: Capsule())
        .overlay(Capsule().stroke(CanvasSkin.border, lineWidth: 0.7).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
    private var separator: some View {
        Rectangle().fill(CanvasSkin.border).frame(width: 1, height: 20).padding(.horizontal, 5)
    }
    private func glyph(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 16)).frame(height: 19)
            Text(name).font(.system(size: 9, weight: .medium)).lineLimit(1).fixedSize()
        }
        .foregroundColor(CanvasSkin.chromeInk).frame(width: 50, height: 52)
        .contentShape(RoundedRectangle(cornerRadius: 12)).help(explanation(name)).accessibilityLabel(name)
    }
    private func explanation(_ name: String) -> String {
        switch name {
        case "背景色": return "为整组设置背景颜色，方便区分不同流程"
        case "布局": return "按方格或连线依赖，自动整理组内节点"
        case "运行全部": return "确认后按依赖顺序生成组内全部任务"
        case "停止运行": return "停止后续执行，已提交任务可继续取回"
        case "保存工作流", "更新工作流": return "把组内节点、提示词和连线保存为可复用工作流"
        case "解除编组": return "移除容器，保留所有节点、内容和连线"
        case "批量下载": return "下载组内已有的图片和视频原文件"
        default: return name
        }
    }
    private func action(_ symbol: String, _ name: String, enabled: Bool = true,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { glyph(symbol, name) }
            .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
            .accessibilityIdentifier("canvas-group-\(name)")
    }
}

struct CanvasGroupTitleEditor: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    let persist: (String) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        TextField("新建组", text: $text)
            .textFieldStyle(.plain).focused($focused)
            .onSubmit(save).onExitCommand(perform: cancel)
            .onAppear { focused = true }
            .onChange(of: focused) { value in if !value { save() } }
            .task(id: text) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                persist(text)
            }
            .accessibilityIdentifier("canvas-group-title-editor")
    }
}

struct CanvasActionToolbar: View {
    private typealias TapSkin = CanvasSkin
    let width: CGFloat
    let canArchive: Bool
    var imageDownload = false
    let canRun: Bool
    let running: Bool
    let canArrange: Bool
    let grouped: Bool
    let canGroup: Bool
    let archive: () -> Void
    let run: () -> Void
    let arrange: () -> Void
    let reset: () -> Void
    let group: () -> Void
    var canPile = false
    var pile: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { firstActions; lastActions }
            VStack(spacing: 2) {
                HStack(spacing: 4) { firstActions }
                HStack(spacing: 4) { lastActions }
            }
        }
        .padding(6).frame(maxWidth: width)
        .background(TapSkin.chromeFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(TapSkin.border, lineWidth: 0.7)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private var firstActions: some View {
        Group {
            action(imageDownload ? "下载原图" : "入库", imageDownload ? "arrow.down.to.line" : "tray.and.arrow.down",
                   enabled: canArchive, perform: archive)
            action(running ? "停止" : "运行", running ? "stop.fill" : "play.fill",
                   enabled: canRun || running, perform: run)
            action("自动排布", "rectangle.3.group", enabled: canArrange, perform: arrange)
        }
    }

    private var lastActions: some View {
        Group {
            action("重置尺寸", "arrow.up.left.and.arrow.down.right", enabled: true, perform: reset)
            if let pile { action("堆叠", "square.stack.3d.up", enabled: canPile, perform: pile) }
            action(grouped ? "解组" : "编组", "square.dashed", enabled: canGroup || grouped, perform: group)
        }
    }

    private func action(_ title: String, _ symbol: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .fixedSize().padding(.horizontal, 8).frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundColor(TapSkin.chromeInk.opacity(enabled ? 1 : 0.35))
        .disabled(!enabled)
        .accessibilityIdentifier("canvas-action-\(title)")
        .help(title)
    }
}

extension CanvasWorkspaceView {
    var selectionIsWholeGroup: Bool {
        canvas.selectedGroupID != nil
    }

    var actionToolbarWidth: CGFloat { min(466, max(190, canvasContentViewport.width - 20)) }
    var actionToolbarHeight: CGFloat {
        actionToolbarWidth < 435 || (canvas.selectedGroupID == nil && canvas.selectedNodeIds.count > 1) ? 76 : 42
    }
    private var canvasActionViewport: CGRect {
        let rect = canvasContentViewport
        let top = max(rect.minY, TapSkin.titlebarInset + 52)
        return CGRect(x: rect.minX, y: top, width: rect.width, height: max(0, rect.maxY - top))
    }

    func selectionToolbar(at anchor: CGPoint, retainedSelection: [CanvasNode]? = nil) -> some View {
        let selected = retainedSelection ?? selectedCanvasNodes
        let position = selectionToolbarPosition(anchor)
        return CanvasActionToolbar(
            width: actionToolbarWidth,
            canArchive: selected.contains(where: canArchiveToLibrary)
                || selected.contains { $0.kind == .image && !$0.isMediaSource && renderMedia(of: $0) != nil },
            imageDownload: selected.contains { $0.kind == .image && !$0.isMediaSource },
            canRun: selected.contains(where: \.canGenerate),
            running: canvas.selectionGenerationTask != nil,
            canArrange: selected.count > 1, grouped: selectionIsWholeGroup, canGroup: selected.count > 1,
            archive: {
                if selected.contains(where: { $0.kind == .image && !$0.isMediaSource }) {
                    downloadGeneratedImages(selected)
                } else { requestArchive(selected) }
            },
            run: {
                if canvas.selectionGenerationTask != nil { canvas.stopSelectionGeneration() }
                else { runGenerationForSelection() }
            },
            arrange: { canvas.autoArrange(canvas.selectedNodeIds) },
            reset: { canvas.resetNodeSizes(canvas.selectedNodeIds) },
            group: {
                if selectionIsWholeGroup { canvas.ungroupNodes(canvas.selectedNodeIds) }
                else { _ = canvas.groupNodes(canvas.selectedNodeIds) }
            }, canPile: canvas.selectedGroupID == nil
                && CanvasPileGeometry.creation(sourceIDs: canvas.selectedNodeIds.sorted(),
                    nodes: canvas.nodes, piles: canvas.piles, groups: canvas.groups) != nil,
            pile: canvas.selectedGroupID == nil && selected.count > 1 ? { createSelectionPile() } : nil)
            .canvasControlRegion("selection-actions")
            .position(position)
            .opacity(toolbarDoesNotCoverImages(position) ? 1 : 0)
            .allowsHitTesting(toolbarDoesNotCoverImages(position))
    }

    private func selectionToolbarPosition(_ anchor: CGPoint) -> CGPoint {
        let viewport = canvasActionViewport
        let x = min(max(anchor.x, viewport.minX + actionToolbarWidth / 2 + 6),
                    viewport.maxX - actionToolbarWidth / 2 - 6)
        var y = min(max(anchor.y, viewport.minY + actionToolbarHeight / 2 + 6),
                    viewport.maxY - actionToolbarHeight / 2 - 6)
        for group in canvas.groups where !canvas.selectedNodeIds.isDisjoint(with: canvas.groupMemberIDs(group.id)) {
            guard let header = groupHeaderFrame(group) else { continue }
            let frame = CGRect(x: x - actionToolbarWidth / 2, y: y - actionToolbarHeight / 2,
                               width: actionToolbarWidth, height: actionToolbarHeight)
            if frame.intersects(header.insetBy(dx: -6, dy: -6)) {
                let above = header.minY - 8 - actionToolbarHeight / 2
                let below = (groupScreenBounds(group)?.maxY ?? header.maxY) + 8 + actionToolbarHeight / 2
                if above - actionToolbarHeight / 2 >= viewport.minY + 6 { y = above }
                else if below + actionToolbarHeight / 2 <= viewport.maxY - 6 { y = below }
                else { y = header.maxY + 8 + actionToolbarHeight / 2 }
            }
        }
        let preferred = CGPoint(x: x, y: y)
        guard selectedCanvasNodes.contains(where: { $0.kind == .image && !$0.isMediaSource }) else {
            return preferred
        }
        // Toolbar may be clamped onto another batch image when the selected
        // image sits near the top edge. Find free canvas space before rendering.
        var candidates = [preferred]
        let images = canvas.nodes.filter { $0.kind == .image && !$0.isMediaSource }.map(screenFrame)
        let xs = [x, viewport.minX + actionToolbarWidth / 2 + 6,
                  viewport.maxX - actionToolbarWidth / 2 - 6]
        var ys = [viewport.minY + actionToolbarHeight / 2 + 6,
                  viewport.maxY - actionToolbarHeight / 2 - 6]
        for image in images {
            ys += [image.minY - actionToolbarHeight / 2 - 8,
                   image.maxY + actionToolbarHeight / 2 + 8]
        }
        candidates += xs.flatMap { candidateX in ys.map { CGPoint(x: candidateX, y: $0) } }
        return candidates.filter {
            let frame = toolbarRect($0)
            return viewport.contains(frame) && toolbarDoesNotCoverImages($0)
                && !(composerFrame?.intersects(frame) ?? false)
        }.min {
            hypot($0.x - preferred.x, $0.y - preferred.y) < hypot($1.x - preferred.x, $1.y - preferred.y)
        } ?? preferred
    }

    private func toolbarRect(_ center: CGPoint) -> CGRect {
        CGRect(x: center.x - actionToolbarWidth / 2, y: center.y - actionToolbarHeight / 2,
               width: actionToolbarWidth, height: actionToolbarHeight)
    }

    private func toolbarDoesNotCoverImages(_ center: CGPoint) -> Bool {
        guard selectedCanvasNodes.contains(where: { $0.kind == .image && !$0.isMediaSource }) else { return true }
        let frame = toolbarRect(center)
        return !canvas.nodes.contains {
            $0.kind == .image && !$0.isMediaSource && screenFrame(of: $0).intersects(frame)
        }
    }

    /// Keep the group's Generate action reachable while a large group is
    /// partially outside the viewport, without occupying the library or Agent.
    func groupHeaderFrame(_ group: CanvasNodeGroup) -> CGRect? {
        guard let bounds = groupScreenBounds(group) else { return nil }
        let font = min(12, 60 * zoom)
        return CGRect(x: bounds.minX, y: bounds.minY - max(24 * zoom, font + 8),
                      width: min(max(100, bounds.width), 360), height: max(22, font + 8))
    }

    func groupScreenBounds(_ group: CanvasNodeGroup) -> CGRect? {
        guard var frame = CanvasGroupGeometry.frame(group, nodes: canvas.nodes) else { return nil }
        if canvas.selectedGroupID == group.id, let preview = groupResizePreview { frame = preview }
        let movingRoot = groupDragID ?? (groupResizePreview != nil ? canvas.selectedGroupID : nil)
        if let root = movingRoot,
           CanvasGroupHierarchy.subtreeIDs(root, groups: canvas.groups).contains(group.id),
           !(canvas.selectedGroupID == group.id && groupResizePreview != nil) {
            frame = frame.offsetBy(dx: dragDelta.width, dy: dragDelta.height)
        }
        let origin = CanvasGeometry.screenPoint(canvas: frame.origin, pan: effectivePan, zoom: zoom)
        return CGRect(origin: origin, size: CGSize(width: frame.width * zoom, height: frame.height * zoom))
    }

    @ViewBuilder var groupBackgroundLayer: some View {
        ForEach(CanvasGroupHierarchy.parentFirst(canvas.groups)) { group in
            if let rect = groupScreenBounds(group) {
                let selected = canvas.selectedGroupID == group.id
                RoundedRectangle(cornerRadius: 12 * zoom)
                    .fill(group.color.map { groupFill($0) } ?? Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 12 * zoom)
                        .stroke(selected ? TapSkin.accent : TapSkin.border, lineWidth: selected ? 1.5 : 0.8))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func groupFill(_ color: CanvasGroupColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = dark ? color.rgb : color.swatch
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255,
                alpha: dark ? 0.8 : 0.10)
        })
    }

    @ViewBuilder var groupHeaderLayer: some View {
        ForEach(CanvasGroupHierarchy.parentFirst(canvas.groups)) { group in
            if let rect = groupHeaderFrame(group) {
                Group {
                    if editingGroupID == group.id {
                        CanvasGroupTitleEditor(text: $groupTitleDraft,
                            save: { finishGroupTitle() }, cancel: { editingGroupID = nil },
                            persist: { if editingGroupID == group.id { canvas.renameGroup(group.id, name: $0) } })
                            .canvasControlRegion("group-title-editor-\(group.id)")
                    } else {
                        Text(group.name).lineLimit(1).allowsHitTesting(false)
                    }
                }
                .font(.system(size: min(12, 60 * zoom), weight: .medium))
                .foregroundColor(TapSkin.chromeInk).frame(width: rect.width, height: rect.height, alignment: .leading)
                .position(x: rect.midX, y: rect.midY)
            }
            if canvas.selectedGroupID == group.id, let bounds = groupScreenBounds(group) {
                ForEach(CanvasGroupResizeHandle.allCases, id: \.self) { handle in
                    let point = handle.point(in: bounds)
                    Rectangle().fill(TapSkin.chromeFill)
                        .overlay(Rectangle().stroke(TapSkin.accent, lineWidth: 1))
                        .frame(width: 7, height: 7).position(point).allowsHitTesting(false)
                }
                if groupDragID == nil, groupResizePreview == nil, addMenu == nil {
                    let members = canvas.nodes.filter { canvas.groupMemberIDs(group.id).contains($0.id) }
                    let running = canvas.runningGroupID == group.id && canvas.selectionGenerationTask != nil
                    CanvasGroupToolbar(group: group, running: running,
                        canRun: canvas.selectionGenerationTask == nil && members.contains(where: \.canGenerate),
                        canDownload: members.contains { node in
                            guard let entry = contentSnapshots.entry(node),
                                  let media = CanvasMediaPick.primary(node: node, attachments: entry.content.attachments) else { return false }
                            return [media.storagePath, media.path, media.originalPath].compactMap { $0 }
                                .contains(where: entry.existingPaths.contains)
                        },
                        color: { canvas.setGroupColor(group.id, color: $0) },
                        layout: { canvas.arrangeGroup(group.id, layout: $0) },
                        run: {
                            if running { canvas.stopSelectionGeneration() }
                            else { requestGroupRun(group) }
                        }, save: { saveGroupWorkflow(group) },
                        ungroup: { canvas.ungroupGroup(group.id) },
                        download: { downloadGroupMedia(group) },
                        duplicate: {
                            canvas.selectGroup(group.id)
                            copyCanvasStructure(duplicate: true)
                        })
                        .canvasControlRegion("group-toolbar-\(group.id)")
                        .position(groupToolbarPosition(bounds))
                }
            }
        }
    }

    func beginGroupTitle(_ group: CanvasNodeGroup) {
        endInlineEditing()
        canvas.selectGroup(group.id)
        groupTitleDraft = group.name
        editingGroupID = group.id
    }

    func finishGroupTitle() {
        guard let id = editingGroupID else { return }
        editingGroupID = nil
        canvas.renameGroup(id, name: groupTitleDraft)
    }

    private func groupToolbarPosition(_ bounds: CGRect) -> CGPoint {
        let viewport = canvasActionViewport
        let halfWidth: CGFloat = 199
        let x = max(viewport.minX + halfWidth + 6, min(bounds.midX, viewport.maxX - halfWidth - 6))
        let above = bounds.minY - min(48, 60 * zoom) - 32
        let y = above >= viewport.minY + 36 ? above : bounds.maxY + 44
        return CGPoint(x: x, y: max(viewport.minY + 36, min(y, viewport.maxY - 36)))
    }

    func requestGroupRun(_ group: CanvasNodeGroup) {
        guard groupRunAlert == nil, let window = inputRouter.anchorView?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "运行「\(group.name)」中的全部节点？"
        alert.informativeText = "将按连线依赖顺序执行生成，使用各节点当前的模型和参数。"
        alert.addButton(withTitle: "运行全部")
        alert.addButton(withTitle: "取消")
        groupRunAlert = alert
        let project = canvas.activeProjectId
        let memberIDs = canvas.groupMemberIDs(group.id)
        alert.beginSheetModal(for: window) { response in
            groupRunAlert = nil
            guard response == .alertFirstButtonReturn, canvas.activeProjectId == project,
                  let live = canvas.groups.first(where: { $0.id == group.id }),
                  canvas.groupMemberIDs(live.id) == memberIDs, canvas.selectionGenerationTask == nil else { return }
            runGeneration(nodeIDs: canvas.groupMemberIDs(live.id), groupID: live.id)
        }
    }

    func groupWorkflow(_ group: CanvasNodeGroup) throws -> WorkflowSkill {
        guard canvas.flushTextDocuments?() != false else { throw AgentOperationError("正文尚未保存，请重试。") }
        let ids = canvas.groupMemberIDs(group.id)
        let facts = CanvasWorkflowCapture.facts(nodes: canvas.nodes.filter { ids.contains($0.id) }, store: store)
        let graph = CanvasWorkflowSnapshot(projectID: canvas.activeProjectId, facts: facts,
            edges: canvas.interactionEdges.filter { ids.contains($0.fromNodeId) && ids.contains($0.toNodeId) },
            selectionIDs: ids.sorted(), models: modelCatalog.imageModels + modelCatalog.videoModels)
        var skill = try WorkflowSkill(snapshot: .init(graph: graph, runs: []),
            method: "按组内连线顺序复用「\(group.name)」的节点与参数。",
            messageID: nil, receipts: [], selectedWorkflow: true)
        skill.name = group.name
        return skill
    }

    func saveGroupWorkflow(_ group: CanvasNodeGroup) {
        do {
            let context = CanvasAgentContext(canvas: canvas, store: store, projectID: canvas.activeProjectId)
            context.onLeaveProject = { groupWorkflowDraft = nil }
            var draft = try groupWorkflow(group)
            var original: WorkflowSkill?
            if let id = group.workflowSkillID,
               let entry = WorkflowSkillStore().list(projectID: canvas.activeProjectId).first(where: { $0.id == id }) {
                let saved = try WorkflowSkillStore().load(entry, projectID: canvas.activeProjectId)
                draft.id = saved.id; draft.version = saved.version
                draft.scope = saved.scope; draft.projectID = saved.projectID
                draft.method = saved.method; draft.summary = saved.summary
                original = saved
            }
            let skillID = draft.id
            groupWorkflowDraft = .init(skill: draft, context: context, original: original, onSaved: {
                guard context.isActive else { return }
                canvas.attachGroupWorkflow(group.id, skillID: skillID)
                store.transientUI.showToast("编组工作流已保存")
            })
        } catch { store.transientUI.showToast(error.localizedDescription) }
    }

    func downloadGroupMedia(_ group: CanvasNodeGroup) {
        let files = canvas.groupMemberIDs(group.id).sorted().compactMap { canvas.node(id: $0) }.compactMap { node in
            (previewableMedia(of: node)?.canvasLocalURL).map { (node, $0) }
        }
        Task {
            var count = 0
            for (node, file) in files {
                do {
                    if node.kind == .image {
                        _ = try await CanvasImageDownloads.shared.save(file: file, taskID: node.taskId ?? node.id)
                    } else {
                        let root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("ClipSlots")
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        let target = root.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
                        try FileManager.default.copyItem(at: file, to: target)
                    }
                    count += 1
                } catch { store.transientUI.showToast("下载失败：" + error.localizedDescription); return }
            }
            store.transientUI.showToast("已下载 \(count) 个文件到 Downloads/ClipSlots")
        }
    }
}
