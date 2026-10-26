import SwiftUI
import ClipSlotsKit

struct ModelResultSlotEditor: View {
    let cell: ModelEvaluationCell
    @ObservedObject var models: ModelWorkspaceStore
    let store: SlotStoreObservable
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [SpecialSlot] = []
    @State private var groupID = ""
    @State private var slot = 1
    @State private var snapshot: SlotContent?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存测评结果到槽位").font(.system(size: 20, weight: .semibold))
            Picker("槽位组", selection: $groupID) {
                Text("选择槽位组").tag("")
                ForEach(groups) { Text($0.name).tag($0.id) }
            }
            Picker("槽位", selection: $slot) { ForEach(1...10, id: \.self) { Text("槽位 \($0)").tag($0) } }
            if let snapshot {
                Text(snapshot.isEmpty ? "目标为空，可以保存。" : "目标已有内容，请选择空槽；原内容保留。")
                    .font(.system(size: 12)).foregroundStyle(snapshot.isEmpty ? Color.secondary : Color.orange)
            } else { Text("未读取到目标槽位").font(.system(size: 12)).foregroundStyle(.secondary) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { Task { await save() } }
                    .disabled(busy || !models.canWrite || snapshot?.isEmpty != true)
            }
        }.padding(24).frame(width: 480)
            .task {
                groups = await Task.detached { SpecialSlotStorage.shared.loadIndex().specialSlots.filter { !SpecialSlotStorage.isReservedGroupId($0.id) } }.value
            }
            .task(id: "\(groupID)#\(slot)") {
                guard !groupID.isEmpty else { snapshot = nil; return }
                let group = groupID, number = slot
                snapshot = await Task.detached { SpecialSlotStorage.shared.getOrUnknown(number, in: group) }.value
            }
    }
    private func save() async {
        guard let snapshot, snapshot.isEmpty, let group = groups.first(where: { $0.id == groupID }) else { return }
        busy = true; defer { busy = false }
        do {
            var media = cell.localMediaPaths.map { URL(fileURLWithPath: $0) }
            for raw in cell.mediaURLs {
                guard let url = URL(string: raw) else { throw ModelWorkspaceError.response }
                let (temporary, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ModelWorkspaceError.response }
                let root = ClipSlotsPaths.dataRoot.appendingPathComponent("models/media")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "bin" : url.pathExtension))
                try FileManager.default.moveItem(at: temporary, to: file); media.append(file)
            }
            guard models.canWrite else { throw ModelWorkspaceError.unreadable }
            var content = try store.writeModelQuestion(groupID: groupID, slot: slot,
                expectedRevision: BatchGenerationSource.revision(of: snapshot),
                text: cell.text.isEmpty ? "模型测评结果 · \(cell.id.prefix(8))" : cell.text)
            for file in media {
                var attachment = SlotContent.SlotAttachment(name: file.lastPathComponent,
                    type: CanvasAttachmentKind.from(fileName: file.lastPathComponent) == .image ? .image : .file)
                attachment.storagePath = file.path
                let source = BatchGenerationSource(pageID: group.pageId ?? "", group: group, slot: slot, content: content)
                try await store.appendBatchGeneratedAttachment(attachment, source: source)
                guard let current = SpecialSlotStorage.shared.getOrUnknown(slot, in: groupID) else { throw ModelWorkspaceError.unreadable }
                content = current
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
