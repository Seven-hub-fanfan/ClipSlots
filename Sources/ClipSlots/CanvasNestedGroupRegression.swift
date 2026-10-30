#if DEBUG
import Foundation
import AppKit
import CoreGraphics
import ClipSlotsKit

/// Parent-agent entry point. Exercises the production Store, not GUI events.
/// Uses a fresh temporary root and never opens or edits the user's data.
enum CanvasNestedGroupRegression {
    /// Runs before application startup in a dedicated test bundle. No window,
    /// production root, preferences migration or external integration is needed.
    @MainActor static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPSLOTS_STORE_REGRESSION"] == "1" else { return }
        guard Bundle.main.bundleIdentifier == "com.clipslots.app.store-regression",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true,
              let folder = env["CLIPSLOTS_DATA_DIR"], folder.hasPrefix("/tmp/clipslots-store-regression-"),
              env["CLIPSLOTS_CONFIG_PATH"] == folder + "/config.toml" else { exit(2) }
        let directory = URL(fileURLWithPath: folder).standardizedFileURL
        let resolved = directory.resolvingSymlinksInPath().path
        guard resolved == directory.path || resolved == "/private" + directory.path else { exit(2) }
        if env["CLIPSLOTS_ARTIFACT_PAGE_REGRESSION"] == "1" || env["CLIPSLOTS_APP_REPLY_PAGE_REGRESSION"] == "1"
            || env["CLIPSLOTS_ARTIFACT_PRESENTATION_REGRESSION"] == "1"
            || env["CLIPSLOTS_ARTIFACT_REMOTE_PANEL_REGRESSION"] == "1"
            || env["CLIPSLOTS_ARTIFACT_HTTPS_REGRESSION"] == "1"
            || env["CLIPSLOTS_ARTIFACT_TEMPLATE_REGRESSION"] == "1" {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let report: [String: Any]
                if env["CLIPSLOTS_ARTIFACT_REMOTE_PANEL_REGRESSION"] == "1" {
                    report = await runArtifactRemotePanelRegression(directory: directory)
                } else if env["CLIPSLOTS_ARTIFACT_HTTPS_REGRESSION"] == "1" {
                    report = await runArtifactHTTPSRegression(directory: directory)
                } else if env["CLIPSLOTS_ARTIFACT_TEMPLATE_REGRESSION"] == "1" {
                    report = await runArtifactTemplateRegression(directory: directory)
                } else if env["CLIPSLOTS_ARTIFACT_PRESENTATION_REGRESSION"] == "1" {
                    report = await runArtifactPresentationRegression(directory: directory)
                } else if env["CLIPSLOTS_APP_REPLY_PAGE_REGRESSION"] == "1" {
                    report = await runAppReplyPageRegression(directory: directory)
                } else { report = await runArtifactPageRegression(directory: directory) }
                do {
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
                } catch { exit(2) }
                exit((report["failures"] as? [String])?.isEmpty == true ? 0 : 1)
            }
            NSApplication.shared.run()
            exit(2)
        }
        if env["CLIPSLOTS_READBACK_REGRESSION"] == "1" || env["CLIPSLOTS_CLOUD_SESSION_REGRESSION"] == "1"
            || env["CLIPSLOTS_CONTEXT_USAGE_REGRESSION"] == "1" || env["CLIPSLOTS_SUBAGENT_REGRESSION"] == "1"
            || env["CLIPSLOTS_STEER_REGRESSION"] == "1" || env["CLIPSLOTS_DECISION_REGRESSION"] == "1" {
            Task { @MainActor in
                let report: [String: Any]
                if env["CLIPSLOTS_DECISION_REGRESSION"] == "1" {
                    report = await runGatewayDecisionRegression(directory: directory)
                } else if env["CLIPSLOTS_STEER_REGRESSION"] == "1" {
                    report = await runGatewaySteerRegression(directory: directory)
                } else if env["CLIPSLOTS_SUBAGENT_REGRESSION"] == "1" {
                    report = await runTaskSubagentRegression(directory: directory)
                } else if env["CLIPSLOTS_CONTEXT_USAGE_REGRESSION"] == "1" {
                    report = await runContextUsageRegression(directory: directory)
                } else if env["CLIPSLOTS_CLOUD_SESSION_REGRESSION"] == "1" {
                    report = await runCloudSessionRegression(directory: directory)
                } else { report = await runCanvasReadbackRegression(directory: directory) }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
                } catch { exit(2) }
                exit((report["failures"] as? [String])?.isEmpty == true ? 0 : 1)
            }
            dispatchMain()
        }
        let report = run()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch { exit(2) }
        exit((report["failures"] as? [String])?.isEmpty == true ? 0 : 1)
    }

    @MainActor static func run() -> [String: Any] {
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let storage = CanvasStorage(rootOverride: root)
            let projects = CanvasProjectStorage(rootOverride: root)
            let index = projects.load()
            let a = CanvasNode(pageId: "page", groupId: "storage", slot: 1, kind: .text, x: 140, y: 180)
            let b = CanvasNode(pageId: "page", groupId: "storage", slot: 2, kind: .text, x: 470, y: 270)
            let parent = CanvasNodeGroup(id: "parent", nodeIDs: [a.id],
                containerFrame: CGRect(x: 100, y: 100, width: 1300, height: 1100),
                layoutType: .grid, createdBy: .server)
            let child = CanvasNodeGroup(id: "child", nodeIDs: [b.id],
                containerFrame: CGRect(x: 420, y: 220, width: 600, height: 600),
                parentGroupID: parent.id, createdBy: .server)
            let edge = CanvasEdge(id: "store-edge", fromNodeId: a.id, toNodeId: b.id)
            let original = CanvasDocument(nodes: [a, b], edges: [edge], groups: [child, parent])
            guard storage.save(original, projectId: index.activeProjectId) else {
                throw AgentOperationError("Store fixture 保存失败。")
            }
            let store = CanvasStore(storage: storage, projectStorage: projects)
            store.selectGroup(parent.id)
            check(store.selectedNodeIds == [a.id, b.id], "父组选中全部后代")
            check(store.groupDragEntityIDs(parent.id) == [a.id, b.id], "父组拖动预览集合")
            let cursor = store.history.cursor
            store.moveGroup(parent.id, by: CGSize(width: 40, height: -15))
            check(store.node(id: b.id)?.frame.origin == CGPoint(x: 510, y: 255), "真实 Store 父组移动后代一次")
            check(store.groups.first(where: { $0.id == child.id })?.containerFrame?.origin == CGPoint(x: 460, y: 205),
                  "真实 Store 父组移动子边界")
            check(store.history.cursor == cursor + 1, "真实 Store 群组移动单 undo 事务")
            check(store.undo() != nil && store.nodes == original.nodes && store.groups == original.groups,
                  "真实 Store undo 恢复完整层级")
            check(store.redo() != nil && store.node(id: b.id)?.x == 510, "真实 Store redo 恢复后代世界位置")
            _ = store.undo()
            for handle in CanvasGroupResizeHandle.allCases {
                guard let frame = parent.containerFrame else { continue }
                let resized = CanvasGroupGeometry.resized(frame, handle: handle, delta: CGSize(width: 20, height: 10))
                store.resizeGroup(parent.id, frame: resized)
                let delta = CGSize(width: resized.minX - frame.minX, height: resized.minY - frame.minY)
                check(store.node(id: b.id)?.frame.origin == CGPoint(x: b.x + delta.width, y: b.y + delta.height),
                      "真实 Store \(handle) resize 传递 origin")
                check(store.node(id: b.id)?.frame.size == b.frame.size && store.edges == [edge],
                      "真实 Store \(handle) resize 不缩放媒体/不改边")
                _ = store.undo()
                check(store.nodes == original.nodes && store.groups == original.groups,
                      "真实 Store \(handle) resize undo")
            }
            store.ungroupGroup(parent.id)
            check(store.groups.count == 1 && store.groups[0].parentGroupID == nil,
                  "真实 Store 解父组提升子容器")
            check(store.nodes == original.nodes && store.edges == [edge], "真实 Store 解组保留世界位置和连线")
            _ = store.undo()
            check(store.groups == original.groups, "真实 Store 解组 undo")

            // Undo suppression is cleared only by a new confirmed group proposal.
            var renamed = parent
            renamed.name = "服务器更新"
            let proposal = AgentCanvasMutation(projectID: store.activeProjectId, conversationID: "conversation",
                runID: "run", mutationID: "store-group", changes: [],
                groupChanges: [.init(before: parent, after: renamed)])
            let plan = try store.applyGatewayMutation(proposal, conversationID: "conversation", runID: "run",
                                                      contentAvailable: { _ in true })
            check(plan.changedGroupIDs == [parent.id] && store.groups.last?.name == renamed.name,
                  "真实 Store GROUP 生产入口提交")
            let measurements = [a.id: a.frame.size, b.id: b.frame.size]
            let beforeLayout = store.history.cursor
            store.updateGroupMeasurements(measurements, projectID: store.activeProjectId, allowLayout: false)
            check(store.history.cursor == beforeLayout, "真实 Store 拖拽门控不布局")
            store.reconcileMeasuredServerGroups(projectID: store.activeProjectId, allowLayout: false)
            check(store.history.cursor == beforeLayout, "真实 Store reconcile 入口也拒绝 live gesture 写入")
            store.reconcileMeasuredServerGroups(projectID: "old-project", allowLayout: true)
            check(store.history.cursor == beforeLayout, "真实 Store reconcile 入口拒绝旧项目写入")
            store.reconcileMeasuredServerGroups(projectID: store.activeProjectId, allowLayout: true)
            check(store.history.cursor == beforeLayout + 1 && store.serverGroupLayoutStates[parent.id] == .applied,
                  "真实 Store 实际尺寸 ready 记录布局事务")
            check(store.serverGroupLayoutStates[child.id] == .nestedServer, "真实 Store nested server guard")
            let laidOut = store.groups
            store.reconcileMeasuredServerGroups(projectID: store.activeProjectId, allowLayout: true)
            check(store.history.cursor == beforeLayout + 1 && store.groups == laidOut, "真实 Store 签名去重")
            _ = store.undo()
            store.reconcileMeasuredServerGroups(projectID: store.activeProjectId, allowLayout: true)
            check(store.history.cursor == beforeLayout && store.groups.last?.measuredLayoutSignature == nil,
                  "真实 Store 自动布局 undo 不被回调立即重做")
            check(store.flushSave(), "真实 Store 群组和 receipt 落盘")
            storage.invalidateCache()
            let restarted = CanvasStore(storage: storage, projectStorage: projects)
            let restartPlan = try restarted.applyGatewayMutation(proposal, conversationID: "conversation", runID: "run",
                                                                 contentAvailable: { _ in true })
            check(restartPlan.alreadyApplied && restarted.history.entries.isEmpty, "真实 Store 首次加载恢复 receipt 去重")
            let liveNodes = restarted.nodes, liveGroups = restarted.groups
            var invalid = renamed
            invalid.parentGroupID = child.id
            let bad = AgentCanvasMutation(projectID: restarted.activeProjectId, conversationID: "conversation",
                runID: "run", mutationID: "invalid-group", changes: [],
                groupChanges: [.init(before: renamed, after: invalid)])
            do {
                _ = try restarted.applyGatewayMutation(bad, conversationID: "conversation", runID: "run",
                                                        contentAvailable: { _ in true })
                check(false, "真实 Store 拒绝非法 cycle")
            } catch {
                check(restarted.nodes == liveNodes && restarted.groups == liveGroups && restarted.history.entries.isEmpty,
                      "真实 Store 非法 proposal 原子拒绝")
            }
            let titleHistory = restarted.history.cursor
            restarted.renameGroup(parent.id, name: "   ")
            check(restarted.groups.first(where: { $0.id == parent.id })?.name == "   ",
                  "真实 Store 保留目标实测纯空格标题")
            restarted.renameGroup(parent.id, name: "")
            check(restarted.history.cursor == titleHistory + 1 &&
                  restarted.groups.first(where: { $0.id == parent.id })?.name == "   ",
                  "真实 Store 空标题不改变内容和历史")
            _ = restarted.undo()
            check(restarted.groups == liveGroups, "真实 Store 标题 undo 保留完整配置")
            _ = restarted.redo()
            check(restarted.groups.first(where: { $0.id == parent.id })?.name == "   ", "真实 Store 空格标题 redo")
            restarted.renameGroup(parent.id, name: " REA Group ")
            let sameTitleHistory = restarted.history.cursor
            restarted.renameGroup(parent.id, name: " REA Group ")
            check(restarted.groups.first(where: { $0.id == parent.id })?.name == " REA Group " &&
                  restarted.history.cursor == sameTitleHistory, "真实 Store 保留前后空格并跳过同值更新")

            // Validate the application store transaction, rather than only its
            // shared value helper, for two edges with the same endpoints.
            let edgeRoot = root.appendingPathComponent("edge-store")
            let edgeStorage = CanvasStorage(rootOverride: edgeRoot)
            let edgeProjects = CanvasProjectStorage(rootOverride: edgeRoot)
            let edgeProjectID = edgeProjects.load().activeProjectId
            var source = CanvasNode(pageId: "page", groupId: "edge-storage", slot: 1, kind: .video, x: 0, y: 0)
            source.state = .succeeded(assetPath: "/fixture/draft.mp4")
            source.draftVideoID = "draft-identity"
            source.duration = 6; source.ratio = "16:9"; source.generateAudio = false
            var target = CanvasNode(pageId: "page", groupId: "edge-storage", slot: 2, kind: .video, x: 500, y: 0)
            target.draftReference = CanvasDraftReference()
            target.duration = 3; target.ratio = "1:1"; target.resolution = "1080p"
            guard edgeStorage.save(CanvasDocument(nodes: [source, target]), projectId: edgeProjectID) else {
                throw AgentOperationError("连线 Store fixture 保存失败。")
            }
            let edgeStore = CanvasStore(storage: edgeStorage, projectStorage: edgeProjects)
            check(edgeStore.connect(from: source.id, to: target.id, role: .prompt, purpose: .generationInput) == nil,
                  "真实 Store 创建生成提示词边")
            let beforeReference = edgeStore.nodes, beforeReferenceEdges = edgeStore.edges
            let edgeCursor = edgeStore.history.cursor
            check(edgeStore.connect(from: source.id, to: target.id) == nil &&
                  edgeStore.edges.count == 2 && edgeStore.history.cursor == edgeCursor + 1,
                  "真实 Store 自动用途创建独立引用边且单历史事务")
            let connectedNodes = edgeStore.nodes, connectedEdges = edgeStore.edges
            let connectedTarget = edgeStore.node(id: target.id)
            check(connectedTarget?.draftReference == CanvasDraftReference(sourceNodeID: source.id, videoID: source.draftVideoID)
                  && connectedTarget?.duration == 6 && connectedTarget?.ratio == "16:9"
                  && connectedTarget?.generateAudio == false && connectedTarget?.resolution == "1080p",
                  "真实 Store 引用边和参数同时更新")
            check(edgeStore.connect(from: source.id, to: target.id) == .duplicate &&
                  edgeStore.history.cursor == edgeCursor + 1, "真实 Store 重复引用不写历史")
            _ = edgeStore.undo()
            check(edgeStore.nodes == beforeReference && edgeStore.edges == beforeReferenceEdges,
                  "真实 Store 引用边 undo 精确恢复节点和原边")
            _ = edgeStore.redo()
            check(edgeStore.nodes == connectedNodes && edgeStore.edges == connectedEdges,
                  "真实 Store 引用边 redo 精确恢复")
            check(edgeStore.flushSave(), "真实 Store 混合用途连线落盘")
            edgeStorage.invalidateCache()
            let edgeReload = CanvasStore(storage: edgeStorage, projectStorage: edgeProjects)
            check(edgeReload.nodes == connectedNodes && edgeReload.edges == connectedEdges,
                  "真实 Store 新实例重载保留混合用途和参数")
            if let reference = edgeReload.edges.first(where: { $0.purpose == .draftReference }) {
                check(edgeReload.disconnect(edgeId: reference.id) &&
                      edgeReload.edges == beforeReferenceEdges &&
                      edgeReload.node(id: target.id)?.draftReference == CanvasDraftReference(),
                      "真实 Store 断开引用仅清空引用身份")
                _ = edgeReload.undo()
                check(edgeReload.nodes == connectedNodes && edgeReload.edges == connectedEdges,
                      "真实 Store 断开引用 undo 同时恢复参数")
            } else { check(false, "真实 Store 重载引用边存在") }
        } catch { failures.append("Store 测试准备失败：\(error)") }
        return ["passed": passed, "failures": failures, "evidence": "self-owned-production-store",
                "gui": false, "remote": false]
    }
}
#endif
