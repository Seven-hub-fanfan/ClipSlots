import Foundation

/// A reversible move protected by the same lock as GUI/CLI writes. Each replay
/// compares both slots first; external edits refuse undo rather than being lost.
public final class CanvasArchiveTransfer {
    public struct Location {
        public let storage: SpecialSlotStorage
        public let groupID: String
        public let slot: Int
        public init(storage: SpecialSlotStorage, groupID: String, slot: Int) {
            self.storage = storage; self.groupID = groupID; self.slot = slot
        }
    }
    private let source: Location
    private let target: Location
    private let sourceBirth: Date
    private let targetBirth: Date
    private let targetPage: String
    private var targetBefore: SlotContent
    private var sourceExpected = ""
    private var targetExpected = ""
    private var archived = false

    private init(source: Location, target: Location, sourceBirth: Date, targetBirth: Date,
                 targetPage: String, targetBefore: SlotContent) {
        self.source = source; self.target = target
        self.sourceBirth = sourceBirth; self.targetBirth = targetBirth
        self.targetPage = targetPage; self.targetBefore = targetBefore
    }

    public static func begin(source: Location, target: Location, pageID: String) throws -> CanvasArchiveTransfer {
        try StorageLock.shared.withLock(timeout: 0.15) {
            guard !StorageLock.shared.isDegraded else { throw AgentCanvasError.busy }
            guard source.groupID != target.groupID || source.slot != target.slot,
                  target.slot > 0, target.slot <= 10,
                  let from = source.storage.loadIndex().specialSlots.first(where: { $0.id == source.groupID }),
                  let to = target.storage.loadIndex().specialSlots.first(where: { $0.id == target.groupID && $0.pageId == pageID }),
                  !SpecialSlotStorage.isReservedGroupId(to.id) else { throw AgentCanvasError.staleTarget }
            let a = try read(source), b = try read(target)
            guard b.isEmpty else { throw AgentCanvasError.conflict }
            let transaction = CanvasArchiveTransfer(source: source, target: target,
                sourceBirth: from.createdAt, targetBirth: to.createdAt, targetPage: pageID, targetBefore: b)
            transaction.sourceExpected = signature(a)
            transaction.targetExpected = signature(b)
            try transaction.exchange(undo: false)
            return transaction
        }
    }

    public func exchange(undo: Bool) throws {
        try StorageLock.shared.withLock(timeout: 0.15) {
            guard !StorageLock.shared.isDegraded else { throw AgentCanvasError.busy }
            guard archived == undo,
                  source.storage.loadIndex().specialSlots.contains(where: { $0.id == source.groupID && $0.createdAt == sourceBirth }),
                  target.storage.loadIndex().specialSlots.contains(where: {
                      $0.id == target.groupID && $0.createdAt == targetBirth && $0.pageId == targetPage
                  }) else { throw AgentCanvasError.staleTarget }
            let a = try Self.read(source), b = try Self.read(target)
            guard Self.signature(a) == sourceExpected, Self.signature(b) == targetExpected else {
                throw AgentCanvasError.conflict
            }
            let from = undo ? target : source, to = undo ? source : target
            let moving = undo ? b : a, previousDestination = undo ? a : b
            let vacated = undo ? targetBefore : SlotContent()
            guard previousDestination.isEmpty else { throw AgentCanvasError.conflict }
            // Destination is durably staged before the source is replaced.
            guard to.storage.set(to.slot, content: moving, in: to.groupID, replacingLabel: true) else { throw AgentCanvasError.writeFailed }
            guard from.storage.set(from.slot, content: vacated, in: from.groupID, replacingLabel: true) else {
                _ = to.storage.set(to.slot, content: previousDestination, in: to.groupID, replacingLabel: true)
                throw AgentCanvasError.writeFailed
            }
            sourceExpected = Self.signature(try Self.read(source))
            targetExpected = Self.signature(try Self.read(target))
            archived = !undo
        }
    }

    private static func read(_ location: Location) throws -> SlotContent {
        guard var value = location.storage.getOrUnknown(location.slot, in: location.groupID) else {
            throw AgentCanvasError.unavailable
        }
        value.label = location.storage.getLabel(location.slot, in: location.groupID)
        if value.manualThumbnailId != nil,
           let url = location.storage.manualThumbnailURL(location.slot, in: location.groupID) {
            value.pendingManualThumbnailData = try Data(contentsOf: url)
        }
        return value
    }

    private static func signature(_ content: SlotContent) -> String {
        var value = content
        // An intervening edit followed by its own undo restores semantic content
        // with a new storage revision. That must still allow the earlier move's undo.
        value.timestamp = Date(timeIntervalSince1970: 0)
        value.contentId = ""
        value.updatedAt = 0
        return CanvasWorkflowSnapshot.digest((try? CanvasWorkflowSnapshot.jsonData(value)) ?? Data())
    }
}
