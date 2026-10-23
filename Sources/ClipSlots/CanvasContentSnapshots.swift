import SwiftUI
import ClipSlotsKit

/// Rendering never checks the filesystem. Unknown data stays unknown; this
/// cache is deliberately not used to decide whether a slot can be overwritten.
final class CanvasContentSnapshots: ObservableObject {
    struct Entry {
        let content: SlotContent
        let label: String?
        let revision: Int
        let existingPaths: Set<String>
        let fileVersions: [String: String]
    }
    private(set) var entries: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "clipslots.canvas.render-content", qos: .userInitiated)
    private var request = 0
    private var running = false
    private var pending: (() -> Void)?
    private var pendingFinished: (() -> Void)?
    private var notificationQueued = false
    private func publish(_ values: [String: Entry]) {
        entries = values
        guard !notificationQueued else { return }
        notificationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationQueued = false
            self.objectWillChange.send()
        }
    }
    static func key(_ group: String, _ slot: Int) -> String { "\(group)#\(slot)" }
    func entry(_ node: CanvasNode) -> Entry? { entries[Self.key(node.groupId, node.slot)] }

    /// The batch loader already read these text slots off the main thread.
    /// Reuse them before the first card mounts; the normal refresh reconciles
    /// labels, subsequent writes and any draft owned by the document store.
    func seedText(group: String, contents: [Int: SlotContent]) {
        var next = entries
        var changed = false
        for (slot, content) in contents {
            let key = Self.key(group, slot)
            guard next[key] == nil, content.attachments.isEmpty else { continue }
            next[key] = Entry(content: content, label: nil, revision: 1,
                              existingPaths: [], fileVersions: [:])
            changed = true
        }
        if changed { publish(next) }
    }

    func refresh(nodes: [CanvasNode], store: SlotStoreObservable,
                 finished: @escaping () -> Void = {}, completed: @escaping () -> Void) {
        request &+= 1
        if running {
            pendingFinished?()
            pendingFinished = finished
            pending = { [weak self, weak store] in
                guard let self, let store else { finished(); return }
                self.refresh(nodes: nodes, store: store, finished: finished, completed: completed)
            }
            return
        }
        running = true
        let ticket = request
        let reads = Dictionary(nodes.map { node in
            (Self.key(node.groupId, node.slot),
             (node.groupId, node.slot, store.canvasStorage(groupId: node.groupId)))
        }, uniquingKeysWith: { first, _ in first })
        let current = store.currentSpecialSlotId, memory = store.slots, labels = store.labels
        queue.async { [weak self, weak store] in
            var values: [String: (SlotContent, String?, Set<String>, [String: String])] = [:]
            for (key, (group, slot, storage)) in reads {
                guard let content = group == current ? (memory[slot] ?? storage.getOrUnknown(slot, in: group))
                                                     : storage.getOrUnknown(slot, in: group) else { continue }
                let paths = Set(content.attachments.flatMap { [$0.storagePath, $0.path, $0.originalPath].compactMap { $0 } }
                    .filter { FileManager.default.fileExists(atPath: $0) })
                let versions = Dictionary(paths.map { path in
                    let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                    return (path, "\(attrs[.modificationDate] ?? "")|\(attrs[.size] ?? "")|\(attrs[.systemFileNumber] ?? "")")
                }, uniquingKeysWith: { first, _ in first })
                values[key] = (content, group == current ? (labels[slot] ?? storage.getLabel(slot, in: group))
                                                         : storage.getLabel(slot, in: group), paths, versions)
            }
            DispatchQueue.main.async {
                guard let self else { finished(); return }
                self.running = false
                defer {
                    finished()
                    let latest = self.pending
                    self.pending = nil
                    self.pendingFinished = nil
                    latest?()
                }
                guard self.request == ticket else { return }
                var next = self.entries
                var changed = false
                for (key, value) in values {
                    let previous = next[key]
                    if previous?.content.contentId != value.0.contentId
                        || previous?.content.updatedAt != value.0.updatedAt || previous?.label != value.1
                        || previous?.existingPaths != value.2 || previous?.fileVersions != value.3 {
                        next[key] = Entry(content: value.0, label: value.1, revision: (previous?.revision ?? 0) + 1,
                                          existingPaths: value.2, fileVersions: value.3)
                        changed = true
                    }
                    store?.canvasTextDocuments[key]?.refreshFromStorage(value.0)
                }
                let retainedKeys = Set(reads.keys)
                if !Set(next.keys).isSubset(of: retainedKeys) {
                    next = next.filter { retainedKeys.contains($0.key) }
                    changed = true
                }
                if changed {
                    self.publish(next)
                    completed()
                }
            }
        }
    }
}

extension CanvasWorkspaceView {
    func renderText(for node: CanvasNode) -> String {
        let key = CanvasContentSnapshots.key(node.groupId, node.slot)
        if let draft = store.canvasTextDocuments[key], draft.isDirty { return draft.text }
        return contentSnapshots.entry(node)?.content.plainText ?? ""
    }
    func renderAttachments(for node: CanvasNode) -> [SlotContent.SlotAttachment] {
        contentSnapshots.entry(node)?.content.attachments ?? []
    }
    func renderMedia(of node: CanvasNode) -> SlotContent.SlotAttachment? {
        CanvasMediaPick.primary(node: node, attachments: renderAttachments(for: node))
    }
    func renderInputAttachments(for node: CanvasNode) -> [SlotContent.SlotAttachment] {
        CanvasWorkflowCapture.inputAttachments(node: node, attachments: renderAttachments(for: node))
    }
    func renderImagePaths(for node: CanvasNode, all: Bool = false) -> [String] {
        let paths = contentSnapshots.entry(node)?.existingPaths ?? []
        return CrateGeneration.inputImagePaths(from: all ? renderAttachments(for: node) : renderInputAttachments(for: node),
            excludingAttachmentIds: all ? [] : Set(node.outputAttachmentIds),
            includingGeneratedAssets: all,
            explicitInputIds: all ? [] : Set(node.inputAttachmentIds),
            fileExists: paths.contains)
    }
    func renderPlan(for node: CanvasNode) -> CanvasWorkflowResolver.Plan {
        let ids = Set(canvas.incomingEdges(of: node.id).map(\.fromNodeId) + [node.id])
        let facts = canvas.nodes.filter { ids.contains($0.id) }.map { item -> CanvasWorkflowFacts in
            let entry = contentSnapshots.entry(item)
            let primary = renderMedia(of: item).flatMap { attachment in
                [attachment.storagePath, attachment.path, attachment.originalPath].compactMap { $0 }
                    .first { entry?.existingPaths.contains($0) == true }
            }
            return .init(node: item, title: "", body: renderText(for: item), bodyRevision: "",
                bodyAvailable: entry != nil, primaryAssetPath: primary,
                slotImagePaths: renderImagePaths(for: item, all: true), inputImagePaths: renderImagePaths(for: item),
                expectedSlotImages: renderAttachments(for: item).filter(\.canvasIsImageLike).count,
                expectedInputImages: renderInputAttachments(for: item).filter(\.canvasIsImageLike).count)
        }
        let all = Dictionary(facts.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fact = all[node.id] ?? .init(node: node, title: "", body: "", bodyRevision: "", bodyAvailable: false)
        return CanvasWorkflowResolver.resolve(fact, all: all, edges: canvas.edges,
            model: CrateModelCatalogStore.shared.model(id: node.model))
    }

    func refreshCanvasContent() {
        let project = canvas.activeProjectId
        contentSnapshots.refresh(nodes: canvas.nodes, store: store) {
            guard canvas.activeProjectId == project else { return }
            synchronizeMediaLayouts()
        }
    }
}
