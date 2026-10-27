import Foundation

public enum ModelCanvasInput {
    public static func question(node: CanvasNode, facts: [CanvasWorkflowFacts], edges: [CanvasEdge],
                                promptOverride: String? = nil) throws -> ModelQuestion {
        let all = Dictionary(facts.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let own = all[node.id], own.bodyAvailable else { throw ModelWorkspaceError.unreadable }
        var question = ModelQuestion(); question.kind = node.kind == .text ? .llm : ModelKind(rawValue: node.kind.rawValue) ?? .image
        question.title = node.displayName; question.nodeParameters = parameters(node)
        var prompts = [promptOverride ?? own.body], seen = Set<String>()
        func append(path: String, name: String?, role: String) throws {
            var ref = ModelReference(path: path, name: name)
            let mime = ModelEvaluationService.mime(for: ref)
            guard !mime.isEmpty, ref.isCurrent else { throw ModelWorkspaceError.invalid("参考素材缺失或类型未声明。") }
            ref.mediaKind = mime.hasPrefix("image/") ? .image : mime.hasPrefix("video/") ? .video : .audio
            if ["firstFrame","lastFrame"].contains(role), ref.mediaKind != .image { throw ModelWorkspaceError.invalid("首尾帧需要图像素材。") }
            ref.role = role
            if seen.insert(path + "|" + role).inserted { question.references.append(ref) }
        }
        for media in own.media {
            let explicit = node.inputAttachmentIds.contains(media.attachmentID)
            let output = node.outputAttachmentIds.contains(media.attachmentID)
                || (node.taskId?.hasPrefix("api-") == true && node.tools?.resourceAttachmentID == media.attachmentID)
            guard explicit || (!output && !CrateGeneration.isGeneratedAssetName(media.name)) else { continue }
            let candidate = ModelReference(path: own.resourcePaths[media.id] ?? "", name: media.name)
            if !ModelEvaluationService.mime(for: candidate).isEmpty {
                guard let path = own.resourcePaths[media.id] else { throw ModelWorkspaceError.invalid("节点参考文件不可用。") }
                try append(path: path, name: media.name, role: "reference")
            }
        }
        for edge in edges.filter({ $0.toNodeId == node.id && $0.purpose.isGenerationDependency && $0.fromNodeId != node.generationSourceID })
            .sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let source = all[edge.fromNodeId], source.bodyAvailable else { throw ModelWorkspaceError.unreadable }
            if edge.role == .prompt || source.node.kind == .text { prompts.append(source.body); continue }
            let role = edge.role == .firstFrame ? "firstFrame" : edge.role == .lastFrame ? "lastFrame" : "reference"
            if source.node.kind == .slot {
                for media in source.media {
                    let ref = ModelReference(path: source.resourcePaths[media.id] ?? "", name: media.name)
                    if !ModelEvaluationService.mime(for: ref).isEmpty {
                        guard let path = source.resourcePaths[media.id] else { throw ModelWorkspaceError.invalid("上游参考文件不可用。") }
                        try append(path: path, name: media.name, role: role)
                    }
                }
                prompts.append(source.body)
            } else {
                guard let path = source.primaryAssetPath else { throw ModelWorkspaceError.invalid("上游媒体尚未就绪。") }
                let name = source.resourcePaths.first(where: { $0.value == path }).flatMap { pair in source.media.first { $0.id == pair.key }?.name }
                try append(path: path, name: name, role: role)
            }
        }
        question.prompt = prompts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        let first = question.references.contains { $0.role == "firstFrame" }, last = question.references.contains { $0.role == "lastFrame" }
        if last && !first { throw ModelWorkspaceError.invalid("尾帧生成需要补齐首帧。") }
        let oneImage = question.references.count == 1 && question.references[0].mediaKind == .image
        question.generationMode = last ? "start_end" : first || (node.kind == .video && oneImage) ? "image"
            : question.references.isEmpty ? "text" : "reference"
        return question
    }
    public static func parameters(_ node: CanvasNode) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        if node.kind == .image || node.kind == .video {
            let selection = CanvasImageConfiguration.selection(ratio: node.ratio, resolution: node.resolution)
            values["aspectRatio"] = .string(selection.ratio)
            if !node.resolution.isEmpty { values["resolution"] = .string(node.resolution) }
            if let duration = node.duration { values["duration"] = .number(Double(duration)) }
            if let audio = node.generateAudio { values["generateAudio"] = .bool(audio) }
        }
        if node.kind == .audio {
            let audio = node.tools?.audio ?? CanvasAudioConfiguration()
            if !audio.voiceID.isEmpty { values["voice"] = .string(audio.voiceID) }
            values["speed"] = .number(audio.rate)
            if let cloud = node.tools?.cloudGeneration {
                values["duration"] = .number(cloud.duration)
                values["instrumental"] = .bool(cloud.instrumental)
                if !cloud.lyrics.isEmpty { values["lyrics"] = .string(cloud.lyrics) }
            }
        }
        return values
    }
}
