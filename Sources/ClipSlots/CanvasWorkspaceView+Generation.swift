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
    /// 选取规则：有选中就跑选中的可生成节点；没选中且画布上只有一个就跑它；其余情况明确
    /// 要求先选中——刻意不做"全部一起跑"，那会在一次误点后烧掉一堆额度。
    ///
    /// v2.11.19 起「可生成」= 图像节点 ∪ 视频节点。刻意**不做类型混检**（选中 3 图 + 2 视频就
    /// 五个一起提交）：用户的选区就是他的意图，而这两类的产物都各自写回自己的槽位，互不干扰。
    func runGenerationForSelection() {
        let runnable = canvas.nodes.filter { $0.kind.producesAsset }
        let selected = runnable.filter { canvas.selectedNodeIds.contains($0.id) }

        let targets: [CanvasNode]
        if !selected.isEmpty {
            targets = selected
        } else if runnable.count == 1 {
            targets = runnable
        } else if runnable.isEmpty {
            store.transientUI.showToast("画布上还没有图像 / 视频生成节点")
            return
        } else {
            store.transientUI.showToast("先选中要生成的节点")
            return
        }

        // 选区里混了别的类型时说一声，否则用户会以为文本节点也提交了。
        let skipped = canvas.selectedNodeIds.count - targets.count
        if skipped > 0 {
            store.transientUI.showToast("已提交 \(targets.count) 个节点（跳过 \(skipped) 个不可生成节点）")
        }
        for node in targets {
            startGeneration(node)
        }
    }

    /// 单个节点的生成 / 重跑。
    ///
    /// v2.11.19 起按 kind 分流到两条链路。分流点放在这里（而不是各自一个入口方法）是因为前面那
    /// 五道门禁（运行中 / 排队中 / 空提示词 / 张数 / 类型）两条链路完全一样，而它们每一条都对应
    /// 一个具体的历史 bug，复制一份只会让下次改动漏掉一侧。
    func startGeneration(_ node: CanvasNode, reusingSeed: Bool = false) {
        guard node.kind.producesAsset else {
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

        if node.kind == .video {
            startVideoGeneration(node, prompt: prompt, reusingSeed: reusingSeed)
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
                    // 尺寸被拒同理：选择器里明明写着 4:3，出来却是模型默认尺寸，不说一声就是"选项失灵"。
                    if submission.droppedRatio {
                        store.transientUI.showToast("\(node.model) 不支持比例 \(node.ratio)，本次用模型默认尺寸", duration: 2.6)
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

    // MARK: - 视频链路（v2.11.19）

    /// 视频节点的生成 / 重跑。
    ///
    /// 与图像链路结构相同（提交 → 轮询 → 下载 → 写回槽位），四处刻意不同：
    ///
    ///   1. **入参图按角色分配**（首帧 / 尾帧 / 参考图），而不是一把 `--image`；
    ///   2. **轮询时限 1800s** 而不是 600s（视频动辄几分钟，600s 会把成功的任务误判成超时）；
    ///   3. **产物兜底扩展名是 mp4**，否则 URL 认不出扩展名时会落成 `.jpg`，卡片按扩展名判类别
    ///      就会拿 `NSImage` 去读一个 mp4，预览区空白；
    ///   4. **参数按模型能力裁剪**——分辨率 / 时长 / 配音三项只在模型声明了对应参数时才传，
    ///      否则 CLI 当场拒收整次请求（`does not publish parameter`）。
    ///
    /// 第 4 点依赖模型目录。目录还没加载好（首次打开画布、或 `model list` 失败）时的选择是
    /// **照用户存的值传**：目录只是"能不能传"的最优判据，不是必要条件，而把用户选的 4k 因为
    /// 一次元数据请求失败就悄悄丢掉，比让 CLI 报一次明确的错更糟。服务层还有一层按报错重试的退路。
    private func startVideoGeneration(_ node: CanvasNode, prompt: String, reusingSeed: Bool) {
        // 直接读单例而不是挂 `@ObservedObject`：这是"点生成这一刻"的一次性查表，不需要反应式
        // 刷新（视图里没有任何东西显示它）。把它挂成 ObservedObject 反而会让整个画布跟着模型
        // 目录的加载状态重绘一次。
        let info = CrateModelCatalogStore.shared.videoModels.first { $0.id == node.model }
        if let info, info.requiresImageInput, inputImagePaths(for: node).isEmpty {
            store.transientUI.showToast(CrateRequestError.missingRequiredImage(model: node.model).userMessage,
                                        duration: 2.8)
            return
        }

        let frames: (first: String?, last: String?, references: [String])
        if let info {
            frames = CrateModelCatalog.assignVideoFrames(imagePaths: inputImagePaths(for: node), model: info)
        } else {
            // 目录缺席时只敢认首帧：尾帧 / 参考图是"模型声明了才有"的角色，瞎传会被拒。
            frames = (inputImagePaths(for: node).first, nil, [])
        }

        let request = CrateVideoRequest(
            model: node.model,
            prompt: prompt,
            ratio: node.ratio,
            resolution: (info?.supportsResolution ?? true) ? node.resolution : "",
            duration: (info?.supportsDuration ?? true) ? node.duration : nil,
            generateAudio: (info?.supportsAudio ?? false) ? node.generateAudio : nil,
            firstFramePath: frames.first,
            lastFramePath: frames.last,
            referenceImagePaths: frames.references,
            seed: reusingSeed ? node.seed : nil)

        let nodeId = node.id
        let groupId = node.groupId
        let slot = node.slot
        let modelName = node.model

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
                    if submission.droppedSeed {
                        store.transientUI.showToast("\(modelName) 不支持固定 seed，本次用新种子", duration: 2.6)
                    }
                    // 合成一条而不是每项一条 Toast：Toast 是串行队列，四条依次弹完要十几秒，
                    // 而这几项本来就是同一件事（"这些参数这个模型不吃"）。
                    if !submission.droppedParameters.isEmpty {
                        let list = submission.droppedParameters.joined(separator: "、")
                        store.transientUI.showToast("\(modelName) 不支持 \(list)，本次用模型默认值", duration: 2.8)
                    }
                }

                let urls = try await service.waitForCompletion(
                    taskId: submitted.taskId,
                    timeout: CrateGeneration.videoPollTimeout
                ) { progress in
                    Task { @MainActor in
                        applyProgress(progress, toNodeId: nodeId)
                    }
                }
                guard let first = urls.first else {
                    throw CrateGenerationService.ServiceError.taskFailed(reason: "任务完成但没有产物")
                }

                let file = try await service.download(urlString: first,
                                                      taskId: submitted.taskId,
                                                      index: 0,
                                                      fallbackExtension: "mp4")
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
                NSLog("[ClipSlots][crate] video node=\(nodeId) 失败：\(err.logDetail)")
                await MainActor.run {
                    canvas.updateNode(id: nodeId) { $0.state = .failed(reason: err.userMessage) }
                    store.transientUI.showToast(err.userMessage, duration: 2.6)
                }
            } catch {
                NSLog("[ClipSlots][crate] video node=\(nodeId) 失败：\(error)")
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
        let paths = CrateGeneration.inputImagePaths(from: attachments,
                                                   excludingAttachmentIds: Set(node.outputAttachmentIds),
                                                   fileExists: { FileManager.default.fileExists(atPath: $0) })
        // 「文生图」与「图生图」的分岔就在这一行，而它完全取决于产物判定这个纯数据判断。判错了
        // UI 上看不出任何异常 —— 只是出图莫名变成"在上一张基础上改"。留一条日志，出问题时
        // `log show --predicate 'eventMessage CONTAINS "[ClipSlots][crate]"'` 能一眼看出取了几张。
        let images = attachments.filter { $0.type == .image }
        if !images.isEmpty {
            NSLog("[ClipSlots][crate] slot \(node.slot): 图片附件 \(images.count) 张 → 入参 \(paths.count) 张，判为产物跳过 \(images.count - paths.count) 张")
        }
        return paths
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
        // 附件类型按**扩展名**判，不按节点 kind 判（v2.11.19）。
        //
        // `SlotContent.AttachmentType` 只有 `.image` / `.file` 两个取值（那是槽位
        // 数据的历史 schema，给它加 `.video` 会让新写的数据在旧版本 App 里解不出来），所以 mp4
        // 一律进 `.file`。卡片上的视频图标与首帧预览走的是另一套判定
        // （`CanvasAttachmentKind.from(fileName:)`，按扩展名），两者互不依赖。
        //
        // 按扩展名而不是按 kind 的好处是：将来 transform 链路（去背 / 超分）产出的文件类型与节点
        // 类型不一定对应（视频节点吐 mp4、图像节点吐 svg），这条规则不用跟着改。
        let attachmentType: SlotContent.AttachmentType =
            CanvasAttachmentKind.from(fileName: downloadedFile.lastPathComponent) == .image ? .image : .file
        let attachment = SlotContent.SlotAttachment(name: downloadedFile.lastPathComponent,
                                                    type: attachmentType,
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
