import Foundation
import CryptoKit

/// File URLs stay in the in-process facts. Codable snapshots expose only resource identities.
public struct CanvasWorkflowMedia: Codable, Equatable, Identifiable {
    public var id: String
    public var attachmentID: String
    public var name: String
    public var kind: String
    public var role: String
    public var revision: String
    public var availability: String

    public init(id: String, attachmentID: String, name: String, kind: String, role: String,
                revision: String, availability: String) {
        self.id = id; self.attachmentID = attachmentID; self.name = name
        self.kind = kind; self.role = role; self.revision = revision; self.availability = availability
    }
}

public struct CanvasWorkflowFacts {
    public var node: CanvasNode
    public var title: String
    public var body: String
    public var bodyRevision: String
    public var bodyAvailable: Bool
    public var primaryAssetPath: String?
    public var slotImagePaths: [String]
    public var inputImagePaths: [String]
    public var expectedSlotImages: Int
    public var expectedInputImages: Int
    public var media: [CanvasWorkflowMedia]
    public var resourcePaths: [String: String]

    public init(node: CanvasNode, title: String, body: String, bodyRevision: String,
                bodyAvailable: Bool = true, primaryAssetPath: String? = nil,
                slotImagePaths: [String] = [], inputImagePaths: [String] = [],
                expectedSlotImages: Int = 0, expectedInputImages: Int = 0,
                media: [CanvasWorkflowMedia] = [], resourcePaths: [String: String] = [:]) {
        self.node = node; self.title = title; self.body = body; self.bodyRevision = bodyRevision
        self.bodyAvailable = bodyAvailable; self.primaryAssetPath = primaryAssetPath
        self.slotImagePaths = slotImagePaths; self.inputImagePaths = inputImagePaths
        self.expectedSlotImages = expectedSlotImages; self.expectedInputImages = expectedInputImages
        self.media = media; self.resourcePaths = resourcePaths
    }
}

/// A single input implementation shared by generation, the composer and Agent inspection.
public enum CanvasWorkflowResolver {
    public struct Plan {
        public var edgeInputs: CanvasEdgeInputs.Resolved
        public var prompt: String
        public var fragments: [CanvasEdgeInputs.Binding]
        public var imageRequest: CrateImageRequest?
        public var videoRequest: CrateVideoRequest?
        public var blockingReasons: [String]
        public var providerImages: [String] = []

        public func effectiveBindings(targetNodeID: String) -> [CanvasEdgeInputs.Binding] {
            var result = fragments
            func append(_ path: String?, role: CanvasEdgeRole) {
                guard let path else { return }
                let source = edgeInputs.bindings.first { $0.path == path }
                result.append(.init(edgeID: source?.edgeID ?? "", sourceNodeID: source?.sourceNodeID ?? targetNodeID,
                                    role: role, path: path))
            }
            if let videoRequest {
                append(videoRequest.firstFramePath, role: .firstFrame)
                append(videoRequest.lastFramePath, role: .lastFrame)
                videoRequest.referenceImagePaths.forEach { append($0, role: .reference) }
            } else if let imageRequest {
                imageRequest.imagePaths.forEach { append($0, role: .reference) }
            } else {
                providerImages.forEach { append($0, role: .reference) }
            }
            return result
        }
    }

    public static func resolve(_ fact: CanvasWorkflowFacts, all: [String: CanvasWorkflowFacts],
                               edges: [CanvasEdge], model: CrateModelCatalog.ModelInfo? = nil,
                               reusingSeed: Bool = false) -> Plan {
        let node = fact.node
        let incoming = CanvasEdgeGraph.incoming(of: node.id, edges: edges)
            .filter { $0.purpose.isGenerationDependency && $0.fromNodeId != node.generationSourceID }
        var upstreams: [String: CanvasEdgeInputs.Upstream] = [:]
        for edge in incoming {
            guard let source = all[edge.fromNodeId] else { continue }
            upstreams[source.node.id] = .init(nodeId: source.node.id, kind: source.node.kind,
                text: source.body, assetPath: source.primaryAssetPath,
                imagePaths: source.node.kind == .slot ? source.slotImagePaths : [])
        }
        var resolved = CanvasEdgeInputs.resolve(incoming: incoming, upstreams: upstreams, downstreamKind: node.kind)
        for id in Set(incoming.filter { $0.role != .prompt }.map(\.fromNodeId)) {
            if let source = all[id], source.node.kind == .slot,
               source.slotImagePaths.count < source.expectedSlotImages {
                resolved.unavailableUpstreamCount += 1
            }
        }
        var reasons = fact.bodyAvailable ? [] : ["节点正文不可用"]
        // Wiring is supported, but current provider requests cannot carry a remote draft identity.
        if node.draftReference?.sourceNodeID != nil {
            reasons.append("当前生成后端尚不支持草稿引用，请先断开草稿引用")
        }
        if incoming.contains(where: { all[$0.fromNodeId]?.bodyAvailable != true }) {
            reasons.append("部分上游节点不可读取，请检查来源")
        }
        var fragments = resolved.bindings.filter { $0.text != nil }
        if node.kind == .text {
            // Text optimization consumes all upstream text, regardless of an edge's media role.
            fragments = incoming.compactMap { edge in
                guard let text = all[edge.fromNodeId]?.body, !text.isEmpty else { return nil }
                return .init(edgeID: edge.id, sourceNodeID: edge.fromNodeId, role: .prompt, text: text)
            }
            if fact.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fragments.isEmpty {
                reasons.append("先描述画面想法，或连接参考文本")
            }
            let prompt = CanvasImagePrompt.request(intent: fact.body,
                                                   existing: "", references: fragments.compactMap(\.text))
            return Plan(edgeInputs: resolved, prompt: prompt, fragments: fragments,
                        imageRequest: nil, videoRequest: nil, blockingReasons: reasons)
        }
        if node.isMediaSource {
            return Plan(edgeInputs: resolved, prompt: "", fragments: [],
                        imageRequest: nil, videoRequest: nil, blockingReasons: reasons)
        }
        if let reason = resolved.blockingReason { reasons.append(reason) }
        if fact.inputImagePaths.count < fact.expectedInputImages { reasons.append("本节点有参考图片不可用") }
        let prompt = CanvasEdgeInputs.mergedPrompt(own: fact.body, upstream: resolved.promptFragments)
        if node.generationProvider == .byteartist {
            return Plan(edgeInputs: resolved, prompt: prompt, fragments: fragments,
                        imageRequest: nil, videoRequest: nil, blockingReasons: reasons,
                        providerImages: CanvasEdgeInputs.imageReferences(edgeInputs: resolved, slotImages: fact.inputImagePaths))
        }
        if prompt.isEmpty { reasons.append(CrateRequestError.emptyPrompt.userMessage) }
        // Node count is a batch setting. Each task owns one node and submits once.
        var image: CrateImageRequest?
        var video: CrateVideoRequest?
        if node.kind == .video {
            let frames = CanvasEdgeInputs.videoFrames(edgeInputs: resolved, slotImages: fact.inputImagePaths, model: model)
            if model?.requiresImageInput == true, frames.first == nil, frames.last == nil, frames.references.isEmpty {
                reasons.append(CrateRequestError.missingRequiredImage(model: node.model).userMessage)
            }
            video = .init(model: node.model, prompt: prompt, ratio: node.ratio,
                resolution: (model?.supportsResolution ?? true) ? node.resolution : "",
                duration: (model?.supportsDuration ?? true) ? node.duration : nil,
                generateAudio: (model?.supportsAudio ?? false) ? node.generateAudio : nil,
                firstFramePath: frames.first, lastFramePath: frames.last, referenceImagePaths: frames.references,
                seed: reusingSeed ? node.seed : nil)
        } else {
            let split = CanvasImageConfiguration.supportsSplit(model)
                || (model == nil && CanvasImageConfiguration.splitModels.contains(node.model))
            let selection = CanvasImageConfiguration.selection(ratio: node.ratio, resolution: node.resolution)
            let minimumPixels = model?.imageMinimumPixels
                ?? (split ? CanvasImageConfiguration.seedreamMinimumPixels : nil)
            let dimensions = split ? CanvasImageConfiguration.dimensions(
                ratio: selection.ratio, quality: selection.quality, minimumPixels: minimumPixels) : nil
            if split && dimensions == nil { reasons.append(CrateRequestError.invalidImageDimensions.userMessage) }
            image = .init(model: node.model, prompt: prompt, ratio: node.ratio, count: 1,
                imagePaths: CanvasEdgeInputs.imageReferences(edgeInputs: resolved, slotImages: fact.inputImagePaths),
                seed: reusingSeed ? node.seed : nil,
                width: dimensions?.width, height: dimensions?.height,
                resolution: split ? selection.quality : nil)
            if split { image?.ratio = selection.ratio }
        }
        return Plan(edgeInputs: resolved, prompt: prompt, fragments: fragments,
                    imageRequest: image, videoRequest: video, blockingReasons: reasons)
    }
}

public struct CanvasWorkflowSnapshot: Codable, Equatable {
    public struct Node: Codable, Equatable, Identifiable {
        /// Geometry is retained for workflow reuse; asset paths are stripped.
        public var configuration: CanvasNode
        public var title: String
        public var bodyText: String
        public var bodyRevision: String
        public var bodyAvailable: Bool
        public var observedState: String
        public var media: [CanvasWorkflowMedia]
        public var resolvedPrompt: String
        public var promptSources: [CanvasEdgeInputs.Binding]
        /// Path fields contain resource IDs, never local filesystem paths.
        public var bindings: [CanvasEdgeInputs.Binding]
        public var plannedRequest: GenerationRequestRecord?
        public var blockingReasons: [String]
        public var latestRunID: UUID?
        public var id: String { configuration.id }
    }

    public var schemaVersion = 2
    public var snapshotID: UUID
    public var projectID: String
    public var capturedAt: Date
    public var graphRevision: String
    public var selectionIDs: [String]
    public var nodes: [Node]
    public var edges: [CanvasEdge]
    public var groups: [CanvasNodeGroup]
    public var piles: [CanvasPile]
    public var omissions: [String]

    public init(projectID: String, facts: [CanvasWorkflowFacts], edges: [CanvasEdge], selectionIDs: [String],
                models: [CrateModelCatalog.ModelInfo] = [], latestRuns: [String: UUID] = [:],
                groups: [CanvasNodeGroup] = [], piles: [CanvasPile] = []) {
        snapshotID = UUID(); self.projectID = projectID; capturedAt = Date()
        self.groups = groups; self.piles = piles
        self.edges = edges.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        self.selectionIDs = selectionIDs.sorted()
        graphRevision = ""
        let all = Dictionary(facts.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = facts.reduce(into: [String: String]()) { result, fact in
            for (id, path) in fact.resourcePaths where result[path] == nil { result[path] = id }
        }
        omissions = ["媒体仅建立索引，尚未读取图像内容、视频画面或音轨；未记录的历史请求不可还原。"]
        nodes = facts.map { fact in
            let plan = CanvasWorkflowResolver.resolve(fact, all: all, edges: edges,
                model: models.first { $0.id == fact.node.model })
            var config = fact.node
            config.generationRawOutput = nil
            config.generationDiagnostic = nil
            for workflow in config.byteArtist.drafts.keys {
                let fields = config.byteArtist.drafts[workflow]?.fields.mapValues {
                    paths[$0] ?? (($0.hasPrefix("/") || $0.hasPrefix("file:")) ? "local-file-required" : $0)
                } ?? [:]
                config.byteArtist.drafts[workflow]?.fields = fields
            }
            let state: String
            switch config.state {
            case .idle: state = "idle"
            case .queued: state = "queued"
            case .running: state = "running"
            case .succeeded: state = "succeeded"; config.state = .succeeded(assetPath: "")
            case .failed(let reason): state = "failed: \(reason)"
            }
            let bindings = plan.effectiveBindings(targetNodeID: fact.node.id).map { source -> CanvasEdgeInputs.Binding in
                var result = source
                result.path = source.path.map { paths[$0] ?? "unavailable" }
                return result
            }
            let request = plan.imageRequest.map { GenerationRequestRecord($0, resourceIDs: paths) }
                ?? plan.videoRequest.map { GenerationRequestRecord($0, resourceIDs: paths) }
            return Node(configuration: config, title: fact.title, bodyText: fact.body,
                bodyRevision: fact.bodyRevision, bodyAvailable: fact.bodyAvailable, observedState: state,
                media: fact.media, resolvedPrompt: plan.prompt, promptSources: plan.fragments,
                bindings: bindings, plannedRequest: request, blockingReasons: plan.blockingReasons,
                latestRunID: latestRuns[config.id])
        }
        // Layout/pan/zoom do not invalidate semantic context; content, media and roles do.
        var semanticNodes = nodes
        for i in semanticNodes.indices {
            semanticNodes[i].configuration.x = 0; semanticNodes[i].configuration.y = 0
            semanticNodes[i].configuration.width = 0; semanticNodes[i].configuration.height = 0
            semanticNodes[i].configuration.updatedAt = .distantPast
        }
        let semanticGroups = groups.map { group -> CanvasNodeGroup in
            var copy = group
            copy.containerFrame = nil; copy.measuredLayoutSignature = nil
            return copy
        }
        let semanticPiles = piles.map { pile -> CanvasPile in
            var copy = pile
            copy.x = 0; copy.y = 0
            return copy
        }
        struct Revision: Encodable {
            let nodes: [Node]; let edges: [CanvasEdge]
            let groups: [CanvasNodeGroup]; let piles: [CanvasPile]
        }
        graphRevision = Self.digest((try? Self.jsonData(Revision(nodes: semanticNodes, edges: self.edges,
            groups: semanticGroups, piles: semanticPiles))) ?? Data())
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshotID, projectID, capturedAt, graphRevision, selectionIDs, nodes, edges, groups, piles, omissions
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        snapshotID = try values.decode(UUID.self, forKey: .snapshotID)
        projectID = try values.decode(String.self, forKey: .projectID)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        graphRevision = try values.decode(String.self, forKey: .graphRevision)
        selectionIDs = try values.decode([String].self, forKey: .selectionIDs)
        nodes = try values.decode([Node].self, forKey: .nodes)
        edges = try values.decode([CanvasEdge].self, forKey: .edges)
        groups = try values.decodeIfPresent([CanvasNodeGroup].self, forKey: .groups) ?? []
        piles = try values.decodeIfPresent([CanvasPile].self, forKey: .piles) ?? []
        omissions = try values.decode([String].self, forKey: .omissions)
    }

    public func expandedSelection(_ roots: [String]) -> Set<String> {
        var result = Set(roots).intersection(Set(nodes.map(\.id)))
        for root in roots {
            let containers = CanvasGroupHierarchy.subtreeIDs(root, groups: groups)
            result.formUnion(groups.filter { containers.contains($0.id) }.flatMap(\.nodeIDs))
            for pile in piles where pile.id == root || pile.groupID.map(containers.contains) == true {
                result.formUnion(pile.memberIDs)
            }
        }
        return result
    }

    public enum Direction: String, Codable { case upstream, downstream, both }
    public func subgraphIDs(roots: [String], direction: Direction) -> Set<String> {
        let known = Set(nodes.map(\.id))
        var adjacency: [String: [String]] = [:]
        for edge in edges {
            if direction != .downstream { adjacency[edge.toNodeId, default: []].append(edge.fromNodeId) }
            if direction != .upstream { adjacency[edge.fromNodeId, default: []].append(edge.toNodeId) }
        }
        var visited = Set(roots).intersection(known)
        var queue = Array(visited)
        var index = 0
        while index < queue.count {
            let id = queue[index]; index += 1
            for next in adjacency[id] ?? [] {
                if known.contains(next), visited.insert(next).inserted { queue.append(next) }
            }
        }
        return visited
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
