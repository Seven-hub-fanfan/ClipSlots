import SwiftUI
import ClipSlotsKit

/// 从槽位库拖到画布时携带的信息。
///
/// ★ v2.11.7 hotfix20：去掉了 `prompt`。画布节点就是槽位，正文永远当场从槽位读 —— 载荷里带一份
/// 文本副本只会在"拖的那一刻"和"松手那一刻"之间产生一个必然会过期的快照，而它唯一的下游
/// （`addNodeFromSlot`）已经不存在了。`name` 留下来只用于拖影与 toast 文案。
struct CanvasSlotDragPayload {
    let pageId: String
    let groupId: String
    let slot: Int
    /// 展示名（Label / 正文首行 / 附件兜底），只用于拖影与提示，不是数据。
    let name: String
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

    /// 侧栏宽度。展开 240 / 收起 44。
    ///
    /// ★ v2.11.7 hotfix18：从「浮动卡片 208/132」改成「贴边侧栏 240/44」。
    ///   - 240 是 Figma / Sketch 这类画布工具左栏的实际量级。旧的 208 在三级缩进
    ///     （页面 → 组 → 槽位）之后只剩 ~120pt 给文字，槽位 Label 一到 6 字就被省略号吃掉。
    ///   - 收起态从 132 收到 44：132 是「窄面板」，还留着标题文字，占着地方又读不到内容；
    ///     44 是**真正的图标轨**，只留库图标与展开箭头，视觉上明确表达「这里被折叠了」。
    ///
    /// ★ 必须钉在**外层 VStack** 上，不能只钉在各个子视图上。第一版把宽度分别写在 `header` 和
    /// `ScrollView` 上，结果面板铺满了整个画布宽度（实测 1290pt，把右上角的「生成」按钮吞进了自己的
    /// 白底里）。根因是中间那条 `Divider()`：它**没有固有宽度、会主动占满可用宽度**，于是 VStack 的
    /// 宽度取三个子视图的最大值 = 无穷大。Divider 在 HStack 里是根竖线（高度自适应），
    /// 在 VStack 里是根横线（宽度贪心）。
    private var panelWidth: CGFloat { Self.width(expanded: canvas.isLibraryExpanded) }

    /// 供画布布局读取（缩放控件 / 工具栏要避开侧栏，不能各自硬编码一份宽度）。
    static func width(expanded: Bool) -> CGFloat { expanded ? 240 : 44 }

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
            }
            // 撑满剩余高度：贴边侧栏要从顶栏下方一直落到窗口底边，内容少时下半截是空白底色，
            // 而不是让侧栏缩成半截、露出下面的画布网格（那样就又变回浮动卡片了）。
            Spacer(minLength: 0)
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // 贴边侧栏：不透明底 + 无圆角 + 无阴影。
        // 不透明是硬要求 —— 多彩皮肤的整窗氛围层里有一枚 820pt 的蓝紫大圆，半透明底会把它透进
        // 侧栏，看起来像侧栏自己染了一块蓝。
        .background(AppTheme.canvasChromeSurface)
        // 只在右侧留一条分隔线（左/上/下都贴着窗口边框，画描边只会变成双线）。
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.subtleBorder)
                .frame(width: 1)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            if canvas.isLibraryExpanded {
                Text("槽位库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.canvasChromeInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Button {
                withAnimation(Anim.reveal) { canvas.isLibraryExpanded.toggle() }
            } label: {
                Image(systemName: canvas.isLibraryExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canvas.isLibraryExpanded ? "收起槽位库" : "展开槽位库")
        }
        // 收起态只有 44pt 宽，两侧各 10pt 内边距会把 16pt 的箭头挤出去；收起时改用 4pt。
        .padding(.horizontal, canvas.isLibraryExpanded ? 10 : 4)
        .padding(.vertical, 8)
    }

    // MARK: - 页面 / 组 / 槽位

    @ViewBuilder
    private func pageSection(_ page: SlotPage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
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
                    .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                    .frame(width: 8)
                Image(systemName: group.icon)
                    .font(.system(size: 9))
                    .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                Text(group.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppTheme.canvasChromeInk)
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
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
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
        /// 附件数量。只做角标展示，不参与拖拽载荷 —— 节点建好后附件由卡片按槽位实时读取，
        /// 在载荷里带一份计数只会多出一个会过期的副本。
        let attachmentCount: Int
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
            out.append(SlotEntry(slot: slot,
                                 label: label,
                                 prompt: text,
                                 attachmentCount: content.attachments.count))
        }
        return out
    }

    /// 行标题。有 Label 用 Label；没有 Label 且**只有入参文件没有文本**时，用文件数兜底 ——
    /// 否则这一行会显示成一片空白，用户完全不知道它是什么（hotfix19）。
    private func displayTitle(_ entry: SlotEntry) -> String {
        if let label = entry.label, !label.isEmpty { return label }
        if !entry.prompt.isEmpty { return entry.prompt }
        return entry.attachmentCount > 0 ? "（\(entry.attachmentCount) 个入参文件）" : "（空）"
    }

    private func slotRow(page: SlotPage, group: SpecialSlot, entry: SlotEntry) -> some View {
        let payload = CanvasSlotDragPayload(pageId: page.id,
                                           groupId: group.id,
                                           slot: entry.slot,
                                           name: displayTitle(entry))
        let key = "\(group.id)#\(entry.slot)"
        return HStack(spacing: 5) {
            Text("\(entry.slot)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.canvasChromeInk)
                .frame(width: 14, height: 14)
                .background(Circle().fill(AppTheme.chipBackground))
            Text(displayTitle(entry))
                .font(.system(size: 9))
                // ★ hotfix19：原 `.primary.opacity(0.72)`。深色下 `.primary` 本身就不是纯白，
                // 再乘 0.72 后压在 0.14 的侧栏底上，正文对比度掉到 AA 线以下。
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            // 附件角标：让用户在拖之前就知道这个槽位带图 / 带文件（hotfix19）。
            if entry.attachmentCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 6, weight: .bold))
                    Text("\(entry.attachmentCount)")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                }
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 7))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk.opacity(0.7))
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
