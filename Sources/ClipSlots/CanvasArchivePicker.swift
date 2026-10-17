import SwiftUI
import ClipSlotsKit

struct CanvasArchiveRequest: Identifiable {
    let id = UUID()
    let projectID: String
    let nodes: [CanvasNode]
}

struct CanvasArchivePicker: View {
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var canvas: CanvasStore
    let request: CanvasArchiveRequest
    let archive: (CanvasNode, String, String, Int) throws -> Void
    let close: () -> Void
    @State private var pageID: String?
    @State private var groupID: String?
    @State private var index = 0
    @State private var error: String?
    @State private var saving = false

    private var pages: [SlotPage] { store.pages.sorted { $0.order < $1.order } }
    private var groups: [SpecialSlot] {
        store.specialSlots.filter { $0.pageId == pageID && !SpecialSlotStorage.isReservedGroupId($0.id) }
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("保存到槽位库").font(.system(size: 18, weight: .semibold))
                    Text(index < request.nodes.count
                         ? "\(canvas.nodeTitle(request.nodes[index]))  ·  \(index + 1) / \(request.nodes.count)"
                         : "已完成")
                        .font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk)
                }
                Spacer()
                Button("完成", action: close).keyboardShortcut(.cancelAction)
            }
            Text("选择页面 → 槽位组 → 空槽位，点击槽位即可保存")
                .font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk)
            HStack(alignment: .top, spacing: 10) {
                column("1  页面") {
                    ForEach(pages) { page in
                        row(page.name, symbol: "doc.on.doc", selected: pageID == page.id) {
                            pageID = page.id; groupID = nil; error = nil
                        }.accessibilityIdentifier("archive-page-\(page.id)")
                    }
                    if pages.isEmpty { hint("请先在槽位库创建页面") }
                }
                column("2  槽位组") {
                    if pageID == nil { hint("先选择页面") }
                    else if groups.isEmpty { hint("此页面暂无槽位组") }
                    ForEach(groups) { group in
                        row(group.name, symbol: group.icon, selected: groupID == group.id) {
                            groupID = group.id; error = nil
                        }.accessibilityIdentifier("archive-group-\(group.id)")
                    }
                }
                column("3  槽位") {
                    if let groupID {
                        ForEach(1...max(1, min(10, store.config.slots)), id: \.self) { slot in
                            let free = store.canvasSlotIsFree(groupId: groupID, slot: slot)
                                && canvas.node(forGroupId: groupID, slot: slot) == nil
                            let label = store.canvasSlotLabel(groupId: groupID, slot: slot)
                            row("\(slot)  ·  \(label?.isEmpty == false ? label! : (free ? "空槽位" : "已占用"))",
                                symbol: free ? "tray" : "lock", selected: false) { choose(slot) }
                                .disabled(!free || saving)
                                .opacity(free ? 1 : 0.45)
                                .accessibilityIdentifier("archive-slot-\(slot)")
                        }
                    } else { hint("先选择槽位组") }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundColor(.orange) }
        }
        .padding(22).frame(width: 660)
        .foregroundColor(TapSkin.chromeInk)
        .background(TapSkin.chromeFill)
        .onChange(of: canvas.activeProjectId) { _ in close() }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 4, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10).frame(maxWidth: .infinity).frame(height: 336)
        .background(TapSkin.subtleFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 14)
                Text(title).lineLimit(2)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark") }
            }
            .font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(TapSkin.secondaryInk).padding(.vertical, 10)
    }

    private func choose(_ slot: Int) {
        guard !saving, let pageID, let groupID, index < request.nodes.count else { return }
        saving = true
        defer { saving = false }
        do {
            guard canvas.activeProjectId == request.projectID else { throw AgentCanvasError.staleTarget }
            try archive(request.nodes[index], pageID, groupID, slot)
            index += 1
            error = nil
            if index == request.nodes.count { close() }
        } catch { self.error = error.localizedDescription }
    }
}

extension SlotStoreObservable {
    func prepareArchiveExchange() throws {
        guard flushCanvasTextDocuments() else { throw AgentCanvasError.writeFailed }
        let drained = DispatchSemaphore(value: 0)
        slotWriteQueue.async { drained.signal() }
        guard drained.wait(timeout: .now() + 0.15) == .success else { throw AgentCanvasError.busy }
    }

    func refreshArchivedSlots(_ locations: [CanvasArchiveTransfer.Location]) {
        suppressWatcher()
        for location in locations {
            let content = location.storage.get(location.slot, in: location.groupID)
            if location.groupID == currentSpecialSlotId {
                slots[location.slot] = content
                labels[location.slot] = location.storage.getLabel(location.slot, in: location.groupID)
            }
            canvasTextDocuments["\(location.groupID)#\(location.slot)"]?.refreshFromStorage(content)
            ThumbnailProvider.shared.invalidateSlot(specialSlotId: location.groupID, slot: location.slot)
        }
        bumpCanvasSlotRevision()
        refreshTrigger = UUID()
    }
}
