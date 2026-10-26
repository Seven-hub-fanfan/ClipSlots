import SwiftUI
import AVFoundation
import SceneKit
import UniformTypeIdentifiers
import ClipSlotsKit

@MainActor final class CanvasToolSession: ObservableObject {
    let canvas: CanvasStore
    let store: SlotStoreObservable
    let project: String
    let nodeID: String
    let createdAt: Date
    @Published var attachments: [SlotContent.SlotAttachment]
    @Published var busy = false
    @Published var message = ""
    @Published var player = AVPlayer()
    @Published var waveform: [Float] = []
    @Published var scene: SCNScene?
    @Published var cloud: CanvasGaussianCloud?
    @Published var composite:CanvasStageComposite?
    @Published var previewTime: Double = 0
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var previewComposition: CanvasToolMedia.Composition?
    private var audioLease: CanvasMediaFileLease?
    private var sourceDurations: [String: Double] = [:]
    private let speech = CanvasSpeechExporter()
    weak var window: NSWindow?
    var capturePreview: (() throws -> NSImage)?
    init(canvas: CanvasStore, store: SlotStoreObservable, node: CanvasNode,
         attachments: [SlotContent.SlotAttachment]) {
        self.canvas = canvas; self.store = store; project = canvas.activeProjectId
        nodeID = node.id; createdAt = node.createdAt; self.attachments = attachments
    }
    var node: CanvasNode? {
        guard canvas.activeProjectId == project, let node = canvas.node(id: nodeID),
              node.createdAt == createdAt else { return nil }
        return node
    }
    var configuration: CanvasToolConfiguration { node?.tools ?? .init() }
    var urls: [String: URL] {
        Dictionary(uniqueKeysWithValues: attachments.compactMap { attachment in
            guard let path = [attachment.storagePath, attachment.path, attachment.originalPath]
                .compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
            return (attachment.id.uuidString, URL(fileURLWithPath: path))
        })
    }
    var resources: [String: (url: URL, name: String)] {
        Dictionary(uniqueKeysWithValues: attachments.compactMap {
            guard let url = urls[$0.id.uuidString] else { return nil }
            return ($0.id.uuidString, (url, $0.name))
        })
    }
    var canvasResources:[CanvasNode] {
        canvas.nodes.filter {$0.id != nodeID && $0.kind == .threeD && $0.tools?.resourceAttachmentID != nil}
    }
    func referenceResource(_ source:CanvasNode) {
        guard let id=source.tools?.resourceAttachmentID,
              let attachment=store.canvasSlotAttachments(groupId:source.groupId,slot:source.slot).first(where:{$0.id.uuidString==id}),
              let path=[attachment.storagePath,attachment.path,attachment.originalPath].compactMap({$0})
                .first(where:{FileManager.default.fileExists(atPath:$0)}) else {message="来源节点素材不可用";return}
        let metadata=source.tools?.cloudResources?[id]
        run {
            let lease=try CanvasMediaFileLease(source:URL(fileURLWithPath:path),name:attachment.name)
            try await self.ingest(lease.url,cloudMetadata:metadata)
        }
    }
    @discardableResult
    func save(_ config: CanvasToolConfiguration, detail: String) -> Bool {
        guard let node, !busy, canvas.prepareToolMutation() else { return false }
        if let error = config.validationError(for: node.kind) { message = error; return false }
        if node.kind == .timeline, config.timeline.clips.contains(where: {
            if let bound = sourceDurations[$0.attachmentID] { return $0.sourceEnd > bound + 0.001 }
            return false
        }) { message = "裁剪范围超过素材时长"; return false }
        canvas.editTool(id: nodeID, configuration: config, detail: detail)
        return configuration == config
    }
    func cancel() {
        operation?.cancel(); speech.cancel(); player.pause()
    }
    func run(_ body: @escaping () async throws -> Void) {
        guard !busy, node != nil, !canvas.connectionPolicy.readOnly else { return }
        busy = true; message = ""
        let token = UUID(); operationID = token
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == token { self.busy = false; self.operation = nil; self.operationID = nil }
            }
            do { try await body() }
            catch is CancellationError { self.message = "操作已取消" }
            catch { self.message = error.localizedDescription }
        }
    }
    func chooseImport() {
        guard let node, let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = node.kind == .timeline || node.kind == .stage
        panel.canChooseDirectories = false
        switch node.kind {
        case .audio: panel.allowedContentTypes = [.audio]; panel.message = "导入音乐、配音或音效"
        case .timeline: panel.allowedContentTypes = [.movie, .audio]; panel.message = "添加视频片段或音频轨道"
        default:
            panel.allowedContentTypes = ["glb","spz","obj","dae","scn","usdz"].compactMap { UTType(filenameExtension: $0) }
            panel.message = node.kind == .stage ? "添加 GLB / SPZ / OBJ / DAE / SCN / USDZ 场景对象" : "导入 3D 模型或 SPZ 世界"
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.run { for url in panel.urls { try await self.ingest(url) } }
        }
    }
    func chooseReferenceImage() {
        guard let window,!busy else { return }
        let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.jpeg];panel.canChooseDirectories=false
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self,let url=panel.url else { return }
            self.run { try await self.ingest(url,referenceImage:true) }
        }
    }
    func chooseEnvironment() {
        guard let window,!busy else { return }
        let panel=NSOpenPanel();panel.allowedContentTypes=["hdr","exr","png","jpg","jpeg"].compactMap { UTType(filenameExtension:$0) }
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self,let url=panel.url else { return }
            self.run { try await self.ingest(url,environment:true) }
        }
    }
    private func persistCloud(_ expected:CanvasToolConfiguration,task:CanvasCloudTask) throws -> CanvasToolConfiguration {
        guard node?.tools==expected,canvas.prepareToolMutation() else { throw CanvasToolError.invalid("节点已变更，云端任务未写回此节点") }
        var next=expected;next.cloudGeneration?.task=task
        canvas.editTool(id:nodeID,configuration:next,detail:"保存云端任务状态")
        guard configuration==next else { throw CanvasToolError.invalid("云端任务状态保存失败") };return next
    }
    func generateCloud(key:String,resume:Bool=false) {
        guard var config=configuration.cloudGeneration else { return }
        if let error=config.validationError { message=error;return }
        if !resume && config.task != nil { message="已有任务，请先查询或明确新建任务";return }
        run {
            let client=CanvasCloudClient()
            var expected=self.configuration
            var submitted=resume
            do {
                if config.provider == .elevenLabs || config.provider == .miniMax {
                    guard !resume else { throw CanvasCloudError.invalid("此音频服务不支持恢复提交，请先检查服务控制台") }
                    expected=try self.persistCloud(expected,task:.init(provider:config.provider,mode:config.mode,state:.submitting))
                    submitted=true
                    let result=try await client.audio(config,key:key)
                    try Task.checkCancellation()
                    try await self.acceptCloud(result,expected:expected)
                    return
                }
                if !resume {
                    var imageToken:String?
                    if config.mode == .image3D {
                        guard let id=config.inputAttachmentID,let resource=self.resources[id] else { throw CanvasToolError.missingMedia }
                        let lease=try CanvasMediaFileLease(source:resource.url,name:resource.name)
                        imageToken=try await client.uploadImage(lease.url,key:key)
                    }
                    expected=try self.persistCloud(expected,task:.init(provider:config.provider,mode:config.mode,state:.submitting))
                    submitted=true
                    let task=try await client.submit(config,key:key,imageToken:imageToken)
                    // Retain the returned ID even if local cancellation occurred
                    // after the service accepted the request.
                    expected=try self.persistCloud(expected,task:task);config.task=task
                }
                guard let task=config.task else { throw CanvasCloudError.remote }
                self.message="云端任务已保存，正在查询…"
                for _ in 0..<300 {
                    try Task.checkCancellation()
                    let status=try await client.status(task,quality:config.worldQuality,key:key)
                    if status.done {
                        let result=try await client.download(status)
                        try Task.checkCancellation();try await self.acceptCloud(result,expected:expected);return
                    }
                    try await Task.sleep(nanoseconds:2_000_000_000)
                }
                throw CanvasCloudError.expired
            } catch {
                if submitted,let current=self.node?.tools,current==expected,let pending=current.cloudGeneration?.task,pending.id==nil {
                    var unknown=pending;unknown.state = .unknown;_ = try? self.persistCloud(expected,task:unknown)
                    throw CanvasCloudError.unknownSubmission
                }
                if error is CancellationError,config.task?.id != nil { throw CanvasCloudError.cancelled }
                throw error
            }
        }
    }
    func generateConfiguredAudio(prompt: String) {
        let models = ModelWorkspaceStore.shared
        guard let source = node, let profile = models.canvasProfile(for: source) else {
            message = "请在模型配置中心设置音频 API"; return
        }
        let expected = configuration
        run {
            let id: String
            if let old = source.modelEvaluationCellID, let cell = models.evaluationCell(old),
               (cell.state != .succeeded || source.taskId != "api-" + old),
               cell.state != .failed && cell.state != .cancelled {
                id = old
            } else {
                var question = ModelQuestion(); question.kind = .audio
                question.prompt = prompt; question.title = "画布音频"
                guard let created = await models.beginCanvas(question: question, profile: profile) else {
                    throw ModelWorkspaceError.invalid(models.message ?? "任务未保存")
                }
                id = created
                self.canvas.updateNode(id: self.nodeID) { $0.modelEvaluationCellID = id }
                self.canvas.flushSave()
            }
            await models.resumeCanvas(id)
            while self.node != nil {
                try Task.checkCancellation()
                guard let cell = models.evaluationCell(id) else { throw ModelWorkspaceError.unreadable }
                if cell.state == .succeeded {
                    guard self.configuration == expected else { throw CanvasToolError.invalid("节点已修改，结果保留在模型结果集中") }
                    let url: URL
                    if let path = cell.localMediaPaths.first { url = URL(fileURLWithPath: path) }
                    else {
                        guard let raw = cell.mediaURLs.first, let remote = URL(string: raw) else { throw ModelWorkspaceError.response }
                        let (file, response) = try await URLSession.shared.download(from: remote)
                        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ModelWorkspaceError.response }
                        let root = ClipSlotsPaths.dataRoot.appendingPathComponent("models/media")
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        url = root.appendingPathComponent("api-\(id)." + (remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension))
                        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: file, to: url) }
                    }
                    try await self.ingest(url)
                    self.canvas.updateNode(id: self.nodeID) { $0.taskId = "api-" + id }
                    self.canvas.flushSave()
                    self.message = "音频生成完成"; return
                }
                if [.unknown, .failed, .cancelled].contains(cell.state) || !cell.detail.isEmpty {
                    throw ModelWorkspaceError.invalid(cell.detail.isEmpty ? cell.state.title : cell.detail)
                }
                self.message = cell.state.title
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
    func acceptCloud(_ result:CanvasCloudClient.Result,expected:CanvasToolConfiguration) async throws {
        guard node?.tools==expected else { throw CanvasToolError.invalid("节点已变更，云端结果未覆盖新配置") }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("云生成-\(UUID().uuidString).\(result.fileExtension)")
        defer { try? FileManager.default.removeItem(at:url) }
        try result.data.write(to:url,options:.atomic)
        try await ingest(url,cloudMetadata:result.metadata)
        message="云端结果已导入，可继续引用与导出"
    }
    func ingest(_ url: URL, referenceImage:Bool=false,environment:Bool=false,
                cloudMetadata:CanvasCloudResourceMetadata?=nil) async throws {
        guard let original = node else { throw CanvasToolError.cancelled }
        let beforeConfig = configuration, access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count > 0, count <= 512 * 1024 * 1024 else {
            throw CanvasToolError.invalid("素材为空或超过 512 MB")
        }
        let name = url.lastPathComponent, ext = url.pathExtension.lowercased()
        if original.kind == .stage,ext=="spz",beforeConfig.stage.entities.contains(where:{entity in
            entity.attachmentID.flatMap {resources[$0]?.name}.map {($0 as NSString).pathExtension.lowercased()=="spz"} == true
        }) {throw CanvasToolError.invalid("一个片场暂支持一个 SPZ 世界")}
        var duration: Double = 0, isVideo = false
        if referenceImage || environment {
            guard let image=NSImage(contentsOf:url),image.size.width>0,image.size.height>0 else { throw CanvasToolError.invalid("图片无法解码") }
        } else if original.kind == .audio || original.kind == .timeline {
            let facts = try await CanvasToolMedia.inspect(url); duration = facts.duration; isVideo = facts.video
            if original.kind == .audio && isVideo { throw CanvasToolError.invalid("音频节点请导入音频文件") }
        } else {
            try await CanvasToolMedia.worker {
                if ext == "spz" { _ = try CanvasSPZ.load(url) }
                else { _ = try CanvasGLBScene.load(url, name: name) }
            }
        }
        await store.prepareCanvasToolWrite()
        try Task.checkCancellation()
        guard let current = node, current.tools == beforeConfig, canvas.prepareToolMutation() else {
            throw CanvasToolError.invalid("节点已变更，请重试")
        }
        attachments = store.canvasSlotAttachments(groupId: current.groupId, slot: current.slot)
        let before = attachments
        let attachment = SlotContent.SlotAttachment(name: name, type: .file, storagePath: url.path)
        guard let persisted = store.appendCanvasGeneratedAttachment(attachment, groupId: current.groupId, slot: current.slot) else {
            throw CanvasToolError.invalid("素材保存失败")
        }
        if duration > 0 { sourceDurations[persisted.id.uuidString] = duration }
        // The storage revision may synchronously refresh the mounted editor's
        // attachments. Build from the pre-import snapshot so it is added once.
        attachments = before + [persisted]
        var config = beforeConfig
        if let cloudMetadata {
            if config.cloudResources==nil { config.cloudResources=[:] }
            config.cloudResources?[persisted.id.uuidString]=cloudMetadata
            config.cloudGeneration?.task?.state = .complete
        }
        if referenceImage { config.cloudGeneration?.inputAttachmentID=persisted.id.uuidString }
        else if environment { config.stage.animation.environment.attachmentID=persisted.id.uuidString }
        else {
        switch original.kind {
        case .audio, .threeD: config.resourceAttachmentID = persisted.id.uuidString
        case .timeline:
            config.timeline.clips.append(.init(attachmentID: persisted.id.uuidString, name: name, duration: duration,
                isAudio: !isVideo, timelineStart: isVideo ? config.timeline.clips.filter { !$0.isAudio }.map(\.end).max() ?? 0 : previewTime))
            config.timeline.reflowVideo()
        case .stage: config.stage.entities.append(.init(name: name, shape: .resource, attachmentID: persisted.id.uuidString))
        default: break
        }
        }
        if let error=config.validationError(for:original.kind) {
            store.writeCanvasSlotAttachments(groupId:current.groupId,slot:current.slot,attachments:before)
            attachments=before;throw CanvasToolError.invalid(error)
        }
        canvas.recordToolImport(id: nodeID, configuration: config, edit: .init(groupId: current.groupId,
            slot: current.slot, before: before, after: attachments, stashToken: UUID().uuidString))
        try await refreshPreview()
        message = "已导入 \(name)"
    }
    func refreshPreview() async throws {
        guard let node else { return }
        let config = configuration, urls = urls, resources = resources
        switch node.kind {
        case .audio:
            guard let id = config.resourceAttachmentID, let url = urls[id] else { player.replaceCurrentItem(with: nil); waveform = []; return }
            let lease = try CanvasMediaFileLease(source:url,name:resources[id]?.name ?? "")
            player.replaceCurrentItem(with: AVPlayerItem(url: lease.url)); audioLease = lease
            let result = try await CanvasToolMedia.worker { try CanvasToolMedia.waveform(url) }
            guard self.node?.tools == config else { return }; waveform = result
        case .timeline:
            guard !config.timeline.clips.isEmpty else { player.replaceCurrentItem(with: nil); return }
            for clip in config.timeline.clips where sourceDurations[clip.attachmentID] == nil {
                guard let resource = resources[clip.attachmentID] else { throw CanvasToolError.missingMedia }
                let lease = try CanvasMediaFileLease(source: resource.url, name: resource.name)
                let facts = try await CanvasToolMedia.inspect(lease.url)
                try Task.checkCancellation()
                guard self.node?.tools == config else { return }
                sourceDurations[clip.attachmentID] = facts.duration
            }
            let composition = try await CanvasToolMedia.composition(config.timeline, urls: urls)
            guard self.node?.tools == config else { return }
            let item = AVPlayerItem(asset: composition.asset); item.videoComposition = composition.video; item.audioMix = composition.audio
            previewComposition = composition
            player.replaceCurrentItem(with: item)
        case .threeD:
            guard let id = config.resourceAttachmentID, let resource = resources[id] else { scene = nil; cloud = nil; return }
            if (resource.name as NSString).pathExtension.lowercased() == "spz" {
                let metadata=config.cloudResources?[id]
                let result = try await CanvasToolMedia.worker { CanvasSPZ.transformed(try CanvasSPZ.load(resource.url),metadata:metadata) }
                guard self.node?.tools == config else { return }; cloud = result; scene = nil
            } else {
                let result = try await CanvasToolMedia.worker { try CanvasGLBScene.load(resource.url, name: resource.name) }
                guard self.node?.tools == config else { return }; scene = result; cloud = nil
            }
        case .stage:
            let result = try await CanvasToolMedia.worker {
                let scene=try CanvasStageRenderer.scene(config.stage,urls:resources)
                let composite=try CanvasStageRenderer.composite(config.stage,scene:scene,urls:resources,metadata:config.cloudResources ?? [:])
                return (scene,composite)
            }
            guard self.node?.tools == config else { return };scene=result.0;composite=result.1
        default: break
        }
    }
    func renderExport(_ type: String, to url: URL, original: Bool = false) async throws {
        guard let node else { throw CanvasToolError.cancelled }
        let config = configuration, urls = urls, resources = resources
        if let error = config.validationError(for: node.kind) { throw CanvasToolError.invalid(error) }
        try Task.checkCancellation()
        switch node.kind {
        case .audio:
            if original {
                guard let id = config.resourceAttachmentID, let source = urls[id] else { throw CanvasToolError.missingMedia }
                try await CanvasToolMedia.worker { try FileManager.default.copyItem(at: source, to: url) }
            } else { _ = try await speech.export(config.audio, to: url) }
        case .threeD: try photograph(to: url)
        case .timeline:
            let composition = try await CanvasToolMedia.composition(config.timeline, urls: urls)
            try await CanvasToolMedia.export(composition, to: url)
        case .stage:
            let time = previewTime
            if type == "png" {
                try await CanvasToolMedia.worker { try CanvasStageRenderer.photograph(config.stage, urls: resources, time: time, to: url,metadata:config.cloudResources ?? [:]) }
            } else { try await CanvasStageRenderer.exportVideo(config.stage, urls: resources, to: url,metadata:config.cloudResources ?? [:]) }
        default: throw CanvasToolError.invalid("此工具不支持该导出")
        }
        try Task.checkCancellation()
        guard self.node?.tools == config else { throw CanvasToolError.invalid("节点已变更，导出未写回画布") }
    }
    @discardableResult
    func receiveExport(_ url: URL, type: String, expected: CanvasToolConfiguration) async throws -> CanvasNode? {
        await store.prepareCanvasToolWrite()
        try Task.checkCancellation()
        guard let source = node, source.tools == expected, canvas.prepareToolMutation() else {
            throw CanvasToolError.invalid("节点已变更，导出未写回画布")
        }
        // Speech is the audio node's selected source. Other exports become
        // independent media nodes without occupying a user's numbered slot.
        let downstream = source.kind != .audio
        let group = downstream ? canvas.privateGroupId : source.groupId
        if downstream, !store.ensureCanvasPrivateGroup(id: group, name: canvas.activeProject.privateGroupName) {
            throw CanvasToolError.invalid("存储繁忙，未能创建输出节点")
        }
        let slot: Int
        if downstream {
            guard let allocated = store.allocateCanvasPrivateSlot(groupId: group, occupied: canvas.occupiedSlots(inGroup: group)) else {
                throw CanvasToolError.invalid("项目暂存区已满，请先归档部分节点")
            }
            slot = allocated
        } else { slot = source.slot }
        let before = store.canvasSlotAttachments(groupId: group, slot: slot)
        let attachment = SlotContent.SlotAttachment(name: "\(source.kind.displayName)导出.\(type)",
            type: type == "png" ? .image : .file, storagePath: url.path)
        guard let persisted = store.appendCanvasGeneratedAttachment(attachment, groupId: group, slot: slot) else {
            throw CanvasToolError.invalid("导出素材保存失败")
        }
        let after = store.canvasSlotAttachments(groupId: group, slot: slot)
        let edit = CanvasHistoryEntry.SlotAttachmentEdit(groupId: group, slot: slot, before: before, after: after, stashToken: UUID().uuidString)
        if downstream {
            let kind: CanvasNodeKind = type == "png" ? .image : type == "mp4" ? .video : .audio
            let size = CanvasNodeSizing.initialSize(for: kind)
            let origin = CanvasSpawnGeometry.nonOverlappingOrigin(
                desired: CGPoint(x: source.x + source.width + 100, y: source.y),
                existing: canvas.nodes.map { CGPoint(x: $0.x, y: $0.y) })
            var output = CanvasNode(pageId: source.pageId, groupId: group, slot: slot, kind: kind,
                mediaRole: .source, x: origin.x, y: origin.y, width: size.width, height: size.height,
                state: .succeeded(assetPath: persisted.storagePath ?? url.path), parentNodeId: source.id,
                outputAttachmentIds: [persisted.id.uuidString])
            if kind == .audio { var config = CanvasToolConfiguration(); config.resourceAttachmentID = persisted.id.uuidString; output.tools = config }
            guard canvas.recordToolOutput(sourceID: source.id, output: output, edit: edit) else {
                store.writeCanvasSlotAttachments(groupId: group, slot: slot, attachments: before)
                throw CanvasToolError.invalid("输出节点保存失败")
            }
            message = "已合并回画布，可继续引用输出节点"
            return output
        }
        attachments = after
        var next = expected; next.resourceAttachmentID = persisted.id.uuidString
        canvas.recordToolImport(id: nodeID, configuration: next, edit: edit)
        try await refreshPreview(); message = "配音已生成到节点"
        return nil
    }
    func chooseExport(_ type: String, attach: Bool = false, original: Bool = false) {
        guard let node, !busy else { return }
        let config = configuration
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-tool-\(UUID().uuidString).\(type)")
        if attach {
            run {
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard self.node?.tools == config else { throw CanvasToolError.cancelled }
                try await self.renderExport(type, to: temporary, original: original)
                try await self.receiveExport(temporary, type: type, expected: config)
            }
            return
        }
        guard let window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(node.kind.displayName).\(type)"
        panel.allowedContentTypes = [UTType(filenameExtension: type) ?? .data]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // Export to a temporary sibling, then atomically replace the chosen
            // file only after a complete encoder result.
            let staging = url.deletingLastPathComponent().appendingPathComponent(".clipslots-\(UUID().uuidString).\(type)")
            self.run {
                defer { try? FileManager.default.removeItem(at: staging) }
                guard self.node?.tools == config else { throw CanvasToolError.cancelled }
                try await self.renderExport(type, to: staging, original: original)
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staging) }
                else { try FileManager.default.moveItem(at: staging, to: url) }
                self.message = "已导出 \(url.lastPathComponent)"
            }
        }
    }
    private func photograph(to url: URL) throws {
        guard let image=try capturePreview?(),let tiff=image.tiffRepresentation,
              let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {
            throw CanvasToolError.invalid("3D 预览尚未就绪")
        }
        try png.write(to:url,options:.atomic)
    }
}

@MainActor final class CanvasToolWindows: NSObject, NSWindowDelegate {
    static let shared = CanvasToolWindows()
    private var sessions: [String: (NSWindow, CanvasToolSession)] = [:]
    func open(node: CanvasNode, canvas: CanvasStore, store: SlotStoreObservable,
              attachments: [SlotContent.SlotAttachment]) {
        let key = canvas.activeProjectId + "/" + node.id
        if let existing = sessions[key] { existing.0.makeKeyAndOrderFront(nil); return }
        let session = CanvasToolSession(canvas: canvas, store: store, node: node, attachments: attachments)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = node.kind.displayName; window.minSize = NSSize(width: 800, height: 580)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(CanvasSkin.chromeFill)
        window.isReleasedWhenClosed = false; window.delegate = self; session.window = window
        window.contentView = NSHostingView(rootView: CanvasToolEditor(session: session, canvas: canvas))
        sessions[key] = (window, session); window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = sessions.first(where: { $0.value.0 === window })?.key else { return }
        sessions.removeValue(forKey: key)?.1.cancel()
    }
}
