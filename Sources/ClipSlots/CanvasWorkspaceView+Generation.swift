import SwiftUI
import ClipSlotsKit

/// 画布生图的**编排层**（v2.11.17）。
///
/// 把三件事串起来：从槽位读入参 → 交给 `CrateGenerationService` 跑 CLI → 产物写回槽位附件、
/// 节点状态落到 `.succeeded/.failed`。之所以放在 `CanvasWorkspaceView` 的扩展里，是因为这条链路
/// 同时需要 `store`（槽位读写）与 `canvas`（节点状态），而这里是唯一同时持有两者的地方。
///
/// ★ 数据流向遵守 hotfix20 立下的规矩
///
/// 节点不持有内容：提示词**当场从槽位读**，产物**写回槽位附件**。节点上只留"这次任务是怎么跑的"
/// 这类元信息（taskId / seed / state）。如果产物存进节点字段，画布文档（派生资产，损坏即丢弃重建）
/// 就变成了用户唯一资产的载体，这是不能接受的。
extension CanvasWorkspaceView {

    // MARK: - 入口

    /// 右上「生成」按钮。
    ///
    /// 选取规则：有选中就跑选中的图像节点；没选中且画布上只有一个图像节点就跑它；其余情况明确
    /// 要求先选中——刻意不做"全部一起跑"，那会在一次误点后烧掉一堆额度。
    func runGenerationForSelection() {
        let imageNodes = canvas.nodes.filter { $0.kind == .image }
        let selected = imageNodes.filter { canvas.selectedNodeIds.contains($0.id) }

        let targets: [CanvasNode]
        if !selected.isEmpty {
            targets = selected
        } else if imageNodes.count == 1 {
            targets = imageNodes
        } else if imageNodes.isEmpty {
            store.transientUI.showToast("画布上还没有图像生成节点")
            return
        } else {
            store.transientUI.showToast("先选中要生成的图像节点")
            return
        }

        // 选区里混了别的类型时说一声，否则用户会以为文本节点也提交了。
        let skipped = canvas.selectedNodeIds.count - targets.count
        if skipped > 0 {
            store.transientUI.showToast("已提交 \(targets.count) 个图像节点（跳过 \(skipped) 个非图像节点）")
        }
        for node in targets {
            startGeneration(node)
        }
    }

    /// 单个节点的生成 / 重跑。
    func startGeneration(_ node: CanvasNode, reusingSeed: Bool = false) {
        guard node.kind == .image else {
            store.transientUI.showToast("\(node.kind.displayName)节点还没接入生成")
            return
        }
        // 进行中的节点不允许再点。两次提交会产生两个任务，但节点只有一个 taskId 字段，
        // 后一个会把前一个覆盖掉——那张图就成了无主产物。
        if case .running = node.state {
            store.transientUI.showToast("这个节点正在生成中")
            return
        }
        if case .queued = node.state {
            store.transientUI.showToast("这个节点正在排队中")
            return
        }

        let prompt = store.canvasSlotText(groupId: node.groupId, slot: node.slot) ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.transientUI.showToast(CrateRequestError.emptyPrompt.userMessage)
            return
        }
        guard node.count == 1 else {
            // 刻意拒绝而不是"悄悄只出一张"：参数栏写着 4 张却只出 1 张，等于 UI 在骗人。
            // n 张 = n 个独立任务（CLI 的 --count 语义），而节点身份是 groupId#slot，
            // 同一槽位放不下第二个节点——这个冲突留给批量模版节点一起解决。
            store.transientUI.showToast(CrateRequestError.unsupportedCount(node.count).userMessage)
            return
        }

        let request = CrateImageRequest(model: node.model,
                                       prompt: prompt,
                                       ratio: node.ratio,
                                       count: node.count,
                                       imagePaths: inputImagePaths(for: node),
                                       seed: reusingSeed ? node.seed : nil)
        let nodeId = node.id
        let groupId = node.groupId
        let slot = node.slot

        canvas.updateNode(id: nodeId) { $0.state = .running(startedAt: Date()) }

        Task {
            let service = CrateGenerationService.shared
            do {
                try await service.preflight()
                let submission = try await service.submit(request)
                let submitted = submission.result
                await MainActor.run {
                    canvas.updateNode(id: nodeId) {
                        $0.taskId = submitted.taskId
                        if let seed = submitted.seed { $0.seed = seed }
                    }
                    // 用户点的是「重跑」（= 同一个种子再来一次），而这个模型压根不收 seed。
                    // 不说一声就等于让人以为"同样的参数出了不一样的图"。
                    if submission.droppedSeed {
                        store.transientUI.showToast("\(node.model) 不支持固定 seed，本次用新种子", duration: 2.6)
                    }
                }

                let urls = try await service.waitForCompletion(taskId: submitted.taskId) { progress in
                    Task { @MainActor in
                        applyProgress(progress, toNodeId: nodeId)
                    }
                }
                guard let first = urls.first else {
                    throw CrateGenerationService.ServiceError.taskFailed(reason: "任务完成但没有产物")
                }

                let file = try await service.download(urlString: first,
                                                      taskId: submitted.taskId,
                                                      index: 0)
                await MainActor.run {
                    finishGeneration(nodeId: nodeId,
                                     groupId: groupId,
                                     slot: slot,
                                     downloadedFile: file,
                                     taskId: submitted.taskId)
                }
            } catch is CancellationError {
                await MainActor.run {
                    canvas.updateNode(id: nodeId) { $0.state = .failed(reason: "已取消") }
                }
            } catch let err as CrateGenerationService.ServiceError {
                NSLog("[ClipSlots][crate] node=\(nodeId) 失败：\(err.logDetail)")
                await MainActor.run {
                    canvas.updateNode(id: nodeId) { $0.state = .failed(reason: err.userMessage) }
                    store.transientUI.showToast(err.userMessage, duration: 2.6)
                }
            } catch {
                NSLog("[ClipSlots][crate] node=\(nodeId) 失败：\(error)")
                await MainActor.run {
                    let reason = error.localizedDescription
                    canvas.updateNode(id: nodeId) { $0.state = .failed(reason: reason) }
                    store.transientUI.showToast(reason, duration: 2.6)
                }
            }
        }
    }

    // MARK: - 中间步骤

    /// 服务端观测 → 节点状态。
    ///
    /// `running` 的 `startedAt` 只在**首次**进入时设：每轮轮询都刷新一次的话，卡片上的已用秒数
    /// 会永远停在 0~5s，等于把"跑了多久"这个唯一的进度信息废掉。
    @MainActor
    private func applyProgress(_ progress: CrateTaskProgress, toNodeId nodeId: String) {
        switch progress {
        case .queued(let ahead):
            canvas.updateNode(id: nodeId) { $0.state = .queued(ahead: ahead) }
        case .running:
            canvas.updateNode(id: nodeId) { node in
                if case .running = node.state { return }
                node.state = .running(startedAt: Date())
            }
        case .succeeded, .failed:
            // 终态由 startGeneration 的主流程统一落（要先把产物下载并写进槽位，才算真成功）。
            break
        }
    }

    /// 入参图片：槽位里 image 型附件的本地路径，**剔除本节点自己的历史产物**。
    ///
    /// 规则本体在 `CrateGeneration.inputImagePaths`（Kit 层，带 smoke 覆盖）；这里只负责取数据。
    private func inputImagePaths(for node: CanvasNode) -> [String] {
        let attachments = store.canvasSlotAttachments(groupId: node.groupId, slot: node.slot)
        return CrateGeneration.inputImagePaths(from: attachments,
                                              excludingAttachmentIds: Set(node.outputAttachmentIds),
                                              fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// 产物落地：写成槽位附件 → 节点置 `.succeeded`。
    ///
    /// `assetPath` 存的是**槽位附件的本地字节路径**而不是 CDN URL：URL 会过期，而节点状态要落盘。
    /// 取存储层回填的 `storagePath`（写入时字节被摄取进 `attachments/{id}.bin`），这样"卡片预览"
    /// 与"槽位附件"永远是同一份字节，不会出现删了附件预览还在的幽灵。
    @MainActor
    private func finishGeneration(nodeId: String,
                                 groupId: String,
                                 slot: Int,
                                 downloadedFile: URL,
                                 taskId: String) {
        defer {
            // 临时文件用完即删（字节已被存储层摄取）。目录是我们自己建的一次性目录。
            try? FileManager.default.removeItem(at: downloadedFile.deletingLastPathComponent())
        }

        // 字节走 `data` 交给存储层，**刻意不填 path / originalPath**：那两个字段的语义是"用户
        // 磁盘上的源文件"，而这里的源文件是我们自己刚建、马上就要删的临时文件。填了它就是一条
        // 天生断链的引用 —— 断链检测会对着一张明明还在的图报"源文件已丢失"。
        guard let bytes = try? Data(contentsOf: downloadedFile) else {
            let reason = "产物读取失败（\(downloadedFile.lastPathComponent)）"
            canvas.updateNode(id: nodeId) { $0.state = .failed(reason: reason) }
            store.transientUI.showToast(reason, duration: 2.6)
            return
        }
        let attachment = SlotContent.SlotAttachment(name: downloadedFile.lastPathComponent,
                                                    type: .image,
                                                    data: bytes)
        var attachments = store.canvasSlotAttachments(groupId: groupId, slot: slot)
        attachments.append(attachment)

        guard store.writeCanvasSlotAttachments(groupId: groupId, slot: slot, attachments: attachments) else {
            let reason = "产物写入槽位失败（槽位 \(slot)）"
            canvas.updateNode(id: nodeId) { $0.state = .failed(reason: reason) }
            store.transientUI.showToast(reason, duration: 2.6)
            return
        }

        // 写完再读一次，拿存储层回填后的真实路径。找不到就退化用原始下载路径——但那个文件马上要删，
        // 所以此时宁可只把状态标成成功、预览等下次刷新，也不要留一个指向已删文件的 assetPath。
        let persisted = store.canvasSlotAttachments(groupId: groupId, slot: slot)
        let stillThere = Set(persisted.map { $0.id.uuidString })
        let saved = persisted.last { $0.id == attachment.id }
        let assetPath = saved?.storagePath ?? saved?.path ?? ""

        canvas.updateNode(id: nodeId) { node in
            node.state = .succeeded(assetPath: assetPath)
            node.taskId = taskId
            // 顺手清掉已经不在槽位里的旧 id（用户手动删过产物）：这个数组每轮生成都会长一项，
            // 不清就会变成一份只增不减的墓碑名单，而它每次提交都要参与集合判定。
            node.outputAttachmentIds = node.outputAttachmentIds.filter { stillThere.contains($0) }
            node.outputAttachmentIds.append(attachment.id.uuidString)
        }
        // 卡片上的附件行 / 缩略图靠这个 revision 重取（槽位数据变了，画布侧要知道）。
        store.bumpCanvasSlotRevision()
        canvas.noteSlotDataChanged()
        store.transientUI.showToast("生成完成")
    }
}
