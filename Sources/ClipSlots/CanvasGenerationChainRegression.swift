#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runGenerationChainProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        var expectedSubmissions = 0
        var observations: [[String: Any]] = []
        func check(_ valid: Bool, _ title: String) {
            if valid { passed += 1 } else { failures.append(title) }
            NSLog("[GenerationChain] \(valid ? "PASS" : "FAIL") \(title)")
        }
        func settle(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .seconds(seconds)) }
        func report(_ complete: Bool) {
            let value: [String: Any] = ["passed": passed, "failures": failures, "complete": complete,
                "expectedCrateSubmissions": expectedSubmissions, "observations": observations,
                "scope": "actual app generation pipeline and real installed CLI parameter builder, local test media"]
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
        }
        modelCatalog.reload()
        for _ in 0..<100 { if !modelCatalog.isLoading { break }; await settle(0.05) }
        check(modelCatalog.model(id: "seedream45")?.imageMinimumPixels == 3_686_400,
              "actual Seedream 4.5 manifest minimum area is parsed")
        canvas.isLibraryExpanded = false
        let mode = ProcessInfo.processInfo.environment["CLIPSLOTS_CHAIN_MODE"] ?? "counts"
        if mode == "independence" {
            await runImageIndependenceProbe(directory: directory)
            return
        }
        if mode == "ratios" {
            for model in ["seedream45", "seedream5", "seedream5-pro"] {
                guard let info = modelCatalog.model(id: model) else {
                    check(false, "missing \(model) live catalog fixture"); continue
                }
                for quality in CanvasImageConfiguration.qualities(for: info).filter({ $0 != "4K" }) {
                    for ratio in CanvasImageConfiguration.ratios {
                        guard let source = createNode(kind: .image, at: CGPoint(x: 300, y: 240),
                            parentNodeId: nil, beginEditing: false, quiet: true) else {
                            check(false, "create ratio fixture"); continue
                        }
                        commitEdit(source, text: "生成比例校验 \(model) \(quality) \(ratio)")
                        canvas.updateNode(id: source.id) { $0.mediaRole = .generation }
                        canvas.updateNodeGeneration(id: source.id, model: model, ratio: ratio,
                                                    count: 1, resolution: quality)
                        let configured = canvas.node(id: source.id)!
                        let plan = CanvasWorkflowCapture.plan(node: configured, canvas: canvas, store: store)
                        let expected = CanvasImageConfiguration.dimensions(ratio: ratio, quality: quality, model: info)!
                        let prefix = "\(model) \(quality) \(ratio)"
                        check(plan.imageRequest?.width == expected.width &&
                              plan.imageRequest?.height == expected.height, "\(prefix) resolves explicit dimensions")
                        let before = canvas.nodes.count
                        if let task = generateAdjacentResults(configured) {
                            expectedSubmissions += 1
                            await task.value
                        } else { check(false, "\(prefix) starts generation") }
                        check(canvas.nodes.count == before, "\(prefix) count one uses original node")
                        guard let latest = canvas.node(id: source.id) else { continue }
                        check(latest.taskId != nil && latest.outputAttachmentIds.count == 1,
                              "\(prefix) stores output on starting node")
                        if let media = previewableMedia(of: latest) {
                            let facts = await CanvasMediaProbe.load(for: media).facts
                            check(facts.pixelSize == CGSize(width: expected.width, height: expected.height),
                                  "\(prefix) decodes requested output pixel dimensions")
                            check(abs((facts.pixelSize!.width / facts.pixelSize!.height) -
                                CanvasNodeSizing.aspectRatio(ratio)!) < 0.003,
                                  "\(prefix) media aspect matches selection")
                        } else { check(false, "\(prefix) result is previewable") }
                        synchronizeMediaLayouts()
                        await mediaLayoutTask?.value
                        let rendered = canvas.node(id: source.id)!
                        check(abs(rendered.width / rendered.height - CanvasNodeSizing.aspectRatio(ratio)!) < 0.003,
                              "\(prefix) rendered card retains generated aspect")
                        observations.append(["kind": "ratio", "model": model, "quality": quality,
                            "ratio": ratio, "width": expected.width, "height": expected.height,
                            "node": source.id, "task": latest.taskId ?? ""])
                        report(false)
                    }
                }
            }
            // Cold catalog must still avoid a square request for supported Seedream models.
            var cold = CanvasNode(pageId: "p", groupId: "g", slot: 1, kind: .image,
                                  x: 0, y: 0, width: 400, height: 225)
            cold.model = "seedream45"; cold.ratio = "16:9"; cold.count = 4
            let fact = CanvasWorkflowFacts(node: cold, title: "", body: "cold catalog", bodyRevision: "")
            let request = CanvasWorkflowResolver.resolve(fact, all: [cold.id: fact], edges: []).imageRequest
            check(request?.width == 2560 && request?.height == 1440 && request?.count == 1,
                  "cold catalog and count four resolve one explicit 16:9 task")
        } else {
            let positions = [CGPoint(x: -1400, y: -700), .zero,
                             CGPoint(x: 1800, y: 320), CGPoint(x: 100000, y: 1800)]
            for kind in [CanvasNodeKind.image, .video] {
                for (index, origin) in positions.enumerated() {
                    for count in (index == 0 ? [1, 2, 3, 4] : [4]) {
                        guard let source = createNode(kind: kind, at: origin, parentNodeId: nil,
                            beginEditing: false, quiet: true) else {
                            check(false, "create count fixture"); continue
                        }
                        commitEdit(source, text: "批量起始节点 \(kind.rawValue) \(index) \(count)")
                        canvas.updateNode(id: source.id) { $0.mediaRole = .generation }
                        canvas.updateNodeGeneration(id: source.id,
                            model: kind == .image ? "seedream45" : "seedance2-mini",
                            ratio: "16:9", count: count, resolution: kind == .image ? "2K" : "720p")
                        canvas.select(id: source.id, additive: false)
                        let configured = canvas.node(id: source.id)!
                        let before = Set(canvas.nodes.map(\.id))
                        let prefix = "\(kind.rawValue) start\(index) count\(count)"
                        let preflight = CanvasWorkflowCapture.plan(node: configured, canvas: canvas, store: store)
                        check(preflight.blockingReasons.isEmpty, "\(prefix) preflight: \(preflight.blockingReasons)")
                        let task = generateAdjacentResults(configured)
                        if task != nil { expectedSubmissions += count }
                        check(task != nil, "\(prefix) starts batch \(task == nil ? store.transientUI.toastMessage ?? "nil" : "")")
                        let added = canvas.nodes.filter { !before.contains($0.id) }.sorted { $0.x < $1.x }
                        check(added.count == count - 1, "\(prefix) creates exactly N minus one later nodes")
                        check(canvas.soleSelectedNode?.id == source.id, "\(prefix) keeps starting node selected")
                        check(generateAdjacentResults(configured) == nil, "\(prefix) blocks duplicate click")
                        check(canvas.node(id: source.id)?.frame == configured.frame,
                              "\(prefix) leaves starting position unchanged")
                        check(added.allSatisfy { $0.y == configured.y && $0.x >= configured.frame.maxX + 28 },
                              "\(prefix) later nodes stay aligned after starting node")
                        check(zip(added, added.dropFirst()).allSatisfy { $0.frame.maxX + 28 <= $1.x },
                              "\(prefix) consecutive later nodes do not overlap")
                        if count > 1 {
                            check(canvas.undo() == nil, "\(prefix) cannot undo submitting result nodes")
                        }
                        await task?.value
                        let ids = [source.id] + added.map(\.id)
                        let completed = ids.compactMap { canvas.node(id: $0) }
                        check(completed.count == count && completed.allSatisfy {
                            if case .succeeded = $0.state { return $0.taskId != nil }; return false
                        }, "\(prefix) all N outputs include starting node")
                        check(Set(completed.compactMap(\.taskId)).count == count,
                              "\(prefix) each output has independent task identity")
                        check(ids == canvas.adjacentLastResultIDs[source.id], "\(prefix) result order begins at source")
                        if count == 4 {
                            let latest = canvas.node(id: source.id)!
                            check(canvas.undo() != nil && added.allSatisfy { canvas.node(id: $0.id) == nil }
                                  && canvas.node(id: source.id)?.taskId == latest.taskId,
                                  "\(prefix) undo removes only added nodes and retains first output")
                            check(canvas.redo() != nil && completed.allSatisfy {
                                canvas.node(id: $0.id)?.taskId == $0.taskId
                            }, "\(prefix) redo restores outputs without resubmission")
                        }
                        synchronizeMediaLayouts()
                        await mediaLayoutTask?.value
                        check(canvas.node(id: source.id)?.frame.origin == configured.frame.origin,
                              "\(prefix) media layout preserves starting origin")
                        observations.append(["kind": "count", "mediaKind": kind.rawValue,
                            "startIndex": index, "x": origin.x, "y": origin.y, "count": count,
                            "source": source.id, "outputs": ids])
                        report(false)
                    }
                }
            }
            // Selection generation must use the new first output as the dependent input.
            let image = createNode(kind: .image, at: CGPoint(x: 120, y: 200), parentNodeId: nil,
                                   beginEditing: false, quiet: true)!
            let video = createNode(kind: .video, at: CGPoint(x: 620, y: 200), parentNodeId: image.id,
                                   beginEditing: false, quiet: true)!
            commitEdit(image, text: "依赖图像"); commitEdit(video, text: "依赖视频")
            canvas.updateNode(id: image.id) { $0.mediaRole = .generation }
            canvas.updateNodeGeneration(id: image.id, model: "seedream45", ratio: "16:9", count: 1, resolution: "2K")
            canvas.updateNodeGeneration(id: video.id, model: "seedance2-mini", ratio: "16:9", count: 1)
            let before = canvas.nodes.count
            runGeneration(nodeIDs: [image.id, video.id])
            expectedSubmissions += 2
            await canvas.selectionGenerationTask?.value
            check(canvas.nodes.count == before, "dependency count one creates no extra nodes")
            check([image.id, video.id].allSatisfy {
                if case .succeeded = canvas.node(id: $0)?.state { return true }; return false
            }, "dependent image and video generate on original starting nodes")
            let crowded = canvas.createProject(name: "容量边界")
            _ = crowded
            await settle()
            let edgeSource = createNode(kind: .image, at: CGPoint(x: 120, y: 240),
                parentNodeId: nil, beginEditing: false, quiet: true)!
            commitEdit(edgeSource, text: "容量不足必须保持起始节点")
            canvas.updateNode(id: edgeSource.id) { $0.mediaRole = .generation }
            canvas.updateNodeGeneration(id: edgeSource.id, ratio: "16:9", count: 4)
            for slot in 2...59 {
                _ = canvas.placeSlot(pageId: edgeSource.pageId, groupId: canvas.privateGroupId,
                    slot: slot, name: "占用", at: CGPoint(x: 1000 + slot * 30, y: 1200), kind: .text)
            }
            let beforeCapacity = canvas.nodes.count
            let candidate = canvas.node(id: edgeSource.id)!
            check(generateAdjacentResults(candidate) == nil, "count four refuses insufficient free slots")
            check(canvas.nodes.count == beforeCapacity && canvas.node(id: edgeSource.id)?.taskId == nil,
                  "capacity refusal adds no partial nodes and submits no task")
            canvas.updateNodeGeneration(id: edgeSource.id, count: 1)
            if let task = generateAdjacentResults(canvas.node(id: edgeSource.id)!) {
                expectedSubmissions += 1
                await task.value
            }
            check(canvas.nodes.count == beforeCapacity && canvas.node(id: edgeSource.id)?.taskId != nil,
                  "count one works at capacity without allocating another slot")
        }
        report(true)
        NSApp.terminate(nil)
    }
}
#endif
