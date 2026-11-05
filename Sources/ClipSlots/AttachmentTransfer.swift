import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipSlotsKit

/// Internal drags carry source identity, while Finder/clipboard imports append.
enum AttachmentTransfer {
    static let bodyType = UTType(exportedAs: "com.clipslots.slot-body", conformingTo: .data)
    static let bundleType = UTType(exportedAs: "com.clipslots.slot-attachments", conformingTo: .data)
    static let dropTypes: [UTType] = [bodyType, bundleType, .fileURL, .image]
    static func type(for source: SlotFileMove) -> UTType {
        source.attachmentBundle == nil ? bodyType : bundleType
    }

    static func canDrag(_ content: SlotContent) -> Bool {
        content.items.contains { group in
            group.contains { $0.type == UTType.fileURL.identifier || SlotContent.isImagePasteboardType($0.type) }
        } || SlotFileMove.isTextBody(content)
    }

    static func files(_ urls: [URL]) -> [SlotContent.SlotAttachment] {
        urls.filter {
            $0.isFileURL && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }.map {
            .init(name: $0.lastPathComponent,
                  type: SlotContent.imageFileExtensions.contains($0.pathExtension.lowercased()) ? .image : .file,
                  path: $0.path)
        }
    }

    static func body(_ content: SlotContent) -> [SlotContent.SlotAttachment] {
        SlotFileMove.bodyAttachments(in: content)
    }

    static func provider(_ source: SlotFileMove) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(source)) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type(for: source).identifier, visibility: .ownProcess) {
            completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    enum Loaded { case move(SlotFileMove), additions([SlotContent.SlotAttachment]) }

    @discardableResult
    static func receive(_ providers: [NSItemProvider], completion: @escaping (Loaded) -> Void) -> Bool {
        let internalItems = providers.filter {
            $0.hasItemConformingToTypeIdentifier(bodyType.identifier)
                || $0.hasItemConformingToTypeIdentifier(bundleType.identifier)
        }
        if !internalItems.isEmpty {
            guard internalItems.count == 1 else { return false }
            let isBundle = internalItems[0].hasItemConformingToTypeIdentifier(bundleType.identifier)
            internalItems[0].loadDataRepresentation(forTypeIdentifier: (isBundle ? bundleType : bodyType).identifier) { data, _ in
                guard let data, let move = try? JSONDecoder().decode(SlotFileMove.self, from: data),
                      (move.attachmentBundle != nil) == isBundle else { return }
                DispatchQueue.main.async { completion(.move(move)) }
            }
            return true
        }
        return load(providers) { completion(.additions($0)) }
    }

    static func clipboard(_ pasteboard: NSPasteboard) -> [SlotContent.SlotAttachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return files(urls) }
        let groups = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> PasteboardItem? in
                guard SlotContent.isImagePasteboardType(type.rawValue), let data = item.data(forType: type) else { return nil }
                return PasteboardItem(type: type.rawValue, data: data)
            }
        }
        let images = body(SlotContent(items: groups))
        if !images.isEmpty { return images }
        if let raw = pasteboard.string(forType: .URL), let url = URL(string: raw), !url.isFileURL {
            return [.init(name: raw, type: .url, url: raw)]
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return [] }
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return [.init(name: text, type: .url, url: text)]
        }
        return [.init(name: String(text.prefix(30)), type: .text, data: Data(text.utf8))]
    }

    /// Resolve in provider order, returning on main. Destination identity is
    /// captured by the caller before any asynchronous provider is requested.
    @discardableResult
    static func load(_ providers: [NSItemProvider],
                     completion: @escaping ([SlotContent.SlotAttachment]) -> Void) -> Bool {
        let relevant = providers.filter { provider in
            dropTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        guard !relevant.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var results = Array(repeating: [SlotContent.SlotAttachment](), count: relevant.count)
        for (index, provider) in relevant.enumerated() {
            group.enter()
            func finish(_ attachments: [SlotContent.SlotAttachment]) {
                lock.lock()
                results[index] = attachments
                lock.unlock()
                group.leave()
            }
            if provider.hasItemConformingToTypeIdentifier(bodyType.identifier)
                || provider.hasItemConformingToTypeIdentifier(bundleType.identifier) {
                finish([]) // Internal drags must retain and validate their source.
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        ?? (item as? String).flatMap(URL.init(string:))
                    finish(files(url.map { [$0] } ?? []))
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    finish(data.map { body(SlotContent(items: [[.init(type: type, data: $0)]])) } ?? [])
                }
            } else { finish([]) }
        }
        group.notify(queue: .main) { completion(results.flatMap { $0 }) }
        return true
    }
}

extension SlotStoreObservable {
    /// Drop acceptance is immediate; success-dependent UI waits for the actual
    /// storage result. Source removal remains part of moveFile's transaction.
    func acceptTransferInBackground(_ loaded: AttachmentTransfer.Loaded, groupID: String, slot: Int,
                                    destination: SlotFileMoveDestination = .attachments,
                                    completion: @escaping (Bool) -> Void = { _ in }) {
        Task { @MainActor in
            switch loaded {
            case .additions(let additions):
                completion(await appendTransferredAttachmentsAsync(additions, groupID: groupID, slot: slot))
            case .move(let move):
                guard canvasTextDocuments["\(groupID)#\(slot)"]?.flush() != false,
                      canvasTextDocuments["\(move.groupID)#\(move.slot)"]?.flush() != false else {
                    completion(false); return
                }
                let target = canvasStorage(groupId: groupID)
                let source = canvasStorage(groupId: move.groupID)
                do {
                    let result: (SlotContent, SlotContent?) = try await withCheckedThrowingContinuation { continuation in
                        slotWriteQueue.async {
                            do {
                                let saved = try target.moveFile(move, from: source, to: slot,
                                    groupID: groupID, destination: destination)
                                continuation.resume(returning: (saved, source.getOrUnknown(move.slot, in: move.groupID)))
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    if displayedSpecialSlotId == groupID { slots[slot] = result.0 }
                    if displayedSpecialSlotId == move.groupID { slots[move.slot] = result.1 }
                    refreshTrigger = UUID()
                    bumpCanvasSlotRevision()
                    completion(true)
                } catch {
                    transientUI.showToast((error as? AgentOperationError)?.localizedDescription
                        ?? "移动未完成，原内容已保留，请重新拖动")
                    completion(false)
                }
            }
        }
    }

    @MainActor func appendTransferredAttachmentsAsync(_ additions: [SlotContent.SlotAttachment],
                                                     groupID: String, slot: Int) async -> Bool {
        guard !additions.isEmpty else {
            transientUI.showToast("没有可添加的内容，或源文件已不可用")
            return false
        }
        let storage = canvasStorage(groupId: groupID)
        let threshold = config.attachmentWarningCount
        if threshold > 0 {
            let count: Int = await withCheckedContinuation { continuation in
                slotWriteQueue.async {
                    continuation.resume(returning: (storage.getOrUnknown(slot, in: groupID)?.attachments.count ?? 0)
                        + additions.count)
                }
            }
            if count > threshold {
                let alert = NSAlert()
                alert.messageText = "附件将达到 \(count) 项"
                alert.informativeText = "较多附件可能增加打开和预览时的负担。仍可继续添加；也可以分到其他槽位。"
                alert.addButton(withTitle: "继续添加")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
        }
        guard canvasTextDocuments["\(groupID)#\(slot)"]?.flush() != false else { return false }
        do {
            let saved: SlotContent = try await withCheckedThrowingContinuation { continuation in
                slotWriteQueue.async {
                    do {
                        continuation.resume(returning: try storage.appendTransferredAttachments(additions,
                            slot: slot, groupID: groupID))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            if displayedSpecialSlotId == groupID { slots[slot] = saved }
            refreshTrigger = UUID()
            bumpCanvasSlotRevision()
            return true
        } catch {
            transientUI.showToast("附件保存失败，源文件与原槽位未修改，请重试")
            return false
        }
    }

    func fileMoveSource(groupID: String, slot: Int,
                        attachment: SlotContent.SlotAttachment? = nil,
                        moveAllAttachments: Bool = false) -> SlotFileMove? {
        guard canvasTextDocuments["\(groupID)#\(slot)"]?.flush() != false else { return nil }
        guard let snapshot = try? canvasStorage(groupId: groupID).editorSnapshot(slot, in: groupID) else { return nil }
        if let attachment, !snapshot.content.attachments.contains(attachment) { return nil }
        if moveAllAttachments {
            guard !snapshot.content.attachments.isEmpty else { return nil }
        } else if attachment == nil, !AttachmentTransfer.canDrag(snapshot.content) { return nil }
        return SlotFileMove(snapshot: snapshot, attachment: attachment, moveAllAttachments: moveAllAttachments)
    }

    @discardableResult
    func acceptTransfer(_ loaded: AttachmentTransfer.Loaded, groupID: String, slot: Int,
                        destination: SlotFileMoveDestination = .attachments) -> Bool {
        switch loaded {
        case .additions(let files):
            return appendTransferredAttachments(files, groupID: groupID, slot: slot)
        case .move(let move):
            guard canvasTextDocuments["\(groupID)#\(slot)"]?.flush() != false,
                  canvasTextDocuments["\(move.groupID)#\(move.slot)"]?.flush() != false else { return false }
            do {
                let targetStorage = canvasStorage(groupId: groupID)
                let sourceStorage = canvasStorage(groupId: move.groupID)
                let saved = try slotWriteQueue.sync {
                    try targetStorage.moveFile(move, from: sourceStorage, to: slot,
                        groupID: groupID, destination: destination)
                }
                if displayedSpecialSlotId == groupID { slots[slot] = saved }
                if displayedSpecialSlotId == move.groupID {
                    slots[move.slot] = sourceStorage.getOrUnknown(move.slot, in: move.groupID)
                }
                refreshTrigger = UUID()
                bumpCanvasSlotRevision()
                return true
            } catch {
                transientUI.showToast((error as? AgentOperationError)?.localizedDescription
                    ?? "移动未完成，原内容已保留，请重新拖动")
                return false
            }
        }
    }

    func dropFilesIntoGroup(_ providers: [NSItemProvider], groupID: String) -> Bool {
        guard !providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(AttachmentTransfer.bundleType.identifier)
        }) else { return false }
        guard providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(AttachmentTransfer.bodyType.identifier)
        }) else { return false }
        return AttachmentTransfer.receive(providers) { loaded in
            let storage = self.canvasStorage(groupId: groupID)
            guard storage.loadIndex().specialSlots.contains(where: { $0.id == groupID }) else { return }
            let capacity = SpecialSlotStorage.isReservedGroupId(groupID) ? SpecialSlotStorage.unfiledCapacity : 10
            guard let emptySlot = (1...capacity).first(where: {
                guard let content = storage.getOrUnknown($0, in: groupID) else { return false }
                return content.items.isEmpty && content.htmlSource?.isEmpty != false
            }) else {
                self.transientUI.showToast("这个组没有空槽位，请悬停切组后拖到附件按钮")
                return
            }
            self.acceptTransferInBackground(loaded, groupID: groupID, slot: emptySlot, destination: .body) { success in
                if success { self.switchSpecialSlot(id: groupID, fromNavigation: true) }
            }
        }
    }

    @discardableResult
    func appendTransferredAttachments(_ additions: [SlotContent.SlotAttachment],
                                      groupID: String, slot: Int) -> Bool {
        guard !additions.isEmpty else {
            transientUI.showToast("没有可添加的内容，或源文件已不可用")
            return false
        }
        let storage = canvasStorage(groupId: groupID)
        let threshold = config.attachmentWarningCount
        let count = (storage.getOrUnknown(slot, in: groupID)?.attachments.count ?? 0) + additions.count
        if threshold > 0, count > threshold {
            let alert = NSAlert()
            alert.messageText = "附件将达到 \(count) 项"
            alert.informativeText = "较多附件可能增加打开和预览时的负担。仍可继续添加；也可以分到其他槽位。"
            alert.addButton(withTitle: "继续添加")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        guard canvasTextDocuments["\(groupID)#\(slot)"]?.flush() != false else { return false }
        do {
            let saved = try slotWriteQueue.sync {
                try storage.appendTransferredAttachments(additions, slot: slot, groupID: groupID)
            }
            if displayedSpecialSlotId == groupID { slots[slot] = saved }
            refreshTrigger = UUID()
            bumpCanvasSlotRevision()
            return true
        } catch {
            transientUI.showToast("附件保存失败，源文件与原槽位未修改，请重试")
            return false
        }
    }
}

struct SlotBodyDragModifier: ViewModifier {
    let content: SlotContent
    let groupID: String
    let slot: Int
    let store: SlotStoreObservable?
    let onOpen: () -> Void
    @State private var thumbnail: NSImage?
    @ViewBuilder func body(content view: Content) -> some View {
        if AttachmentTransfer.canDrag(content), let store {
            view.overlay(FirstMouseClickHandle(action: onOpen,
                moveSource: { store.fileMoveSource(groupID: groupID, slot: slot) },
                dragImage: { CompactFileDrag.image(thumbnail: thumbnail,
                    count: SlotFileMove.isTextBody(content) ? 1 : AttachmentTransfer.body(content).count) },
                onDragStarted: { AttachmentPreviewWindowController.shared.hide() }))
            .task(id: content.contentId) {
                if SlotFileMove.isTextBody(content) {
                    thumbnail = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
                    return
                }
                guard let file = AttachmentTransfer.body(content).first else { return }
                thumbnail = await CanvasAttachmentThumbnails.load(file, maxPixel: 144)
            }
        } else {
            view
        }
    }
}

struct FileTransferDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    var types: [UTType] = AttachmentTransfer.dropTypes
    let receive: ([NSItemProvider]) -> Bool
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [AttachmentTransfer.bodyType, AttachmentTransfer.bundleType]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return receive(info.itemProviders(for: types))
    }
}

enum CompactFileDrag {
    static let size = NSSize(width: 88, height: 64)
    static func image(thumbnail: NSImage?, count: Int = 1) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.stroke()
            let image = thumbnail ?? NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
            if let image {
                let area = rect.insetBy(dx: 10, dy: 10)
                let ratio = min(area.width / max(1, image.size.width), area.height / max(1, image.size.height))
                let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
                image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height))
            }
            if count > 1 {
                ("\(count)" as NSString).draw(at: NSPoint(x: 66, y: 5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
            }
            return true
        }
    }
}

/// Common run-loop mode keeps the dwell timer active during macOS drag tracking.
final class GroupDragDwell: ObservableObject {
    @Published private(set) var isTargeted = false
    private var timer: Timer?
    func enter(action: @escaping () -> Void, isDragging: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        cancel()
        isTargeted = true
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, self.isTargeted, isDragging() else { self?.cancel(); return }
            self.timer = nil
            action()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() {
        timer?.invalidate()
        timer = nil
        isTargeted = false
    }
    deinit { timer?.invalidate() }
}

struct GroupDragSwitchDelegate: DropDelegate {
    let dwell: GroupDragDwell
    let isCurrent: Bool
    let action: () -> Void
    var receive: (([NSItemProvider]) -> Bool)? = nil
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: AttachmentTransfer.dropTypes) }
    func dropEntered(info: DropInfo) {
        guard !isCurrent else { return }
        dwell.enter(action: action)
    }
    func dropExited(info: DropInfo) { dwell.cancel() }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [AttachmentTransfer.bundleType]) {
            return DropProposal(operation: .cancel)
        }
        return DropProposal(operation: info.hasItemsConforming(to: [AttachmentTransfer.bodyType]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        dwell.cancel()
        guard !info.hasItemsConforming(to: [AttachmentTransfer.bundleType]) else { return false }
        return receive?(info.itemProviders(for: AttachmentTransfer.dropTypes)) ?? false
    }
}
