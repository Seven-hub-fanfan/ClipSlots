import Foundation
import ClipSlotsKit

@MainActor
enum CanvasWorkflowCapture {
    static func inputAttachments(node: CanvasNode, attachments: [SlotContent.SlotAttachment]) -> [SlotContent.SlotAttachment] {
        guard !node.isMediaSource else { return [] }
        let outputs = Set(node.outputAttachmentIds), explicit = Set(node.inputAttachmentIds)
        return attachments.filter {
            !outputs.contains($0.id.uuidString) &&
                (explicit.contains($0.id.uuidString) || !CrateGeneration.isGeneratedAssetName($0.name))
        }
    }

    static func facts(nodes: [CanvasNode], store: SlotStoreObservable,
                      includeMediaMetadata: Bool = true) -> [CanvasWorkflowFacts] {
        let index = includeMediaMetadata ? store.specialStorage.loadIndex() : nil
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        return nodes.map { node in
            let content = store.canvasReadFullContent(groupId: node.groupId, slot: node.slot)
            let attachments = content?.attachments ?? []
            let inputs = inputAttachments(node: node, attachments: attachments)
            let label = includeMediaMetadata ? store.canvasSlotLabel(groupId: node.groupId, slot: node.slot) ?? "" : ""
            let pathLabel = CanvasCardText.pathLabel(pageName: index?.pages.first { $0.id == node.pageId }?.name,
                groupName: index?.specialSlots.first { $0.id == node.groupId }?.name, slot: node.slot,
                isUnfiled: SpecialSlotStorage.isReservedGroupId(node.groupId))
            let body = store.canvasSlotText(groupId: node.groupId, slot: node.slot) ?? ""
            var paths: [String: String] = [:]
            var media: [CanvasWorkflowMedia] = includeMediaMetadata ? attachments.map { attachment -> CanvasWorkflowMedia in
                let resource = "media-" + attachment.id.uuidString
                // Match the generator's path preference including the legacy originalPath fallback.
                let path = [attachment.storagePath, attachment.path, attachment.originalPath]
                    .compactMap { $0 }.first { !$0.isEmpty && exists($0) }
                if let path { paths[resource] = path }
                let attrs = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) } ?? [:]
                let revision = CanvasWorkflowSnapshot.digest(Data((
                    "\(attachment.id)|\(attachment.name)|\(path ?? "")|\(attrs[.size] ?? 0)|"
                    + "\(attrs[.modificationDate] ?? "")|\(attrs[.systemFileNumber] ?? 0)|"
                    + (attachment.data.map(CanvasWorkflowSnapshot.digest) ?? "")
                ).utf8))
                return .init(id: resource, attachmentID: attachment.id.uuidString, name: attachment.name,
                    kind: attachment.canvasIsVideoLike ? "video" : attachment.canvasIsImageLike ? "image" : "file",
                    role: node.outputAttachmentIds.contains(attachment.id.uuidString) ? "output"
                        : node.isMediaSource ? "source" : "input",
                    revision: revision,
                    availability: path != nil ? "local" : attachment.data?.isEmpty == false ? "inline" : "missing")
            } : []
            var primary: String?
            if node.kind.isMediaNode {
                primary = CanvasMediaPick.primary(node: node, attachments: attachments)?.canvasLocalURL?.path
            } else if case .succeeded(let asset) = node.state, !asset.isEmpty, exists(asset) {
                primary = asset
            }
            if includeMediaMetadata, let primary, !paths.values.contains(primary) {
                let resource = "legacy-" + CanvasWorkflowSnapshot.digest(Data(primary.utf8))
                paths[resource] = primary
                let attrs = (try? FileManager.default.attributesOfItem(atPath: primary)) ?? [:]
                media.append(.init(id: resource, attachmentID: "", name: URL(fileURLWithPath: primary).lastPathComponent,
                    kind: node.kind == .video ? "video" : "image", role: "output",
                    revision: CanvasWorkflowSnapshot.digest(Data("\(attrs[.size] ?? 0)|\(attrs[.modificationDate] ?? "")".utf8)),
                    availability: "local"))
            }
            return .init(node: node, title: label.isEmpty ? pathLabel : "\(label) · \(pathLabel)",
                body: body, bodyRevision: includeMediaMetadata ? CanvasWorkflowSnapshot.digest(Data(body.utf8)) : "",
                bodyAvailable: content != nil, primaryAssetPath: primary,
                slotImagePaths: CrateGeneration.inputImagePaths(from: attachments, excludingAttachmentIds: [],
                    includingGeneratedAssets: true, fileExists: exists),
                inputImagePaths: CrateGeneration.inputImagePaths(from: inputs,
                    excludingAttachmentIds: Set(node.outputAttachmentIds),
                    explicitInputIds: Set(node.inputAttachmentIds), fileExists: exists),
                expectedSlotImages: attachments.filter(\.canvasIsImageLike).count,
                expectedInputImages: inputs.filter(\.canvasIsImageLike).count,
                media: media, resourcePaths: paths)
        }
    }

    static func plan(node: CanvasNode, canvas: CanvasStore, store: SlotStoreObservable,
                     reusingSeed: Bool = false,
                     upstreamResults: [String: String] = [:]) -> CanvasWorkflowResolver.Plan {
        let edges = canvas.edges.map { edge -> CanvasEdge in
            var copy = edge
            if edge.toNodeId == node.id { copy.fromNodeId = upstreamResults[edge.fromNodeId] ?? edge.fromNodeId }
            return copy
        }
        let ids = Set(CanvasEdgeGraph.incoming(of: node.id, edges: edges).map(\.fromNodeId) + [node.id])
        let collected = facts(nodes: canvas.nodes.filter { ids.contains($0.id) }, store: store, includeMediaMetadata: false)
        let all = Dictionary(collected.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fact = all[node.id] ?? .init(node: node, title: "", body: "", bodyRevision: "", bodyAvailable: false)
        fact.node = node
        return CanvasWorkflowResolver.resolve(fact, all: all, edges: edges,
            model: CrateModelCatalogStore.shared.model(id: node.model), reusingSeed: reusingSeed)
    }

    static func snapshot(canvas: CanvasStore, store: SlotStoreObservable,
                         runs capturedRuns: [GenerationRun]? = nil) -> (CanvasWorkflowSnapshot, [String: String]) {
        let collected = facts(nodes: canvas.nodes, store: store)
        let runs = capturedRuns ?? GenerationRunStore.shared.runs(project: canvas.activeProjectId)
        let latest = collected.reduce(into: [String: UUID]()) { result, fact in
            result[fact.node.id] = runs.first {
                $0.nodeID == fact.node.id && $0.nodeCreatedAt == fact.node.createdAt
            }?.id
        }
        let snapshot = CanvasWorkflowSnapshot(projectID: canvas.activeProjectId, facts: collected, edges: canvas.edges,
            selectionIDs: canvas.selectedGroupID.map { [$0] } ?? Array(canvas.selectedNodeIds),
            models: CrateModelCatalogStore.shared.imageModels + CrateModelCatalogStore.shared.videoModels, latestRuns: latest,
            groups: canvas.groups, piles: canvas.piles)
        let paths = collected.reduce(into: [String: String]()) { result, fact in
            for (resource, path) in fact.resourcePaths where result[path] == nil { result[path] = resource }
        }
        return (snapshot, paths)
    }
}
