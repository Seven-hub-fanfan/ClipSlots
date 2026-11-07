#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

/// Isolated benchmark only; invoked by the signed native regression runner.
enum SlotStoragePerformanceRegression {
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to:&info) {
            $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    @MainActor static func run(root: URL) async throws {
        let storage = SpecialSlotStorage.shared
        let group = storage.loadIndex().specialSlots[0]
        let fixture = root.deletingLastPathComponent().appendingPathComponent("fixtures/image.jpg")
        let store = SlotStoreObservable()
        for slot in 2...10 { storage.set(slot, content: SlotContent(text:"Stable slot \(slot)"), in:group.id) }
        store.reloadAll()
        let host = NSHostingView(rootView: PerformanceGrid(store:store,groupID:group.id))
        let window = NSWindow(contentRect:NSRect(x:60,y:100,width:1320,height:690),
            styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for:.milliseconds(1500))
        var gaps: [Double] = []
        var last = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval:0.004,repeats:true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now-last)*1000); last=now
        }
        RunLoop.main.add(timer,forMode:.common)
        defer { timer.invalidate() }
        try await Task.sleep(for:.seconds(1))
        let idleGaps = gaps
        let modes = ["reference","clone","physical"]
        var records: [[String:Any]] = []
        for rep in 0..<15 {
            for offset in 0..<3 {
                let mode = modes[(rep+offset)%3]
                // Fixture reset and its rendering settle outside the timed window.
                let _: Bool = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos:.userInitiated).async {
                        continuation.resume(returning:storage.set(1,content:SlotContent(),in:group.id))
                    }
                }
                store.slots[1] = SlotContent()
                try await Task.sleep(for:.milliseconds(300))
                gaps=[]; last=ProcessInfo.processInfo.systemUptime
                let start=last
                let rssBefore = residentBytes()
                store.fileImportPreferClone = mode != "physical"
                store.fileImportReferenceOnly = mode == "reference"
                let snapshot = try storage.editorSnapshot(1,in:group.id)
                try await store.importSelectedFile(fixture,snapshot:snapshot)
                let saved = storage.getOrUnknown(1,in:group.id)!
                let committed = ProcessInfo.processInfo.systemUptime
                let key=saved.thumbnailKey(specialSlotId:group.id,slot:1)
                var loaded=false
                for _ in 0..<250 {
                    if ThumbnailProvider.shared.image(for:key) != nil { loaded=true; break }
                    try await Task.sleep(for:.milliseconds(8))
                }
                let preview=ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for:.milliseconds(500))
                records.append(["rep":rep,"mode":mode,"commit_return_ms":(committed-start)*1000,
                    "preview_ready_ms":(preview-start)*1000,"preview_loaded":loaded,
                    "main_queue_gaps_ms":gaps,"window_ms":(ProcessInfo.processInfo.systemUptime-start)*1000,
                    "rss_before_bytes":rssBefore,"rss_after_bytes":residentBytes()])
                guard loaded else { throw AgentCanvasError.unavailable }
            }
        }
        // Confirm a larger file stays off the UI thread through the same upload entry.
        var uploadRecords: [[String:Any]]=[]
        let large=root.deletingLastPathComponent().appendingPathComponent("fixtures/large.bin")
        for rep in 0..<3 {
            let _: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos:.userInitiated).async {
                    continuation.resume(returning:storage.set(1,content:SlotContent(),in:group.id))
                }
            }
            store.slots[1]=SlotContent()
            try await Task.sleep(for:.milliseconds(300))
            let snapshot=try storage.editorSnapshot(1,in:group.id)
            gaps=[]; last=ProcessInfo.processInfo.systemUptime
            let start=last
            let mode=modes[rep%3]
            store.fileImportPreferClone=mode != "physical"
            store.fileImportReferenceOnly=mode == "reference"
            try await store.importSelectedFile(large,snapshot:snapshot)
            let committed=ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for:.milliseconds(500))
            uploadRecords.append(["rep":rep,"mode":mode,"return_ms":(committed-start)*1000,"main_queue_gaps_ms":gaps])
        }
        timer.invalidate()
        // Verify the real sidebar scheduler: hidden groups remain without summaries.
        var extra: [SpecialSlot] = []
        var pageID = ""
        for i in 0..<20 {
            if i % 8 == 0 {
                pageID = try storage.createPage(name:"Lazy page \(i)",withDefaultGroup:false).page.id
            }
            extra.append(try storage.createSpecialSlot(name:"Lazy benchmark \(i)",pageId:pageID))
        }
        store.reloadAll()
        let canvas=CanvasStore()
        let library=CanvasLibrarySummaries()
        library.connect(store:store,canvas:canvas)
        let start=ProcessInfo.processInfo.systemUptime
        for group in extra.prefix(2) { library.show(group.id) }
        for _ in 0..<300 {
            if extra.prefix(2).allSatisfy({!library.summary($0.id).values.isEmpty}) { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let firstReady=(ProcessInfo.processInfo.systemUptime-start)*1000
        try await Task.sleep(for:.milliseconds(2200))
        let loaded=extra.filter{!library.summary($0.id).values.isEmpty}.map(\.id)
        let lazy: [String:Any]=["groups":extra.count,"shown_groups":2,"populated_groups":loaded.count,
            "first_ready_ms":firstReady,"hidden_groups_remain_unloaded":loaded.count==2,
            "observed_across_timer_refresh":true]
        let report: [String:Any]=["records":records,"production_upload":uploadRecords,"idle_gaps_ms":idleGaps,
            "lazy_sidebar":lazy,"passed":loaded.count==2,
            "scope":"signed DEBUG build; visible native SlotCardView grid; all modes use importSelectedFile including progress, undo, and watcher; DEBUG ownership override only",
            "sampling":"4ms main-runloop timer gaps are responsiveness, not display FPS"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("ui-performance.json"))
        guard loaded.count==2 else { throw AgentCanvasError.conflict }
    }
}

private struct PerformanceGrid: View {
    @ObservedObject var store: SlotStoreObservable
    let groupID: String
    var body: some View {
        LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:5),spacing:14) {
            ForEach(1...10,id:\.self) { slot in
                SlotCardView(slot:slot,content:store.slots[slot] ?? SlotContent(),specialSlotId:groupID,
                    externalContentRevision:store.slotPreviewRevision(slot,groupID:groupID),
                    onPaste:{},onCopy:{},onSave:{},onClear:{},onSetLabel:{_ in},store:store)
                    .frame(height:310)
            }
        }.padding(18)
    }
}
#endif
