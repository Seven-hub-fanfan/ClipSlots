import SwiftUI
import ClipSlotsKit

/// 从槽位库拖到画布时携带的信息。
struct CanvasSlotDragPayload {
    let pageId: String
    let groupId: String
    let slot: Int
    let label: String?
    let prompt: String
}

/// 左侧浮动槽位库面板（v2.11.7）。
///
/// 只做**只读**消费：列出页面 → 槽位组 → 槽位，供拖拽到画布建节点。绝不写回槽位数据。
///
/// 拖拽刻意用 `DragGesture` 而非 `.onDrag` / `NSItemProvider`：面板与画布在同一个 SwiftUI 视图树里，
/// 走系统拖拽要序列化再反序列化一遍，还拿不到实时落点；用 `DragGesture` + 命名坐标空间可以直接
/// 算出画布落点，且能画出跟手的拖影。项目里现有的 12 处拖拽全是 `.onDrop`（接收外部文件），
/// 内部拖拽没有先例，这里不必勉强对齐。
///
/// **拖影不画在本面板里**：面板自身有 `clipShape` 语义的圆角背景与有限尺寸，画在这里的拖影一出
/// 面板边界就被裁掉。所以本视图只上报「拖到哪了」（`onDragChanged`），拖影由画布根视图渲染。
struct CanvasSlotLibraryPanel: View {
    @ObservedObject var store: SlotStoreObservable
    @ObservedObject var canvas: CanvasStore
    /// 拖拽进行中的回调。`nil` payload 表示拖拽结束/取消。坐标在 `CanvasWorkspaceView.spaceName` 空间。
    let onDragChanged: (CanvasSlotDragPayload?, CGPoint) -> Void
    /// 松手落到画布。坐标同上。
    let onDropSlot: (CanvasSlotDragPayload, CGPoint) -> Void

    @State private var expandedGroupIds: Set<String> = []
    /// 正在拖的槽位标识（仅用于行高亮）。
    @State private var draggingKey: String? = nil

    private var pages: [SlotPage] {
        store.pages.sorted { $0.order < $1.order }
    }

    private func groups(for page: SlotPage) -> [SpecialSlot] {
        store.specialSlots.filter { $0.pageId == page.id }.sorted { $0.order < $1.order }
    }

    /// 面板宽度。展开 208 / 收起 132。
    ///
    /// ★ 必须钉在**外层 VStack** 上，不能只钉在各个子视图上。第一版把 208 分别写在 `header` 和
    /// `ScrollView` 上，结果面板铺满了整个画布宽度（实测 1290pt，把右上角的「生成」按钮吞进了自己的
    /// 白底里，中间的空画布引导文字也被白底压没）。根因是中间那条 `Divider()`：它**没有固有宽度、
    /// 会主动占满可用宽度**，于是 VStack 的宽度取三个子视图的最大值 = 无穷大。
    /// 这是 SwiftUI 里很容易踩的一脚——Divider 在 HStack 里是根竖线（高度自适应），
    /// 在 VStack 里是根横线（宽度贪心）。
    private var panelWidth: CGFloat {
        canvas.isLibraryExpanded ? 208 : 132
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if canvas.isLibraryExpanded {
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pages) { page in
                            pageSection(page)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
                // 高度上限：内容多时内部滚动，而不是把面板顶到画布底部去挤掉工具栏。
                .frame(maxHeight: 420)
            }
        }
        .frame(width: panelWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 10, x: 0, y: 4)
        // 固定宽度后仍要显式 fixedSize：外层 ZStack 会把可用宽度整个让给它，
        // 少了这一句在某些父级布局下 frame 仍可能被放大。
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text("槽位库")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
            Spacer(minLength: 0)
            Button {
                withAnimation(Anim.reveal) { canvas.isLibraryExpanded.toggle() }
            } label: {
                Image(systemName: canvas.isLibraryExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canvas.isLibraryExpanded ? "收起槽位库" : "展开槽位库")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 页面 / 组 / 槽位

    @ViewBuilder
    private func pageSection(_ page: SlotPage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.65))
                .padding(.horizontal, 4)
                .padding(.top, 4)

            ForEach(groups(for: page)) { group in
                groupRow(page: page, group: group)
                if expandedGroupIds.contains(group.id) {
                    slotList(page: page, group: group)
                }
            }
        }
    }

    private func groupRow(page: SlotPage, group: SpecialSlot) -> some View {
        Button {
            withAnimation(Anim.reveal) {
                if expandedGroupIds.contains(group.id) {
                    expandedGroupIds.remove(group.id)
                } else {
                    expandedGroupIds.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expandedGroupIds.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 8)
                Image(systemName: group.icon)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.8))
                Text(group.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 槽位行。只列**非空**槽位 —— 空槽没有 prompt，拖到画布也是个空节点，先不干扰列表。
    @ViewBuilder
    private func slotList(page: SlotPage, group: SpecialSlot) -> some View {
        let entries = slotEntries(group: group)
        if entries.isEmpty {
            Text("无可用内容")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.45))
                .padding(.leading, 24)
                .padding(.vertical, 3)
        } else {
            ForEach(entries, id: \.slot) { entry in
                slotRow(page: page, group: group, entry: entry)
            }
        }
    }

    private struct SlotEntry {
        let slot: Int
        let label: String?
        let prompt: String
    }

    /// 读取某组的槽位内容。
    ///
    /// ★ 关键：必须用 `specialStorage.slotStorage(for: group.id)` 拿**该组自己的**存储句柄。
    /// 一开始这里写的是 `store.storage`，那是「当前所在组」的句柄 —— 于是展开任意一个组，列出来的
    /// 全是当前组的内容（同一份数据被贴上了 10 个不同组的标签），拖出去的节点 prompt 全错。这个错法
    /// 在 UI 上极难察觉，因为默认组恰好就是当前组，只有切到第二个组才暴露。
    ///
    /// 用 `searchScanSnapshot` 而不是 `snapshot()`：后者只是进程内缓存，只含本次会话被 `get(_:)`
    /// 读过的槽位，也就是用户真正打开过的组 —— 冷启动进画布会看到大片「无可用内容」。这是
    /// v2.11.7 hotfix11 全局搜索踩过的同一个坑，直接复用它的结论。
    ///
    /// 另外刻意**不切组去读** `store.slots`：切组是用户可见的副作用（会改变主界面所在位置）。
    private func slotEntries(group: SpecialSlot) -> [SlotEntry] {
        let slotCount = max(1, store.config.slots)
        let storage = store.specialStorage.slotStorage(for: group.id)
        let snapshot = storage.searchScanSnapshot(slotCount: slotCount)
        var out: [SlotEntry] = []
        for slot in 1...slotCount {
            guard let content = snapshot[slot] else { continue }
            let text = content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasAttachment = !content.attachments.isEmpty
            guard !text.isEmpty || hasAttachment else { continue }
            // label 优先取 SlotContent 自带的；扫描快照里没有时回落到存储层的独立 label 文件。
            let label = content.label ?? storage.getLabel(slot)
            out.append(SlotEntry(slot: slot, label: label, prompt: text))
        }
        return out
    }

    private func slotRow(page: SlotPage, group: SpecialSlot, entry: SlotEntry) -> some View {
        let payload = CanvasSlotDragPayload(pageId: page.id,
                                           groupId: group.id,
                                           slot: entry.slot,
                                           label: entry.label,
                                           prompt: entry.prompt)
        let key = "\(group.id)#\(entry.slot)"
        return HStack(spacing: 5) {
            Text("\(entry.slot)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
                .background(Circle().fill(AppTheme.chipBackground))
            Text(entry.label ?? entry.prompt)
                .font(.system(size: 9))
                .foregroundColor(.primary.opacity(0.72))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 7))
                .foregroundColor(.secondary.opacity(0.35))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .padding(.leading, 18)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(draggingKey == key ? AppTheme.chromeAccentSoftFill : Color.clear)
        )
        .gesture(
            // 坐标空间用画布根视图的命名空间，这样 value.location 直接就是可换算成画布坐标的量；
            // 用 `.global` 还得再减一次窗口偏移，多一步就多一处能算错的地方。
            DragGesture(minimumDistance: 4, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
                .onChanged { value in
                    draggingKey = key
                    onDragChanged(payload, value.location)
                }
                .onEnded { value in
                    draggingKey = nil
                    onDragChanged(nil, value.location)
                    onDropSlot(payload, value.location)
                }
        )
        .help(entry.prompt.isEmpty ? "拖到画布创建节点" : entry.prompt)
    }
}
