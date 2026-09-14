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

    func addNode(_ node: CanvasNode) {
        nodes.append(node)
        selectedNodeIds = [node.id]
        scheduleSave()
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
        nodes[idx].setFrameOrigin(CanvasGeometry.snap(origin, step: CanvasStore.snapStep))
        scheduleSave()
    }

    func removeNodes(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        nodes.removeAll { ids.contains($0.id) }
        selectedNodeIds.subtract(ids)
        scheduleSave()
    }

    func removeSelected() {
        removeNodes(ids: selectedNodeIds)
    }

    func updateNode(id: String, _ mutate: (inout CanvasNode) -> Void) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&nodes[idx])
        nodes[idx].updatedAt = Date()
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
        scheduleSave()
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
    static let snapStep: CGFloat = 12
    /// 多张展开的节点间距。
    static let fanGap: CGFloat = 20
    /// 背景网格基准步长。
    static let gridBase: CGFloat = 24
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
