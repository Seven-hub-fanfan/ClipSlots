import SwiftUI
import Combine
@preconcurrency import ClipSlotsKit

/// Owns the window's canvas without forwarding each node/selection/save change
/// into ContentView. Child workspaces observe CanvasStore directly.
@MainActor final class CanvasWorkspaceOwner: ObservableObject {
    let canvas = CanvasStore()
    @Published private(set) var activeProjectID: String
    private var projectSubscription: AnyCancellable?
    init() {
        activeProjectID = canvas.activeProjectId
        projectSubscription = canvas.$activeProjectId.removeDuplicates().sink { [weak self] id in
            guard self?.activeProjectID != id else { return }
            self?.activeProjectID = id
        }
    }
}

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
    /// Legacy batch lineage edges never represented an image reference.
    /// Keep the document intact while excluding them from visible/input controls.
    var interactionEdges: [CanvasEdge] {
        edges.filter { node(id: $0.toNodeId)?.generationSourceID != $0.fromNodeId }
    }
    private static let instances = NSHashTable<CanvasStore>.weakObjects()
    static func flushAll() -> Bool {
        let results = instances.allObjects.map { $0.flushSave() }
        return results.allSatisfy { $0 }
    }

    enum SaveStatus: Equatable {
        case saved, saving, failed(String)
    }
    final class SaveProgress: ObservableObject {
        @Published var status: SaveStatus = .saved
    }
    let saveProgress = SaveProgress()
    private(set) var saveStatus: SaveStatus {
        get { saveProgress.status }
        set { saveProgress.status = newValue }
    }
    var flushTextDocuments: (() -> Bool)?
    private var pendingDocuments: [String: CanvasDocument] = [:]
    private var saveVersions: [String: UUID] = [:]
    private var saveFailures: [String: String] = [:]

    // MARK: - 发布状态

    private let nodesSubject = CurrentValueSubject<[CanvasNode], Never>([])
    var nodeChanges: AnyPublisher<[CanvasNode], Never> { nodesSubject.eraseToAnyPublisher() }
    private var graphNotificationQueued = false
    private func notifyGraphChange() {
        guard !graphNotificationQueued else { return }
        graphNotificationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.graphNotificationQueued = false
            self.objectWillChange.send()
            if self.nodesSubject.value != self.nodes { self.nodesSubject.send(self.nodes) }
        }
    }

    private(set) var graphRevision: UInt64 = 0
    @Published var connectionPolicy = CanvasConnectionPolicy() {
        didSet { graphRevision &+= 1 }
    }
    private(set) var nodes: [CanvasNode] = [] {
        didSet { graphRevision &+= 1; notifyGraphChange() }
    }
    /// 节点之间的连线（v2.12.0）。
    ///
    /// 与 `nodes` 同级发布：连线是**内容**（决定生成入参），不是装饰，拖动一个节点时连线要跟着动
    /// —— 但那条通路走的是 View 侧 `dragOffset`（与节点自身相同的办法），不经过这个数组。
    /// 这里只在"真的增删改了一条线"时才变。
    private(set) var edges: [CanvasEdge] = [] {
        didSet { graphRevision &+= 1; notifyGraphChange() }
    }
    private(set) var groups: [CanvasNodeGroup] = [] { didSet { notifyGraphChange() } }
    private(set) var piles: [CanvasPile] = [] {
        didSet { graphRevision &+= 1; notifyGraphChange() }
    }
    private var appliedAgentMutationIDs: [String] = []
    private var groupMeasurements: [String: CGSize] = [:]
    private var groupMeasurementProjectID: String?
    private var suppressedServerGroupLayouts = Set<String>()
    @Published private(set) var serverGroupLayoutStates: [String: CanvasServerGroupLayout.State] = [:]
    var selectedGroupID: String? { didSet { if selectedGroupID != oldValue { notifyGraphChange() } } }
    let selectedNodesDidChange = PassthroughSubject<Set<String>, Never>()
    var selectedNodeIds: Set<String> = [] {
        didSet {
            if let id = selectedGroupID,
               groupMemberIDs(id) != selectedNodeIds {
                selectedGroupID = nil
            }
            if selectedNodeIds != oldValue {
                selectedNodesDidChange.send(selectedNodeIds)
                notifyGraphChange()
            }
        }
    }
    /// 当前选中的连线（一次只选一条）。
    ///
    /// 刻意**不与 `selectedNodeIds` 合并成一个"选中对象"集合**：两者能做的操作几乎不重叠
    /// （连线没有移动/改参数/生成，节点没有角色），混在一起会让每个操作入口都得先判类型。
    var selectedEdgeId: String? { didSet { if selectedEdgeId != oldValue { notifyGraphChange() } } }
    @Published var activeTool: CanvasTool = .select
    /// 左侧槽位库面板是否展开。
    @Published var isLibraryExpanded: Bool = true
    /// 撤销栈 + 操作流水。**只活在本次会话内，刻意不落盘**：它是「我刚才干了什么」的记忆辅助，
    /// 不是文档内容；持久化它就得回答「跨天该不该 Cmd+Z」「导出 pack 要不要带」这些没有好答案的问题。
    private(set) var history = CanvasUndoStack() { didSet { notifyGraphChange() } }
    /// 槽位内容版本号。
    ///
    /// 绑定槽位的节点卡片显示的是**槽位实时文本**，而槽位数据住在主 store 里。画布子树不订阅主 store
    /// （那会把这个轻量 store 拖回全局重绘），所以需要一个显式的「脏」信号：主 store 那边槽位一变，
    /// 或撤销/重做把槽位文本改回去了，就 `+= 1`，绑定节点据此重读。
    @Published private(set) var slotRevision: Int = 0
    struct AgentFocusRequest: Equatable {
        let id = UUID()
        let nodeID: String
    }
    @Published private(set) var agentFocusRequest: AgentFocusRequest?
    @Published private(set) var workflowFitRequest: UUID?
    @Published private(set) var agentHistoryError: String?
    private var agentBodyEdits: [String: (undo: () throws -> Void, redo: () throws -> Void)] = [:]
    private var workflowEdits: [String: (WorkflowProjectTransaction, WorkflowProjectTransaction.Receipt)] = [:]
    private var isComposingAgentEdit = false
    var agentGenerationHandler: ((Set<String>) -> Task<Void, Never>?)?
    var agentGenerationOwner: UUID?

    /// Prevent a newly allocated text slot from taking the identity of an
    /// undone Agent node while that node remains redoable.
    var agentReservedPrivateSlots: Set<Int> {
        Set(history.entries.flatMap { $0.before + $0.after }
            .filter { $0.groupId == privateGroupId }.map(\.slot))
    }

    /// Combine native graph changes and a compare-and-exchange body write into
    /// one durable operation and one undo entry. No await is allowed in commit.
    @discardableResult
    func performAgentEdit(detail: String, undoBody: (() throws -> Void)? = nil,
                          redoBody: (() throws -> Void)? = nil,
                          _ operation: () throws -> Void) throws -> String? {
        guard !documentLoadFailed, !connectionPolicy.readOnly, flushSave() else {
            throw AgentCanvasError.writeFailed
        }
        let before = gatewayDocument(), oldHistory = history, oldBodyEdits = agentBodyEdits
        let oldSelection = selectedNodeIds, oldGroup = selectedGroupID, oldEdge = selectedEdgeId
        let flusher = flushTextDocuments
        flushTextDocuments = nil
        isComposingAgentEdit = true
        defer { flushTextDocuments = flusher; isComposingAgentEdit = false }
        do {
            try operation()
            let after = gatewayDocument()
            guard before.nodes != after.nodes || before.edges != after.edges
                    || before.groups != after.groups || before.piles != after.piles
                    || undoBody != nil else { return nil }
            let entry = CanvasHistoryEntry(kind: .editNode, detail: "Agent · " + detail,
                before: before.nodes, after: after.nodes,
                beforeEdges: before.edges, afterEdges: after.edges,
                beforeGroups: before.groups, afterGroups: after.groups,
                beforePiles: before.piles, afterPiles: after.piles)
            history = oldHistory
            history.push(entry)
            agentBodyEdits = oldBodyEdits.filter { key, _ in history.entries.contains { $0.id == key } }
            if undoBody != nil || redoBody != nil {
                agentBodyEdits[entry.id] = (undoBody ?? {}, redoBody ?? {})
            }
            noteSlotDataChanged()
            guard flushSave() else { throw AgentCanvasError.writeFailed }
            let retainedTokens = Set(history.entries.compactMap { $0.attachmentEdit?.stashToken })
            for token in Set(oldHistory.entries.compactMap { $0.attachmentEdit?.stashToken }).subtracting(retainedTokens) {
                discardAttachmentStash(token)
            }
            return entry.id
        } catch {
            // Restore body before removing its newly created target.
            do { try undoBody?() }
            catch { agentHistoryError = error.localizedDescription }
            apply(nodes: before.nodes, edges: before.edges, groups: before.groups, piles: before.piles)
            history = oldHistory; agentBodyEdits = oldBodyEdits
            selectedNodeIds = oldSelection; selectedGroupID = oldGroup; selectedEdgeId = oldEdge
            noteSlotDataChanged()
            _ = flushSave()
            throw error
        }
    }

    func focusAgentNode(_ id: String) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        selectedNodeIds = [id]
        agentFocusRequest = AgentFocusRequest(nodeID: id)
    }

    func completeWorkflowFit(_ request: UUID) {
        if workflowFitRequest == request { workflowFitRequest = nil }
    }

    /// Body writes have already succeeded before recording. Never advance the
    /// history cursor if a later compare-and-exchange refuses undo or redo.
    func recordAgentBodyEdit(detail: String, undo: @escaping () throws -> Void,
                             redo: @escaping () throws -> Void) -> String {
        let entry = CanvasHistoryEntry(kind: .editNode, detail: "Agent · " + detail,
            before: nodes, after: nodes, beforeEdges: edges, afterEdges: edges,
            beforeGroups: groups, afterGroups: groups, beforePiles: piles, afterPiles: piles)
        let oldTokens = Set(history.entries.compactMap { $0.attachmentEdit?.stashToken })
        history.push(entry)
        let retained = Set(history.entries.map(\.id))
        agentBodyEdits = agentBodyEdits.filter { retained.contains($0.key) }
        agentBodyEdits[entry.id] = (undo, redo)
        let newTokens = Set(history.entries.compactMap { $0.attachmentEdit?.stashToken })
        for token in oldTokens.subtracting(newTokens) { discardAttachmentStash(token) }
        agentHistoryError = nil
        noteSlotDataChanged()
        return entry.id
    }

    func gatewayDocument() -> CanvasDocument {
        CanvasDocument(nodes: nodes, edges: edges, groups: groups, piles: piles,
                       appliedAgentMutationIDs: appliedAgentMutationIDs,
                       panX: pan.width, panY: pan.height, zoom: zoom)
    }

    func appendStructure(_ capture: CanvasStructureCapture, slots: [Int], delta: CGSize) throws {
        guard !documentLoadFailed, flushSave() else { throw AgentCanvasError.writeFailed }
        let before = gatewayDocument()
        let next = try saveQueue.sync {
            try CanvasStructureCopyTransaction(root: projectStorage.dataRoot).append(
                capture, to: before, projectID: activeProjectId, slots: slots, delta: delta)
        }
        storage.invalidateCache()
        // flushSave already fenced the editor; do not invoke its callback again
        // after the durable graph commit.
        let flusher = flushTextDocuments
        flushTextDocuments = nil
        defer { flushTextDocuments = flusher }
        commit(.duplicate, detail: "\(slots.count) 个节点") {
            nodes = next.nodes; edges = next.edges; groups = next.groups; piles = next.piles
        }
        let newGroups = groups.filter { group in !before.groups.contains { $0.id == group.id } }
        if let root = newGroups.first(where: { $0.parentGroupID == nil }) { selectGroup(root.id) }
        else {
            selectedGroupID = nil
            let newPiles = piles.filter { pile in !before.piles.contains { $0.id == pile.id } }
            let piled = Set(newPiles.flatMap(\.memberIDs))
            selectedNodeIds = Set(nodes.filter { node in !before.nodes.contains { $0.id == node.id }
                && !piled.contains(node.id) }.map(\.id) + newPiles.map(\.id))
        }
    }

    /// Invoked only after the user has reviewed a typed graph proposal.
    func applyGatewayMutation(_ mutation: AgentCanvasMutation, conversationID: String,
                              runID: String, contentAvailable: (CanvasNode) -> Bool) throws -> AgentCanvasSync.Plan {
        guard mutation.projectID == activeProjectId, !documentLoadFailed,
              flushSave() else { throw AgentCanvasError.staleTarget }
        let before = gatewayDocument()
        let plan = try AgentCanvasSync.plan(mutation, current: before, expectedProject: activeProjectId,
                                           expectedConversation: conversationID, expectedRun: runID)
        guard !plan.alreadyApplied else { return plan }
        for change in mutation.changes {
            if let after = change.after {
                guard contentAvailable(after) else {
                    throw AgentOperationError("节点引用的内容不在本地可用范围，未应用不完整快照。")
                }
            }
        }
        saveTask?.cancel()
        let project = activeProjectId
        try saveQueue.sync {
            try storage.saveComparingGraph(plan.document,
                expectedRevision: AgentCanvasSync.revision(before), projectId: project)
        }
        appliedAgentMutationIDs = plan.document.appliedAgentMutationIDs
        suppressedServerGroupLayouts.subtract(plan.changedGroupIDs)
        commit(.editNode, detail: "Agent · \(plan.changedNodeIDs.count) 个节点 · \(plan.changedGroupIDs.count) 个编组变更") {
            nodes = plan.document.nodes
            edges = plan.document.edges
            groups = plan.document.groups
            piles = plan.document.piles
        }
        return plan
    }

    // MARK: - 视口（非 @Published，见类型注释）

    /// 视口只在进出画布与防抖落盘时读写，不参与视图订阅。
    private(set) var pan: CGSize = .zero
    private(set) var zoom: CGFloat = 1

    // MARK: - 依赖

    private let storage: CanvasStorage
    private let projectStorage: CanvasProjectStorage
    private var workflowPrivateStorage: SpecialSlotStorage {
        if projectStorage.dataRoot.standardizedFileURL == ClipSlotsPaths.dataRoot.standardizedFileURL { return .canvasPrivate }
        return SpecialSlotStorage(baseDirectory: projectStorage.dataRoot.appendingPathComponent("canvas/private_slots"),
                                  role: .canvasPrivate)
    }
    private var saveTask: Task<Void, Never>?
    /// 画布文档写入队列。防抖任务一旦把 IO 派出去就不能再取消，必须让所有写入串行，
    /// 否则旧快照可能比新快照更晚写完，把用户刚拖好的位置覆盖回去。
    private let saveQueue = DispatchQueue(label: "com.clipslots.canvas.save", qos: .utility)
    private var generationTickets: [UUID: CanvasGenerationTicket] = [:]
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    @Published private var stoppedGenerations = Set<UUID>()
    @Published var selectionGenerationTask: Task<Void, Never>?
    @Published var runningGroupID: String?
    var selectionGenerationID: UUID?
    var selectionGenerationNodes: [CanvasNode] = []
    var adjacentGenerationIDs: [String: UUID] = [:]
    var adjacentGenerationTasks: [String: Task<Void, Never>] = [:]
    var adjacentLastResultIDs: [String: [String]] = [:]
    var recoverGenerationAction: ((CanvasNode) -> Void)?
    var byteArtistInputPlan: ((CanvasNode) -> CanvasWorkflowResolver.Plan)?
    private var generationHistoryResults: [String: CanvasNode] = [:]

    func selectionGenerationNode(_ snapshot: CanvasNode) -> CanvasNode? {
        let sameBirth = nodes.filter { $0.createdAt == snapshot.createdAt }
        return sameBirth.first { $0.id == snapshot.id }
            ?? (sameBirth.count == 1 ? sameBirth.first : nil)
    }

    func stopSelectionGeneration() {
        selectionGenerationID = nil
        selectionGenerationTask?.cancel()
        selectionGenerationTask = nil
        runningGroupID = nil
        for snapshot in selectionGenerationNodes {
            if let node = selectionGenerationNode(snapshot) { stopGeneration(node) }
            for resultID in adjacentLastResultIDs[snapshot.id] ?? [] {
                if let result = node(id: resultID) { stopGeneration(result) }
            }
        }
        selectionGenerationNodes = []
    }
    /// 防抖窗口。拖拽松手 / 缩放停止后 0.4s 落盘，避免高频写。
    private let saveDebounce: Duration = .milliseconds(400)

    init(storage: CanvasStorage = .shared, projectStorage: CanvasProjectStorage = .shared) {
        self.storage = storage
        self.projectStorage = projectStorage
        // 项目索引先读：它决定该打开哪一份画布文档（并在首次运行时把 v2.12 的单画布迁移过来）。
        let index = projectStorage.load()
        self.projects = index.displayOrder
        self.activeProjectId = index.activeProjectId
        let doc = storage.load(projectId: index.activeProjectId)
        self.nodes = doc.nodes
        // 文档解码时已经做过规整与 `parentNodeId` 迁移（见 `CanvasDocument.init(from:)`），
        // 这里直接取用；在 store 里再规整一遍只会掩盖那边出的问题。
        self.edges = doc.edges
        self.groups = doc.groups
        self.piles = doc.piles
        self.appliedAgentMutationIDs = doc.appliedAgentMutationIDs
        self.pan = doc.pan
        self.zoom = CanvasGeometry.clampZoom(doc.zoom)
        Self.instances.add(self)
    }

    // MARK: - 项目（v2.13.0）

    /// 全部项目，按"最近打开"倒序（`CanvasProjectIndex.displayOrder`）。
    @Published private(set) var projects: [CanvasProject] = []
    /// 当前打开的项目 id。
    @Published private(set) var activeProjectId: String = CanvasProject.defaultId

    /// 当前项目。
    ///
    /// 刻意返回非可空：整个画布 UI 都建立在"当前一定有一个项目"之上（见
    /// `CanvasProjectIndex.normalized` 的注释），每个调用点各写一次 `?? fallback` 只是把同一个
    /// 不变量抄了 N 遍。索引侧已经保证列表非空且 activeId 有效，这里的兜底只在内存被改坏时生效。
    var activeProject: CanvasProject {
        projects.first { $0.id == activeProjectId }
            ?? projects.first
            ?? CanvasProject(id: CanvasProject.defaultId, name: CanvasProject.defaultName)
    }

    /// 当前项目的**私有槽位组** id：画布上"凭空新建"的节点落在这里。
    ///
    /// 默认项目就是历史上的「未入库」（`__unfiled__`），见 `CanvasProject.privateGroupId`。
    var privateGroupId: String { activeProject.privateGroupId }

    /// 当前项目的画布文档这次加载是否失败过。
    ///
    /// ★ 对账私有内容前**必须**问它（`CanvasPrivateReconcile` 的安全闸 1）：文档读不出来时
    /// `nodes` 是空的，此时对账会把整个项目的内容一次全搬进暂存区。
    var documentLoadFailed: Bool { storage.lastLoadFailed(projectId: activeProjectId) }

    /// 本项目私有组里**当前画布节点占用**的槽位号。
    ///
    /// 这是 v2.14.0 对账的唯一真源：可见内容 == 这个集合（见 `CanvasPrivateReconcile`）。
    ///
    /// v2.13.0 还额外给撤销栈引用到的槽位开了豁免口，结果"删了节点内容不消失"——那个豁免已经
    /// 连同 `privateSlotsReferencedByHistory()` 一起删掉：撤销安全现在靠**磁盘暂存区**兜，
    /// 不靠"把内容留在原地"。
    func privateSlotsReferencedByNodes() -> Set<Int> {
        CanvasPrivateReconcile.slots(of: nodes, in: privateGroupId)
    }

    /// 新建项目并切过去。
    ///
    /// 返回新项目。名字会去重（`CanvasProject.uniqueName`）——重名不影响数据（身份是 id），
    /// 但切换器里两行一模一样的名字等于让用户抓瞎。
    @discardableResult
    func createProject(name: String) -> CanvasProject {
        // 先把当前项目落盘：新项目一旦切过去，`nodes` 就被换掉了，没落盘的改动再也找不回来。
        guard flushSave() else { return activeProject }
        let unique = CanvasProject.uniqueName(base: name, existing: projects.map(\.name))
        let project = CanvasProject(name: unique)
        var index = CanvasProjectIndex(projects: projects + [project], activeProjectId: project.id)
        index = CanvasProjectIndex.normalized(index)
        projectStorage.save(index)
        projects = index.displayOrder
        adoptProject(id: project.id)
        return project
    }

    func createWorkflowProject(name: String, instance: WorkflowSkill.Instance) async throws {
        guard flushSave() else { throw AgentCanvasError.writeFailed }
        let origin = activeProjectId
        let expected = CanvasProjectIndex(projects: projects, activeProjectId: origin)
        let unique = CanvasProject.uniqueName(base: name, existing: projects.map(\.name))
        let transaction = WorkflowProjectTransaction(root: projectStorage.dataRoot)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try transaction.prepare(name: unique, instance: instance)
        }.value
        guard activeProjectId == origin, !Task.isCancelled else {
            transaction.discard(prepared); throw AgentCanvasError.staleTarget
        }
        do {
            guard flushSave() else { throw AgentCanvasError.writeFailed }
            // Index ordering on disk may differ from the displayed recent-project ordering.
            let diskIndex = projectStorage.load()
            guard Set(diskIndex.projects.map(\.id)) == Set(expected.projects.map(\.id)),
                  diskIndex.activeProjectId == origin else { throw AgentCanvasError.staleTarget }
            let privateContents = workflowPrivateStorage
            let receipt = try transaction.commit(prepared, expected: diskIndex, privateStorage: privateContents)
            projectStorage.invalidateCache()
            storage.invalidateCache()
            privateContents.invalidateContentCaches()
            projects = projectStorage.load().displayOrder
            adoptProject(id: receipt.project.id)
            let entry = CanvasHistoryEntry(kind: .addNode, detail: "Skill · \(receipt.document.nodes.count) 个节点与连线",
                before: [], after: receipt.document.nodes, beforeEdges: [], afterEdges: receipt.document.edges)
            history.push(entry)
            workflowEdits[entry.id] = (transaction, receipt)
            selectedNodeIds = Set(nodes.map(\.id))
            workflowFitRequest = UUID()
        } catch {
            transaction.discard(prepared)
            projectStorage.invalidateCache()
            throw error
        }
    }

    /// 切到另一个项目。返回是否真的切了（id 不存在 / 已经是它 → false）。
    @discardableResult
    func switchProject(to id: String) -> Bool {
        guard id != activeProjectId, projects.contains(where: { $0.id == id }) else { return false }
        guard flushSave() else { return false }
        touchProject(id: id)
        adoptProject(id: id)
        return true
    }

    @discardableResult
    func renameProject(id: String, name: String) -> Bool {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return false }
        let others = projects.enumerated().filter { $0.offset != idx }.map(\.element.name)
        let unique = CanvasProject.uniqueName(base: name, existing: others)
        guard unique != projects[idx].name else { return false }
        projects[idx].name = unique
        projects[idx].updatedAt = Date()
        persistProjectIndex()
        return true
    }

    /// 删除项目。
    ///
    /// 只负责**索引与画布文档**（文档目录进 `canvas/.trash`）。它的**私有槽位组**由调用方删
    /// （`SlotStoreObservable.deleteCanvasPrivateGroup`）—— 这个 store 刻意不认识槽位存储层，
    /// 见类型注释。所以这里把被删的项目返回出去，让调用方拿到 `privateGroupId`。
    ///
    /// 返回 nil = 没删（最后一个项目不能删，见 `CanvasProjectIndex.canDelete`）。
    @discardableResult
    func deleteProject(id: String) -> CanvasProject? {
        let index = CanvasProjectIndex(projects: projects, activeProjectId: activeProjectId)
        guard index.canDelete(id), let victim = projects.first(where: { $0.id == id }) else { return nil }
        // 删的是当前项目 → 先把最新状态同步落进即将被 trash 的项目文档。
        // v2.16.2：这里不能只 cancel 防抖任务。用户最后一次拖动/缩放/连线可能还停在 400ms
        // 防抖窗口里；直接 cancel 会让 .trash 里的备份少掉最后一步，等价于把“删除前最后状态”丢了。
        // 先 flush 到当前 projectId，再 trash 该项目目录；activeProjectId 尚未切走，不会串写到下一项目。
        if id == activeProjectId, !flushSave() { return nil }

        var next = CanvasProjectIndex(projects: projects.filter { $0.id != id },
                                     activeProjectId: id == activeProjectId ? "" : activeProjectId)
        next = CanvasProjectIndex.normalized(next)
        projectStorage.save(next)
        saveQueue.sync {}
        // v2.16.5：文档移入 .trash 失败时盘上还留着该项目文档；若继续按「已删」推进，索引里
        // 再无它的记录，文档将成为永久孤儿。回滚索引（内存状态此刻尚未改变），放弃删除。
        guard projectStorage.trashProjectDocs(projectId: id) else {
            projectStorage.save(index)
            NSLog("[ClipSlots] deleteProject: 项目文档移入 .trash 失败，已回滚项目索引 \(id)")
            return nil
        }
        generationTickets = generationTickets.filter { $0.value.projectId != id }
        projects = next.displayOrder
        if id == activeProjectId {
            adoptProject(id: next.activeProjectId)
        }
        return victim
    }

    /// 把某个项目的文档读进来当作当前状态。
    ///
    /// 撤销栈**整条清掉**：它的快照是"那个项目的节点数组"，留着跨项目 Cmd+Z 会把 A 项目的节点
    /// 写进 B 项目的文档（而且 id 是 `groupId#slot`，撞上就是静默串数据）。历史刻意不落盘
    /// （见 `history` 的注释），所以这里没有"保存 A 的历史"这个选项。
    private func adoptProject(id: String) {
        stopSelectionGeneration()
        generationHistoryResults = [:]
        groupMeasurements = [:]
        groupMeasurementProjectID = nil
        suppressedServerGroupLayouts = []
        serverGroupLayoutStates = [:]
        activeProjectId = id
        let doc = pendingDocuments[id] ?? storage.load(projectId: id)
        nodes = doc.nodes
        edges = doc.edges
        groups = doc.groups
        piles = doc.piles
        appliedAgentMutationIDs = doc.appliedAgentMutationIDs
        pan = doc.pan
        zoom = CanvasGeometry.clampZoom(doc.zoom)
        selectedNodeIds = []
        selectedEdgeId = nil
        // 撤销/重做栈不能跨项目共享；切项目前收走所有附件暂存字节（条目全部消失）。
        for entry in history.entries {
            if let token = entry.attachmentEdit?.stashToken {
                discardAttachmentStash(token)
            }
        }
        history.removeAll()
        agentBodyEdits.removeAll()
        workflowEdits.removeAll()
        agentHistoryError = nil
        agentFocusRequest = nil
        workflowFitRequest = nil
        slotRevision += 1
    }

    /// 更新"最近打开"时间（切换器的排序依据）。
    private func touchProject(id: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].updatedAt = Date()
        persistProjectIndex()
    }

    private func persistProjectIndex() {
        let index = CanvasProjectIndex(projects: projects, activeProjectId: activeProjectId)
        projectStorage.save(index)
        projects = CanvasProjectIndex.normalized(index).displayOrder
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
                   // ★ v2.15.0：默认槽位节点。从左侧槽位库拖上来 / 「摆到画布」按钮走的都是这条路，
                   // 它们摆的就是"已有槽位的展台"，不是图片生成节点（理由见 `CanvasNodeKind.slot`）。
                   kind: CanvasNodeKind = .slot,
                   parentNodeId: String? = nil,
                   parentNodeIds: [String] = [],
                   avoidOverlap: Bool = false) -> CanvasSlotPlacement {
        let id = CanvasNode.makeId(groupId: groupId, slot: slot)
        if let existing = nodes.first(where: { $0.id == id }) {
            selectedEdgeId = nil
            selectedNodeIds = [existing.id]
            return .alreadyPlaced(node: existing, name: name)
        }
        let size = CanvasNodeSizing.initialSize(for: kind)
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
        // 出图参数按 kind 取默认（v2.11.19）：视频节点拿到 `seedream45` 会在第一次点生成时
        // 直接被 CLI 拒收，而用户什么都没改过。
        let node = CanvasNode(pageId: pageId,
                              groupId: groupId,
                              slot: slot,
                              kind: kind,
                              mediaRole: parentNodeId == nil && parentNodeIds.isEmpty ? .source : .generation,
                              x: snapped.x,
                              y: snapped.y,
                              width: size.width,
                              height: size.height,
                              model: CanvasNode.defaultModel(for: kind),
                              ratio: CanvasNode.defaultRatio(for: kind),
                              parentNodeId: parentNodeId)
        commit(.addNode, detail: name) {
            nodes.append(node)
            selectedEdgeId = nil
            selectedNodeIds = [node.id]
            // v2.12.0：上游不再只写进 `parentNodeId`，同时落一条真实连线。
            //
            // 两个字段都写是刻意的：`parentNodeId` 仍然是"这个节点是从谁身上长出来的"这一 UI 事实
            // （降级回 v2.11.x 时血缘还在），连线才是参与生成的那份真相。迁移函数会判重，不会因此
            // 每次打开画布都多一条。
            for parentNodeId in Set(parentNodeIds + [parentNodeId].compactMap { $0 }).sorted()
                where nodes.contains(where: { $0.id == parentNodeId }) {
                if CanvasEdgeGraph.canConnect(from: parentNodeId,
                                              to: node.id,
                                              edges: edges,
                                              nodeIds: Set(nodes.map(\.id))) == nil {
                    edges.append(CanvasEdge(fromNodeId: parentNodeId, toNodeId: node.id, role: .auto))
                }
            }
        }
        return .placed(node: node, name: name)
    }

    /// 某个节点在画布上的即时快照（按 id）。
    @discardableResult
    func groupNodes(_ ids: Set<String>, name: String = "新建组", allowSingle: Bool = false) -> CanvasNodeGroup? {
        let ids = expandedNodeIDs(ids)
        let members = nodes.filter { ids.contains($0.id) }.map(\.id)
        guard members.count >= (allowSingle ? 1 : 2), members.count <= 50,
              flushTextDocuments?() != false else { return nil }
        if let existing = groups.first(where: { Set($0.nodeIDs) == Set(members) }) {
            selectGroup(existing.id); return existing
        }
        let touched = groups.filter { !ids.isDisjoint(with: $0.nodeIDs) }
        var group = touched.count == 1 ? touched[0] : CanvasNodeGroup(name: name, nodeIDs: members, createdBy: .client)
        if touched.count == 1 { group.nodeIDs = Array(Set(group.nodeIDs + members)).sorted() }
        guard group.nodeIDs.count <= 50 else { return nil }
        let descendantIDs = groupMemberIDs(group.id).union(group.nodeIDs)
        group.containerFrame = CanvasGroupGeometry.enclosing(layoutNodes(descendantIDs))
        group.layoutType = group.layoutType ?? .horizontal
        group.autoLayoutEnabled = false
        commit(.groupNodes, detail: "\(name) · \(members.count) 个节点") {
            assignGroup(group)
            selectGroup(group.id)
        }
        return group
    }

    private func assignGroup(_ group: CanvasNodeGroup) {
        let members = Set(group.nodeIDs)
        var nextGroups = groups
        for index in nextGroups.indices { nextGroups[index].nodeIDs.removeAll { members.contains($0) } }
        nextGroups.removeAll { $0.id == group.id }
        nextGroups.append(group)
        groups = nextGroups
        for index in piles.indices where Set(piles[index].memberIDs).isSubset(of: members) {
            piles[index].groupID = group.id
        }
    }

    var piledMemberIDs: Set<String> { Set(piles.flatMap(\.memberIDs)) }
    var visibleEntityIDs: Set<String> {
        Set(nodes.map(\.id)).subtracting(piledMemberIDs).union(piles.map(\.id))
    }
    var selectedPile: CanvasPile? {
        guard selectedNodeIds.count == 1 else { return nil }
        return piles.first { selectedNodeIds.contains($0.id) }
    }
    func pile(containing id: String) -> CanvasPile? { piles.first { $0.memberIDs.contains(id) } }
    func expandedNodeIDs(_ ids: Set<String>) -> Set<String> {
        var result = ids.intersection(Set(nodes.map(\.id)))
        for pile in piles where ids.contains(pile.id) { result.formUnion(pile.memberIDs) }
        return result
    }

    /// Geometry-only copies use a real top member's ID so layout engines do not
    /// need synthetic slot references. They are never persisted as nodes.
    func layoutNodes(_ ids: Set<String>) -> [CanvasNode] {
        let expanded = expandedNodeIDs(ids)
        var result = nodes.filter { expanded.contains($0.id) && !piledMemberIDs.contains($0.id) }
        for pile in piles where ids.contains(pile.id) || Set(pile.memberIDs).isSubset(of: expanded) {
            guard var proxy = node(id: pile.memberIDs.last ?? "") else { continue }
            let frame = CanvasPileGeometry.frame(pile, nodes: nodes)
            proxy.setFrameOrigin(frame.origin); proxy.width = frame.width; proxy.height = frame.height
            result.append(proxy)
        }
        return result
    }

    private var layoutEdges: [CanvasEdge] {
        interactionEdges.compactMap { edge in
            var projected = edge
            projected.fromNodeId = pile(containing: edge.fromNodeId)?.memberIDs.last ?? edge.fromNodeId
            projected.toNodeId = pile(containing: edge.toNodeId)?.memberIDs.last ?? edge.toNodeId
            return projected.fromNodeId == projected.toNodeId ? nil : projected
        }
    }

    private func applyLayoutOrigins(_ origins: [String: CGPoint]) {
        for index in piles.indices {
            if let top = piles[index].memberIDs.last, let origin = origins[top] {
                piles[index].x = origin.x; piles[index].y = origin.y
            }
        }
        let hidden = piledMemberIDs
        for index in nodes.indices where !hidden.contains(nodes[index].id) {
            if let origin = origins[nodes[index].id], origin != nodes[index].frame.origin {
                nodes[index].setFrameOrigin(origin)
            }
        }
    }

    @discardableResult
    func createPile(_ ids: Set<String>) -> CanvasPile? {
        // Stable paint/document order, rather than Set iteration order.
        let ordered = nodes.filter { ids.contains($0.id) }.map(\.id)
            + piles.filter { ids.contains($0.id) }.map(\.id)
        guard flushTextDocuments?() != false,
              let pile = CanvasPileGeometry.creation(sourceIDs: ordered, nodes: nodes, piles: piles, groups: groups)
        else { return nil }
        commit(.pileNodes, detail: "堆叠 · \(pile.memberIDs.count) 个节点") {
            piles.removeAll { ids.contains($0.id) }
            piles.append(pile)
            // Different parents detach; a shared parent is retained.
            for index in groups.indices where groups[index].id != pile.groupID {
                groups[index].nodeIDs.removeAll { pile.memberIDs.contains($0) }
            }
            selectedGroupID = nil; selectedEdgeId = nil; selectedNodeIds = [pile.id]
        }
        return pile
    }

    func unpile(_ id: String) {
        guard let pile = piles.first(where: { $0.id == id }) else { return }
        let origins = CanvasPileGeometry.unstackOrigins(pile, nodes: nodes)
        commit(.pileNodes, detail: "展开堆叠 · \(pile.memberIDs.count) 个节点") {
            for index in nodes.indices {
                if let origin = origins[nodes[index].id] { nodes[index].setFrameOrigin(origin) }
            }
            piles.removeAll { $0.id == id }
            for index in groups.indices { groups[index].nodeIDs.removeAll { pile.memberIDs.contains($0) } }
            selectedGroupID = nil; selectedNodeIds = Set(pile.memberIDs)
        }
    }

    func movePileMemberToTop(_ pileID: String, memberID: String) {
        guard let index = piles.firstIndex(where: { $0.id == pileID }),
              piles[index].memberIDs.contains(memberID), piles[index].memberIDs.last != memberID else { return }
        commit(.pileNodes, detail: "成员置顶") {
            piles[index].memberIDs.removeAll { $0 == memberID }
            piles[index].memberIDs.append(memberID)
        }
    }

    func extractPileMember(_ pileID: String, memberID: String, at origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite,
              let index = piles.firstIndex(where: { $0.id == pileID }),
              piles[index].memberIDs.contains(memberID),
              let member = nodes.firstIndex(where: { $0.id == memberID }) else { return }
        let center = CanvasPileGeometry.frame(piles[index], nodes: nodes)
        commit(.pileNodes, detail: "抽出成员") {
            nodes[member].setFrameOrigin(origin)
            piles[index].memberIDs.removeAll { $0 == memberID }
            if piles[index].memberIDs.count < 2 {
                for i in nodes.indices where piles[index].memberIDs.contains(nodes[i].id) {
                    nodes[i].setFrameOrigin(CGPoint(x: center.midX - nodes[i].width / 2,
                                                   y: center.midY - nodes[i].height / 2))
                }
                piles.remove(at: index)
            } else {
                let size = CanvasPileGeometry.frame(piles[index], nodes: nodes).size
                piles[index].x = center.midX - size.width / 2
                piles[index].y = center.midY - size.height / 2
            }
            for i in groups.indices { groups[i].nodeIDs.removeAll { $0 == memberID } }
            selectedGroupID = nil; selectedNodeIds = [memberID]
        }
    }

    /// CGe/EGe append incoming members on top and preserve the target's center.
    @discardableResult
    func addToPile(_ id: String, entityIDs: Set<String>) -> Bool {
        guard let index = piles.firstIndex(where: { $0.id == id }), !entityIDs.contains(id) else { return false }
        let old = piles[index], incoming = expandedNodeIDs(entityIDs)
        let ordered = nodes.filter { entityIDs.contains($0.id) }.map(\.id)
            + piles.filter { entityIDs.contains($0.id) }.flatMap(\.memberIDs)
        var seen = Set(old.memberIDs)
        let newIDs = ordered.filter { seen.insert($0).inserted }
        guard !newIDs.isEmpty, old.memberIDs.count + newIDs.count <= 50,
              newIDs.allSatisfy({ memberID in
                  guard let node = node(id: memberID), CanvasPileGeometry.isEligible(node) else { return false }
                  return pile(containing: memberID).map { entityIDs.contains($0.id) } ?? true
              }) else { return false }
        let center = CanvasPileGeometry.frame(old, nodes: nodes)
        commit(.pileNodes, detail: "合入堆叠 · \(newIDs.count) 个节点") {
            piles[index].memberIDs += newIDs
            let size = CanvasPileGeometry.frame(piles[index], nodes: nodes).size
            piles[index].x = center.midX - size.width / 2; piles[index].y = center.midY - size.height / 2
            piles.removeAll { entityIDs.contains($0.id) }
            for i in groups.indices where groups[i].id != old.groupID {
                groups[i].nodeIDs.removeAll { incoming.contains($0) }
            }
            if let parent = old.groupID, let group = groups.firstIndex(where: { $0.id == parent }) {
                groups[group].nodeIDs += newIDs.filter { !groups[group].nodeIDs.contains($0) }
            }
            selectedGroupID = nil; selectedNodeIds = [id]
        }
        return true
    }

    func movePile(_ id: String, by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite, delta != .zero,
              let index = piles.firstIndex(where: { $0.id == id }) else { return }
        commit(.moveNode, detail: "移动堆叠") {
            piles[index].x += delta.width; piles[index].y += delta.height
            if let parent = piles[index].groupID,
               let group = groups.first(where: { $0.id == parent }),
               let frame = CanvasGroupGeometry.frame(group, nodes: nodes),
               CanvasGroupGeometry.completelyOutside(CanvasPileGeometry.frame(piles[index], nodes: nodes), container: frame) {
                let ids = Set(piles[index].memberIDs)
                for i in groups.indices where groups[i].id == parent { groups[i].nodeIDs.removeAll { ids.contains($0) } }
                piles[index].groupID = nil
            }
        }
    }

    func ungroupNodes(_ ids: Set<String>) {
        let ids = expandedNodeIDs(ids)
        if let id = selectedGroupID, groupMemberIDs(id) == ids {
            ungroupGroup(id); return
        }
        guard groups.contains(where: { !ids.isDisjoint(with: $0.nodeIDs) }) else { return }
        commit(.groupNodes, detail: "解除编组") {
            let removed = Set(groups.filter { !ids.isDisjoint(with: $0.nodeIDs) }.map(\.id))
            groups = CanvasGroupHierarchy.dissolving(removed, groups: groups)
            selectedGroupID = nil
        }
    }

    func ungroupGroup(_ id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        commit(.groupNodes, detail: "解除编组") {
            groups = CanvasGroupHierarchy.dissolving([id], groups: groups)
            selectedGroupID = nil
        }
    }

    func groupMemberIDs(_ id: String) -> Set<String> {
        CanvasGroupHierarchy.memberIDs(id, groups: groups)
    }

    func groupDragEntityIDs(_ id: String) -> Set<String> {
        let containers = CanvasGroupHierarchy.subtreeIDs(id, groups: groups)
        return groupMemberIDs(id).union(piles.filter { $0.groupID.map(containers.contains) == true }.map(\.id))
    }

    func renameGroup(_ id: String, name: String) {
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].name != name else { return }
        commit(.groupNodes, detail: name) { groups[index].name = name }
    }

    func selectGroup(_ id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        let members = groupMemberIDs(id)
        if selectedNodeIds != members { selectedNodeIds = members }
        if selectedGroupID != id { selectedGroupID = id }
        if selectedEdgeId != nil { selectedEdgeId = nil }
    }

    func setGroupColor(_ id: String, color: CanvasGroupColor?) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        commit(.groupNodes, detail: "编组背景色") { groups[index].color = color }
    }

    func attachGroupWorkflow(_ id: String, skillID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        commit(.groupNodes, detail: "关联编组工作流") { groups[index].workflowSkillID = skillID }
    }

    func resizeGroup(_ id: String, frame: CGRect) {
        guard CanvasGroupGeometry.isValid(frame), let index = groups.firstIndex(where: { $0.id == id }) else { return }
        if CanvasGroupHierarchy.hasHierarchy(id, groups: groups) || groups[index].provenance == .server {
            do {
                let next = try CanvasGroupHierarchy.resizing(id, to: frame, in: gatewayDocument())
                commit(.groupNodes, detail: "调整多层编组边界") {
                    nodes = next.nodes; groups = next.groups; piles = next.piles
                    freezeGroupAutoLayout(id)
                }
            } catch { agentHistoryError = error.localizedDescription }
            return
        }
        commit(.groupNodes, detail: "调整编组边界") { groups[index].containerFrame = frame }
    }

    func moveGroup(_ id: String, by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite, delta != .zero,
              let group = groups.first(where: { $0.id == id }) else { return }
        do {
            let next = try CanvasGroupHierarchy.moving(id, by: delta, in: gatewayDocument())
            commit(.moveNode, detail: "移动编组 · \(group.name)") {
                nodes = next.nodes; groups = next.groups; piles = next.piles
                freezeGroupAutoLayout(id)
            }
        } catch { agentHistoryError = error.localizedDescription }
    }

    func arrangeGroup(_ id: String, layout: CanvasGroupLayoutType) {
        do { try arrangeGroupChecked(id, layout: layout) }
        catch { agentHistoryError = error.localizedDescription }
    }

    private func arrangeGroupChecked(_ id: String, layout: CanvasGroupLayoutType) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              let frame = CanvasGroupGeometry.frame(groups[index], nodes: nodes) else {
            throw AgentOperationError("编组没有可布局的容器边界。")
        }
        if CanvasGroupHierarchy.hasHierarchy(id, groups: groups) {
            var next = try CanvasServerGroupLayout.arranging(id, layout: layout, in: gatewayDocument())
            let previous = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            for index in next.nodes.indices {
                if let before = previous[next.nodes[index].id], before.frame.origin == next.nodes[index].frame.origin {
                    next.nodes[index].updatedAt = before.updatedAt
                }
            }
            commit(.moveNode, detail: "多层编组布局") {
                nodes = next.nodes; groups = next.groups; piles = next.piles
                freezeGroupAutoLayout(id)
            }
            return
        }
        let members = layoutNodes(Set(groups[index].nodeIDs))
        let result: (origins: [String: CGPoint], frame: CGRect)
        if layout == .grid {
            result = CanvasGroupGeometry.grid(nodes: members, at: frame.origin)
        } else {
            guard let layout = CanvasDagreLayout.layout(nodes: members, edges: layoutEdges, at: frame.origin) else {
                throw AgentOperationError("横向布局引擎加载失败，未回写编组。")
            }
            result = (layout.origins, layout.frame)
        }
        guard CanvasGroupHierarchy.validWorldFrame(result.frame),
              members.allSatisfy({ node in
                  guard let origin = result.origins[node.id] else { return false }
                  return CanvasGroupHierarchy.validWorldFrame(CGRect(origin: origin, size: node.frame.size))
              }) else { throw AgentOperationError("编组布局结果不完整或超出坐标上限。") }
        commit(.moveNode, detail: layout == .grid ? "方格布局" : "横向布局") {
            applyLayoutOrigins(result.origins)
            groups[index].layoutType = layout
            groups[index].containerFrame = result.frame
            freezeGroupAutoLayout(id)
        }
    }

    private func freezeGroupAutoLayout(_ id: String) {
        var affected = CanvasGroupHierarchy.subtreeIDs(id, groups: groups)
        var parent = groups.first(where: { $0.id == id })?.parentGroupID
        while let value = parent, affected.insert(value).inserted {
            parent = groups.first(where: { $0.id == value })?.parentGroupID
        }
        for i in groups.indices where affected.contains(groups[i].id) && groups[i].provenance == .server {
            groups[i].autoLayoutEnabled = false
        }
    }

    /// Actual rendered node sizes, scoped to the active project. No fallback to
    /// default model sizes and no layout writes while a pointer gesture is live.
    func updateGroupMeasurements(_ measurements: [String: CGSize], projectID: String, allowLayout: Bool) {
        guard projectID == activeProjectId else { return }
        groupMeasurementProjectID = projectID
        groupMeasurements = measurements
        if allowLayout { reconcileMeasuredServerGroups() }
    }

    func reconcileMeasuredServerGroups() {
        guard groupMeasurementProjectID == activeProjectId, !documentLoadFailed,
              groups.contains(where: { $0.provenance == .server && $0.autoLayoutEnabled != false }) else { return }
        do {
            let result = try CanvasServerGroupLayout.reconcile(gatewayDocument(), measurements: groupMeasurements,
                suppressedGroupIDs: suppressedServerGroupLayouts)
            if serverGroupLayoutStates != result.states { serverGroupLayoutStates = result.states }
            guard !result.appliedGroupIDs.isEmpty else { return }
            commit(.groupNodes, detail: "服务端编组布局 · " + result.appliedGroupIDs.joined(separator: "、")) {
                nodes = result.document.nodes
                groups = result.document.groups
                piles = result.document.piles
            }
        } catch { agentHistoryError = error.localizedDescription }
    }

    /// Membership changes share the movement transaction; nodes and edges keep
    /// world coordinates. Keep a frozen frame when upgrading an old document.
    private func updateGroupMembership(movedIDs: Set<String>, frames: [String: CGRect]) {
        for group in groups where !movedIDs.isDisjoint(with: group.nodeIDs) { freezeGroupAutoLayout(group.id) }
        for node in nodes where movedIDs.contains(node.id) {
            if let owner = groups.firstIndex(where: { $0.nodeIDs.contains(node.id) }),
               let frame = frames[groups[owner].id] {
                if !CanvasGroupGeometry.completelyOutside(node.frame, container: frame) { continue }
                groups[owner].nodeIDs.removeAll { $0 == node.id }
                continue
            }
            let candidate = groups.indices.filter {
                groups[$0].nodeIDs.count < 50 && frames[groups[$0].id]?.contains(node.frame) == true
            }.min {
                let a = frames[groups[$0].id]!, b = frames[groups[$1].id]!
                return a.width * a.height < b.width * b.height
            }
            if let candidate {
                groups[candidate].nodeIDs.append(node.id)
                freezeGroupAutoLayout(groups[candidate].id)
            }
        }
        for i in groups.indices { groups[i].containerFrame = frames[groups[i].id] ?? groups[i].containerFrame }
    }

    /// One transaction for a whole library drag: deduplicate nodes, import real
    /// connections, arrange and group. Existing node configuration is untouched.
    @discardableResult
    func placeSlotGroup(pageID: String, groupID: String, slots: [Int], name: String,
                        edges imported: [CanvasEdge], at point: CGPoint) -> CanvasNodeGroup? {
        let slots = Array(Set(slots.filter { $0 > 0 })).sorted()
        guard !slots.isEmpty, flushTextDocuments?() != false else { return nil }
        let ids = Set(slots.map { CanvasNode.makeId(groupId: groupID, slot: $0) })
        let previousGroup = groups.first { Set($0.nodeIDs) == ids }
        var group = previousGroup ?? CanvasNodeGroup(name: name, nodeIDs: slots.map { CanvasNode.makeId(groupId: groupID, slot: $0) }, createdBy: .client)
        commit(.addNode, detail: "\(name) · \(slots.count) 个槽位") {
            var nextNodes = nodes
            let existingIDs = Set(nextNodes.map(\.id))
            for slot in slots where !existingIDs.contains(CanvasNode.makeId(groupId: groupID, slot: slot)) {
                nextNodes.append(CanvasNode(pageId: pageID, groupId: groupID, slot: slot, x: point.x, y: point.y))
            }
            let allowedEdges = imported.filter { ids.contains($0.fromNodeId) && ids.contains($0.toNodeId) }
            let nextEdges = CanvasEdgeGraph.normalized(edges + allowedEdges, nodeIds: Set(nextNodes.map(\.id)),
                                                      preservingImageCycles: nextNodes)
            let selected = nextNodes.filter { ids.contains($0.id) }
            let origins = CanvasGroupLayout.origins(nodes: selected, edges: nextEdges, at: point)
            for index in nextNodes.indices {
                if let origin = origins[nextNodes[index].id] { nextNodes[index].setFrameOrigin(origin) }
            }
            group.containerFrame = CanvasGroupGeometry.enclosing(nextNodes.filter { ids.contains($0.id) })
            group.layoutType = group.layoutType ?? .horizontal
            nodes = nextNodes
            if edges != nextEdges { edges = nextEdges }
            assignGroup(group)
            selectGroup(group.id)
        }
        return group
    }

    func autoArrange(_ ids: Set<String>) {
        if let id = selectedGroupID, groupMemberIDs(id) == expandedNodeIDs(ids),
           let group = groups.first(where: { $0.id == id }) {
            arrangeGroup(id, layout: group.layoutType ?? .horizontal); return
        }
        if let group = groups.first(where: { Set($0.nodeIDs) == expandedNodeIDs(ids) }) {
            arrangeGroup(group.id, layout: group.layoutType ?? .horizontal); return
        }
        let selected = layoutNodes(ids)
        guard selected.count > 1, let left = selected.map(\.x).min(), let top = selected.map(\.y).min() else { return }
        let origins = CanvasGroupLayout.origins(nodes: selected, edges: layoutEdges, at: CGPoint(x: left, y: top))
        commit(.moveNode, detail: "自动排布 \(selected.count) 个节点") {
            applyLayoutOrigins(origins)
        }
    }

    /// A single native transaction. Whole child groups and piles remain atomic;
    /// partial group selections keep membership and expand their existing frame.
    /// Call inside performAgentEdit so layout failures also roll back history.
    func layoutAgentNodes(_ ids: Set<String>, layout: CanvasGroupLayoutType) throws {
        guard ids.count >= 2, ids.count <= 50, ids.isSubset(of: Set(nodes.map(\.id))) else {
            throw AgentOperationError("请选择2至50个现有节点。")
        }
        try CanvasGroupHierarchy.validate(groups, nodeIDs: Set(nodes.map(\.id)))
        guard nodes.filter({ ids.contains($0.id) }).allSatisfy({ CanvasGroupHierarchy.validWorldFrame($0.frame) }) else {
            throw AgentOperationError("节点尺寸尚不可用于排布。")
        }
        for pile in piles where !ids.isDisjoint(with: pile.memberIDs) {
            guard Set(pile.memberIDs).isSubset(of: ids) else {
                throw AgentOperationError("堆叠需要选择全部成员，未移动隐藏节点。")
            }
        }
        if let group = CanvasGroupHierarchy.parentFirst(groups).first(where: { groupMemberIDs($0.id) == ids }) {
            try arrangeGroupChecked(group.id, layout: layout)
            let next = try enclosingLayoutContainers(gatewayDocument(), affectedIDs: ids,
                preserving: CanvasGroupHierarchy.subtreeIDs(group.id, groups: groups))
            commit(.moveNode, detail: "保留父编组边界") { groups = next.groups }
            return
        }

        var units: [CanvasNode] = [], groupUnits: [String: String] = [:]
        var projected: [String: String] = [:], covered = Set<String>()
        for group in CanvasGroupHierarchy.parentFirst(groups) {
            let members = groupMemberIDs(group.id)
            guard !members.isEmpty, members.isSubset(of: ids), members.isDisjoint(with: covered) else { continue }
            guard let frame = CanvasGroupGeometry.frame(group, nodes: nodes),
                  var proxy = nodes.first(where: { members.contains($0.id) }) else {
                throw AgentOperationError("子编组缺少真实布局边界。")
            }
            // A pile cannot be split between a group unit and an outside unit.
            guard !piles.contains(where: {
                !members.isDisjoint(with: $0.memberIDs) && !Set($0.memberIDs).isSubset(of: members)
            }) else { throw AgentOperationError("堆叠横跨编组，无法安全排布。") }
            let containers = CanvasGroupHierarchy.subtreeIDs(group.id, groups: groups)
            guard !piles.contains(where: {
                $0.groupID.map(containers.contains) == true && !Set($0.memberIDs).isSubset(of: members)
            }) else { throw AgentOperationError("编组堆叠归属不一致，未排布。") }
            proxy.setFrameOrigin(frame.origin); proxy.width = frame.width; proxy.height = frame.height
            units.append(proxy); groupUnits[proxy.id] = group.id
            for member in members { projected[member] = proxy.id }
            covered.formUnion(members)
        }
        let individualIDs = ids.subtracting(covered)
        units += layoutNodes(individualIDs)
        for id in individualIDs { projected[id] = pile(containing: id)?.memberIDs.last ?? id }
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        units.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        guard units.allSatisfy({ CanvasGroupHierarchy.validWorldFrame($0.frame) }) else {
            throw AgentOperationError("节点或容器尺寸尚不可用于排布。")
        }
        guard units.count > 1, let left = units.map(\.x).min(), let top = units.map(\.y).min() else { return }
        let anchor = CGPoint(x: left - 100, y: top - 100)
        let origins: [String: CGPoint]
        if layout == .grid {
            let placed = CanvasGroupGeometry.grid(nodes: units, at: anchor).origins
            guard let minX = placed.values.map(\.x).min(), let minY = placed.values.map(\.y).min() else {
                throw AgentOperationError("方格布局没有返回节点位置。")
            }
            origins = placed.mapValues { CGPoint(x: $0.x + left - minX, y: $0.y + top - minY) }
        } else {
            let projectedEdges = interactionEdges.compactMap { edge -> CanvasEdge? in
                guard let from = projected[edge.fromNodeId], let to = projected[edge.toNodeId], from != to else { return nil }
                var value = edge; value.fromNodeId = from; value.toNodeId = to
                return value
            }
            guard let result = CanvasDagreLayout.layout(nodes: units, edges: projectedEdges, at: anchor) else {
                throw AgentOperationError("横向布局引擎加载失败，未移动节点。")
            }
            origins = result.origins
        }
        var next = gatewayDocument()
        for unit in units {
            guard let origin = origins[unit.id],
                  CanvasGroupHierarchy.validWorldFrame(CGRect(origin: origin, size: unit.frame.size)) else {
                throw AgentOperationError("布局结果不完整或超出坐标上限。")
            }
            if let groupID = groupUnits[unit.id] {
                next = try CanvasGroupHierarchy.moving(groupID,
                    by: CGSize(width: origin.x - unit.x, height: origin.y - unit.y), in: next)
            } else if let index = next.piles.firstIndex(where: { $0.memberIDs.last == unit.id }) {
                next.piles[index].x = origin.x; next.piles[index].y = origin.y
            } else if let index = next.nodes.firstIndex(where: { $0.id == unit.id }),
                      next.nodes[index].frame.origin != origin {
                next.nodes[index].setFrameOrigin(origin)
            }
        }
        let preserved = groupUnits.values.reduce(into: Set<String>()) {
            $0.formUnion(CanvasGroupHierarchy.subtreeIDs($1, groups: next.groups))
        }
        next = try enclosingLayoutContainers(next, affectedIDs: ids, preserving: preserved)
        guard next.nodes.allSatisfy({ CanvasGroupHierarchy.validWorldFrame($0.frame) }) else {
            throw AgentOperationError("布局后的节点坐标非法。")
        }
        commit(.moveNode, detail: layout == .grid ? "方格布局" : "横向布局") {
            nodes = next.nodes; groups = next.groups; piles = next.piles
        }
    }

    private func enclosingLayoutContainers(_ document: CanvasDocument, affectedIDs ids: Set<String>,
                                           preserving: Set<String>) throws -> CanvasDocument {
        var next = document
        // Preserve owners and existing padding, including ancestors. Expanding
        // from the old frame rather than applying padding repeatedly is stable.
        for group in CanvasGroupHierarchy.parentFirst(next.groups).reversed() {
            let members = CanvasGroupHierarchy.memberIDs(group.id, groups: next.groups)
            guard !preserving.contains(group.id), !members.isDisjoint(with: ids),
                  let index = next.groups.firstIndex(where: { $0.id == group.id }) else { continue }
            var bounds = CanvasGroupGeometry.frame(next.groups[index], nodes: next.nodes)
            for node in next.nodes where group.nodeIDs.contains(node.id) && !piledMemberIDs.contains(node.id) {
                bounds = bounds.map { $0.union(node.frame.insetBy(dx: -20, dy: -20)) } ?? node.frame.insetBy(dx: -20, dy: -20)
            }
            for pile in next.piles where pile.groupID == group.id {
                let frame = CanvasPileGeometry.frame(pile, nodes: next.nodes).insetBy(dx: -20, dy: -20)
                bounds = bounds.map { $0.union(frame) } ?? frame
            }
            for child in next.groups where child.parentGroupID == group.id {
                if let frame = child.containerFrame { bounds = bounds.map { $0.union(frame) } ?? frame }
            }
            next.groups[index].containerFrame = bounds
            if next.groups[index].provenance == .server { next.groups[index].autoLayoutEnabled = false }
        }
        try CanvasGroupHierarchy.validate(next.groups, nodeIDs: Set(next.nodes.map(\.id)))
        return next
    }

    func resetNodeSizes(_ ids: Set<String>) {
        commit(.styleNode, detail: "重置节点尺寸") {
            for index in nodes.indices where ids.contains(nodes[index].id) {
                let node = nodes[index]
                let size: CGSize
                if node.kind.isMediaNode, node.width > 0, node.height > 0 {
                    let factor = CanvasNodeSizing.defaultShortSide / min(node.width, node.height)
                    size = CGSize(width: node.width * factor, height: node.height * factor)
                } else { size = CanvasNodeSizing.initialSize(for: node.kind) }
                nodes[index].width = size.width
                nodes[index].height = size.height
            }
        }
    }

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
        let frames = Dictionary(uniqueKeysWithValues: groups.compactMap { group in
            CanvasGroupGeometry.frame(group, nodes: nodes).map { (group.id, $0) }
        })
        commit(.moveNode, detail: title) {
            nodes[idx].setFrameOrigin(snapped)
            updateGroupMembership(movedIDs: [id], frames: frames)
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
    ///
    /// ## ★ v2.16.0：**取消网格吸附**
    ///
    /// 原来这里对 delta 做 `snapScalar(step: snapStep)`。它是 ClipSlots 画布"不丝滑"最直接的一个
    /// 来源，而且是双重的：
    ///
    /// 1. **拖拽过程中预览用的是原始位移**（`CanvasWorkspaceView.dragDelta` 没有吸附），
    ///    提交时才吸附 —— 于是每次松手，卡片都会**往回跳**最多半格。用户的手已经把卡片放在了
    ///    他想要的位置，屏幕上却在最后一刻挪了一下。这不是"整齐"，这是"不听话"。
    /// 2. 即使把预览也改成吸附（另一种自洽方案），拖动就会变成逐格跳 —— 实测 TapNow 是**连续**的，
    ///    它的卡片左边缘落在 16pt 网格的非整数倍上，根本没有吸附这回事。
    ///
    /// v2.16.2：这 0.5pt 也不能是**画布空间固定 0.5pt**。在 8x 放大时，0.5 canvas pt
    /// 会变成 4 screen pt 的跳格，TapNow 那种像素级微调感就没了。现在按当前 zoom 换算成
    /// "约 0.5 screen pt" 的落盘精度：足够吞掉浮点尾巴，但放大后仍然跟手。
    ///
    /// 吸附并没有从项目里消失：**新建节点**仍然走 `CanvasGeometry.snap`（见 `placeSlot`）。
    /// 那里是对的 —— 算出来的落点本来就没有"用户的手"可以尊重，对齐让批量新建看起来整齐。
    /// 区别在于：吸附该服务于"系统自己决定的位置"，而不该覆盖"用户亲手指定的位置"。
    func moveNodes(ids: Set<String>, by rawDelta: CGSize) {
        guard rawDelta.width.isFinite, rawDelta.height.isFinite else { return }
        if ids.count == 1, let id = ids.first, piles.contains(where: { $0.id == id }) {
            movePile(id, by: rawDelta); return
        }
        if let id = selectedGroupID, groupMemberIDs(id) == ids {
            moveGroup(id, by: rawDelta); return
        }
        guard !ids.isEmpty else { return }
        let step = CanvasStore.dragPersistenceStep(forZoom: zoom)
        let delta = CGSize(width: CanvasStore.roundDragDelta(rawDelta.width, step: step),
                           height: CanvasStore.roundDragDelta(rawDelta.height, step: step))
        guard delta.width != 0 || delta.height != 0 else { return }
        let moved = nodes.filter { ids.contains($0.id) && !piledMemberIDs.contains($0.id) }
        let movedPiles = piles.filter { ids.contains($0.id) }
        guard !moved.isEmpty || !movedPiles.isEmpty else { return }
        let detail = moved.count == 1 && movedPiles.isEmpty ? nodeTitle(moved[0])
            : "\(moved.count + movedPiles.count) 个对象"
        let frames = Dictionary(uniqueKeysWithValues: groups.compactMap { group in
            CanvasGroupGeometry.frame(group, nodes: nodes).map { (group.id, $0) }
        })
        commit(.moveNode, detail: detail) {
            for idx in nodes.indices where moved.contains(where: { $0.id == nodes[idx].id }) {
                let origin = nodes[idx].frame.origin
                nodes[idx].setFrameOrigin(CGPoint(x: origin.x + delta.width,
                                                  y: origin.y + delta.height))
            }
            for index in piles.indices where ids.contains(piles[index].id) {
                piles[index].x += delta.width; piles[index].y += delta.height
                if let parent = piles[index].groupID, let frame = frames[parent],
                   CanvasGroupGeometry.completelyOutside(CanvasPileGeometry.frame(piles[index], nodes: nodes), container: frame) {
                    let members = Set(piles[index].memberIDs)
                    for group in groups.indices where groups[group].id == parent {
                        groups[group].nodeIDs.removeAll { members.contains($0) }
                    }
                    piles[index].groupID = nil
                }
            }
            updateGroupMembership(movedIDs: Set(moved.map(\.id)), frames: frames)
        }
    }

    func removeNodes(ids: Set<String>) {
        let ids = expandedNodeIDs(ids)
        guard !ids.isEmpty else { return }
        let removed = nodes.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        generationTickets = generationTickets.filter {
            $0.value.projectId != activeProjectId || !ids.contains($0.value.nodeId)
        }
        // 一次删多个只记一条，写成「3 个节点」而不是刷 3 行 —— 框选批量删是常态操作。
        let detail = removed.count == 1 ? nodeTitle(removed[0]) : "\(removed.count) 个节点"
        commit(.removeNode, detail: detail) {
            for pile in piles {
                let remaining = pile.memberIDs.filter { !ids.contains($0) }
                if remaining.count == 1, let last = nodes.firstIndex(where: { $0.id == remaining[0] }) {
                    let frame = CanvasPileGeometry.frame(pile, nodes: nodes)
                    nodes[last].setFrameOrigin(CGPoint(x: frame.midX - nodes[last].width / 2,
                                                      y: frame.midY - nodes[last].height / 2))
                }
            }
            nodes.removeAll { ids.contains($0.id) }
            for idx in nodes.indices {
                if let parent = nodes[idx].parentNodeId, ids.contains(parent) { nodes[idx].parentNodeId = nil }
            }
            selectedNodeIds.subtract(ids)
            // 连线跟着节点走。留下野线的症状是画布上有一条连到虚空的曲线，而它长得跟正常线一样 ——
            // 取入参时那条线又什么都拿不到，于是"生成结果莫名少了一张参考图"。
            edges = CanvasEdgeGraph.removing(nodeIds: ids, from: edges)
            nodes = CanvasEdgeGraph.reconcilingDraftReferences(nodes: nodes, edges: edges)
            if let selected = selectedEdgeId, !edges.contains(where: { $0.id == selected }) {
                selectedEdgeId = nil
            }
        }
    }

    /// 删除全部选中节点（Delete / Backspace）。返回删掉的数量，便于调用方决定要不要提示。
    @discardableResult
    func removeSelected() -> Int {
        let ids = expandedNodeIDs(selectedNodeIds)
        let count = nodes.filter { ids.contains($0.id) }.count
        removeNodes(ids: ids)
        return count
    }

    func updateNode(id: String, _ mutate: (inout CanvasNode) -> Void) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        let owner = piles.firstIndex { $0.memberIDs.contains(id) }
        let pileFrame = owner.map { CanvasPileGeometry.frame(piles[$0], nodes: nodes) }
        var next = nodes[idx]
        mutate(&next)
        guard next != nodes[idx] else { return }
        next.updatedAt = Date()
        nodes[idx] = next
        if let owner, let old = pileFrame {
            let size = CanvasPileGeometry.frame(piles[owner], nodes: nodes).size
            piles[owner].x = old.midX - size.width / 2; piles[owner].y = old.midY - size.height / 2
        }
        scheduleSave()
    }

    func hasActiveGeneration(_ node: CanvasNode) -> Bool {
        generationTickets.values.contains { $0.matches(node, projectId: activeProjectId) }
    }

    func beginGeneration(_ node: CanvasNode, recovering: Bool = false, restarting: Bool = false) -> CanvasGenerationTicket? {
        guard let current = self.node(id: node.id), current.createdAt == node.createdAt,
              current.canGenerate || current.kind == .text,
              recovering || restarting || !current.needsGenerationRecovery,
              !generationTickets.values.contains(where: { $0.matches(current, projectId: activeProjectId) })
        else { return nil }
        let ticket = CanvasGenerationTicket(projectId: activeProjectId, node: current)
        generationTickets[ticket.token] = ticket
        updateNode(id: node.id) {
            $0.state = .running(startedAt: Date())
            if !recovering {
                $0.taskId = nil
                $0.generationTask = nil
                $0.generationRawOutput = nil
                $0.generationDiagnostic = nil
            }
        }
        return ticket
    }

    /// 非活跃项目从独立文档读取，绝不使用当前画布的同名节点。
    func generationNode(_ token: UUID) -> CanvasNode? {
        guard let ticket = generationTickets[token],
              projects.contains(where: { $0.id == ticket.projectId }) else { return nil }
        let candidates = ticket.projectId == activeProjectId ? nodes
            : (pendingDocuments[ticket.projectId] ?? storage.load(projectId: ticket.projectId)).nodes
        return candidates.first { ticket.matches($0, projectId: ticket.projectId) }
    }

    func updateGeneration(_ token: UUID, _ mutate: (inout CanvasNode) -> Void) {
        guard let ticket = generationTickets[token], generationNode(token) != nil else { return }
        if ticket.projectId == activeProjectId {
            updateNode(id: ticket.nodeId, mutate)
        } else {
            var doc = pendingDocuments[ticket.projectId] ?? storage.load(projectId: ticket.projectId)
            guard let idx = doc.nodes.firstIndex(where: { ticket.matches($0, projectId: ticket.projectId) }) else { return }
            var next = doc.nodes[idx]
            mutate(&next)
            guard next != doc.nodes[idx] else { return }
            next.updatedAt = Date()
            doc.nodes[idx] = next
            let version = retainPending(doc, projectId: ticket.projectId)
            let ok = saveQueue.sync { storage.save(doc, projectId: ticket.projectId) }
            completeSave(projectId: ticket.projectId, version: version, success: ok)
        }
    }

    func trackGeneration(_ task: Task<Void, Never>, token: UUID) {
        generationTasks[token] = task
    }

    func shouldTrackGeneration(_ token: UUID) -> Bool {
        generationNode(token) != nil && !stoppedGenerations.contains(token)
    }

    func isStoppingGeneration(_ node: CanvasNode) -> Bool {
        generationTickets.values.contains { $0.matches(node, projectId: activeProjectId) && stoppedGenerations.contains($0.token) }
    }

    func stopGeneration(_ node: CanvasNode) {
        guard let ticket = generationTickets.values.first(where: { $0.matches(node, projectId: activeProjectId) }) else { return }
        stoppedGenerations.insert(ticket.token)
        // submit 尚未返回时让它交还 taskId；取消这个过程会丢失远端身份。
        if node.kind == .text || generationNode(ticket.token)?.taskId != nil {
            generationTasks[ticket.token]?.cancel()
            updateGeneration(ticket.token) { $0.state = .idle }
            flushSave()
        }
    }

    func endGeneration(_ token: UUID) {
        if stoppedGenerations.contains(token) { updateGeneration(token) { $0.state = .idle } }
        generationTickets.removeValue(forKey: token)
        generationTasks.removeValue(forKey: token)
        stoppedGenerations.remove(token)
    }

    // MARK: - 连线（v2.12.0）

    /// 连一条线。
    ///
    /// 返回值区分"连上了"与"为什么连不上"，而不是返回 `Bool` —— 用户拖了一条线却什么都没发生时，
    /// 唯一有用的信息就是原因（是环？是重复？），调用方拿它做 toast。
    @discardableResult
    func connect(from: String, to: String, role: CanvasEdgeRole = .auto,
                 purpose: CanvasEdgePurpose? = nil) -> CanvasEdgeGraph.Rejection? {
        guard connectionPolicy.canConnect(from: from, to: to) else { return .disabled }
        let resolvedPurpose = purpose ?? node(id: to).map(CanvasEdgeGraph.defaultPurpose) ?? .generationInput
        if let rejection = CanvasEdgeGraph.canConnect(from: from, to: to, nodes: nodes, edges: edges,
                                                      purpose: resolvedPurpose, role: role) {
            return rejection
        }
        let detail = connectionDetail(from: from, to: to)
        let edge = CanvasEdge(fromNodeId: from, toNodeId: to, role: role, purpose: resolvedPurpose)
        var rejection: CanvasEdgeGraph.Rejection? = .editBlocked
        commit(.connect, detail: detail) {
            switch CanvasEdgeGraph.connecting(edge, nodes: nodes, edges: edges) {
            case .failure(let reason): rejection = reason
            case .success(let edit):
                nodes = edit.nodes
                edges = edit.edges
                selectedNodeIds = []
                selectedEdgeId = edge.id
                rejection = nil
            }
        }
        return rejection
    }

    /// 断开一条线。
    @discardableResult
    func disconnect(edgeId: String) -> Bool {
        guard let edge = edges.first(where: { $0.id == edgeId }) else { return false }
        let detail = connectionDetail(from: edge.fromNodeId, to: edge.toNodeId)
        var changed = false
        commit(.disconnect, detail: detail) {
            guard let edit = CanvasEdgeGraph.disconnecting(edgeID: edgeId, nodes: nodes, edges: edges) else { return }
            nodes = edit.nodes
            edges = edit.edges
            if selectedEdgeId == edgeId { selectedEdgeId = nil }
            changed = true
        }
        return changed
    }

    /// 改一条线的用途（首帧 / 尾帧 / 参考图 / 提示词 / 自动）。
    func setEdgeAnimated(edgeId: String, animated: Bool) {
        guard let index = edges.firstIndex(where: { $0.id == edgeId }), edges[index].animated != animated else { return }
        commit(.edgeRole, detail: animated ? "开启连线流光" : "关闭连线流光") {
            edges[index].animated = animated
        }
    }

    func setEdgeRole(edgeId: String, role: CanvasEdgeRole) {
        guard let idx = edges.firstIndex(where: { $0.id == edgeId }), edges[idx].role != role else { return }
        let edge = edges[idx]
        guard CanvasEdgeGraph.canConnect(from: edge.fromNodeId, to: edge.toNodeId, nodes: nodes,
            edges: edges.filter { $0.id != edgeId }, purpose: edge.purpose, role: role) == nil else { return }
        let detail = "\(connectionDetail(from: edges[idx].fromNodeId, to: edges[idx].toNodeId)) · \(role.displayName)"
        commit(.edgeRole, detail: detail) {
            edges[idx].role = role
        }
    }

    @discardableResult
    func setEdgePurpose(edgeId: String, purpose: CanvasEdgePurpose,
                        role: CanvasEdgeRole? = nil) -> CanvasEdgeGraph.Rejection? {
        guard var edge = edges.first(where: { $0.id == edgeId }) else { return .missingNode }
        guard edge.purpose != purpose else { return nil }
        edge.purpose = purpose
        edge.role = role ?? (purpose == .draftReference ? .auto : edge.role)
        var rejection: CanvasEdgeGraph.Rejection? = .editBlocked
        commit(.edgeRole, detail: connectionDetail(from: edge.fromNodeId, to: edge.toNodeId)) {
            guard let removed = CanvasEdgeGraph.disconnecting(edgeID: edgeId, nodes: nodes, edges: edges) else {
                rejection = .missingNode
                return
            }
            switch CanvasEdgeGraph.connecting(edge, nodes: removed.nodes, edges: removed.edges) {
            case .failure(let reason): rejection = reason
            case .success(let edit):
                nodes = edit.nodes
                edges = edit.edges
                rejection = nil
            }
        }
        return rejection
    }

    func edge(id: String) -> CanvasEdge? {
        edges.first { $0.id == id }
    }

    /// 指向某节点的入边（已按生成语义定序）。
    func incomingEdges(of nodeId: String) -> [CanvasEdge] {
        CanvasEdgeGraph.incoming(of: nodeId, edges: edges)
    }

    /// 从某节点出发的出边。
    func outgoingEdges(of nodeId: String) -> [CanvasEdge] {
        CanvasEdgeGraph.outgoing(of: nodeId, edges: edges)
    }

    /// 历史条目 / toast 用的「A → B」描述。
    private func connectionDetail(from: String, to: String) -> String {
        let source = node(id: from).map { nodeTitle($0) } ?? "节点"
        let target = node(id: to).map { nodeTitle($0) } ?? "节点"
        return "\(source) → \(target)"
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

    /// 改节点的出图参数（模型 / 比例）。
    ///
    /// 与 `updateNodeStyle` 同构：走 `commit` 进撤销栈，而不是只落盘的 `updateNode`（用后者的
    /// 症状是"改完 Cmd+Z 撤不掉"）。
    ///
    /// ★ 模型与比例**一次写**，不拆成两个方法
    ///
    /// 换模型经常要顺带把比例改掉 —— 新模型不一定认旧比例（判定在
    /// `CrateModelCatalog.resolvedRatio`）。分两次 commit 的后果是撤销栈里多出一条"用户从没做过"
    /// 的中间态：Cmd+Z 一次只退回比例、模型还留在新的，而那个组合可能压根不合法。
    ///
    /// `ratio` 允许是空串：那是"该模型不吃比例"的合法取值，提交时就不会带 `--ratio`。
    ///
    /// ★ 为什么每个视频参数都是双层可选（`Int??` / `Bool??`，v2.11.19）
    ///
    /// 这三个视频字段本身就是可选的（nil = 不传，用模型默认），所以"不改这个字段"与"把这个字段
    /// 改成 nil"是两件**都要能表达**的事。单层可选下 `duration: nil` 二义，调用方想显式清空时
    /// 只能另开一个 `clearDuration: Bool` 参数——那是把类型问题挪到参数列表里。
    ///
    /// 约定：外层 nil = 不动；内层 nil = 显式清空。
    func updateNodeProvider(id: String, provider: GenerationProviderID? = nil,
                            configuration: ByteArtistCanvasConfiguration? = nil) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        guard provider.map({ $0 != nodes[index].generationProvider }) ?? false
                || configuration.map({ $0 != nodes[index].byteArtist }) ?? false else { return }
        commit(.paramNode, detail: "生成来源与工作流") {
            if let provider { nodes[index].generationProvider = provider }
            if let configuration { nodes[index].byteArtist = configuration }
            nodes[index].updatedAt = Date()
        }
    }

    func updateNodeGeneration(id: String,
                              model: String? = nil,
                              ratio: String? = nil,
                              count: Int? = nil,
                              resolution: String? = nil,
                              duration: Int?? = nil,
                              generateAudio: Bool?? = nil) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }

        let newModel = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? nodes[idx].model
        let newRatio = ratio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? nodes[idx].ratio
        let newCount = count.map { min(4, max(1, $0)) } ?? nodes[idx].count
        let newResolution = resolution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? nodes[idx].resolution
        let newDuration = duration ?? nodes[idx].duration
        let newAudio = generateAudio ?? nodes[idx].generateAudio
        let newSize = nodes[idx].kind.producesAsset && ratio != nil
            ? CanvasNodeSizing.size(ratio: newRatio, shortSide: min(nodes[idx].width, nodes[idx].height)) : nil
        guard newModel != nodes[idx].model
                || newRatio != nodes[idx].ratio
                || newCount != nodes[idx].count
                || newResolution != nodes[idx].resolution
                || newDuration != nodes[idx].duration
                || newAudio != nodes[idx].generateAudio
                || (newSize != nil && newSize != nodes[idx].frame.size) else { return }

        // 撤销栈里的描述只取「模型 · 尺寸/分辨率」两项：时长与音频改动频繁，全塞进来会让撤销
        // 菜单变成一行读不完的长句，而用户认这条记录靠的就是前两项。
        let sizeHint = newResolution.isEmpty ? newRatio : newResolution
        let detail = sizeHint.isEmpty ? newModel : "\(newModel) · \(sizeHint)"
        commit(.paramNode, detail: detail) {
            // The card, ports and composer share the persisted frame. Keep the short side
            // and center stable when changing portrait/landscape; one undo restores both.
            if let size = newSize {
                let center = CGPoint(x: nodes[idx].frame.midX, y: nodes[idx].frame.midY)
                nodes[idx].width = size.width
                nodes[idx].height = size.height
                nodes[idx].x = center.x - size.width / 2
                nodes[idx].y = center.y - size.height / 2
            }
            nodes[idx].model = newModel
            nodes[idx].ratio = newRatio
            nodes[idx].count = newCount
            nodes[idx].resolution = newResolution
            nodes[idx].duration = newDuration
            nodes[idx].generateAudio = newAudio
            nodes[idx].updatedAt = Date()
        }
    }

    /// Configuration/results have separate slots; a single undo removes the
    /// entire newly submitted batch and its edges.
    func addGenerationResults(source: CanvasNode, slots: [Int],
                              inputIDs: [Int: [String]] = [:],
                              upstreamResults: [String: String] = [:]) -> [CanvasNode] {
        guard let live = node(id: source.id), live.createdAt == source.createdAt,
              live.kind.isMediaNode, !slots.isEmpty else { return [] }
        guard Set(slots).count == slots.count else { return [] }
        guard flushTextDocuments?() != false else { return [] }
        var occupied = nodes.map(\.frame)
        var children: [CanvasNode] = []
        let incoming = incomingEdges(of: live.id).filter {
            $0.purpose.isGenerationDependency && $0.fromNodeId != live.generationSourceID
        }
        var resultEdges: [CanvasEdge] = []
        for slot in slots {
            var child = live
            child.groupId = privateGroupId
            child.slot = slot
            guard !nodes.contains(where: { $0.id == child.id }) else { return [] }
            let point = CanvasMagnetGeometry.resultOrigin(source: live.frame, size: live.frame.size, occupied: occupied)
            child.x = point.x
            child.y = point.y
            child.mediaRole = .generation
            child.state = .idle
            child.taskId = nil
            child.generationTask = nil
            child.generationRawOutput = nil
            child.generationDiagnostic = nil
            child.draftVideoID = nil
            child.draftReference = nil
            child.seed = nil
            child.count = 1
            child.outputAttachmentIds = []
            child.inputAttachmentIds = inputIDs[slot] ?? []
            child.mediaLayoutAttachmentID = nil
            child.parentNodeId = nil
            child.generationSourceID = live.id
            child.createdAt = Date()
            child.updatedAt = child.createdAt
            children.append(child)
            occupied.append(child.frame)
            // Copy the same upstream roles; the source's own prompt arrives last.
            resultEdges += incoming.map {
                CanvasEdge(fromNodeId: upstreamResults[$0.fromNodeId] ?? $0.fromNodeId, toNodeId: child.id,
                           role: $0.role, createdAt: $0.createdAt)
            }
            // generationSourceID records batch membership. It is not a reference
            // edge: all attempts share the original inputs, not attempt one's image.
        }
        let selectedGroup = selectedGroupID
        commit(.addNode, detail: "\(children.count) 个生成结果") {
            nodes.append(contentsOf: children)
            edges.append(contentsOf: resultEdges)
            selectedEdgeId = nil
            if let selectedGroup { selectGroup(selectedGroup) }
            else { selectedNodeIds = [live.id] }
        }
        return children.filter { child in nodes.contains { $0.id == child.id && $0.createdAt == child.createdAt } }
    }

    /// Native media can widen a result after download. Push only its later
    /// generated results to the right, keeping their row and leaving manually
    /// placed nodes untouched.
    func reserveSpaceForResult(id: String) {
        guard let result = node(id: id), result.generationSourceID != nil
                || adjacentLastResultIDs[id]?.contains(id) == true else { return }
        let siblings = nodes.filter {
            $0.id != id && $0.generationSourceID != nil && $0.x > result.x && abs($0.y - result.y) < 0.5
        }.sorted { $0.x < $1.x }
        var cursor = result.frame
        for sibling in siblings {
            guard let index = nodes.firstIndex(where: { $0.id == sibling.id }) else { continue }
            if sibling.x < cursor.maxX + 28 {
                let point = CanvasMagnetGeometry.resultOrigin(source: cursor, size: sibling.frame.size,
                    occupied: nodes.filter { $0.id != sibling.id && !siblings.contains($0) }.map(\.frame))
                nodes[index].setFrameOrigin(point)
            }
            cursor = nodes[index].frame
        }
        scheduleSave()
    }

    /// 当前选中的**唯一**节点。属性面板只在单选时出现 —— 多选时改字体要么只改一个（用户会以为
    /// 没生效），要么全改（等于偷偷批量改），两种都不如不显示面板。
    var soleSelectedNode: CanvasNode? {
        guard selectedGroupID == nil, selectedNodeIds.count == 1, let id = selectedNodeIds.first else { return nil }
        return nodes.first { $0.id == id }
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
    func rebindNode(id: String, toPageId pageId: String, groupId: String, slot: Int,
                    historyExchange: (undo: () throws -> Void, redo: () throws -> Void)? = nil) -> Bool {
        guard flushTextDocuments?() != false else { return false }
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
        for token in Array(generationTickets.keys) {
            if generationTickets[token]?.matches(nodes[idx], projectId: activeProjectId) == true {
                generationTickets[token]?.nodeId = newId
            }
        }

        let title = nodeTitle(nodes[idx])
        let previousEntry = history.entries.last?.id
        commit(.moveNode, detail: title) {
            nodes[idx].pageId = pageId
            nodes[idx].groupId = groupId
            nodes[idx].slot = slot
            nodes[idx].updatedAt = Date()
            // 血缘引用跟着换 id，否则下游节点会指向一个不存在的父节点。
            for i in nodes.indices where nodes[i].parentNodeId == id {
                nodes[i].parentNodeId = newId
            }
            for i in nodes.indices where nodes[i].generationSourceID == id {
                nodes[i].generationSourceID = newId
            }
            // 连线的两端同理（v2.12.0）。这里是 hotfix 注释里列的第二个坑在连线时代的翻版：
            // 不改就是"把节点归档到另一个槽位后，它的线全断了"，而断链事后无法还原。
            edges = CanvasEdgeGraph.remapping(nodeId: id, to: newId, edges: edges)
            nodes = CanvasEdgeGraph.reconcilingDraftReferences(nodes: nodes, edges: edges)
            for index in groups.indices {
                groups[index].nodeIDs = groups[index].nodeIDs.map { $0 == id ? newId : $0 }
            }
            for index in piles.indices {
                piles[index].memberIDs = piles[index].memberIDs.map { $0 == id ? newId : $0 }
            }
            if selectedNodeIds.contains(id) {
                selectedNodeIds.remove(id)
                selectedNodeIds.insert(newId)
            }
        }
        guard let entry = history.entries.last, entry.id != previousEntry else { return false }
        if let historyExchange { agentBodyEdits[entry.id] = historyExchange }
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

    func setTextGenerationPrompt(id: String, text: String) {
        guard let index = nodes.firstIndex(where: { $0.id == id }),
              nodes[index].textGenerationPrompt != text else { return }
        commit(.editNode, detail: "文本生成提示词") {
            nodes[index].textGenerationPrompt = text
        }
    }

    /// 对齐/排列作为一个历史操作，整组选中保持不变。
    func arrangeSelection(vertically: Bool) {
        let selected = nodes.filter { selectedNodeIds.contains($0.id) }
            .sorted { vertically ? $0.y < $1.y : $0.x < $1.x }
        guard selected.count > 1 else { return }
        let left = selected.map(\.x).min()!
        let top = selected.map(\.y).min()!
        commit(.moveNode, detail: "排列 \(selected.count) 个节点") {
            var cursor = vertically ? top : left
            for node in selected {
                guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { continue }
                nodes[index].x = vertically ? left : cursor
                nodes[index].y = vertically ? cursor : top
                cursor += (vertically ? node.height : node.width) + 48
            }
        }
    }

    /// 记一步「在画布里增 / 删了入参附件」的可撤销历史（v2.16.5）。
    ///
    /// 与文本编辑同构：附件列表已由调用方（画布视图）直接写进槽位，这里只挂历史；
    /// 被删附件的字节在写入前已由调用方复制进 `CanvasAttachmentStash`。
    func recordSlotAttachmentEdit(nodeId: String,
                                  edit: CanvasHistoryEntry.SlotAttachmentEdit,
                                  addingInputs: Bool = true) {
        guard edit.before != edit.after else {
            discardAttachmentStash(edit.stashToken)
            return
        }
        guard let node = nodes.first(where: { $0.id == nodeId }) else {
            discardAttachmentStash(edit.stashToken)
            return
        }
        commit(.editAttachments, detail: nodeTitle(node), attachmentEdit: edit) {
            guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
            let beforeIds = Set(edit.before.map { $0.id.uuidString })
            let alive = Set(edit.after.map { $0.id.uuidString })
            nodes[index].inputAttachmentIds.removeAll { !alive.contains($0) }
            if node.isMediaSource {
                nodes[index].inputAttachmentIds = []
            } else if addingInputs {
                nodes[index].inputAttachmentIds += edit.after.map { $0.id.uuidString }
                    .filter { !beforeIds.contains($0) && !nodes[index].outputAttachmentIds.contains($0) }
            }
        }
    }

    /// 记一步「入参文件提升为主体」（v2.16.5）。
    ///
    /// 提升动作在**同一次槽位写入**里改了正文与附件列表，所以必须进同一条历史 —— 拆成两条
    /// 会让一次 Cmd+Z 只回滚一边，画布出现「正文回来了、附件还缺着」的中间态。
    func recordSlotPromotion(nodeId: String,
                             textEdit: CanvasHistoryEntry.SlotTextEdit,
                             attachmentEdit: CanvasHistoryEntry.SlotAttachmentEdit) {
        guard let node = nodes.first(where: { $0.id == nodeId }) else {
            discardAttachmentStash(attachmentEdit.stashToken)
            return
        }
        commit(.editAttachments, detail: nodeTitle(node),
               slotEdit: textEdit, attachmentEdit: attachmentEdit) { }
    }

    // MARK: - 撤销 / 重做

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// 槽位文本回写钩子。由画布视图在 onAppear 时注入（`CanvasStore` 刻意不认识 `SlotStoreObservable`，
    /// 否则这个轻量 store 又会被主 store 的 60 个 `@Published` 拖回全局重绘的老路上）。
    private var onRestoreSlotText: ((_ groupId: String, _ slot: Int, _ text: String) -> Void)?
    private var slotTextRestorerToken: UUID?
    private var pendingSlotTextRestores: [PendingSlotTextRestore] = []

    /// 安装槽位文本回写钩子。用 token 绑定视图实例，避免 SwiftUI 重建时旧视图的 `onDisappear`
    /// 把新视图刚注入的 handler 清掉；如果离场期间发生过撤销/重做，则在新 handler 到位后补写。
    func installSlotTextRestorer(id: UUID, _ restore: @escaping (_ groupId: String, _ slot: Int, _ text: String) -> Void) {
        slotTextRestorerToken = id
        onRestoreSlotText = restore
        guard !pendingSlotTextRestores.isEmpty else { return }
        let pending = pendingSlotTextRestores
        pendingSlotTextRestores = []
        for item in pending {
            restore(item.groupId, item.slot, item.text)
        }
        slotRevision += 1
    }

    /// 只清理由同一个视图实例安装的回写钩子。旧实例晚到的 `onDisappear` 不得抹掉新实例。
    func clearSlotTextRestorer(id: UUID) {
        guard slotTextRestorerToken == id else { return }
        slotTextRestorerToken = nil
        onRestoreSlotText = nil
    }

    // MARK: - 附件编辑回滚桥（v2.16.5）
    //
    // 与槽位文本回写完全同一套「按视图实例 token 注册 + 离场补写」设计：undo/redo 发生在
    // 无画布视图在场时，附件列表改动排队，等重新进画布后补写。

    typealias AttachmentEditApply = (_ groupId: String,
                                     _ slot: Int,
                                     _ attachments: [SlotContent.SlotAttachment],
                                     _ stashToken: String,
                                     _ stashAwayIds: [String],
                                     _ restoreIds: [String]) -> Void
    typealias AttachmentStashDiscard = (_ token: String) -> Void

    private struct PendingAttachmentEdit {
        let groupId: String
        let slot: Int
        let attachments: [SlotContent.SlotAttachment]
        let stashToken: String
        let stashAwayIds: [String]
        let restoreIds: [String]
    }

    private var onApplyAttachmentEdit: AttachmentEditApply?
    private var onDiscardAttachmentStash: AttachmentStashDiscard?
    private var attachmentBridgeToken: UUID?
    private var pendingAttachmentEdits: [PendingAttachmentEdit] = []

    /// 安装附件编辑回滚桥。token 绑定视图实例；离场期间产生的回滚排队，重新挂载后补写。
    func installAttachmentBridge(id: UUID,
                                 apply: @escaping AttachmentEditApply,
                                 discard: @escaping AttachmentStashDiscard) {
        attachmentBridgeToken = id
        onApplyAttachmentEdit = apply
        onDiscardAttachmentStash = discard
        guard !pendingAttachmentEdits.isEmpty else { return }
        let queued = pendingAttachmentEdits
        pendingAttachmentEdits = []
        for item in queued {
            apply(item.groupId, item.slot, item.attachments, item.stashToken,
                  item.stashAwayIds, item.restoreIds)
        }
        slotRevision += 1
    }

    /// 只清掉同一视图实例安装的附件桥。
    func clearAttachmentBridge(id: UUID) {
        guard attachmentBridgeToken == id else { return }
        attachmentBridgeToken = nil
        onApplyAttachmentEdit = nil
        onDiscardAttachmentStash = nil
    }

    private func applyAttachmentEdit(groupId: String,
                                     slot: Int,
                                     attachments: [SlotContent.SlotAttachment],
                                     stashToken: String,
                                     stashAwayIds: [String],
                                     restoreIds: [String]) {
        if let bridge = onApplyAttachmentEdit {
            bridge(groupId, slot, attachments, stashToken, stashAwayIds, restoreIds)
        } else {
            pendingAttachmentEdits.append(
                PendingAttachmentEdit(groupId: groupId, slot: slot,
                                      attachments: attachments,
                                      stashToken: stashToken,
                                      stashAwayIds: stashAwayIds,
                                      restoreIds: restoreIds))
        }
    }

    private func discardAttachmentStash(_ token: String) {
        if let bridge = onDiscardAttachmentStash {
            bridge(token)
        }
        // 无桥时不删：暂存目录要等画布视图重新挂载、且条目仍在栈中时才能安全收走。
    }

    /// source → target 两个附件列表的 id 差集。
    /// - Returns: `stash` = source 独有（字节需移入暂存）；`restore` = target 独有（需从暂存恢复）。
    private func attachmentIdDiff(source: [SlotContent.SlotAttachment],
                                  target: [SlotContent.SlotAttachment])
    -> (stash: [String], restore: [String]) {
        let sourceIds = Set(source.map { $0.id.uuidString })
        let targetIds = Set(target.map { $0.id.uuidString })
        return (Array(sourceIds.subtracting(targetIds)),
                Array(targetIds.subtracting(sourceIds)))
    }

    private func restoreSlotText(groupId: String, slot: Int, text: String) {
        if let onRestoreSlotText {
            onRestoreSlotText(groupId, slot, text)
        } else {
            pendingSlotTextRestores.append(PendingSlotTextRestore(groupId: groupId, slot: slot, text: text))
        }
    }
    var onRestoreDocument: (() -> Void)?
    var documentRestorerID: UUID?

    /// 撤销一步。返回被撤销的条目（调用方用它做 toast 文案），没得撤时返回 nil。
    @discardableResult
    func undo() -> CanvasHistoryEntry? {
        guard flushTextDocuments?() != false else { return nil }
        agentHistoryError = nil
        if let target = history.undoTarget, !canRestoreGenerationHistory(nodes: target.before) { return nil }
        if let target = history.undoTarget, workflowEdits[target.id] != nil {
            return exchangeWorkflowHistory(target: target, undo: true)
        }
        if let target = history.undoTarget, let edit = agentBodyEdits[target.id] {
            do { try edit.undo() }
            catch { agentHistoryError = error.localizedDescription; return nil }
        }
        guard let entry = history.undo() else { return nil }
        apply(nodes: entry.before, edges: entry.beforeEdges, groups: entry.beforeGroups, piles: entry.beforePiles)
        onRestoreDocument?()
        if let edit = entry.slotEdit {
            restoreSlotText(groupId: edit.groupId, slot: edit.slot, text: edit.before)
        }
        if let edit = entry.attachmentEdit {
            let diff = attachmentIdDiff(source: edit.after, target: edit.before)
            applyAttachmentEdit(groupId: edit.groupId, slot: edit.slot,
                                attachments: edit.before, stashToken: edit.stashToken,
                                stashAwayIds: diff.stash, restoreIds: diff.restore)
        }
        return entry
    }

    @discardableResult
    func redo() -> CanvasHistoryEntry? {
        guard flushTextDocuments?() != false else { return nil }
        agentHistoryError = nil
        if let target = history.redoTarget, !canRestoreGenerationHistory(nodes: target.after) { return nil }
        if let target = history.redoTarget, workflowEdits[target.id] != nil {
            return exchangeWorkflowHistory(target: target, undo: false)
        }
        if let target = history.redoTarget, let edit = agentBodyEdits[target.id] {
            do { try edit.redo() }
            catch { agentHistoryError = error.localizedDescription; return nil }
        }
        guard let entry = history.redo() else { return nil }
        apply(nodes: entry.after, edges: entry.afterEdges, groups: entry.afterGroups, piles: entry.afterPiles)
        onRestoreDocument?()
        if let edit = entry.slotEdit {
            restoreSlotText(groupId: edit.groupId, slot: edit.slot, text: edit.after)
        }
        if let edit = entry.attachmentEdit {
            let diff = attachmentIdDiff(source: edit.before, target: edit.after)
            applyAttachmentEdit(groupId: edit.groupId, slot: edit.slot,
                                attachments: edit.after, stashToken: edit.stashToken,
                                stashAwayIds: diff.stash, restoreIds: diff.restore)
        }
        return entry
    }

    private func exchangeWorkflowHistory(target: CanvasHistoryEntry, undo: Bool) -> CanvasHistoryEntry? {
        guard let (transaction, receipt) = workflowEdits[target.id], receipt.project.id == activeProjectId else { return nil }
        do {
            guard flushSave() else { throw AgentCanvasError.writeFailed }
            let doc = try transaction.exchange(receipt, undo: undo)
            _ = undo ? history.undo() : history.redo()
            storage.invalidateCache()
            workflowPrivateStorage.invalidateContentCaches()
            nodes = doc.nodes; edges = doc.edges; groups = doc.groups; piles = doc.piles; pan = doc.pan; zoom = doc.zoom
            selectedNodeIds = []; selectedEdgeId = nil; slotRevision += 1
            return target
        } catch { agentHistoryError = error.localizedDescription; return nil }
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

    private func canRestoreGenerationHistory(nodes target: [CanvasNode]) -> Bool {
        let removesActiveResult = generationTickets.values.contains { ticket in
            guard ticket.projectId == activeProjectId,
                  let owner = generationNode(ticket.token), owner.generationSourceID != nil else { return false }
            return !target.contains { $0.createdAt == owner.createdAt }
        }
        if removesActiveResult {
            agentHistoryError = "生成结果仍在提交或查询，请等待完成，或停止结果节点后再撤销。"
            return false
        }
        return true
    }

    private func generationHistoryKey(_ node: CanvasNode) -> String {
        "\(node.id)|\(node.createdAt.timeIntervalSinceReferenceDate)"
    }

    private func apply(nodes newNodes: [CanvasNode], edges newEdges: [CanvasEdge],
                       groups newGroups: [CanvasNodeGroup], piles newPiles: [CanvasPile]) {
        let current = nodes
        for node in current where node.generationSourceID != nil {
            generationHistoryResults[generationHistoryKey(node)] = node
        }
        nodes = newNodes.map { restored in
            var next = restored
            // 历史只回滚编辑动作；已经完成的任务结果和正在跑的任务元数据不倒退。
            let sameBirth = current.filter { $0.createdAt == restored.createdAt }
            let live = sameBirth.first { $0.id == restored.id }
                ?? (sameBirth.count == 1 ? sameBirth.first : nil)
                ?? generationHistoryResults[generationHistoryKey(restored)]
            if let live {
                next.state = live.state
                next.taskId = live.taskId
                next.generationTask = live.generationTask
                next.generationRawOutput = live.generationRawOutput
                next.generationDiagnostic = live.generationDiagnostic
                next.seed = live.seed
                next.outputAttachmentIds = live.outputAttachmentIds
            } else {
                switch next.state {
                case .running, .queued: next.state = .idle
                default: break
                }
            }
            return next
        }
        for token in Array(generationTickets.keys) {
            guard let ticket = generationTickets[token], ticket.projectId == activeProjectId else { continue }
            let sameBirth = nodes.filter { $0.createdAt == ticket.createdAt }
            let owner = sameBirth.first { $0.id == ticket.nodeId }
                ?? (sameBirth.count == 1 ? sameBirth.first : nil)
            if let owner {
                generationTickets[token]?.nodeId = owner.id
            } else {
                generationTickets.removeValue(forKey: token)
            }
        }
        // 选中集合里可能有已经不存在的 id（撤销"新建"之后），留着会让工具栏的"删除选中"对着空气生效。
        let alive = Set(newNodes.map(\.id))
        piles = CanvasPile.normalized(newPiles, nodes: nodes)
        selectedNodeIds = selectedNodeIds.intersection(visibleEntityIDs)
        // 连线快照里可能有指向已不存在节点的线（老条目不带 edges 时是空数组，那是对的；
        // 带了也可能与节点快照错位）。规整一次，宁可少一条线也不留野线。
        edges = CanvasEdgeGraph.normalized(newEdges, nodeIds: alive, preservingImageCycles: nodes)
        nodes = CanvasEdgeGraph.reconcilingDraftReferences(nodes: nodes, edges: edges)
        groups = CanvasNodeGroup.normalized(newGroups, nodeIDs: alive)
        suppressedServerGroupLayouts.formUnion(groups.filter { $0.provenance == .server }.map(\.id))
        reconcileGroupSelection()
        if let selected = selectedEdgeId, !edges.contains(where: { $0.id == selected }) {
            selectedEdgeId = nil
        }
        slotRevision += 1
        scheduleSave()
    }

    /// 写操作的唯一入口：跑一遍变更、记一步撤销、落盘。
    ///
    /// v2.12.0 起快照里**同时**带节点与连线。两者必须一起进同一条条目：删一个节点会顺带清掉它的线，
    /// 若分成两条历史条目，用户 Cmd+Z 一次只回来节点、线还是没了（而且第二次 Cmd+Z 才补回来 ——
    /// 中间那一帧的画布是从未存在过的状态）。
    private func commit(_ kind: CanvasHistoryEntry.Kind,
                        detail: String,
                        slotEdit: CanvasHistoryEntry.SlotTextEdit? = nil,
                        attachmentEdit: CanvasHistoryEntry.SlotAttachmentEdit? = nil,
                        _ mutate: () -> Void) {
        // A later canvas action must follow the text burst in undo history.
        // Persist callbacks themselves record a slotEdit and must not recurse.
        guard slotEdit != nil || flushTextDocuments?() != false else { return }
        let before = nodes
        let beforeEdges = edges
        let beforeGroups = groups
        let beforePiles = piles
        mutate()
        let normalizedGroups = CanvasNodeGroup.normalized(groups, nodeIDs: Set(nodes.map(\.id)))
        let normalizedPiles = CanvasPile.normalized(piles, nodes: nodes)
        if groups != normalizedGroups { groups = normalizedGroups }
        if piles != normalizedPiles { piles = normalizedPiles }
        let groupIDs = Set(groups.map(\.id))
        for index in piles.indices where piles[index].groupID.map({ !groupIDs.contains($0) }) == true {
            piles[index].groupID = nil
        }
        reconcileGroupSelection()
        if selectedGroupID == nil { selectedNodeIds = selectedNodeIds.intersection(visibleEntityIDs) }
        guard nodes != before || edges != beforeEdges
                || groups != beforeGroups || piles != beforePiles || slotEdit != nil || attachmentEdit != nil else { return }
        if isComposingAgentEdit { scheduleSave(); return }
        let tokensBefore = Set(history.entries.compactMap { $0.attachmentEdit?.stashToken })
        history.push(CanvasHistoryEntry(kind: kind,
                                        detail: detail,
                                        before: before,
                                        after: nodes,
                                        beforeEdges: beforeEdges,
                                        afterEdges: edges,
                                        beforeGroups: beforeGroups,
                                        afterGroups: groups,
                                        beforePiles: beforePiles,
                                        afterPiles: piles,
                                        slotEdit: slotEdit,
                                        attachmentEdit: attachmentEdit))
        // push 会截断已撤销分支 / 在超限时丢最旧条目：那些条目的暂存字节必须同步收走，
        // 否则 redo 已不可能，磁盘上只剩无人引用的孤儿字节。
        let tokensAfter = Set(history.entries.compactMap { $0.attachmentEdit?.stashToken })
        let retainedIDs = Set(history.entries.map(\.id))
        agentBodyEdits = agentBodyEdits.filter { retainedIDs.contains($0.key) }
        for token in tokensBefore.subtracting(tokensAfter) {
            discardAttachmentStash(token)
        }
        if slotEdit != nil || attachmentEdit != nil { slotRevision += 1 }
        scheduleSave()
    }

    // MARK: - 选择

    private func reconcileGroupSelection() {
        guard let id = selectedGroupID else { return }
        guard groups.contains(where: { $0.id == id }) else { selectedGroupID = nil; return }
        let members = groupMemberIDs(id)
        if selectedNodeIds != members { selectedNodeIds = members }
    }

    func select(id: String, additive: Bool) {
        selectedGroupID = nil
        selectedEdgeId = nil
        if additive {
            if selectedNodeIds.contains(id) { selectedNodeIds.remove(id) } else { selectedNodeIds.insert(id) }
        } else {
            selectedNodeIds = [id]
        }
    }

    func clearSelection() {
        selectedGroupID = nil
        if !selectedNodeIds.isEmpty { selectedNodeIds = [] }
        // 连线选中一并清掉：两种选中互斥（Delete 键必须有唯一答案），而"清空"只应该有一个入口。
        if selectedEdgeId != nil { selectedEdgeId = nil }
    }

    /// 框选：命中判定在画布空间做，避免受缩放影响。
    func selectNodes(inCanvasRect rect: CGRect, additive: Bool) {
        selectedGroupID = nil
        selectedEdgeId = nil
        let hit = nodes.filter { !piledMemberIDs.contains($0.id) && $0.frame.intersects(rect) }.map(\.id)
            + piles.filter { CanvasPileGeometry.frame($0, nodes: nodes).intersects(rect) }.map(\.id)
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
                                      edges: edges,
                                      groups: groups,
                                      piles: piles,
                                      appliedAgentMutationIDs: appliedAgentMutationIDs,
                                      panX: pan.width,
                                      panY: pan.height,
                                      zoom: zoom)
        let storage = self.storage
        let projectId = activeProjectId
        let version = retainPending(snapshot, projectId: projectId)
        let delay = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // 编码 + 磁盘 IO 挪出主线程，画布拖拽不因落盘掉帧。
            // 刻意用 GCD 而不是 `Task.detached`：`CanvasStorage` 是带 NSLock 的 class（非 Sendable），
            // 塞进 detached task 会吃一串并发检查警告，而这里根本不需要结构化并发的取消传播 ——
            // 取消已经由外层 `saveTask?.cancel()` 承担。
            guard let self else { return }
            self.saveQueue.async {
                let ok = storage.save(snapshot, projectId: projectId)
                Task { @MainActor [weak self] in
                    self?.completeSave(projectId: projectId, version: version, success: ok)
                }
            }
        }
    }

    /// 立即落盘（离开画布 / App 退出 / 切项目时调用，不等防抖）。
    @discardableResult
    func flushSave() -> Bool {
        guard flushTextDocuments?() != false else {
            saveStatus = .failed("文本尚未保存，请在输入框中重试保存")
            return false
        }
        saveTask?.cancel()
        let snapshot = CanvasDocument(nodes: nodes,
                                      edges: edges,
                                      groups: groups,
                                      piles: piles,
                                      appliedAgentMutationIDs: appliedAgentMutationIDs,
                                      panX: pan.width,
                                      panY: pan.height,
                                      zoom: zoom)
        _ = retainPending(snapshot, projectId: activeProjectId)
        // 先排空已派出的写入，再保存所有失败/未完成快照。后台任务属于其它项目时也不能丢。
        for (projectId, doc) in pendingDocuments {
            let version = saveVersions[projectId]!
            let ok = saveQueue.sync { storage.save(doc, projectId: projectId) }
            completeSave(projectId: projectId, version: version, success: ok)
        }
        return pendingDocuments.isEmpty
    }

    private func retainPending(_ doc: CanvasDocument, projectId: String) -> UUID {
        let version = UUID()
        pendingDocuments[projectId] = doc
        saveVersions[projectId] = version
        if saveFailures.isEmpty, saveStatus != .saving { saveStatus = .saving }
        return version
    }

    private func completeSave(projectId: String, version: UUID, success: Bool) {
        guard saveVersions[projectId] == version else { return }
        if success {
            pendingDocuments.removeValue(forKey: projectId)
            saveFailures.removeValue(forKey: projectId)
        } else {
            saveFailures[projectId] = storage.lastSaveError(projectId: projectId) ?? "无法写入画布文件"
        }
        let next: SaveStatus = saveFailures.values.first.map { .failed($0) }
            ?? (pendingDocuments.isEmpty ? .saved : .saving)
        if saveStatus != next { saveStatus = next }
    }

    // MARK: - 常量

    /// 网格吸附步长（画布空间）。与背景网格基准一致，观感上「贴着线走」。
    /// 真值住在 `CanvasGeometry`（Kit 层）以便被 smoke 断言覆盖，这里只是就近别名。
    static let snapStep: CGFloat = CanvasGeometry.snapStep

    /// 拖动落盘的量化步长：固定到屏幕 0.5pt，而不是画布 0.5pt。
    private static func dragPersistenceStep(forZoom zoom: CGFloat) -> CGFloat {
        0.5 / max(0.01, zoom)
    }

    private static func roundDragDelta(_ value: CGFloat, step: CGFloat) -> CGFloat {
        guard step.isFinite, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    /// 背景网格基准步长。
    static let gridBase: CGFloat = 24
}

private struct PendingSlotTextRestore {
    let groupId: String
    let slot: Int
    let text: String
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
        case .pickSlot: return "plus"
        }
    }

    var title: String {
        switch self {
        case .select: return "选区"
        case .hand: return "抓手"
        case .pickSlot: return "新建节点"
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
        case .hand: return "左键拖动平移；按住空格或中键可临时抓手"
        case .pickSlot: return "新建文本、图像、视频或槽位节点（N）；也可双击空白"
        }
    }
}
