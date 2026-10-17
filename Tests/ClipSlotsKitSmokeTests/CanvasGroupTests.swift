import Foundation
import ClipSlotsKit

func runCanvasGroupTests(_ t: TestRunner) {
    let nodes = (1...5).map { CanvasNode(pageId: "p", groupId: "g", slot: $0, x: CGFloat($0 * 20), y: 0) }
    let ids = nodes.map(\.id)
    for count in 1...50 {
        let sample = (1...count).map { i -> CanvasNode in
            var node = CanvasNode(pageId: "p", groupId: "parity", slot: i, x: 0, y: 0)
            node.width = CGFloat(120 + i * 9); node.height = CGFloat(90 + i * 13)
            return node
        }
        let anchor = CGPoint(x: -80, y: 45)
        let grid = CanvasGroupGeometry.grid(nodes: sample, at: anchor)
        let rows = Int(ceil(sqrt(Double(count)))), columns = Int(ceil(Double(count) / Double(Int(ceil(sqrt(Double(count)))))))
        let maxWidth = sample.map(\.width).max()!, maxHeight = sample.map(\.height).max()!
        t.equal(grid.frame.width, 200 + CGFloat(columns) * maxWidth + CGFloat(columns - 1) * 200, "REA grid \(count) width")
        t.equal(grid.frame.height, 200 + CGFloat(rows) * maxHeight + CGFloat(rows - 1) * 200, "REA grid \(count) height")
        t.check(sample.enumerated().allSatisfy { i, node in
            guard let point = grid.origins[node.id] else { return false }
            return point.x == anchor.x + 100 + CGFloat(i % columns) * (maxWidth + 200) + (maxWidth - node.width) / 2
                && point.y == anchor.y + 100 + CGFloat(i / columns) * (maxHeight + 200) + (maxHeight - node.height) / 2
        }, "REA grid \(count) centers every cell")
    }
    let container = CGRect(x: 0, y: 0, width: 500, height: 400)
    t.check(!CanvasGroupGeometry.completelyOutside(CGRect(x: 500, y: 20, width: 50, height: 50), container: container),
            "touching edge does not leave group")
    t.check(CanvasGroupGeometry.completelyOutside(CGRect(x: 501, y: 20, width: 50, height: 50), container: container),
            "strictly separated node leaves group")
    for handle in CanvasGroupResizeHandle.allCases {
        let frame = CanvasGroupGeometry.resized(container, handle: handle, delta: CGSize(width: 1000, height: -1000))
        t.check(CanvasGroupGeometry.isValid(frame) && frame.width >= 10 && frame.height >= 10, "resize \(handle) cannot invert")
    }
    if let dagre = CanvasDagreLayout.layout(nodes: Array(nodes.prefix(3)),
        edges: [CanvasEdge(fromNodeId: ids[0], toNodeId: ids[1]), CanvasEdge(fromNodeId: ids[1], toNodeId: ids[2])],
        at: .zero) {
        t.equal(dagre.origins[ids[0]], CGPoint(x: 100, y: 100), "Dagre chain starts at reference padding")
        t.equal(dagre.origins[ids[1]]?.x, 100 + nodes[0].width + 200, "Dagre chain rank spacing")
        t.equal(dagre.origins[ids[2]]?.x, 100 + nodes[0].width + nodes[1].width + 400, "Dagre chain third rank")
    } else { t.check(false, "bundled Dagre loads") }
    do {
        let legacy = Data("{\"id\":\"legacy\",\"name\":\"旧组\",\"nodeIDs\":[\"a\",\"b\"]}".utf8)
        let old = try JSONDecoder().decode(CanvasNodeGroup.self, from: legacy)
        t.check(old.containerFrame == nil && old.color == nil && old.layoutType == nil, "membership-only group remains decodable")
        var modern = old
        modern.containerFrame = container; modern.color = .cyan; modern.layoutType = .grid
        t.equal(try JSONDecoder().decode(CanvasNodeGroup.self, from: JSONEncoder().encode(modern)), modern,
                "container style and layout roundtrip")
    } catch { t.check(false, "group migration \(error)") }
    let groups = [
        CanvasNodeGroup(id: "one", name: "组甲", nodeIDs: [ids[0], ids[0], "missing", ids[1]]),
        CanvasNodeGroup(id: "two", name: "组乙", nodeIDs: [ids[1], ids[2]]),
        CanvasNodeGroup(id: "one", nodeIDs: [ids[3]]),
        CanvasNodeGroup(id: "empty", nodeIDs: ["missing"])
    ]
    let normalized = CanvasNodeGroup.normalized(groups, nodeIDs: Set(ids))
    t.equal(normalized.count, 2, "groups discard duplicate IDs and empty memberships")
    t.equal(normalized[0].nodeIDs, [ids[0], ids[1]], "groups discard missing and duplicate members")
    t.equal(normalized[1].nodeIDs, [ids[2]], "a node has only one group")
    t.equal(CanvasNodeGroup.normalized(normalized, nodeIDs: Set(ids)), normalized, "normalization is idempotent")
    let edges = [CanvasEdge(id: "source-edge", fromNodeId: ids[0], toNodeId: ids[1], role: .prompt,
                           sourceFromPort: "bottom", sourceToPort: "top", sourceColorID: 3),
                 CanvasEdge(fromNodeId: ids[1], toNodeId: ids[2])]
    do {
        let document = CanvasDocument(nodes: nodes, edges: edges, groups: normalized)
        let copy = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(document))
        t.equal(copy.groups, normalized, "membership and titles survive reload")
        t.equal(copy.edges, edges, "library edge identity, ports, color and semantic role survive reload")
        t.equal(copy.nodes, nodes, "groups do not alter node properties")
        let legacy = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(CanvasDocument(nodes: nodes)))
        t.check(legacy.groups.isEmpty && legacy.nodes.count == 5, "documents without groups remain compatible")
        let anchor = CGPoint(x: 80, y: 100)
        let positions = CanvasGroupLayout.origins(nodes: nodes, edges: edges, at: anchor)
        t.check(positions[ids[0]]!.x < positions[ids[1]]!.x && positions[ids[1]]!.x < positions[ids[2]]!.x,
                "layout follows dependency columns")
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                t.check(!CGRect(origin: positions[ids[i]]!, size: nodes[i].frame.size)
                    .intersects(CGRect(origin: positions[ids[j]]!, size: nodes[j].frame.size)),
                        "layout keeps nodes \(i) and \(j) apart")
            }
        }
        let cyclic = edges + [CanvasEdge(fromNodeId: ids[2], toNodeId: ids[0])]
        t.equal(CanvasGroupLayout.origins(nodes: nodes, edges: cyclic, at: anchor).count, nodes.count,
                "layout handles cycles without dropping nodes or looping")
        t.equal(CanvasGroupLayout.origins(nodes: nodes, edges: [], at: anchor).count, nodes.count,
                "unconnected nodes receive a complete grid")
    } catch { t.check(false, "group persistence: \(error)") }

    t.withFreshStore("archive transaction") { storage in
        let page = try storage.createPage(name: "目标页面", withDefaultGroup: false)
        let group = try storage.createSpecialSlot(name: "目标组", pageId: page.page.id)
        let privateStorage = SpecialSlotStorage.canvasPrivate
        let privateGroup = try privateStorage.ensureReservedGroup(id: "__canvas__archive-test", name: "未入库")
        var content = SlotContent(text: "  # 完整正文🙂\n路径 /tmp/a & b\n")
        content.attachments = [.init(name: "参考.png", type: .image, data: Data([1, 3, 5, 7]))]
        content.label = "原节点标题"
        content.manualThumbnailId = UUID().uuidString
        content.pendingManualThumbnailData = Data([2, 4, 6, 8])
        t.check(privateStorage.set(1, content: content, in: privateGroup.id, replacingLabel: true), "archive source fixture")
        t.check(storage.setLabel(3, label: "计划标签", in: group.id), "archive empty target label fixture")
        let source = CanvasArchiveTransfer.Location(storage: privateStorage, groupID: privateGroup.id, slot: 1)
        let target = CanvasArchiveTransfer.Location(storage: storage, groupID: group.id, slot: 3)
        let current = storage.loadIndex().currentSpecialSlotId
        t.expectThrows("archive refuses incorrect page-group association") {
            _ = try CanvasArchiveTransfer.begin(source: source, target: target, pageID: "wrong")
        }
        let transfer = try CanvasArchiveTransfer.begin(source: source, target: target, pageID: page.page.id)
        t.check(privateStorage.get(1, in: privateGroup.id).isEmpty, "archive vacates original body")
        t.equal(storage.get(3, in: group.id).plainText, content.plainText, "archive preserves exact text")
        t.equal(storage.get(3, in: group.id).attachments.first?.resolveData(), Data([1, 3, 5, 7]), "archive preserves attachment bytes")
        t.equal(try Data(contentsOf: storage.manualThumbnailURL(3, in: group.id)!), Data([2, 4, 6, 8]), "archive preserves manual thumbnail bytes")
        t.equal(storage.getLabel(3, in: group.id), content.label, "archive moves label atomically with content")
        t.equal(privateStorage.getLabel(1, in: privateGroup.id), nil, "archive clears original label")
        t.equal(storage.loadIndex().currentSpecialSlotId, current, "archive does not navigate editor")
        try transfer.exchange(undo: true)
        t.equal(privateStorage.get(1, in: privateGroup.id).plainText, content.plainText, "undo restores body")
        t.equal(privateStorage.get(1, in: privateGroup.id).attachments.first?.resolveData(), Data([1, 3, 5, 7]), "undo restores attachment bytes")
        t.equal(try Data(contentsOf: privateStorage.manualThumbnailURL(1, in: privateGroup.id)!), Data([2, 4, 6, 8]), "undo restores manual thumbnail bytes")
        t.equal(storage.getLabel(3, in: group.id), "计划标签", "undo restores pre-existing empty-slot label")
        t.check(storage.get(3, in: group.id).isEmpty, "undo empties destination")
        try transfer.exchange(undo: false)
        t.equal(storage.get(3, in: group.id).plainText, content.plainText, "redo restores archived body")
        t.equal(storage.getLabel(3, in: group.id), content.label, "redo restores moved label")
        t.equal(try Data(contentsOf: storage.manualThumbnailURL(3, in: group.id)!), Data([2, 4, 6, 8]), "redo restores manual thumbnail bytes")
        t.expectThrows("second move refuses an occupied destination") {
            _ = try CanvasArchiveTransfer.begin(source: source, target: target, pageID: page.page.id)
        }
        t.check(storage.set(3, content: .init(text: "外部新内容"), in: group.id), "external edit fixture")
        t.expectThrows("undo refuses to overwrite external edits") { try transfer.exchange(undo: true) }
        t.equal(storage.get(3, in: group.id).plainText, "外部新内容", "undo conflict preserves newer content")
        t.check(privateStorage.get(1, in: privateGroup.id).isEmpty, "conflict changes neither endpoint")
    }
}
