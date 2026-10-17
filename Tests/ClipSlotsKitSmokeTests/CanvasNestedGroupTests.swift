import Foundation
import CoreGraphics
import ClipSlotsKit

func runCanvasNestedGroupTests(_ t: TestRunner) {
    let a = CanvasNode(pageId: "page", groupId: "storage", slot: 1, kind: .text, x: 110, y: 220)
    let b = CanvasNode(pageId: "page", groupId: "storage", slot: 2, kind: .text, x: 165, y: 286,
                       parentNodeId: a.id)
    let c = CanvasNode(pageId: "page", groupId: "storage", slot: 3, kind: .text, x: 460, y: 286)
    let nodes = [a, b, c]
    let outer = CanvasNodeGroup(id: "outer", nodeIDs: [a.id],
        containerFrame: CGRect(x: 100, y: 200, width: 1500, height: 1300), layoutType: .grid, createdBy: .server)
    let middle = CanvasNodeGroup(id: "middle", nodeIDs: [],
        containerFrame: CGRect(x: 130, y: 240, width: 1100, height: 950), parentGroupID: "outer", createdBy: .server)
    let inner = CanvasNodeGroup(id: "inner", nodeIDs: [b.id, c.id],
        containerFrame: CGRect(x: 160, y: 280, width: 800, height: 650), parentGroupID: "middle", createdBy: .client)
    let groups = [inner, middle, outer]
    let edges = [CanvasEdge(id: "nested-edge", fromNodeId: a.id, toNodeId: b.id)]
    let original = CanvasDocument(nodes: nodes, edges: edges, groups: groups)
    func mutation(_ groups: [AgentCanvasMutation.GroupChange], nodes: [AgentCanvasMutation.NodeChange] = [],
                  space: AgentCanvasMutation.CoordinateSpace = .world, id: String = "nested") -> AgentCanvasMutation {
        .init(projectID: "project", conversationID: "conversation", runID: "run", mutationID: id,
              changes: nodes, groupChanges: groups, coordinateSpace: space)
    }
    func plan(_ mutation: AgentCanvasMutation, current: CanvasDocument = original) throws -> AgentCanvasSync.Plan {
        try AgentCanvasSync.plan(mutation, current: current, expectedProject: "project",
                                 expectedConversation: "conversation", expectedRun: "run")
    }
    do {
        try CanvasGroupHierarchy.validate(groups, nodeIDs: Set(nodes.map(\.id)))
        t.equal(original.groups, groups, "多层文档保留仅含子组的父容器")
        t.equal(CanvasGroupHierarchy.parentFirst(groups).map(\.id), ["outer", "middle", "inner"], "逆序输入按父链排序")
        t.equal(CanvasGroupHierarchy.memberIDs("outer", groups: groups), Set(nodes.map(\.id)), "父组收集全部后代成员")
        t.equal(CanvasGroupHierarchy.localOrigin(of: b, groups: groups), CGPoint(x: 5, y: 6), "节点 local adapter 不改存储身份")
        t.equal(CanvasGroupHierarchy.localFrame(of: inner, groups: groups)?.origin, CGPoint(x: 30, y: 40), "子容器 local adapter")
        let roundtrip = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(original))
        t.equal(roundtrip.groups, groups, "群组 parent/provenance 持久化往返")
        t.equal(roundtrip.nodes, nodes, "群组往返不改节点字段")
        t.equal(roundtrip.edges, edges, "群组往返不改连线身份")
        let legacy = try JSONDecoder().decode(CanvasNodeGroup.self,
            from: Data("{\"id\":\"old\",\"name\":\"old\",\"nodeIDs\":[\"storage#1\"]}".utf8))
        t.check(legacy.parentGroupID == nil && legacy.provenance == .client && legacy.measuredLayoutSignature == nil,
                "旧 flat 文档缺字段默认 client")

        var localMiddle = middle, localInner = inner
        localMiddle.containerFrame = CGRect(x: 30, y: 40, width: 1100, height: 950)
        localInner.containerFrame = CGRect(x: 30, y: 40, width: 800, height: 650)
        var localA = a, localB = b, localC = c
        localA.x = 10; localA.y = 20
        localB.x = 5; localB.y = 6
        localC.x = 300; localC.y = 6
        let create = mutation([.init(before: nil, after: localInner), .init(before: nil, after: localMiddle),
                               .init(before: nil, after: outer)],
            nodes: [.init(before: a, after: localA), .init(before: b, after: localB), .init(before: c, after: localC)],
            space: .parentLocal)
        let created = try plan(create, current: CanvasDocument(nodes: nodes, edges: edges))
        t.equal(created.document.nodes, nodes, "服务入口只转换一次 parent-local 节点")
        t.equal(created.document.groups.first(where: { $0.id == "inner" })?.containerFrame, inner.containerFrame,
                "逆序 server 快照 parent-first 累加世界边界")
        t.equal(created.document.nodes[1].parentNodeId, a.id, "lineage parentNodeId 不改义")
        t.equal(created.document.nodes.map(\.groupId), ["storage", "storage", "storage"], "storage groupId 不改义")
        let persisted = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(created.document))
        t.check(try plan(create, current: persisted).alreadyApplied, "GROUP receipt 重启后去重")
        t.expectThrows("GROUP 身份上下文必须匹配") {
            _ = try AgentCanvasSync.plan(create, current: original, expectedProject: "other",
                expectedConversation: "conversation", expectedRun: "run")
        }

        var shifted = outer
        shifted.containerFrame = outer.containerFrame?.offsetBy(dx: 20, dy: -10)
        let movedPlan = try plan(mutation([.init(before: outer, after: shifted)]))
        t.equal(Set(movedPlan.changedGroupIDs), Set(["outer", "middle", "inner"]), "父组远端移动追踪后代变更")
        t.check(zip(movedPlan.document.nodes, nodes).allSatisfy { next, before in
            next.x == before.x + 20 && next.y == before.y - 10 && next.id == before.id
        }, "父组远端位移传递每个节点一次")
        t.equal(movedPlan.document.edges, edges, "父组移动保持边端点身份")
        let delta = CGSize(width: -35, height: 70)
        let moved = try CanvasGroupHierarchy.moving("outer", by: delta, in: original)
        t.equal(CanvasGroupHierarchy.localOrigin(of: moved.nodes[1], groups: moved.groups), CGPoint(x: 5, y: 6),
                "多层拖动保持子节点 local 位置")
        t.equal(CanvasGroupHierarchy.localFrame(of: moved.groups[0], groups: moved.groups)?.origin,
                CGPoint(x: 30, y: 40), "多层拖动保持子容器 local 位置")
        t.check(zip(moved.nodes, nodes).allSatisfy { next, before in
            var copy = next
            copy.x -= delta.width; copy.y -= delta.height
            return copy == before
        }, "多层拖动只改世界位置，不改参数/内容/身份")
        let resizedFrame = CGRect(x: 120, y: 190, width: 1600, height: 1400)
        let resized = try CanvasGroupHierarchy.resizing("outer", to: resizedFrame, in: original)
        t.equal(resized.groups.first(where: { $0.id == "outer" })?.containerFrame, resizedFrame, "多层 resize 更新容器")
        t.equal(resized.nodes[1].frame.origin, CGPoint(x: b.x + 20, y: b.y - 10), "左/上 resize 保持后代 local")
        t.equal(resized.nodes[1].frame.size, b.frame.size, "容器 resize 不缩放媒体尺寸")
        let dissolved = CanvasGroupHierarchy.dissolving(["middle"], groups: groups)
        t.equal(dissolved.first(where: { $0.id == "inner" })?.parentGroupID, "outer", "解组提升子组到祖父")
        t.equal(dissolved.first(where: { $0.id == "inner" })?.containerFrame, inner.containerFrame, "解组保留子组世界边界")
        var reparentedInner = inner
        reparentedInner.parentGroupID = "outer"
        let dissolvePlan = try plan(mutation([.init(before: middle, after: nil),
                                             .init(before: inner, after: reparentedInner)]))
        t.equal(dissolvePlan.document.nodes, nodes, "显式解组事务保留节点世界位置")
        t.equal(dissolvePlan.document.groups.first(where: { $0.id == "inner" })?.parentGroupID, "outer",
                "远端解组必须完整重挂父链")
        t.expectThrows("不完整父组删除整份拒绝") { _ = try plan(mutation([.init(before: middle, after: nil)])) }
        t.expectThrows("新增 GROUP 不能覆盖原身份") { _ = try plan(mutation([.init(before: nil, after: outer)])) }
        t.expectThrows("GROUP 不能改写 id") {
            var other = outer; other.id = "renamed-id"
            _ = try plan(mutation([.init(before: outer, after: other)]))
        }
        t.expectThrows("GROUP provenance 不可由更新改写") {
            var other = outer; other.createdBy = .client
            _ = try plan(mutation([.init(before: outer, after: other)]))
        }
        var live = original
        live.groups[2].containerFrame = outer.containerFrame?.offsetBy(dx: 50, dy: 0)
        var renamed = outer; renamed.name = "新标题"
        let merged = try plan(mutation([.init(before: outer, after: renamed)]), current: live)
        t.equal(merged.document.groups[2].containerFrame, live.groups[2].containerFrame, "远端标题保留本地容器位置")
        t.equal(merged.preservedLocalGroupPositions, ["outer"], "容器位置合并可追踪")
        let draggedLive = try CanvasGroupHierarchy.moving("outer", by: CGSize(width: 50, height: 0), in: original)
        let draggedMerge = try plan(mutation([.init(before: outer, after: renamed)]), current: draggedLive)
        t.equal(draggedMerge.document.groups[2].autoLayoutEnabled, false, "远端标题不恢复用户拖动关闭的 auto layout")
        t.equal(draggedMerge.document.nodes, draggedLive.nodes, "标题合并保留所有后代拖动位置")
        t.expectThrows("两个容器位移冲突拒绝") { _ = try plan(mutation([.init(before: outer, after: shifted)]), current: live) }

        let waiting = try CanvasServerGroupLayout.reconcile(original, measurements: [:])
        t.equal(waiting.document, original, "未测量不回写任何布局或签名")
        t.equal(waiting.states["outer"], .waitingForMeasurements, "server 组等待实际尺寸")
        t.equal(waiting.states["middle"], .nestedServer, "嵌套 server 子组自动布局 guard")
        let partial = try CanvasServerGroupLayout.reconcile(original, measurements: [a.id: a.frame.size])
        t.check(partial.appliedGroupIDs.isEmpty, "部分尺寸未 ready 时不回写")
        var measurements = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.frame.size) })
        measurements[b.id] = CGSize(width: b.width + 1, height: b.height)
        t.check(CanvasServerGroupLayout.signature("outer", document: original, measurements: measurements) == nil,
                "过期 measured 尺寸不能触发布局")
        measurements[b.id] = b.frame.size
        let arranged = try CanvasServerGroupLayout.reconcile(original, measurements: measurements)
        t.equal(arranged.appliedGroupIDs, ["outer"], "全部尺寸 ready 仅顶层 server 自动布局")
        t.equal(arranged.states["middle"], .nestedServer, "父布局不重复计算嵌套 server 子组内部")
        t.equal(CanvasGroupHierarchy.localOrigin(of: arranged.document.nodes[1], groups: arranged.document.groups),
                CGPoint(x: 5, y: 6), "自动布局把子组当原子单元")
        let unchanged = try CanvasServerGroupLayout.reconcile(arranged.document, measurements: measurements)
        t.check(unchanged.appliedGroupIDs.isEmpty && unchanged.document == arranged.document, "同 measured signature 不重复回写")
        let suppressed = try CanvasServerGroupLayout.reconcile(original, measurements: measurements, suppressedGroupIDs: ["outer"])
        t.check(suppressed.appliedGroupIDs.isEmpty && suppressed.document == original, "undo 抑制不修改原数据契约")
        let signatureCopy = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(arranged.document))
        t.equal(signatureCopy.groups, arranged.document.groups, "measured signature 持久化")
        let pile = CanvasPile(id: "nested-pile", memberIDs: [b.id, c.id], at: CGPoint(x: 210, y: 300), groupID: "inner")
        let piledDocument = CanvasDocument(nodes: nodes, edges: edges, groups: groups, piles: [pile])
        let piledMove = try CanvasGroupHierarchy.moving("outer", by: delta, in: piledDocument)
        t.equal(piledMove.piles[0].x, pile.x + delta.width, "父组移动 Pile 展示实体一次")
        t.equal(piledMove.nodes[1].x, b.x + delta.width, "父组移动 Pile 隐藏成员世界位置一次")
        let pileGuard = try CanvasServerGroupLayout.reconcile(piledDocument, measurements: measurements)
        t.equal(pileGuard.states["outer"], .blockedByPile, "不伪实现嵌套 Pile 自动重排")
        t.equal(pileGuard.document, piledDocument, "不支持的嵌套 Pile 布局不改原数据")
        var history = CanvasUndoStack()
        history.push(CanvasHistoryEntry(kind: .groupNodes, detail: "多层布局", before: original.nodes, after: arranged.document.nodes,
            beforeEdges: edges, afterEdges: edges, beforeGroups: original.groups, afterGroups: arranged.document.groups))
        let undo = history.undo()
        t.equal(undo?.beforeGroups, original.groups, "undo 同时恢复 parent/provenance/signature")
        t.equal(history.redo()?.afterGroups, arranged.document.groups, "redo 恢复完整层级布局")

        func reject(_ bad: [CanvasNodeGroup], _ message: String) {
            t.expectThrows(message) {
                let changes = bad.map { AgentCanvasMutation.GroupChange(before: nil, after: $0) }
                _ = try plan(mutation(changes), current: CanvasDocument(nodes: nodes))
            }
        }
        var badInner = inner; badInner.parentGroupID = "missing"
        reject([outer, middle, badInner], "missing parent proposal 整份拒绝")
        badInner = inner; badInner.parentGroupID = "inner"
        reject([outer, middle, badInner], "self cycle proposal 整份拒绝")
        var badOuter = outer; badOuter.parentGroupID = "inner"
        reject([badOuter, middle, inner], "多层 cycle proposal 整份拒绝")
        badInner = inner; badInner.nodeIDs.append(a.id)
        reject([outer, middle, badInner], "同一节点多 parent 归属整份拒绝")
        badInner = inner; badInner.nodeIDs.append(b.id)
        reject([outer, middle, badInner], "同组重复成员整份拒绝")
        reject([outer, middle, inner, outer], "重复 group id 整份拒绝")
        badInner = inner; badInner.containerFrame = CGRect(x: CGFloat.infinity, y: 0, width: 30, height: 30)
        reject([outer, middle, badInner], "nonfinite 容器整份拒绝")
        badInner = inner; badInner.containerFrame = CGRect(x: 0, y: 0, width: -1, height: 30)
        reject([outer, middle, badInner], "负尺寸容器整份拒绝")
        badInner = inner; badInner.nodeIDs = ["missing-node"]
        reject([outer, middle, badInner], "缺节点容器整份拒绝")
        let chain = (0..<65).map { i in
            CanvasNodeGroup(id: "depth-\(i)", nodeIDs: [],
                containerFrame: CGRect(x: 0, y: 0, width: 300, height: 300),
                parentGroupID: i == 0 ? nil : "depth-\(i - 1)", createdBy: .server)
        }
        try CanvasGroupHierarchy.validate(Array(chain.prefix(64)), nodeIDs: [])
        t.check(true, "64 层父链边界允许")
        reject(chain, "65 层超深链拒绝且不递归溢出")
        let normalizedCycle = CanvasNodeGroup.normalized([badOuter, middle, inner], nodeIDs: Set(nodes.map(\.id)))
        try CanvasGroupHierarchy.validate(normalizedCycle, nodeIDs: Set(nodes.map(\.id)))
        t.equal(CanvasNodeGroup.normalized(normalizedCycle, nodeIDs: Set(nodes.map(\.id))), normalizedCycle,
                "旧磁盘层级修复幂等，与 proposal 拒绝策略分离")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-group-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CanvasStorage(rootOverride: root)
        t.check(storage.save(original, projectId: "project"), "多层原文档保存")
        try storage.saveComparingGraph(movedPlan.document, expectedRevision: AgentCanvasSync.revision(original), projectId: "project")
        storage.invalidateCache()
        t.equal(storage.load(projectId: "project").groups, movedPlan.document.groups, "真实生产 CAS 持久化整个父链")
        t.expectThrows("过期 revision 不覆盖层级事务") {
            try storage.saveComparingGraph(original, expectedRevision: AgentCanvasSync.revision(original), projectId: "project")
        }
        t.equal(original.nodes, nodes, "所有非法 proposal 未改原节点")
        t.equal(original.groups, groups, "所有非法 proposal 未改原容器")
    } catch { t.check(false, "多层 Group 核心测试准备失败：\(error)") }
}
