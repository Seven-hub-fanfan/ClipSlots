#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

enum SlotFlickerRegression {
    @MainActor static func run(root: URL) async throws {
        let storage = SpecialSlotStorage.shared
        let group = storage.loadIndex().specialSlots[0]
        let file = root.appendingPathComponent("preview-fixture.png")
        let image = NSImage(size: NSSize(width: 1000, height: 600))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 600).fill()
        ("ClipSlots stable preview\n文件副本与引用测试" as NSString).draw(at: NSPoint(x: 70, y: 260),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.white])
        image.unlockFocus()
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: file)
        for slot in [1, 5, 10] {
            let source = root.appendingPathComponent("preview-\(slot).png")
            try FileManager.default.copyItem(at: file, to: source)
            let body = SlotContent(items: [[.init(type: "public.file-url", data: Data(source.absoluteString.utf8))]])
            guard storage.set(slot, content: body, in: group.id) else { throw AgentCanvasError.writeFailed }
        }
        for slot in [2, 3, 4, 6, 7, 9] { storage.set(slot, content: SlotContent(text: "test-slot-\(slot)"), in: group.id) }
        let store = SlotStoreObservable()
        store.reloadAll()
        let host = NSHostingView(rootView: FlickerGrid(store: store, groupID: group.id))
        let window = NSWindow(contentRect: NSRect(x: 70, y: 140, width: 1320, height: 690),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "ClipSlots isolated flicker test"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let stable = [5, 10]
        let keys = stable.map { storage.getOrUnknown($0, in: group.id)!.thumbnailKey(specialSlotId: group.id, slot: $0) }
        for _ in 0..<500 {
            if keys.allSatisfy({ ThumbnailProvider.shared.image(for: $0) != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard keys.allSatisfy({ ThumbnailProvider.shared.image(for: $0) != nil }) else { throw AgentCanvasError.unavailable }
        let originalPreviews = keys.compactMap { ThumbnailProvider.shared.image(for:$0) }
        func capture(_ name: String) throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
        }
        try capture("before.png")
        var events: [[String: Any]] = []
        var frameGaps: [Double] = []
        var blankSamples = 0
        var transitions = 0
        var lastBlank = false
        var lastTick = ProcessInfo.processInfo.systemUptime
        let start = lastTick
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            frameGaps.append((now - lastTick) * 1000); lastTick = now
            let blank = keys.contains { ThumbnailProvider.shared.image(for: $0) == nil }
            if blank { blankSamples += 1 }
            if blank != lastBlank {
                transitions += 1
                events.append(["event": blank ? "unchanged-preview-missing" : "unchanged-preview-restored",
                               "time_ms": (now-start)*1000])
                if blank { try? capture("flicker-\(transitions).png") }
            }
            lastBlank = blank
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate(); window.orderOut(nil) }
        for (source, target) in [(1,8), (8,1)] {
            let snapshot = try storage.editorSnapshot(source, in: group.id)
            let move = SlotFileMove(snapshot: snapshot)
            let ok: Bool = await withCheckedContinuation { continuation in
                store.acceptTransferInBackground(.move(move), groupID: group.id, slot: target,
                    destination: .body) { continuation.resume(returning: $0) }
            }
            events.append(["event":"move","source":source,"target":target,"ok":ok,
                           "time_ms":(ProcessInfo.processInfo.systemUptime-start)*1000])
            guard ok else { throw AgentCanvasError.writeFailed }
            try await Task.sleep(for: .milliseconds(1500))
        }
        try capture("after.png")
        timer.invalidate()
        let retainedAcrossMoves = zip(keys, originalPreviews).allSatisfy {
            ThumbnailProvider.shared.image(for:$0.0) === $0.1
        }
        let revisionBefore = store.slotPreviewRevision(5, groupID: group.id)
        let unaffectedBefore = store.slotPreviewRevision(10, groupID: group.id)
        let oldImage = ThumbnailProvider.shared.image(for: keys[0])
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 600).fill()
        image.unlockFocus()
        try NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            .write(to:root.appendingPathComponent("preview-5.png"),options:.atomic)
        _ = storage.setLabel(7, label:"external refresh", in:group.id)
        try await Task.sleep(for:.milliseconds(1400))
        var externalChecks: [String:Bool] = [
            "changed_file_revision_updated":store.slotPreviewRevision(5,groupID:group.id)>revisionBefore,
            "unrelated_file_revision_unchanged":store.slotPreviewRevision(10,groupID:group.id)==unaffectedBefore,
            "changed_file_thumbnail_replaced":ThumbnailProvider.shared.image(for:keys[0]) !== oldImage
        ]
        let other = try storage.createSpecialSlot(name: "Flicker return group")
        storage.updateSelectedSpecialSlot(id:other.id)
        store.reloadAll()
        let returningRevision = store.slotPreviewRevision(5,groupID:group.id)
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x:0,y:0,width:1000,height:600).fill()
        image.unlockFocus()
        try NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            .write(to:root.appendingPathComponent("preview-5.png"),options:.atomic)
        storage.updateSelectedSpecialSlot(id:group.id)
        store.reloadAll()
        externalChecks["external_edit_detected_after_group_return"] =
            store.slotPreviewRevision(5,groupID:group.id)>returningRevision
        let report: [String:Any] = ["unchanged_preview_missing_samples":blankSamples,
            "passed":retainedAcrossMoves && externalChecks.values.allSatisfy { $0 },
            "unchanged_previews_retained_across_moves":retainedAcrossMoves,
            "started_at_ms":start*1000,
            "preview_transitions":transitions, "samples":frameGaps.count,
            "main_queue_gaps_ms":frameGaps, "events":events,
            "stable_preview_loaded_at_end":keys.allSatisfy { ThumbnailProvider.shared.image(for:$0) != nil },
            "external_checks":externalChecks,
            "scope":"actual Store move + visible SlotCardView + storage watcher"]
        try JSONSerialization.data(withJSONObject:report, options:[.sortedKeys,.prettyPrinted])
            .write(to:root.appendingPathComponent("flicker-regression.json"))
        guard retainedAcrossMoves, externalChecks.values.allSatisfy({ $0 }) else {
            throw AgentCanvasError.conflict
        }
    }
}

private struct FlickerGrid: View {
    @ObservedObject var store: SlotStoreObservable
    let groupID: String
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
            ForEach(1...10, id:\.self) { slot in
                SlotCardView(slot:slot, content:store.slots[slot] ?? SlotContent(), specialSlotId:groupID,
                    externalContentRevision:store.slotPreviewRevision(slot, groupID:groupID),
                    onPaste:{}, onCopy:{}, onSave:{}, onClear:{}, onSetLabel:{_ in}, store:store)
                    .frame(height:310)
            }
        }.padding(18)
    }
}
#endif
