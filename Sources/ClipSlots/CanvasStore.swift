import SwiftUI
import Combine
import ClipSlotsKit

/// 无限画布的状态容器（v2.11.7）。
///
/// **刻意不复用 `SlotStoreObservable`。**后者有 60 个 `@Published`，任一槽位变化都会触发整棵
/// `ContentView.body` 重新求值（项目已知技术债）。画布的拖拽是每帧更新坐标的高频操作，一旦挂到
/// 主 store 上，拖一个节点就会连带重绘整个标题栏与槽位网格。这里走 `TransientUIStore` 开的那条
/// 路：**独立 ObservableObject + 窄粒度发布**，由画布子树单独观察。
///
/// 粒度约定：
///   - `nodes` / `selection` 是 `@Published`，画布子树观察它们。
///   - **拖拽中的临时位移不进 `nodes`**，而是留在 View 的 `@State`（`dragOffset`），松手才写回。
///     否则拖动一个节点会让整个节点数组每帧 CoW + 全部节点视图 diff。
///   - 视口（pan/zoom）同样留在 View 的 `@State`，只在停止操作后防抖落盘；缩放平移不该引起
///     任何节点视图重新求值。
@MainActor
final class CanvasStore: ObservableObject {

    // MARK: - 发布状态

    @Published private(set) var nodes: [CanvasNode] = []
    @Published var selectedNodeIds: Set<String> = []
    @Published var activeTool: CanvasTool = .select
    /// 左侧槽位库面板是否展开。
    @Published var isLibraryExpanded: Bool = true
    /// 撤销栈 + 操作流水。**只活在本次会话内，刻意不落盘**：它是「我刚才干了什么」的记忆辅助，
    /// 不是文档内容；持久化它就得回答「跨天该不该 Cmd+Z」「导出 pack 要不要带」这些没有好答案的问题。
    @Published private(set) var history = CanvasUndoStack()
    /// 槽位内容版本号。
    ///
    /// 绑定槽位的节点卡片显示的是**槽位实时文本**，而槽位数据住在主 store 里。画布子树不订阅主 store
    /// （那会把这个轻量 store 拖回全局重绘），所以需要一个显式的「脏」信号：主 store 那边槽位一变，
    /// 或撤销/重做把槽位文本改回去了，就 `+= 1`，绑定节点据此重读。
    @Published private(set) var slotRevision: Int = 0

    // MARK: - 视口（非 @Published，见类型注释）

    /// 视口只在进出画布与防抖落盘时读写，不参与视图订阅。
    private(set) var pan: CGSize = .zero
    private(set) var zoom: CGFloat = 1

    // MARK: - 依赖

    private let storage: CanvasStorage
    private var saveTask: Task<Void, Never>?
    /// 防抖窗口。拖拽松手 / 缩放停止后 0.4s 落盘，避免高频写。
    private let saveDebounce: Duration = .milliseconds(400)

    init(storage: CanvasStorage = .shared) {
        self.storage = storage
        let doc = storage.load()
        self.nodes = doc.nodes
        self.pan = doc.pan
        self.zoom = CanvasGeometry.clampZoom(doc.zoom)
    }

    // MARK: - 视口更新

    func updateViewport(pan: CGSize, zoom: CGFloat) {
        self.pan = pan
        self.zoom = CanvasGeometry.clampZoom(zoom)
        scheduleSave()
    }

    // MARK: - 节点增删改
    //
    // ★ 所有写操作都必须走 `commit(...)`：它负责「记一步撤销 + 落盘」这两件必须成对发生的事。
    // 直接改 `nodes` 而绕过 commit 的写法，症状是「这一步 Cmd+Z 撤不掉」，而且不会有任何报错。

    /// 把一个槽位**摆到画布上**（v2.11.7 hotfix20）。
    ///
    /// 这是画布上出现节点的**唯一**入口 —— 槽位库拖拽、Cmd+1~0、圆盘命令全部汇到这里。
    /// 名字从 hotfix19 的 `addNodeFromSlot` 改成 `placeSlot` 不是措辞洁癖：旧方法真的会把槽位
    /// 正文拷进 `node.prompt`，所以"创建节点"确实创建了一份内容；现在它只决定「这个槽位画在哪」，
    /// 内容一直是槽位自己的，一个字都不复制。
    ///
    /// 同一槽位已经在画布上时**不再放第二个**（新 id 是 `groupId#slot`，放第二个会撞 id，
    /// 表现为 SwiftUI `ForEach` 里"点 A 动 B"）。这时改为选中已有的那个，并把
    /// `.alreadyPlaced` 返回给调用方，由它决定提示与视口跟随 —— store 不认识 UI 通道。
    @discardableResult
    func placeSlot(pageId: String,
                   groupId: String,
                   slot: Int,
                   name: String,
                   at canvasPoint: CGPoint,
                   kind: CanvasNodeKind = .image,
                   parentNodeId: String? = nil,
                   avoidOverlap: Bool = false) -> CanvasSlotPlacement {
        let id = CanvasNode.makeId(groupId: groupId, slot: slot)
        if let existing = nodes.first(where: { $0.id == id }) {
            selectedNodeIds = [existing.id]
            return .alreadyPlaced(node: existing, name: name)
        }
        let size = CanvasNode.defaultSize
        // 落点即节点中心，符合「拖到哪儿就放哪儿」的直觉。
        var origin = CanvasSpawnGeometry.origin(forCenter: canvasPoint, size: size)
        if avoidOverlap {
            // v2.11.8: 「ADD NODE」菜单与 Cmd+V 走这条路 —— 它们的落点是算出来的（视口中心 /
            // 上游节点下方），连续两次很容易落在同一格。拖拽落点不让位：那是用户亲手指的位置，
            // 系统擅自挪开反而是 bug。
            origin = CanvasSpawnGeometry.nonOverlappingOrigin(desired: origin,
                                                             existing: nodes.map { CGPoint(x: $0.x, y: $0.y) })
        }
        let snapped = CanvasGeometry.snap(origin, step: CanvasStore.snapStep)
        let node = CanvasNode(pageId: pageId,
                              groupId: groupId,
                              slot: slot,
                              kind: kind,
                              x: snapped.x,
                              y: snapped.y,
                              parentNodeId: parentNodeId)
        commit(.addNode, detail: name) {
            nodes.append(node)
            selectedNodeIds = [node.id]
        }
        return .placed(node: node, name: name)
    }

    /// 某个节点在画布上的即时快照（按 id）。
    func node(id: String) -> CanvasNode? {
        nodes.first { $0.id == id }
    }

    /// 当前页面里已经被画布占用的槽位号（按槽位组）。
    ///
    /// 「ADD NODE」要找空槽位，而"空"必须同时满足两件事：槽位里没内容、且没有别的节点已经绑了它。
    /// 后者容易被忽略 —— 漏掉它的表现是新建节点时撞 id，SwiftUI `ForEach` 下会变成"点 A 动 B"。
    func occupiedSlots(inGroup groupId: String) -> Set<Int> {
        Set(nodes.filter { $0.groupId == groupId }.map { $0.slot })
    }

    /// 某个槽位当前的摆位（没摆则 nil）。
    func node(forGroupId groupId: String, slot: Int) -> CanvasNode? {
        let id = CanvasNode.makeId(groupId: groupId, slot: slot)
        return nodes.first { $0.id == id }
    }

    func moveNode(id: String, to origin: CGPoint) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        let snapped = CanvasGeometry.snap(origin, step: CanvasStore.snapStep)
        // 吸附后位置没变就不记流水：拖起来又放回原格（或只是点一下带了 2pt 抖动）不是一次「操作」，
        // 记了只会把历史面板刷成一屏重复的「移动节点」，也会白占撤销栈。
        guard snapped != nodes[idx].frame.origin else { return }
        let title = nodeTitle(nodes[idx])
        commit(.moveNode, detail: title) {
            nodes[idx].setFrameOrigin(snapped)
        }
    }

    /// 批量位移（多选拖动）。
    ///
    /// ★ v2.11.7 hotfix18 修 bug：框选两个节点后拖动其中一个，只有被按住的那个会走。
    /// 根因是拖拽只提交了 `draggingNodeId` 一个节点的新坐标，`selectedNodeIds` 里的其他节点
    /// 从头到尾没被碰过。
    ///
    /// 这里刻意接受**位移量 delta** 而不是「新坐标」：批量移动要保持选中集合内部的相对位置不变，
    /// 逐个算新坐标就得在调用方留一份「拖拽开始时每个节点的原点」快照，而 delta 天然就是不变量。
    /// 吸附也因此只能按 delta 吸附（对每个节点各自 snap 会把原本错开的节点吸到同一条格线上，
    /// 相对位置被悄悄改掉）。
    func moveNodes(ids: Set<String>, by rawDelta: CGSize) {
        guard !ids.isEmpty else { return }
        let delta = CGSize(width: CanvasGeometry.snapScalar(rawDelta.width, step: CanvasStore.snapStep),
                           height: CanvasGeometry.snapScalar(rawDelta.height, step: CanvasStore.snapStep))
        guard delta.width != 0 || delta.height != 0 else { return }
        let moved = nodes.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return }
        let detail = moved.count == 1 ? nodeTitle(moved[0]) : "\(moved.count) 个节点"
        commit(.moveNode, detail: detail) {
            for idx in nodes.indices where ids.contains(nodes[idx].id) {
                let origin = nodes[idx].frame.origin
                nodes[idx].setFrameOrigin(CGPoint(x: origin.x + delta.width,
                                                  y: origin.y + delta.height))
            }
        }
    }

    func removeNodes(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let removed = nodes.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        // 一次删多个只记一条，写成「3 个节点」而不是刷 3 行 —— 框选批量删是常态操作。
        let detail = removed.count == 1 ? nodeTitle(removed[0]) : "\(removed.count) 个节点"
        commit(.removeNode, detail: detail) {
            nodes.removeAll { ids.contains($0.id) }
            selectedNodeIds.subtract(ids)
        }
    }

    /// 删除全部选中节点（Delete / Backspace）。返回删掉的数量，便于调用方决定要不要提示。
    @discardableResult
    func removeSelected() -> Int {
        let ids = selectedNodeIds
        let count = nodes.filter { ids.contains($0.id) }.count
        removeNodes(ids: ids)
        return count
    }

    func updateNode(id: String, _ mutate: (inout CanvasNode) -> Void) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&nodes[idx])
        nodes[idx].updatedAt = Date()
        scheduleSave()
    }

    // MARK: - 节点排版（v2.11.7 hotfix19）

    /// 改节点正文的字体 / 字号。
    ///
    /// 走 `commit` 而不是 `updateNode`：`updateNode` 只落盘、不记撤销栈，用它改字体的症状是
    /// 「改完 Cmd+Z 撤不掉」。字号统一过 `clampBodyFontSize`，越界值到不了磁盘。
    ///
    /// 传 `fontName: .some(nil)` 表示**清空**（回到跟随系统），传 `nil` 表示本次不动这个字段 ——
    /// 双层 Optional 是刻意的：单层的话「清空」与「不改」在类型上无法区分。
    func updateNodeStyle(id: String, fontName: String?? = nil, fontSize: CGFloat?? = nil) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }

        let newName = fontName.map { $0?.isEmpty == true ? nil : $0 } ?? nodes[idx].fontName
        let newSize = fontSize.map { $0.map(CanvasNode.clampBodyFontSize) } ?? nodes[idx].fontSize
        guard newName != nodes[idx].fontName || newSize != nodes[idx].fontSize else { return }

        let detail = newName ?? "跟随系统"
        commit(.styleNode, detail: detail) {
            nodes[idx].fontName = newName
            nodes[idx].fontSize = newSize
            nodes[idx].updatedAt = Date()
        }
    }

    /// 当前选中的**唯一**节点。属性面板只在单选时出现 —— 多选时改字体要么只改一个（用户会以为
    /// 没生效），要么全改（等于偷偷批量改），两种都不如不显示面板。
    var soleSelectedNode: CanvasNode? {
        guard selectedNodeIds.count == 1, let id = selectedNodeIds.first else { return nil }
        return nodes.first { $0.id == id }
    }

    /// 切换某个节点的堆叠卡片展开风格（扇形 ⇄ 水平轮播，v2.11.8 二轮）。
    ///
    /// 走 `commit` 而不是 `updateNode`：和 `updateNodeStyle` 同理 —— 这是用户可感知的显式操作，
    /// 用 `updateNode` 的症状是「切错了 Cmd+Z 撤不回来」，而这个图标只有 15pt，误点是常态。
    func toggleAnimationStyle(id: String) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        let next: CanvasFanGeometry.ExpandStyle = nodes[idx].animationStyle == .fanOut ? .carousel : .fanOut
        commit(.styleNode, detail: next == .fanOut ? "扇形展开" : "水平轮播") {
            nodes[idx].animationStyle = next
            nodes[idx].updatedAt = Date()
        }
    }

    // MARK: - 归槽（v2.11.8 二轮：把画布节点拖进槽位库）

    /// 把一个节点**改绑**到另一个槽位。
    ///
    /// 用户要的动作是「从画布拖一个节点到槽位库的某个槽位块上，内容就归到那个槽位里」。它由两半组成：
    ///   1. **搬内容**（正文 + 入参文件从旧槽位挪到新槽位）—— 那是槽位数据，由认识主 store 的
    ///      调用方做，这里碰不到（见类型注释：本 store 刻意不认识 `SlotStoreObservable`）。
    ///   2. **改摆位**（节点从此指向新槽位）—— 就是这个方法。
    ///
    /// ## 为什么这件事不能写成 `updateNode { $0.slot = n }`
    ///
    /// 因为 `CanvasNode.id` 是**派生的**（`groupId#slot`）：改字段等于换身份。三处会静默失效：
    ///   - `selectedNodeIds` 里还是旧 id → 拖完节点自己"取消选中"了；
    ///   - 别人的 `parentNodeId` 还指着旧 id → 血缘断链，而这个信息事后无法还原；
    ///   - 目标槽位若已有节点 → 撞 id，SwiftUI `ForEach` 下表现为"点 A 动 B"（`placeSlot`
    ///     就是为此才做了 `.alreadyPlaced` 分支）。
    ///
    /// 所以这里三件事一起做，并在目标已被占用时**拒绝**（返回 false）而不是覆盖 —— 覆盖会让
    /// 另一个节点凭空消失，而用户此刻的注意力全在自己拖的那一个上，根本不会发现。
    ///
    /// - Returns: 是否真的改绑了。false = 目标槽位已被别的节点占用（或节点不存在），调用方应据此
    ///   放弃第 1 步的内容搬迁，否则会出现"内容搬了、节点没跟过去"的分歧。
    @discardableResult
    func rebindNode(id: String, toPageId pageId: String, groupId: String, slot: Int) -> Bool {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return false }
        let newId = CanvasNode.makeId(groupId: groupId, slot: slot)
        if newId == id {
            // 拖回原处：不是失败，但也没什么要改的。返回 true 让调用方按"成功"处理（内容搬迁是空操作）。
            if nodes[idx].pageId != pageId {
                updateNode(id: id) { $0.pageId = pageId }
            }
            return true
        }
        guard !nodes.contains(where: { $0.id == newId }) else { return false }

        let title = nodeTitle(nodes[idx])
        commit(.moveNode, detail: title) {
            nodes[idx].pageId = pageId
            nodes[idx].groupId = groupId
            nodes[idx].slot = slot
            nodes[idx].updatedAt = Date()
            // 血缘引用跟着换 id，否则下游节点会指向一个不存在的父节点。
            for i in nodes.indices where nodes[i].parentNodeId == id {
                nodes[i].parentNodeId = newId
            }
            if selectedNodeIds.contains(id) {
                selectedNodeIds.remove(id)
                selectedNodeIds.insert(newId)
            }
        }
        return true
    }

    // MARK: - 节点正文（= 槽位正文）

    /// 记一步「在画布里改了正文」的可撤销历史。
    ///
    /// ★ hotfix20 起**文本本身不由这里写**：节点没有 `prompt` 副本了，正文的唯一真相是槽位数据，
    /// 由调用方（画布视图，它认识主 store）直接写进槽位。这里只负责历史 —— `before == after`
    /// （节点数组一个字节都没变），撤销时靠 `slotEdit` 把槽位文本推回去。
    ///
    /// 把"写数据"和"记历史"拆到两处看着别扭，但另一种写法是让这个轻量 store 认识
    /// `SlotStoreObservable`，那会把画布重新拖回「任一槽位变化触发全局重绘」的老路（见类型注释）。
    func recordSlotTextEdit(nodeId: String, edit: CanvasHistoryEntry.SlotTextEdit) {
        guard edit.before != edit.after else { return }
        guard let node = nodes.first(where: { $0.id == nodeId }) else { return }
        commit(.editNode, detail: nodeTitle(node), slotEdit: edit) { }
    }

    /// 外部（编辑页改了槽位）通知画布：绑定节点该重读槽位文本了。
    func noteSlotDataChanged() {
        slotRevision += 1
    }

    // MARK: - 撤销 / 重做

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// 槽位文本回写钩子。由画布视图在 onAppear 时注入（`CanvasStore` 刻意不认识 `SlotStoreObservable`，
    /// 否则这个轻量 store 又会被主 store 的 60 个 `@Published` 拖回全局重绘的老路上）。
    var onRestoreSlotText: ((_ groupId: String, _ slot: Int, _ text: String) -> Void)?

    /// 撤销一步。返回被撤销的条目（调用方用它做 toast 文案），没得撤时返回 nil。
    @discardableResult
    func undo() -> CanvasHistoryEntry? {
        guard let entry = history.undo() else { return nil }
        apply(nodes: entry.before)
        if let edit = entry.slotEdit {
            onRestoreSlotText?(edit.groupId, edit.slot, edit.before)
        }
        return entry
    }

    @discardableResult
    func redo() -> CanvasHistoryEntry? {
        guard let entry = history.redo() else { return nil }
        apply(nodes: entry.after)
        if let edit = entry.slotEdit {
            onRestoreSlotText?(edit.groupId, edit.slot, edit.after)
        }
        return entry
    }

    /// 历史面板点某一条 → 把画布状态推到「那一条刚做完」的时刻。
    ///
    /// 直接循环调 undo/redo，而不是一步跳到目标快照：`slotEdit` 的回写是**逐条**挂在条目上的，
    /// 跳跃式还原会漏掉中间那些条目的槽位文本，导致画布节点与编辑页槽位对不上。
    func jump(toCursor target: Int) {
        let clamped = max(0, min(target, history.entries.count))
        while history.cursor > clamped { if undo() == nil { break } }
        while history.cursor < clamped { if redo() == nil { break } }
    }

    private func apply(nodes newNodes: [CanvasNode]) {
        nodes = newNodes
        // 选中集合里可能有已经不存在的 id（撤销"新建"之后），留着会让工具栏的"删除选中"对着空气生效。
        let alive = Set(newNodes.map(\.id))
        selectedNodeIds = selectedNodeIds.intersection(alive)
        slotRevision += 1
        scheduleSave()
    }

    /// 写操作的唯一入口：跑一遍变更、记一步撤销、落盘。
    private func commit(_ kind: CanvasHistoryEntry.Kind,
                        detail: String,
                        slotEdit: CanvasHistoryEntry.SlotTextEdit? = nil,
                        _ mutate: () -> Void) {
        let before = nodes
        mutate()
        guard nodes != before || slotEdit != nil else { return }
        history.push(CanvasHistoryEntry(kind: kind,
                                        detail: detail,
                                        before: before,
                                        after: nodes,
                                        slotEdit: slotEdit))
        slotRevision += 1
        scheduleSave()
    }

    // MARK: - 选择

    func select(id: String, additive: Bool) {
        if additive {
            if selectedNodeIds.contains(id) { selectedNodeIds.remove(id) } else { selectedNodeIds.insert(id) }
        } else {
            selectedNodeIds = [id]
        }
    }

    func clearSelection() {
        guard !selectedNodeIds.isEmpty else { return }
        selectedNodeIds = []
    }

    /// 框选：命中判定在画布空间做，避免受缩放影响。
    func selectNodes(inCanvasRect rect: CGRect, additive: Bool) {
        let hit = nodes.filter { $0.frame.intersects(rect) }.map(\.id)
        if additive {
            selectedNodeIds.formUnion(hit)
        } else {
            selectedNodeIds = Set(hit)
        }
    }

    // MARK: - 操作历史

    /// 节点标题解析钩子。由画布视图在 onAppear 注入（store 刻意不认识 `SlotStoreObservable`，
    /// 见类型注释）。返回槽位 Label 或正文首行。
    var slotTitleProvider: ((_ groupId: String, _ slot: Int) -> String?)?

    /// 历史条目 / toast 里显示的节点名。
    ///
    /// hotfix20 起节点不缓存 Label 与正文了，名字只能当场去问槽位。问不到（钩子未注入、
    /// 槽位组已删）就兜底「槽位 N」—— 兜底文案刻意仍带槽位号，因为历史面板上一排"空节点"
    /// 根本没法定位是哪一步。
    func nodeTitle(_ node: CanvasNode) -> String {
        if let resolved = slotTitleProvider?(node.groupId, node.slot) {
            let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.count > 12 ? String(trimmed.prefix(12)) + "…" : trimmed
            }
        }
        return "槽位 \(node.slot)"
    }

    // MARK: - 落盘

    /// 防抖保存。取消上一次未触发的保存任务，重新计时。
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = CanvasDocument(nodes: nodes,
                                      panX: pan.width,
                                      panY: pan.height,
                                      zoom: zoom)
        let storage = self.storage
        let delay = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // 编码 + 磁盘 IO 挪出主线程，画布拖拽不因落盘掉帧。
            // 刻意用 GCD 而不是 `Task.detached`：`CanvasStorage` 是带 NSLock 的 class（非 Sendable），
            // 塞进 detached task 会吃一串并发检查警告，而这里根本不需要结构化并发的取消传播 ——
            // 取消已经由外层 `saveTask?.cancel()` 承担。
            DispatchQueue.global(qos: .utility).async {
                storage.save(snapshot)
            }
            _ = self
        }
    }

    /// 立即落盘（离开画布 / App 退出时调用，不等防抖）。
    func flushSave() {
        saveTask?.cancel()
        let snapshot = CanvasDocument(nodes: nodes,
                                      panX: pan.width,
                                      panY: pan.height,
                                      zoom: zoom)
        storage.save(snapshot)
    }

    // MARK: - 常量

    /// 网格吸附步长（画布空间）。与背景网格基准一致，观感上「贴着线走」。
    /// 真值住在 `CanvasGeometry`（Kit 层）以便被 smoke 断言覆盖，这里只是就近别名。
    static let snapStep: CGFloat = CanvasGeometry.snapStep
    /// 背景网格基准步长。
    static let gridBase: CGFloat = 24
}

// MARK: - 摆位结果

/// 把一个槽位摆到画布上的结果（v2.11.7 hotfix20）。
///
/// 刻意把「结果」建模成一个值而不是让 store 直接弹 toast：store 不该认识 UI 层的提示通道，
/// 而且同一个动作从槽位库拖拽、热键、圆盘三处进来，提示文案得由各自的调用方按上下文决定。
///
/// ★ 取代了 hotfix19 的 `CanvasSlotInjection`。旧枚举有 `bound / rebound / appended` 三档，
/// 那是"节点有自己的内容、槽位内容往里灌"才需要的区分；节点 = 槽位之后，「灌入」这个动作
/// 根本不存在了，只剩「摆上去」和「已经在上面了」两种事实。
enum CanvasSlotPlacement: Equatable {
    /// 新摆上画布。
    case placed(node: CanvasNode, name: String)
    /// 该槽位已在画布上 —— 没有新建，只是选中了已有的那个。
    case alreadyPlaced(node: CanvasNode, name: String)

    var node: CanvasNode {
        switch self {
        case let .placed(node, _), let .alreadyPlaced(node, _): return node
        }
    }

    var isNew: Bool {
        if case .placed = self { return true }
        return false
    }

    /// toast 文案。
    var message: String {
        switch self {
        case let .placed(_, name): return "已放入 \(name)"
        // 提示必须说清"为什么没多出一张卡片"，否则用户会以为快捷键失灵而反复按。
        case let .alreadyPlaced(_, name): return "\(name) 已在画布上，已选中"
        }
    }
}

// MARK: - 工具

/// 底部浮动工具栏的工具。
///
/// ★ v2.11.7 hotfix17（手势重定义）：原来的四个工具里，`select`（点选）与 `marquee`（框选）在
/// 新语义下会变成**同一个东西** —— 箭头工具本身就要能在空白处拖出选区，那再留一个专门的
/// 「框选」按钮就是一个点了没有任何区别的死按钮。所以 `marquee` 整个删掉，`select` 改名「选区」。
///
/// 平移不再依赖工具切换：**中键按住拖动**在任何工具下都能平移画布（见 `CanvasEventInterceptor`），
/// `hand` 只是给「不想用中键、想用左键拖」的人保留的一条备用路径。
enum CanvasTool: String, CaseIterable, Identifiable, Equatable {
    case select
    case hand
    /// 唤出槽位库。
    ///
    /// ★ hotfix20 前这里叫 `newNode`，点一下就在视口中央凭空造一个空节点。节点 = 槽位之后
    /// 「凭空造节点」不存在了 —— 造节点就得造槽位，而槽位是用户的唯一资产，一个工具栏按钮
    /// 顺手往里写一条空记录是不可接受的。所以它改成"从哪儿放"的入口：展开槽位库。
    case pickSlot

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .pickSlot: return "tray.and.arrow.down"
        }
    }

    var title: String {
        switch self {
        case .select: return "选区"
        case .hand: return "抓手"
        case .pickSlot: return "放入槽位"
        }
    }

    /// 快捷键提示（MVP 只做视觉提示，键盘绑定随后接）。
    var shortcut: String {
        switch self {
        case .select: return "V"
        case .hand: return "H"
        case .pickSlot: return "N"
        }
    }

    /// 工具按钮 tooltip 的补充说明：把「不靠工具切换也能用」的手势写在手边，
    /// 否则用户只会以为平移必须先点抓手。
    var hint: String? {
        switch self {
        case .select: return "在空白处拖动画出选区"
        case .hand: return "左键拖动平移；任何工具下按住中键拖动同样可平移"
        case .pickSlot: return "画布节点就是槽位：从左侧槽位库拖入，或按 Cmd+1~0 放入对应槽位"
        }
    }
}
