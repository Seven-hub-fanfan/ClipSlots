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

/// 「正在把画布节点往槽位库里拖」的状态（v2.11.8 二轮）。
///
/// 由 `CanvasWorkspaceView` 的节点拖拽手势产出并下传：手势的整个生命周期归它，侧栏只是被动
/// 渲染分栏块与高亮。命中判定两边共用 `CanvasArchiveDropGeometry`，不各写一份（见那个类型的注释）。
struct CanvasNodeArchiveDrag {
    /// 被拖节点的展示名，画在分栏标题上（"把〈xxx〉归入…"）。
    let title: String
    /// 光标在画布根坐标空间的位置。侧栏贴左上角，所以它同时就是侧栏本地坐标。
    let point: CGPoint
    /// 目标组（当前所在的槽位组）的槽位数。
    let slotCount: Int
    /// 目标组名，画在分栏标题上。
    let groupName: String
}

/// 左侧浮动槽位库面板（v2.11.7 建立，v2.11.8 二轮加入「未入库 / 归槽 / 排序」）。
///
/// ## v2.11.8 二轮：从「只读列表」变成「双向的槽位工作台」
///
/// 一轮它只做**只读**消费：列出页面 → 槽位组 → 槽位，供拖拽到画布建节点，绝不写回槽位数据。
/// 二轮按用户要求补上三件写操作：
///   1. **未入库层级**：顶部一个特殊分组，装那些"还没归到任何槽位"的画布节点（见
///      `SlotStoreObservable.canvasUnfiledGroupId` 的注释）。橙点标识 —— 它是个待整理的暂存区，
///      不是一个正常的组。
///   2. **从画布拖节点进来归槽**：侧栏在拖入时整体变成 10 个槽位分栏块，悬停放大、松手归入。
///   3. **组内拖拽排序**：把一行拖到同组另一行上 = 交换两个槽位的内容（为什么是交换而不是
///      插入顺移，见 `SlotStoreObservable.canvasSwapSlotContent`）。
///
/// 三件事的**数据操作一律上抛**（`onArchive` / `onReorder`）：写槽位要走 `SlotStoreObservable`
/// 的一整套落盘/撤销/缩略图失效流程，面板只负责表达意图。
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
    /// 正在从画布往侧栏拖的节点（nil = 没有）。见 `CanvasNodeArchiveDrag`。
    let archiveDrag: CanvasNodeArchiveDrag?
    /// 组内排序：把 `from` 槽位与 `to` 槽位的内容交换。
    let onReorder: (String, Int, Int) -> Void

    @State private var expandedGroupIds: Set<String> = []
    /// 正在拖的槽位标识（仅用于行高亮）。
    @State private var draggingKey: String? = nil
    /// 组内排序时，光标当前悬停的那一行（`groupId#slot`）。
    @State private var reorderTargetKey: String? = nil
    /// 各槽位行在画布根坐标空间里的矩形，用于排序时判定"拖到哪一行上了"。
    ///
    /// 走 `PreferenceKey` 收集而不是给每行加 `.onHover`：`onHover` 在**按住鼠标拖拽期间**不投递
    /// （AppKit 的 mouseEntered/Exited 在拖拽会话里被抑制），而排序的全部动作都发生在按住的时候。
    @State private var rowFrames: [String: CGRect] = [:]

    private var pages: [SlotPage] {
        store.pages.sorted { $0.order < $1.order }
    }

    /// 某页面下**用户可见**的槽位组。
    ///
    /// ★ v2.11.15 修：必须滤掉「未入库」保留组。它在数据层是个正常槽位组（原因见
    /// `SpecialSlotStorage.unfiledGroupId`），并且为了字段不为空被挂在了"第一个页面"下 ——
    /// 于是它同时出现在两个地方：底部的专属分区 **和** 默认页面的组列表里。后者是纯粹的漏网：
    /// 用户看到的是"一个本该只存放游离节点的保留组，混在自己建的组中间"，而且点进去还能像普通
    /// 组一样操作。`ensureUnfiledGroup` 的注释里写着"它从所有页面分区里都被过滤掉"，这里补上
    /// 那个从来没写过的过滤。
    private func groups(for page: SlotPage) -> [SpecialSlot] {
        store.specialSlots
            // v2.13.0：过滤条件从"不是未入库"放宽成"不是保留组"。每个画布项目各有一个私有
            // 保留组，漏掉它们会让别的项目的暂存区以普通组的形态出现在页面树里。
            .filter { $0.pageId == page.id && !SpecialSlotStorage.isReservedGroupId($0.id) }
            .sorted { $0.order < $1.order }
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
            // v2.16.1: 画布改走 `fullSizeContentView` 之后，窗口顶部 28pt 是标题栏拖拽区、
            // 红绿灯就画在这块（见 `TapSkin.titlebarInset`）。侧栏的**底色照旧铺到顶边**
            // （padding 加在 header 上而不是整块面板上，不然顶边会露出后面的画布网格），
            // 只把内容压到红绿灯下面 —— 否则"槽位库"标题和折叠按钮正好被三颗灯盖住。
            header
                .padding(.top, TapSkin.titlebarInset)
            if canvas.isLibraryExpanded {
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // 未入库排在最前：它是"待整理"的收件箱，压在页面列表下面就等于没有。
                        // ★ v2.11.15：页面在上、「未入库」在最下面（用户要求）。
                        // 它是个待整理的暂存区而不是入口，放顶部会天天挡在真正要点的页面前面。
                        ForEach(pages) { page in
                            pageSection(page)
                        }
                        unfiledSection
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
        // 归槽分栏浮层：盖住整条侧栏。见 archiveOverlay 的注释。
        .overlay {
            if let drag = archiveDrag {
                archiveOverlay(drag)
            }
        }
        .onPreferenceChange(SlotRowFramesKey.self) { rowFrames = $0 }
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

    // MARK: - 未入库

    /// 「未入库」分组（v2.11.8 二轮）。
    ///
    /// 用**橙点**而不是一个图标：它需要传达的不是"这是什么"，而是"这里有东西待处理"。
    ///
    /// 这一节**常驻显示**（哪怕 0 条）。曾经写成"空了就整节隐藏"，理由是别训练用户忽略一个
    /// 空收件箱；但它同时也把"未入库这个层级存在"这件事藏了 —— 新装用户打开槽位库看不到它，
    /// 就不会知道散节点会落到哪儿去。所以改成：常驻，空时点变灰、计数为 0、展开给一句说明。
    @ViewBuilder
    private var unfiledSection: some View {
        let entries = unfiledEntries
        let gid = canvas.privateGroupId
        let isOpen = expandedGroupIds.contains(gid)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Anim.reveal) {
                    if isOpen { expandedGroupIds.remove(gid) } else { expandedGroupIds.insert(gid) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                        .frame(width: 8)
                    Circle()
                        .fill(entries.isEmpty ? AppTheme.canvasChromeTertiaryInk.opacity(0.5) : Color.orange)
                        .frame(width: 6, height: 6)
                    // v2.14.0：所有项目一律叫「未入库」（用户原话：「我希望每个项目都是未入库的
                    // 形式，不要暂存区」）。v2.13.0 给非默认项目起名「暂存区」是自作聪明 ——
                    // 同一个东西在不同项目里换名字，只会让用户以为那是两种不同的容器。
                    // 项目身份由顶部的项目切换器表达，这一行不必也不该重复它。
                    Text(SpecialSlotStorage.unfiledGroupName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(entries.isEmpty
                                         ? AppTheme.canvasChromeSecondaryInk
                                         : AppTheme.canvasChromeInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(entries.count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("本项目里还没归到正式槽位的节点，只存在于画布，不占用任何槽位页面或槽位组。把节点拖到下面的槽位库即可正式归档；在画布上删除节点，这里的内容会立刻一起消失（Cmd+Z 可连内容一起撤回）。")

            if isOpen {
                if entries.isEmpty {
                    Text("新建的独立节点会先落在这里，拖进下面的槽位即可归档")
                        .font(.system(size: 8))
                        .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 21)
                        .padding(.bottom, 3)
                } else {
                    ForEach(entries, id: \.slot) { entry in
                        slotRow(pageId: store.currentPageId,
                                groupId: gid,
                                entry: entry,
                                reorderable: false)
                    }
                }
            }
        }
    }

    /// 未入库组的条目。容量是 60（`unfiledCapacity`）而不是 10 —— 它是暂存区，不受圆盘/快捷键
    /// 那 10 格的物理约束。
    /// 「未入库」分区的条目。
    ///
    /// ★ v2.11.15 修「新建节点不出现在这个分类里」：`slotEntries(groupId:capacity:)` 会跳过
    /// **没有内容**的槽位（`text.isEmpty && attachments.isEmpty` 就 continue）—— 那条规则对
    /// 普通组是对的（空槽位不该在树里占一行），但对未入库恰好相反：画布上"新建节点"落的就是
    /// 一个空槽位，于是节点明明在画布上躺着，未入库里却什么都没有，用户自然认为这个分类坏了。
    ///
    /// 这里补上第二个来源：**画布上归属未入库的节点**。两个来源按槽位号合并去重，
    /// 空节点的行标题由 `displayTitle` 兜底成「（空）」。
    private var unfiledEntries: [SlotEntry] {
        let gid = canvas.privateGroupId
        var out = slotEntries(groupId: gid, capacity: SpecialSlotStorage.unfiledCapacity)
        var known = Set(out.map(\.slot))
        let storage = slotStorage(for: gid)
        for node in canvas.nodes where node.groupId == gid && !known.contains(node.slot) {
            known.insert(node.slot)
            out.append(SlotEntry(slot: node.slot,
                                 label: storage.getLabel(node.slot),
                                 prompt: "",
                                 attachmentCount: 0))
        }
        return out.sorted { $0.slot < $1.slot }
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
        let entries = slotEntries(groupId: group.id, capacity: max(1, store.config.slots))
        if entries.isEmpty {
            Text("无可用内容")
                .font(.system(size: 9))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                .padding(.leading, 24)
                .padding(.vertical, 3)
        } else {
            ForEach(entries, id: \.slot) { entry in
                slotRow(pageId: page.id, groupId: group.id, entry: entry, reorderable: true)
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

    /// 某个组的槽位存储句柄（v2.14.0 起要先选库）。
    ///
    /// 画布私有组（`__unfiled__` / `__canvas__*`）的内容住在 `canvas/private_slots/`，普通组住在
    /// `special_slots/`。走 `store.canvasStorage(groupId:)` 这一个路由，而不是在这里各自判断 ——
    /// 侧栏和画布读到的必须是同一份数据，两处各写一遍判断迟早会分叉。
    private func slotStorage(for groupId: String) -> SlotStorage {
        store.canvasStorage(groupId: groupId).slotStorage(for: groupId)
    }

    /// 读取某组的槽位内容。
    ///
    /// ★ 关键：必须用 `slotStorage(for: groupId)` 拿**该组自己的**存储句柄。
    /// 一开始这里写的是 `store.storage`，那是「当前所在组」的句柄 —— 于是展开任意一个组，列出来的
    /// 全是当前组的内容（同一份数据被贴上了 10 个不同组的标签），拖出去的节点 prompt 全错。这个错法
    /// 在 UI 上极难察觉，因为默认组恰好就是当前组，只有切到第二个组才暴露。
    ///
    /// 用 `searchScanSnapshot` 而不是 `snapshot()`：后者只是进程内缓存，只含本次会话被 `get(_:)`
    /// 读过的槽位，也就是用户真正打开过的组 —— 冷启动进画布会看到大片「无可用内容」。这是
    /// v2.11.7 hotfix11 全局搜索踩过的同一个坑，直接复用它的结论。
    ///
    /// 另外刻意**不切组去读** `store.slots`：切组是用户可见的副作用（会改变主界面所在位置）。
    private func slotEntries(groupId: String, capacity: Int) -> [SlotEntry] {
        let slotCount = max(1, capacity)
        let storage = slotStorage(for: groupId)
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

    /// 槽位行。
    ///
    /// - Parameter reorderable: 是否允许"拖到同组另一行上换位"。未入库组关掉：那里的槽位号只是
    ///   停车位编号，没有快捷键语义，"排序"对它没有任何意义（用户要的是把它拖去归档，不是排它）。
    private func slotRow(pageId: String,
                         groupId: String,
                         entry: SlotEntry,
                         reorderable: Bool) -> some View {
        let payload = CanvasSlotDragPayload(pageId: pageId,
                                           groupId: groupId,
                                           slot: entry.slot,
                                           name: displayTitle(entry))
        let key = Self.rowKey(groupId: groupId, slot: entry.slot)
        let isReorderTarget = (reorderTargetKey == key)
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
                .fill(rowFill(key: key, isReorderTarget: isReorderTarget))
        )
        // 交换目标再加一道描边：仅靠底色变化在拖拽中不够显眼（用户此刻在看拖影，不在看行）。
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(AppTheme.chromeAccentInk, lineWidth: isReorderTarget ? 1.2 : 0)
        )
        // 把本行的矩形上报到面板，供排序命中判定使用（见 rowFrames）。
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SlotRowFramesKey.self,
                                       value: [key: geo.frame(in: .named(CanvasWorkspaceView.spaceName))])
            }
        )
        .gesture(
            // 坐标空间用画布根视图的命名空间，这样 value.location 直接就是可换算成画布坐标的量；
            // 用 `.global` 还得再减一次窗口偏移，多一步就多一处能算错的地方。
            DragGesture(minimumDistance: 4, coordinateSpace: .named(CanvasWorkspaceView.spaceName))
                .onChanged { value in
                    draggingKey = key
                    // 光标还在侧栏里 = 用户在**排序**，不是往画布拖。此时不上报拖影（那是"要建
                    // 节点了"的信号，会误导），改为高亮同组的目标行。
                    if reorderable, value.location.x <= panelWidth,
                       let target = reorderTarget(at: value.location, groupId: groupId, exclude: key) {
                        reorderTargetKey = target
                        onDragChanged(nil, value.location)
                    } else {
                        reorderTargetKey = nil
                        onDragChanged(payload, value.location)
                    }
                }
                .onEnded { value in
                    let target = reorderTargetKey
                    draggingKey = nil
                    reorderTargetKey = nil
                    onDragChanged(nil, value.location)
                    if let target, let slot = Self.slot(fromRowKey: target) {
                        onReorder(groupId, entry.slot, slot)
                        return
                    }
                    // 松手仍在侧栏内但没落到任何一行上：什么都不做。此时把它当"拖到画布"处理会
                    // 在侧栏底下悄悄建一个看不见的节点（被侧栏盖住），用户只会觉得节点凭空消失了。
                    guard value.location.x > panelWidth else { return }
                    onDropSlot(payload, value.location)
                }
        )
        .help(reorderable
              ? (entry.prompt.isEmpty ? "拖到画布创建节点，或拖到同组另一行交换位置" : entry.prompt)
              : (entry.prompt.isEmpty ? "拖到画布创建节点" : entry.prompt))
    }

    private func rowFill(key: String, isReorderTarget: Bool) -> Color {
        if isReorderTarget { return AppTheme.chromeAccentSoftFill }
        if draggingKey == key { return AppTheme.chromeAccentSoftFill.opacity(0.6) }
        return .clear
    }

    /// 找光标下的同组行（排序目标）。
    ///
    /// 只在**同组**内找：跨组交换会静默改变另一个组的内容，而用户拖的时候看的是自己那一行。
    /// 跨组搬迁有专门的入口（把节点拖到归槽分栏），不该由一次列表内拖拽顺手完成。
    private func reorderTarget(at point: CGPoint, groupId: String, exclude: String) -> String? {
        let prefix = "\(groupId)#"
        for (key, rect) in rowFrames where key != exclude && key.hasPrefix(prefix) {
            if rect.contains(point) { return key }
        }
        return nil
    }

    static func rowKey(groupId: String, slot: Int) -> String { "\(groupId)#\(slot)" }

    static func slot(fromRowKey key: String) -> Int? {
        guard let idx = key.lastIndex(of: "#") else { return nil }
        return Int(key[key.index(after: idx)...])
    }

    // MARK: - 归槽分栏浮层

    /// 从画布拖节点进侧栏时，整条侧栏变成 10 个槽位分栏块。
    ///
    /// ## 为什么是"盖住整条侧栏"，而不是在列表里就地画落点
    ///
    /// 因为归槽的目标是**槽位号**（1~10 的物理格子），而列表里只显示**非空**槽位 —— 空槽位根本不在
    /// 列表上，而它们恰恰是归槽最常见的目标。就地落点意味着用户只能归到已经有东西的槽位上，
    /// 与这个功能的意图正好相反。
    ///
    /// 分栏块的矩形取自 `CanvasArchiveDropGeometry`，与 `CanvasWorkspaceView` 判定松手落点用的
    /// 是同一份公式（见那个类型的注释：画块的人和判命中的人不是同一个视图）。这里用绝对定位
    /// （`.position`）而不是 VStack，就是为了让渲染与那份公式**逐像素一致** —— VStack 的实际分配
    /// 受字体行高、内边距舍入影响，和一份独立的数学公式对不齐。
    private func archiveOverlay(_ drag: CanvasNodeArchiveDrag) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let blocks = CanvasArchiveDropGeometry.blocks(panelSize: size, count: drag.slotCount)
            let hovered = CanvasArchiveDropGeometry.blockIndex(at: drag.point,
                                                              panelSize: size,
                                                              count: drag.slotCount)
            ZStack(alignment: .topLeading) {
                AppTheme.canvasChromeSurface.opacity(0.97)

                VStack(alignment: .leading, spacing: 2) {
                    Text("归入槽位")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.canvasChromeInk)
                    Text("\(drag.groupName) · \(drag.title)")
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, CanvasArchiveDropGeometry.sidePadding)
                .padding(.top, 8)

                ForEach(blocks, id: \.slot) { block in
                    archiveBlock(block, hovered: hovered == block.slot)
                        .frame(width: block.rect.width, height: block.rect.height)
                        .position(x: block.rect.midX, y: block.rect.midY)
                }
            }
        }
        .transition(.opacity)
    }

    private func archiveBlock(_ block: CanvasArchiveDropGeometry.Block, hovered: Bool) -> some View {
        let occupied = !store.canvasSlotIsFree(groupId: store.currentSpecialSlotId, slot: block.slot)
        let name = store.canvasSlotLabel(groupId: store.currentSpecialSlotId, slot: block.slot)
        return HStack(spacing: 6) {
            Text("\(block.slot)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(hovered ? .white : AppTheme.canvasChromeInk)
                .frame(width: 18, height: 18)
                .background(Circle().fill(hovered ? AppTheme.chromeAccentInk : AppTheme.chipBackground))
            Text(name?.isEmpty == false ? name! : (occupied ? "已有内容" : "空槽位"))
                .font(.system(size: 9, weight: hovered ? .semibold : .regular))
                .foregroundColor(occupied ? AppTheme.canvasChromeTertiaryInk : AppTheme.canvasChromeSecondaryInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            // 已占用的槽位画一个禁入标记：归槽不覆盖已有内容（覆盖会静默毁掉用户资产），
            // 与其让用户松手后才收到一句"槽位已被占用"，不如在他移过去的路上就说清楚。
            if occupied {
                Image(systemName: "nosign")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(AppTheme.canvasChromeTertiaryInk.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovered && !occupied
                      ? AppTheme.chromeAccentSoftFill
                      : AppTheme.chipBackground.opacity(occupied ? 0.4 : 0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(hovered ? (occupied ? Color.orange : AppTheme.chromeAccentInk) : AppTheme.subtleBorder,
                        lineWidth: hovered ? 1.6 : 0.8)
        )
        // 悬停放大（用户明确要求"hover 某槽位高亮块时该块放大高亮"）。1.04 而不是更大：
        // 块之间只有 5pt 间距，放大过头会互相压住，反而看不清当前落点是哪个。
        .scaleEffect(hovered ? 1.04 : 1, anchor: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: hovered)
    }
}

/// 收集槽位行矩形的 PreferenceKey（排序命中判定用）。见 `CanvasSlotLibraryPanel.rowFrames`。
private struct SlotRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
