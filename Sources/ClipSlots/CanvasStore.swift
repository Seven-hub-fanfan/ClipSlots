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

    func addNode(_ node: CanvasNode) {
        commit(.addNode, detail: nodeTitle(node)) {
            nodes.append(node)
            selectedNodeIds = [node.id]
        }
    }

    /// 从槽位创建节点。prompt 取槽位主体纯文本；空槽也允许拖入（生成前用户可自己补 prompt）。
    func addNodeFromSlot(pageId: String,
                         groupId: String,
                         slot: Int,
                         label: String?,
                         prompt: String,
                         at canvasPoint: CGPoint,
                         kind: CanvasNodeKind = .image) {
        let size = CanvasNode.defaultSize
        // 落点即节点中心，符合「拖到哪儿就放哪儿」的直觉。
        let origin = CGPoint(x: canvasPoint.x - size.width / 2, y: canvasPoint.y - size.height / 2)
        let snapped = CanvasGeometry.snap(origin, step: CanvasStore.snapStep)
        addNode(CanvasNode(kind: kind,
                           x: snapped.x,
                           y: snapped.y,
                           prompt: prompt,
                           sourcePageId: pageId,
                           sourceGroupId: groupId,
                           sourceSlot: slot,
                           sourceLabel: label))
    }

    /// 在视图中心新建一个空节点（工具栏 N / 快捷键）。
    func addBlankNode(at canvasPoint: CGPoint) {
        let size = CanvasNode.defaultSize
        let origin = CGPoint(x: canvasPoint.x - size.width / 2, y: canvasPoint.y - size.height / 2)
        let snapped = CanvasGeometry.snap(origin, step: CanvasStore.snapStep)
        addNode(CanvasNode(x: snapped.x, y: snapped.y))
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

    // MARK: - 节点文本 / 槽位注入

    /// 改节点自己的 prompt（**未绑定槽位**的节点走这条；绑定的节点由调用方写槽位数据）。
    func updateNodePrompt(id: String, text: String, slotEdit: CanvasHistoryEntry.SlotTextEdit? = nil) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        guard nodes[idx].prompt != text || slotEdit != nil else { return }
        let title = nodeTitle(nodes[idx])
        commit(.editNode, detail: title, slotEdit: slotEdit) {
            nodes[idx].prompt = text
            nodes[idx].updatedAt = Date()
        }
    }

    /// Cmd+数字 / 圆盘：把一个槽位的内容送进当前选中的节点。
    ///
    /// 语义分三种，按节点当前状态决定（每种都会在 toast 里说清楚，不做静默行为）：
    ///   - 节点**已绑定**某槽位 → 改绑到新槽位（它本来就是那个槽位的镜像，追加会写脏槽位数据）。
    ///   - 节点**未绑定且为空** → 绑定到该槽位，从此双向同步。
    ///   - 节点**未绑定且有内容** → 把文本追加到末尾（用户在拼一段复合 prompt）。
    ///
    /// **前置条件（hotfix19）**：调用方必须保证选中集合非空。选中为空时正确的行为是新建节点，
    /// 那个决定需要视口尺寸（只有 View 层有），所以留在调用方而不是塞进这里。
    @discardableResult
    func injectSlot(pageId: String,
                    groupId: String,
                    slot: Int,
                    label: String?,
                    text: String) -> CanvasSlotInjection {
        let targets = nodes.filter { selectedNodeIds.contains($0.id) }
        guard !targets.isEmpty else { return .noSelection }

        let name = label?.isEmpty == false ? label! : "槽位 \(slot)"
        var modes: Set<CanvasSlotInjection.Mode> = []
        commit(.bindSlot, detail: targets.count == 1 ? name : "\(name) → \(targets.count) 个节点") {
            for idx in nodes.indices where selectedNodeIds.contains(nodes[idx].id) {
                let isBound = nodes[idx].sourceSlot != nil
                if isBound {
                    modes.insert(.rebound)
                    bind(&nodes[idx], pageId: pageId, groupId: groupId, slot: slot, label: label, text: text)
                } else if nodes[idx].prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    modes.insert(.bound)
                    bind(&nodes[idx], pageId: pageId, groupId: groupId, slot: slot, label: label, text: text)
                } else {
                    modes.insert(.appended)
                    nodes[idx].prompt += "\n" + text
                    nodes[idx].updatedAt = Date()
                }
            }
        }
        // 多个节点混合命中多种语义时报最"重"的那个（改绑 > 追加 > 绑定），提示不能撒谎。
        let mode: CanvasSlotInjection.Mode = modes.contains(.rebound) ? .rebound
            : (modes.contains(.appended) ? .appended : .bound)
        return .applied(mode: mode, name: name, count: targets.count)
    }

    private func bind(_ node: inout CanvasNode,
                      pageId: String,
                      groupId: String,
                      slot: Int,
                      label: String?,
                      text: String) {
        node.prompt = text
        node.sourcePageId = pageId
        node.sourceGroupId = groupId
        node.sourceSlot = slot
        node.sourceLabel = label
        node.updatedAt = Date()
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

    // MARK: - 多张展开（对齐 CLI --count 语义）

    /// 把一个母节点按 `count` 展开成多个独立节点，并把挡路的既有节点向右推开。
    ///
    /// MVP 阶段这里只做布局，不真正提交任务 —— 生图接入见架构文档第三节。
    func fanOut(nodeId: String) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        let parent = nodes[idx]
        let count = max(1, min(parent.count, 4))
        guard count > 1 else { return }

        commit(.fanOut, detail: "\(count) 个节点") {
            let size = CGSize(width: parent.width, height: parent.height)
            let bounds = CanvasGeometry.fanOutBounds(origin: parent.frame.origin,
                                                    nodeSize: size,
                                                    count: count,
                                                    gap: CanvasStore.fanGap)

            // 先推开挡路节点（排除母节点自身）。
            var others = nodes
            others.remove(at: idx)
            let offsets = CanvasGeometry.pushRightOffsets(existing: others.map(\.frame),
                                                         bounds: bounds,
                                                         gap: CanvasStore.fanGap)
            for (otherIdx, dx) in offsets {
                let targetId = others[otherIdx].id
                if let realIdx = nodes.firstIndex(where: { $0.id == targetId }) {
                    nodes[realIdx].x += dx
                    nodes[realIdx].updatedAt = Date()
                }
            }

            // 母节点原地变成第 1 张，其余追加。
            let frames = CanvasGeometry.fanOutFrames(origin: parent.frame.origin,
                                                    nodeSize: size,
                                                    count: count,
                                                    gap: CanvasStore.fanGap)
            if let parentIdx = nodes.firstIndex(where: { $0.id == nodeId }) {
                nodes[parentIdx].count = 1
                nodes[parentIdx].updatedAt = Date()
            }
            var newIds: Set<String> = [nodeId]
            for frame in frames.dropFirst() {
                var child = parent
                child.id = "node_" + UUID().uuidString
                child.x = frame.origin.x
                child.y = frame.origin.y
                child.count = 1
                child.state = .idle
                child.taskId = nil
                child.seed = nil
                child.createdAt = Date()
                child.updatedAt = Date()
                nodes.append(child)
                newIds.insert(child.id)
            }
            selectedNodeIds = newIds
        }
    }

    // MARK: - 操作历史

    /// 历史条目里显示的节点名。优先槽位 Label，其次 prompt 首行，最后兜底「空节点」。
    private func nodeTitle(_ node: CanvasNode) -> String {
        if let label = node.sourceLabel, !label.isEmpty { return label }
        let firstLine = node.prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "空节点" }
        return trimmed.count > 12 ? String(trimmed.prefix(12)) + "…" : trimmed
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
    /// 多张展开的节点间距。
    static let fanGap: CGFloat = 20
    /// 背景网格基准步长。
    static let gridBase: CGFloat = 24
}

// MARK: - 槽位注入结果

/// Cmd+数字 / 圆盘把槽位内容送进画布节点的结果。
///
/// 刻意把「结果」建模成一个值而不是让 store 直接弹 toast：store 不该认识 UI 层的提示通道，
/// 而且同一个动作从热键、圆盘、右键菜单三处进来，提示文案得由各自的调用方按上下文决定。
enum CanvasSlotInjection: Equatable {
    /// 画布里没有选中节点。
    ///
    /// ★ v2.11.7 hotfix19 起这已经**不是一条会走到 UI 的路径**：调用方（`CanvasWorkspaceView`）
    /// 在选中集合为空时改为直接新建节点，不再进 `injectSlot`。这一档保留下来纯粹是因为
    /// `injectSlot` 作为 store 的公开方法不能对"没有目标"这种输入静默无动作 ——
    /// 一个什么都不做又什么都不说的返回值，是下一个 bug 最舒服的藏身处。
    case noSelection
    case applied(mode: Mode, name: String, count: Int)

    enum Mode: Equatable, Hashable {
        /// 空的未绑定节点 → 绑到该槽位，从此双向同步。
        case bound
        /// 已绑定其他槽位 → 改绑（不能追加，那会把别的槽位数据写脏）。
        case rebound
        /// 未绑定但已有文本 → 追加到末尾（用户在拼复合 prompt）。
        case appended
    }

    /// toast 文案。
    var message: String {
        switch self {
        case .noSelection:
            // 正常流程到不了这里（见 `noSelection` 的注释）。文案按"这是异常"来写，
            // 而不是按"这是引导"来写 —— 真出现了说明调用方漏了新建分支。
            return "没有可填入的节点"
        case let .applied(mode, name, count):
            let scope = count == 1 ? "" : "（\(count) 个节点）"
            switch mode {
            case .bound: return "已填入 \(name)\(scope)"
            case .rebound: return "已改绑到 \(name)\(scope)"
            case .appended: return "已追加 \(name)\(scope)"
            }
        }
    }

    var isSuccess: Bool {
        if case .applied = self { return true }
        return false
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
    case newNode

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .newNode: return "plus.square.dashed"
        }
    }

    var title: String {
        switch self {
        case .select: return "选区"
        case .hand: return "抓手"
        case .newNode: return "新建节点"
        }
    }

    /// 快捷键提示（MVP 只做视觉提示，键盘绑定随后接）。
    var shortcut: String {
        switch self {
        case .select: return "V"
        case .hand: return "H"
        case .newNode: return "N"
        }
    }

    /// 工具按钮 tooltip 的补充说明：把「不靠工具切换也能用」的手势写在手边，
    /// 否则用户只会以为平移必须先点抓手。
    var hint: String? {
        switch self {
        case .select: return "在空白处拖动画出选区"
        case .hand: return "左键拖动平移；任何工具下按住中键拖动同样可平移"
        case .newNode: return nil
        }
    }
}
