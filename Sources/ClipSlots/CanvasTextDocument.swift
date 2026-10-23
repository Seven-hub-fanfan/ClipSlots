import AppKit
import Combine
import ClipSlotsKit

/// A slot owns one live document. Only its editors/preview observe keystrokes;
/// the workspace and disk are updated after a typing burst.
final class CanvasTextDocument: ObservableObject {
    @Published private(set) var text: String
    @Published private(set) var saveError: String?
    private(set) var revision: UInt64 = 0
    private(set) var durableText: String
    private var durableBody: AgentSlotBody?
    private var acceptedWrite: UInt64 = 0
    private var nextWrite: UInt64 = 0
    private var inFlight: Set<UInt64> = []
    private var scheduled: DispatchWorkItem?
    private let writer: Writer
    private let queue: DispatchQueue
    var didPersist: ((AgentSlotBody?, String, String, SlotContent) -> Void)?
    var isDirty: Bool { text != durableText || saveError != nil || !inFlight.isEmpty }

    init(content: SlotContent?, storage: SpecialSlotStorage, groupID: String, slot: Int,
         queue: DispatchQueue) {
        let initialText = content?.plainText ?? ""
        text = initialText
        durableText = initialText
        durableBody = content.map(AgentSlotBody.init)
        self.queue = queue
        writer = Writer(content: content, storage: storage, groupID: groupID, slot: slot)
    }

    func edit(_ value: String) {
        guard text != value else { return }
        text = value
        revision &+= 1
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveSoon() }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Blur ends a burst but never performs disk I/O on the input callback.
    func saveSoon() {
        scheduled?.cancel()
        scheduled = nil
        guard isDirty else { return }
        nextWrite &+= 1
        inFlight.insert(nextWrite)
        let value = text, version = nextWrite, writer = writer
        queue.async { [weak self] in
            let result = Result { try writer.save(value) }
            DispatchQueue.main.async {
                self?.inFlight.remove(version)
                self?.accept(result, write: version, text: value)
            }
        }
    }

    /// Used only at explicit boundaries (submit, switch, quit, external write).
    /// The same FIFO fences in-flight saves, so delayed callbacks cannot roll back UI.
    @discardableResult func flush() -> Bool {
        scheduled?.cancel()
        scheduled = nil
        guard isDirty else { return true }
        nextWrite &+= 1
        let value = text, version = nextWrite
        let result = queue.sync { Result { try writer.save(value) } }
        inFlight.removeAll()
        accept(result, write: version, text: value)
        return saveError == nil
    }

    /// Interactive graph actions await the same FIFO without parking AppKit.
    @MainActor @discardableResult func flushAsync() async -> Bool {
        scheduled?.cancel()
        scheduled = nil
        guard isDirty else { return true }
        nextWrite &+= 1
        let value = text, version = nextWrite, writer = writer
        inFlight.insert(version)
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let result = Result { try writer.save(value) }
                DispatchQueue.main.async {
                    guard let self else { continuation.resume(returning: false); return }
                    self.inFlight.remove(version)
                    self.accept(result, write: version, text: value)
                    continuation.resume(returning: self.saveError == nil)
                }
            }
        }
    }

    func refreshFromStorage(_ content: SlotContent) {
        if durableBody == nil {
            let hadInput = !text.isEmpty
            durableBody = AgentSlotBody(content)
            durableText = content.plainText ?? ""
            queue.async { [writer] in writer.expected = AgentSlotBody(content) }
            if !hadInput { text = durableText }
            revision &+= 1
            return
        }
        guard !isDirty, AgentSlotBody(content) != durableBody else { return }
        revision &+= 1
        nextWrite &+= 1
        acceptedWrite = nextWrite
        text = content.plainText ?? ""
        durableText = text
        durableBody = AgentSlotBody(content)
        queue.async { [writer] in writer.expected = AgentSlotBody(content) }
    }

    private func accept(_ result: Result<SlotContent, Error>, write version: UInt64, text value: String) {
        guard version >= acceptedWrite else { return }
        acceptedWrite = version
        switch result {
        case .success(let content):
            let before = durableText
            let beforeBody = durableBody
            durableText = value
            durableBody = AgentSlotBody(content)
            saveError = nil
            if before != value { didPersist?(beforeBody, before, value, content) }
        case .failure(let error):
            saveError = error.localizedDescription + " 输入仍已保留，可复制或重试保存。"
        }
    }

    /// All mutable writer state belongs to the store's existing serial write queue.
    private final class Writer {
        var expected: AgentSlotBody?
        let storage: SpecialSlotStorage
        let groupID: String
        let slot: Int
        init(content: SlotContent?, storage: SpecialSlotStorage, groupID: String, slot: Int) {
            expected = content.map(AgentSlotBody.init)
            self.storage = storage
            self.groupID = groupID
            self.slot = slot
        }
        func save(_ text: String) throws -> SlotContent {
            guard let expected else { throw AgentCanvasError.unavailable }
            let replacement = AgentSlotBody(text: text)
            let content = try storage.exchangeAgentBody(slot, in: groupID,
                expected: expected, replacement: replacement)
            self.expected = AgentSlotBody(content)
            return content
        }
    }
}

extension SlotStoreObservable {
    func canvasTextDocument(groupID: String, slot: Int,
                            renderContent: SlotContent? = nil, rendering: Bool = false) -> CanvasTextDocument {
        let key = "\(groupID)#\(slot)"
        if let existing = canvasTextDocuments[key] {
            return existing
        }
        let document = CanvasTextDocument(content: rendering ? renderContent : canvasReadFullContent(groupId: groupID, slot: slot),
            storage: canvasStorage(groupId: groupID), groupID: groupID, slot: slot, queue: slotWriteQueue)
        document.didPersist = { [weak self] beforeBody, before, after, saved in
            guard let self else { return }
            if groupID == self.currentSpecialSlotId,
               var visible = self.canvasReadFullContent(groupId: groupID, slot: slot),
               (AgentSlotBody(visible) == beforeBody || AgentSlotBody(visible) == AgentSlotBody(saved)) {
                // Keep newer attachment/label edits in memory.
                visible.items = saved.items
                visible.htmlSource = saved.htmlSource
                visible.timestamp = saved.timestamp
                visible.contentId = saved.contentId
                visible.updatedAt = saved.updatedAt
                self.slots[slot] = visible
            }
            self.bumpCanvasSlotRevision()
            self.canvasTextDidPersist?(groupID, slot, before, after)
        }
        canvasTextDocuments[key] = document
        return document
    }

    @discardableResult func flushCanvasTextDocuments() -> Bool {
        let results = Array(canvasTextDocuments.values).map { $0.flush() }
        if !results.allSatisfy({ $0 }) {
            transientUI.showToast("文本尚未保存，输入已保留。请在输入框中重试保存。", duration: 4)
            return false
        }
        return true
    }

    @MainActor func flushCanvasTextDocumentsAsync() async -> Bool {
        for document in Array(canvasTextDocuments.values) {
            guard await document.flushAsync() else {
                transientUI.showToast("文本尚未保存，输入已保留。请重试保存。", duration: 4)
                return false
            }
        }
        return true
    }
}
