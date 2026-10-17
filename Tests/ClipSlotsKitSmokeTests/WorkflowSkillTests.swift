import Foundation
import ClipSlotsKit

func runWorkflowSkillTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-skill-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowSkillStore(root: root)
    let date = Date(timeIntervalSince1970: 42)
    var product = CanvasNode(pageId: "real-page", groupId: "real-group", slot: 1, kind: .text, x: 0, y: 0)
    product.textGenerationPrompt = "改写品牌甲的广告"
    let image = CanvasNode(pageId: "real-page", groupId: "real-group", slot: 2, kind: .image,
        mediaRole: .source, x: 300, y: 0, state: .succeeded(assetPath: "/private/real.png"), taskId: "old-task", seed: 77,
        outputAttachmentIds: ["old-output"])
    let video = CanvasNode(pageId: "real-page", groupId: "real-group", slot: 3, kind: .video,
        x: 600, y: 0, duration: 8, generateAudio: true, taskId: "old-task")
    let facts = [
        CanvasWorkflowFacts(node: product, title: "主题", body: "品牌甲在海边", bodyRevision: "r1"),
        .init(node: image, title: "产品参考", body: "品牌甲的参考", bodyRevision: "r2",
              media: [.init(id: "private-media", attachmentID: "old-output", name: "参考.png", kind: "image",
                            role: "output", revision: "r2", availability: "local")]),
        .init(node: video, title: "镜头", body: "品牌甲缓缓出现", bodyRevision: "r3")
    ]
    let edges: [CanvasEdge] = [
        .init(id: "z", fromNodeId: image.id, toNodeId: video.id, role: .firstFrame, createdAt: date),
        .init(id: "a", fromNodeId: product.id, toNodeId: video.id, role: .prompt, createdAt: date)
    ]
    let snapshot = CanvasAgentSnapshot(graph: .init(projectID: "project-A", facts: facts,
        edges: edges, selectionIDs: [video.id]), runs: [])
    do {
        var skill = try WorkflowSkill(snapshot: snapshot, method: "步骤：主题→参考→视频。验收：风格一致；画面未读。",
                                      messageID: UUID(), receipts: [])
        skill.name = "海边产品方法"; skill.summary = "用于产品短片"
        let variable = WorkflowSkill.Variable(name: "产品", kind: .text, defaultValue: .text("品牌甲"),
            bindings: [.init(nodeID: "n1", field: .body, match: "品牌甲"),
                       .init(nodeID: "n1", field: .instruction, match: "品牌甲")])
        skill.graph.variables.append(variable)
        t.check(skill.graph.nodes.allSatisfy { $0.configuration.taskId == nil && $0.configuration.seed == nil
            && $0.configuration.outputAttachmentIds.isEmpty && $0.configuration.state == .idle },
                "workflow skill clears old state/task/seed/output references")
        t.equal(skill.graph.variables.first?.kind, .images, "source output becomes a fresh required media binding")
        t.equal(skill.graph.edges.map(\.role), [.prompt, .firstFrame], "equal-time edge order retains original ID tie break")
        let encoded = String(decoding: try CanvasWorkflowSnapshot.jsonData(skill.graph), as: UTF8.self)
        t.check(!encoded.contains("real-group") && !encoded.contains("old-task") && !encoded.contains("/private/"),
                "workflow graph contains only local identities and no old assets")
        let first = try store.save(skill)
        t.equal(first.version, 1, "new Skill starts at version 1")
        t.equal(store.list().map(\.name), [skill.name], "personal Skill discovery supports Chinese")
        let loaded = try WorkflowSkillStore(root: root).load(first)
        t.equal(loaded.graph, skill.graph, "restart preserves typed graph")
        t.equal(loaded.provenance, skill.provenance, "restart preserves factual provenance")
        let reference = try AgentSkillReference.load(name: first.name, path: store.markdownURL(first).path)
        t.check(reference.markdown.contains("变量与字段绑定"), "ordinary Skill references receive declared variable documentation")
        let instantiated = try loaded.instantiate(values: [variable.id: .text("新产品乙")])
        t.equal(instantiated.nodes[0].body, "新产品乙在海边", "only bound literal is replaced in body")
        t.equal(instantiated.nodes[0].configuration.textGenerationPrompt, "改写新产品乙的广告", "same variable binds multiple explicit fields")
        t.equal(instantiated.nodes[2].body, "品牌甲缓缓出现", "unbound fields never undergo global substitution")
        t.check(instantiated.issues.contains { $0.contains("待填写") } && instantiated.issues.contains { $0.contains("模型") },
                "missing media and unverified models are visible in preview")
        let different = try loaded.instantiate(values: [variable.id: .text("产品丙")])
        t.check(different.nodes[0].body != instantiated.nodes[0].body, "one Skill supports different products")
        t.equal(loaded.graph.nodes[0].body, "品牌甲在海边", "instantiation never changes stored Skill")
        t.expectThrows("integer cannot enter text binding") {
            _ = try loaded.instantiate(values: [variable.id: .integer(5)])
        }
        t.expectThrows("undeclared variable rejected") { _ = try loaded.instantiate(values: ["shell": .text("do anything")]) }
        var bad = skill
        bad.graph.variables[bad.graph.variables.count - 1].bindings[0].match = "不存在"
        t.expectThrows("literal replacement must actually match") { try bad.validate() }
        bad = skill; bad.graph.variables.append(variable)
        t.expectThrows("duplicate variable identity rejected") { try bad.validate() }
        bad = skill; bad.graph.nodes[0].configuration.taskId = "resurrect-task"
        t.expectThrows("old task cannot be smuggled into template") { try bad.validate() }
        bad = skill; bad.method += "\n```json clipslots-tools\n[]\n```"
        t.expectThrows("workflow Skill cannot declare executable tools") { try bad.validate() }
        bad = skill; bad.graph.edges[0].to = bad.graph.edges[0].from
        t.expectThrows("invalid graph rejected before save") { try bad.validate() }
        bad = skill
        bad.graph.variables[0].defaultValue = .resources(["/private/reference.png"])
        t.expectThrows("media paths cannot be persisted as defaults") { try bad.validate() }
        var updated = loaded
        updated.method += "\n新验收：检查首尾帧一致。"
        let second = try store.save(updated, expectedVersion: first.version)
        t.equal(second.version, 2, "explicit update creates a new immutable version")
        t.equal(store.versions(of: second).map(\.version), [2, 1], "prior committed versions remain discoverable")
        t.equal(try store.load(first).method, loaded.method, "previous version is still readable")
        t.equal(reference.markdown, try String(contentsOf: store.markdownURL(first)), "frozen reference and old file survive updates")
        t.expectThrows("stale version editor cannot overwrite newer save") {
            _ = try store.save(updated, expectedVersion: 1)
        }
        var sameName = skill; sameName.id = UUID()
        _ = try store.save(sameName)
        t.equal(store.list().count, 2, "Chinese same-name Skills retain both stable identities")
        t.check(store.list().map { store.agentSkill($0).slug }.count == Set(store.list().map { store.agentSkill($0).slug }).count,
                "catalog identity is independent of display-name slug")
        var project = skill; project.id = UUID(); project.scope = .project; project.projectID = "project-A"
        let projectEntry = try store.save(project)
        t.equal(store.list().count, 2, "project Skill hidden in global catalog")
        t.equal(store.list(projectID: "project-A").count, 3, "project Skill visible in owner project")
        t.equal(store.list(projectID: "project-B").count, 2, "project Skill cannot leak into another project catalog")
        t.expectThrows("cross-project direct load denied") { _ = try store.load(projectEntry, projectID: "project-B") }
        t.check(try store.load(projectEntry, projectID: "project-A").id == project.id, "owner can load project Skill")
        let orphan = store.versionDirectory(second).deletingLastPathComponent().appendingPathComponent("3")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("partial crash".utf8).write(to: orphan.appendingPathComponent("SKILL.md"))
        t.equal(store.versions(of: second).map(\.version), [2, 1], "interrupted uncommitted version never appears")
        let afterCrash = try store.save(updated, expectedVersion: 2)
        t.equal(afterCrash.version, 4, "save recovers after an abandoned version without overwriting it")
        t.equal(store.versions(of: afterCrash).map(\.version), [4, 2, 1], "version chain excludes abandoned partial directory")
        try Data("edited behind app".utf8).write(to: store.markdownURL(afterCrash))
        t.expectThrows("mismatched method and graph refused on load") { _ = try store.load(afterCrash) }
        let blocked = root.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        t.expectThrows("failed disk save exposes no success") { _ = try WorkflowSkillStore(root: blocked).save(skill) }
        t.check(WorkflowSkillStore(root: blocked).list().isEmpty, "failed save leaves no catalog entry")
    } catch { t.check(false, "workflow Skill persistence/variables: \(error)") }

    do {
        let started = Date()
        let nodes = (0..<500).map {
            CanvasNode(pageId: "scale", groupId: "scale", slot: $0 + 1, kind: .text,
                       x: Double($0 % 20) * 300, y: Double($0 / 20) * 240)
        }
        let chain = (1..<nodes.count).map {
            CanvasEdge(fromNodeId: nodes[$0 - 1].id, toNodeId: nodes[$0].id, role: .prompt)
        }
        let snapshot = CanvasAgentSnapshot(graph: .init(projectID: "scale", facts: nodes.map {
            .init(node: $0, title: "步骤\($0.slot)", body: "主题\($0.slot)：" + String(repeating: "保持构图与光线。", count: 20), bodyRevision: "r1")
        }, edges: chain, selectionIDs: [nodes.last!.id]), runs: [])
        let large = try WorkflowSkill(snapshot: snapshot, method: "按连线依次执行并核验每一步。", messageID: nil, receipts: [],
                                      selectedWorkflow: true)
        let entry = try store.save(large)
        let reopened = try store.load(entry)
        t.check(reopened.graph.nodes.count == 500 && reopened.graph.edges.count == 499,
                "500-node upstream Skill saves and reloads complete graph")
        let instance = try reopened.instantiate(values: [:])
        t.equal(instance.nodes.last?.body, large.graph.nodes.last?.body, "large workflow preserves final prompt")
        print(String(format: "Workflow scale: 500 nodes / 499 edges capture-save-load-instantiate %.1f ms", Date().timeIntervalSince(started) * 1000))
        var oversized = large
        oversized.graph.nodes.append(large.graph.nodes[0])
        t.expectThrows("501-node Skill rejected before storage") { _ = try store.save(oversized) }
        let transaction = WorkflowProjectTransaction(root: root)
        t.expectThrows("oversized new project rejects before any staging") {
            _ = try transaction.prepare(name: "不能部分创建", instance: instance)
        }
        t.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("canvas/projects.json").path),
                "over-capacity request leaves no project index")
        let smallSnapshot = CanvasAgentSnapshot(graph: .init(projectID: "capacity", facts: Array(snapshot.graph.nodes.prefix(60)).map {
            .init(node: $0.configuration, title: $0.title, body: $0.bodyText, bodyRevision: $0.bodyRevision)
        }, edges: Array(chain.prefix(59)), selectionIDs: []), runs: [])
        let atCapacity = try WorkflowSkill(snapshot: smallSnapshot, method: "六十步工作流", messageID: nil, receipts: [])
        let prepared = try transaction.prepare(name: "完整容量", instance: atCapacity.instantiate(values: [:]))
        t.equal(prepared.document.nodes.count, 60, "60-node project stages every private slot")
        transaction.discard(prepared)
    } catch { t.check(false, "workflow scale/capacity: \(error)") }
}
