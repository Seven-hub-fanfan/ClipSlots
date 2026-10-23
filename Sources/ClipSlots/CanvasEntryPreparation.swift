import Foundation
import ClipSlotsKit

/// Reads the private library before mounting. The graph and drafts are checked
/// again on the main actor before any undo stash is moved.
@MainActor
final class CanvasEntryPreparation {
    let snapshots = CanvasContentSnapshots()
    let textSurfaces = CanvasTextSurfacePool()
    private let queue = DispatchQueue(label: "clipslots.canvas.entry", qos: .userInitiated)
    private var generation = UUID()

    func prepare(canvas: CanvasStore, store: SlotStoreObservable) async -> Bool {
        let ticket = UUID(); generation = ticket
        let group = canvas.privateGroupId, project = canvas.activeProjectId
        let references = canvas.privateSlotsReferencedByNodes()
        let revision = store.canvasSlotRevision
        let memory = group == store.currentSpecialSlotId ? store.slots : [:]
        let dirty = Set(store.canvasTextDocuments.compactMap { key, document in
            document.isDirty && !document.text.isEmpty ? key : nil
        })
        let scan: (Set<Int>, Set<Int>)? = await withCheckedContinuation { continuation in
            queue.async {
                let storage = SpecialSlotStorage.canvasPrivate
                guard storage.loadIndex().specialSlots.contains(where: { $0.id == group }) else {
                    continuation.resume(returning: nil); return
                }
                var occupied = Set<Int>()
                for slot in 1...SpecialSlotStorage.unfiledCapacity {
                    let disk = storage.getOrUnknown(slot, in: group)
                    if disk == nil || disk?.isEmpty == false || memory[slot]?.isEmpty == false
                        || dirty.contains("\(group)#\(slot)") { occupied.insert(slot) }
                }
                continuation.resume(returning: (occupied, storage.stashedCanvasUndoSlots(in: group)))
            }
        }
        guard !Task.isCancelled, generation == ticket, canvas.activeProjectId == project,
              canvas.privateSlotsReferencedByNodes() == references,
              revision == store.canvasSlotRevision else { return false }
        let nowDirty = Set(store.canvasTextDocuments.compactMap { key, document in
            document.isDirty && !document.text.isEmpty ? key : nil
        })
        guard nowDirty == dirty else { return false }
        if let scan {
            let plan = CanvasPrivateReconcile.plan(.init(privateGroupId: group,
                occupiedSlots: scan.0, stashedSlots: scan.1, referencedByNodes: references,
                documentLoadFailed: canvas.documentLoadFailed))
            // A destructive disk plan is never committed from a render snapshot.
            // The rare repair goes through the existing authoritative recheck.
            if !plan.isEmpty {
                _ = store.reconcileCanvasPrivateContents(groupId: group,
                    referencedByNodes: references, documentLoadFailed: canvas.documentLoadFailed)
            }
        }
        // Keep the cached content across editor↔canvas switches.
        await withCheckedContinuation { continuation in
            snapshots.refresh(nodes: canvas.nodes, store: store, finished: {
                continuation.resume()
            }, completed: {})
        }
        return !Task.isCancelled && generation == ticket && canvas.activeProjectId == project
    }
}
