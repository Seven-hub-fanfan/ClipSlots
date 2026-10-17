import Foundation
import ClipSlotsKit

func runCanvasEdgePurposeTests(_ t: TestRunner) {
    let date = Date(timeIntervalSince1970: 1234)
    func node(_ slot: Int, _ kind: CanvasNodeKind) -> CanvasNode {
        CanvasNode(pageId: "purpose-page", groupId: "purpose-group", slot: slot, kind: kind,
                   x: 0, y: 0, createdAt: date, updatedAt: date)
    }
    var source = node(1, .video)
    source.state = .succeeded(assetPath: "/fixture/draft.mp4")
    source.draftVideoID = "draft-file-1"
    source.duration = 6
    source.ratio = "16:9"
    source.generateAudio = false
    var target = node(2, .video)
    target.draftReference = CanvasDraftReference()
    target.duration = 3
    target.ratio = "1:1"
    target.resolution = "1080p"
    let text = node(3, .text)
    let image = node(4, .image)
    let reference = CanvasEdge(id: "draft", fromNodeId: source.id, toNodeId: target.id,
                               purpose: .draftReference, createdAt: date)
    let prompt = CanvasEdge(id: "prompt", fromNodeId: source.id, toNodeId: target.id,
                            role: .prompt, createdAt: date)
    let nodes = [source, target, text, image]

    // Old edges keep their exact role/default execution semantics.
    do {
        let old = Data(#"{"id":"old","fromNodeId":"a","toNodeId":"b","role":"lastFrame","createdAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(CanvasEdge.self, from: old)
        t.equal(decoded.purpose, .generationInput, "purpose: legacy edge defaults to generation input")
        t.equal(decoded.role, .lastFrame, "purpose: legacy role preserved")
        t.check(decoded.purpose.isGenerationDependency, "purpose: legacy edge remains a DAG dependency")
        let bytes = try JSONEncoder().encode(decoded)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        t.check(object?["purpose"] == nil, "purpose: default omitted for legacy encoding compatibility")
        t.equal(try JSONDecoder().decode(CanvasEdge.self, from: bytes), decoded, "purpose: old edge roundtrip")
        let explicit = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any]
        t.equal(explicit?["purpose"] as? String, "draft-reference", "purpose: reference encoded explicitly")
        t.equal(try JSONDecoder().decode(CanvasEdge.self, from: JSONEncoder().encode(reference)),
                reference, "purpose: reference edge roundtrip")
        t.expectThrows("purpose: unknown purpose is not silently promoted to generation") {
            _ = try JSONDecoder().decode(CanvasEdge.self, from:
                Data(#"{"fromNodeId":"a","toNodeId":"b","purpose":"future-reference"}"#.utf8))
        }
        let oldNode = try JSONDecoder().decode(CanvasNode.self, from:
            Data(#"{"pageId":"p","groupId":"g","slot":1,"kind":"video","mediaRole":"generation"}"#.utf8))
        t.check(oldNode.draftVideoID == nil && oldNode.draftReference == nil, "purpose: old node has no draft capability")
        t.equal(CanvasEdgeGraph.defaultPurpose(for: oldNode), .generationInput, "purpose: old target default unchanged")
        let legacyEdge = CanvasEdge(id: "kept-old", fromNodeId: text.id, toNodeId: image.id, createdAt: date)
        var document = try JSONSerialization.jsonObject(with:
            JSONEncoder().encode(CanvasDocument(nodes: [text, image], edges: [legacyEdge]))) as? [String: Any] ?? [:]
        var records = document["edges"] as? [[String: Any]] ?? []
        records.append(["id": "unknown", "fromNodeId": image.id, "toNodeId": text.id, "purpose": "future-reference"])
        document["edges"] = records
        let lenient = try JSONDecoder().decode(CanvasDocument.self, from:
            JSONSerialization.data(withJSONObject: document))
        t.equal(lenient.nodes, [text, image], "purpose: unknown edge does not discard document nodes")
        t.equal(lenient.edges, [legacyEdge], "purpose: unknown edge is dropped, not converted into cyclic generation")
    } catch { t.check(false, "purpose: compatibility fixture: \(error)") }

    t.equal(CanvasEdgeGraph.defaultPurpose(for: target), .draftReference, "purpose: opted-in target derives reference")
    t.check(CanvasEdgeGraph.capabilities(of: source).contains(.draftReferenceOutput),
            "purpose: ready draft source advertises typed output capability")
    t.check(CanvasEdgeGraph.capabilities(of: target).contains(.draftReferenceInput),
            "purpose: opted-in target advertises typed input capability")
    t.check(!CanvasEdgeGraph.capabilities(of: image).contains(.draftReferenceOutput),
            "purpose: image has no video draft capability")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [],
                                      purpose: .draftReference), nil, "purpose: capable video draft connects")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [prompt],
                                      purpose: .draftReference), nil, "purpose: same direction allowed for distinct purposes")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [reference],
                                      role: .prompt), nil, "purpose: reverse insertion order also allows distinct purposes")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [reference],
                                      purpose: .draftReference), .duplicate, "purpose: duplicate reference rejected")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [prompt],
                                      role: .auto), .duplicate, "purpose: roles do not bypass purpose duplicate check")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: source.id, nodes: nodes, edges: [],
                                      purpose: .draftReference), .selfLoop, "purpose: reference self-loop rejected")
    t.equal(CanvasEdgeGraph.canConnect(from: "missing", to: target.id, nodes: nodes, edges: [],
                                      purpose: .draftReference), .missingNode, "purpose: missing source rejected")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: "missing", nodes: nodes, edges: [],
                                      purpose: .draftReference), .missingNode, "purpose: missing target rejected")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: [], edges: []),
            .missingNode, "purpose: typed validation never skips an empty node inventory")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [],
                                      purpose: .draftReference, connectable: false), .disabled, "purpose: disabled policy rejected")
    t.equal(CanvasEdgeGraph.canConnect(from: image.id, to: target.id, nodes: nodes, edges: [],
                                      purpose: .draftReference), .incompatibleType, "purpose: image cannot supply video draft")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: nodes, edges: [],
                                      purpose: .draftReference, role: .lastFrame),
            .incompatibleType, "purpose: media roles are not draft purposes")
    var normalTarget = target
    normalTarget.draftReference = nil
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: [source, normalTarget], edges: [],
                                      purpose: .draftReference), .unsupportedPurpose, "purpose: target must opt into references")
    var pending = source
    pending.state = .idle
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: [pending, target], edges: [],
                                      purpose: .draftReference), .unsupportedCapability, "purpose: pending source has no draft output")
    pending = source
    pending.draftVideoID = " "
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: target.id, nodes: [pending, target], edges: [],
                                      purpose: .draftReference), .unsupportedCapability, "purpose: missing video identity rejected")
    var mediaSource = target
    mediaSource.mediaRole = .source
    t.equal(CanvasEdgeGraph.canConnect(from: text.id, to: target.id, nodes: [text, mediaSource], edges: []),
            .unsupportedCapability, "purpose: media-source target cannot consume generation")
    t.equal(CanvasEdgeGraph.canConnect(from: source.id, to: image.id, nodes: nodes, edges: []),
            .incompatibleType, "purpose: video cannot be auto image input")
    t.equal(CanvasEdgeGraph.canConnect(from: text.id, to: target.id, nodes: nodes, edges: [], role: .firstFrame),
            .incompatibleType, "purpose: text cannot provide explicit frame")
    t.equal(CanvasEdgeGraph.canConnect(from: image.id, to: target.id, nodes: nodes, edges: [], role: .firstFrame),
            nil, "purpose: image can provide explicit video frame")
    var secondSource = source
    secondSource.slot = 5
    t.equal(CanvasEdgeGraph.canConnect(from: secondSource.id, to: target.id, nodes: nodes + [secondSource],
                                      edges: [reference], purpose: .draftReference),
            .duplicate, "purpose: target cannot have two single-valued draft references")

    // Graph algorithms do not grant application-level capability to arbitrary reference cycles.
    let reverseReference = CanvasEdge(id: "reverse-reference", fromNodeId: target.id, toNodeId: source.id,
                                      purpose: .draftReference, createdAt: date)
    let reverseGeneration = CanvasEdge(id: "reverse-generation", fromNodeId: target.id, toNodeId: source.id,
                                       role: .prompt, createdAt: date.addingTimeInterval(1))
    let mixedCycle = [prompt, reverseReference]
    t.equal(CanvasEdgeGraph.normalized([prompt, reference, prompt], nodeIds: Set(nodes.map(\.id))).map(\.id),
            ["prompt", "draft"], "purpose: normalization dedupes by endpoint and purpose")
    t.equal(CanvasEdgeGraph.normalized(mixedCycle, nodeIds: Set(nodes.map(\.id))), mixedCycle,
            "purpose: mixed reference cycle survives normalization")
    t.equal(CanvasEdgeInputs.generationOrder(nodes: [target, source], edges: mixedCycle)?.map(\.id),
            [source.id, target.id], "purpose: mixed cycle has a valid execution DAG")
    let onlyReferences = [reference, reverseReference]
    t.equal(CanvasEdgeGraph.normalized(onlyReferences, nodeIds: Set(nodes.map(\.id))), onlyReferences,
            "purpose: reference-only cycle is not broken by execution normalization")
    t.equal(CanvasEdgeInputs.generationOrder(nodes: [target, source], edges: onlyReferences)?.map(\.id),
            [target.id, source.id], "purpose: references do not reorder independent generation")
    t.equal(CanvasEdgeGraph.canConnect(from: target.id, to: source.id, nodes: nodes, edges: mixedCycle,
                                      role: .prompt), .cycle, "purpose: true execution cycle still rejected")
    t.check(CanvasEdgeInputs.generationOrder(nodes: [source, target], edges: [prompt, reverseGeneration]) == nil,
            "purpose: corrupt raw execution cycle still blocks scheduling")
    t.equal(CanvasEdgeGraph.normalized([prompt, reverseGeneration, reverseReference],
                                      nodeIds: Set(nodes.map(\.id))).map(\.id),
            ["prompt", "reverse-reference"], "purpose: normalization removes only the cyclic generation edge")
    t.check(!CanvasEdgeGraph.wouldCreateCycle(from: target.id, to: source.id, edges: onlyReferences),
            "purpose: reference edges are absent from execution reachability")

    // Reference filtering precedes availability checks and both resolution passes.
    let ownInput = CanvasEdge(id: "own-input", fromNodeId: text.id, toNodeId: target.id,
                              role: .prompt, createdAt: date)
    let unavailableReference = CanvasEdge(id: "unavailable-reference", fromNodeId: "missing", toNodeId: target.id,
                                          purpose: .draftReference, createdAt: date)
    let inputs = CanvasEdgeInputs.resolve(incoming: [reference, ownInput, unavailableReference],
        upstreams: [text.id: .init(nodeId: text.id, kind: .text, text: "style", assetPath: nil)],
        downstreamKind: .video)
    t.equal(inputs.promptFragments, ["style"], "purpose: only generation prompt is consumed")
    t.equal(inputs.bindings.map(\.edgeID), ["own-input"], "purpose: reference has no generation binding")
    t.check(inputs.assetPaths.isEmpty && inputs.pendingUpstreamCount == 0 && inputs.unavailableUpstreamCount == 0
            && inputs.incompatibleUpstreamCount == 0, "purpose: unavailable/video reference causes no input blocker")
    let textFact = CanvasWorkflowFacts(node: text, title: "text", body: "own", bodyRevision: "r1")
    let sourceFact = CanvasWorkflowFacts(node: source, title: "draft", body: "must not enter prompt", bodyRevision: "r1")
    let targetFact = CanvasWorkflowFacts(node: target, title: "target", body: "intent", bodyRevision: "r1")
    let textReference = CanvasEdge(fromNodeId: source.id, toNodeId: text.id, purpose: .draftReference)
    let textPlan = CanvasWorkflowResolver.resolve(textFact, all: [source.id: sourceFact, text.id: textFact],
                                                   edges: [textReference])
    t.check(textPlan.fragments.isEmpty && textPlan.blockingReasons.isEmpty,
            "purpose: text resolver cannot reintroduce reference text or blockers")
    let unknownPlan = CanvasWorkflowResolver.resolve(targetFact, all: [target.id: targetFact],
                                                      edges: [unavailableReference])
    t.check(unknownPlan.blockingReasons.isEmpty, "purpose: workflow ignores unavailable reference upstream")

    // Use the same value transaction called by CanvasStore, with the real history/storage types.
    do {
        var withParent = target
        withParent.parentNodeId = source.id
        let beforeNodes = [source, withParent]
        let edit = try CanvasEdgeGraph.connecting(reference, nodes: beforeNodes, edges: [prompt], at: date).get()
        t.equal(edit.edges, [prompt, reference], "purpose: connect publishes both purposes together")
        let patched = edit.nodes[1]
        t.equal(patched.draftReference, CanvasDraftReference(sourceNodeID: source.id, videoID: "draft-file-1"),
                "purpose: target draft params use exact source identity")
        t.equal(patched.duration, source.duration, "purpose: duration copied in edge transaction")
        t.equal(patched.ratio, source.ratio, "purpose: aspect ratio copied in edge transaction")
        t.equal(patched.generateAudio, source.generateAudio, "purpose: explicit false audio preserved")
        t.equal(patched.model, target.model, "purpose: target model not replaced by source model")
        t.equal(patched.resolution, target.resolution, "purpose: unrelated target parameter preserved")
        t.equal(patched.groupId, target.groupId, "purpose: storage group semantics unchanged")
        t.equal(patched.parentNodeId, source.id, "purpose: reference does not rewrite lineage")
        let activeFact = CanvasWorkflowFacts(node: patched, title: "target", body: "intent", bodyRevision: "r1")
        let activePlan = CanvasWorkflowResolver.resolve(activeFact, all: [source.id: sourceFact, target.id: activeFact],
                                                         edges: [reference])
        t.check(!activePlan.blockingReasons.isEmpty && activePlan.edgeInputs.bindings.isEmpty,
                "purpose: unsupported draft protocol blocks submission instead of silently ignoring params")

        var history = CanvasUndoStack()
        history.push(CanvasHistoryEntry(kind: .connect, before: beforeNodes, after: edit.nodes,
                                        beforeEdges: [prompt], afterEdges: edit.edges))
        t.equal(history.count, 1, "purpose: edge and params share one undo entry")
        guard let undo = history.undo(), let redo = history.redo() else {
            t.check(false, "purpose: undo/redo fixture missing entry")
            return
        }
        t.equal(undo.before, beforeNodes, "purpose: one undo restores exact pre-connect params")
        t.equal(undo.beforeEdges, [prompt], "purpose: one undo removes only reference edge")
        t.equal(redo.after, edit.nodes, "purpose: one redo restores copied params")
        t.equal(redo.afterEdges, edit.edges, "purpose: one redo restores both edges")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-purpose-\(UUID())")
        let previousDataRoot = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"]
        setenv("CLIPSLOTS_DATA_DIR", root.path, 1)
        defer {
            if let previousDataRoot { setenv("CLIPSLOTS_DATA_DIR", previousDataRoot, 1) }
            else { unsetenv("CLIPSLOTS_DATA_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let storage = CanvasStorage(rootOverride: root)
        let projectID = "purpose-local-fixture"
        t.check(storage.save(CanvasDocument(nodes: edit.nodes, edges: edit.edges), projectId: projectID),
                "purpose: transaction saved atomically")
        let reopened = CanvasStorage(rootOverride: root).load(projectId: projectID)
        t.equal(reopened.nodes, edit.nodes, "purpose: fresh-cache reload preserves exact reference params")
        t.equal(reopened.edges, edit.edges, "purpose: reload preserves both purposes")
        t.equal(CanvasEdgeGraph.reconcilingDraftReferences(nodes: edit.nodes, edges: edit.edges), edit.nodes,
                "purpose: reference reconciliation is idempotent")
        guard let removed = CanvasEdgeGraph.disconnecting(edgeID: reference.id, nodes: edit.nodes, edges: edit.edges,
                                                           at: date) else {
            t.check(false, "purpose: disconnect fixture missing edit")
            return
        }
        t.equal(removed.edges, [prompt], "purpose: disconnect leaves generation edge")
        t.equal(removed.nodes[1].draftReference, CanvasDraftReference(), "purpose: disconnect clears reference params but retains opt-in")
        t.equal(removed.nodes[1].parentNodeId, source.id, "purpose: reference disconnect never clears generation lineage")
        t.equal(removed.nodes[1].ratio, source.ratio, "purpose: disconnect does not overwrite user generation settings")
        t.check(storage.save(CanvasDocument(nodes: removed.nodes, edges: removed.edges), projectId: projectID),
                "purpose: disconnect saved in one document")
        let afterRemove = CanvasStorage(rootOverride: root).load(projectId: projectID)
        t.equal(afterRemove.edges, [prompt], "purpose: reload cannot resurrect reference")
        t.equal(afterRemove.nodes[1].draftReference, CanvasDraftReference(), "purpose: cleared reference params survive reload")
        history.push(CanvasHistoryEntry(kind: .disconnect, before: edit.nodes, after: removed.nodes,
                                        beforeEdges: edit.edges, afterEdges: removed.edges))
        let undoRemove = history.undo()
        t.equal(undoRemove?.before, edit.nodes, "purpose: one disconnect undo restores full reference params")
        t.equal(undoRemove?.beforeEdges, edit.edges, "purpose: same disconnect undo restores reference edge")
        if let undoRemove {
            t.check(storage.save(CanvasDocument(nodes: undoRemove.before, edges: undoRemove.beforeEdges), projectId: projectID),
                    "purpose: undo snapshot saved as one document")
            let undoReload = CanvasStorage(rootOverride: root).load(projectId: projectID)
            t.equal(undoReload.nodes, edit.nodes, "purpose: undo params survive fresh-cache reload")
            t.equal(undoReload.edges, edit.edges, "purpose: undo edges survive the same reload")
        }
        let noGeneration = CanvasEdgeGraph.disconnecting(edgeID: prompt.id, nodes: edit.nodes, edges: edit.edges, at: date)
        t.check(noGeneration?.nodes[1].parentNodeId == nil && noGeneration?.nodes[1].draftReference?.videoID == "draft-file-1",
                "purpose: generation disconnect clears only lineage and leaves draft params")
        if let noGeneration {
            t.check(storage.save(CanvasDocument(nodes: noGeneration.nodes, edges: noGeneration.edges), projectId: projectID),
                    "purpose: reference-only document saved")
            t.equal(CanvasStorage(rootOverride: root).load(projectId: projectID).edges, [reference],
                    "purpose: parent migration does not recreate removed generation edge")
        }
        let legacy = CanvasEdgeGraph.migratedFromParentLinks(nodes: beforeNodes, edges: [reference])
        t.check(legacy.contains { $0.fromNodeId == source.id && $0.toNodeId == target.id && $0.purpose == .generationInput },
                "purpose: genuine legacy parent still migrates as generation, not reference")
        t.equal(CanvasEdgeGraph.migratedFromParentLinks(nodes: beforeNodes, edges: legacy), legacy,
                "purpose: purpose-aware parent migration remains idempotent")
        let deleted = CanvasEdgeGraph.reconcilingDraftReferences(nodes: [patched],
            edges: CanvasEdgeGraph.removing(nodeIds: [source.id], from: edit.edges))
        t.equal(deleted[0].draftReference, CanvasDraftReference(), "purpose: source deletion clears dangling reference params")
        var renamed = source
        renamed.slot = 9
        let remapped = CanvasEdgeGraph.remapping(nodeId: source.id, to: renamed.id, edges: [reference])
        let rebound = CanvasEdgeGraph.reconcilingDraftReferences(nodes: [renamed, patched], edges: remapped)
        t.equal(rebound[1].draftReference?.sourceNodeID, renamed.id, "purpose: remap updates reference identity")
        t.equal(rebound[1].draftReference?.videoID, source.draftVideoID, "purpose: remap preserves draft video identity")

        let snapshot = CanvasAgentSnapshot(graph: .init(projectID: projectID, facts: [sourceFact, activeFact],
                                                        edges: [reference], selectionIDs: []), runs: [])
        let portable = try WorkflowSkill(snapshot: snapshot, method: "generation only", messageID: nil, receipts: [])
        t.check(portable.graph.edges.isEmpty, "purpose: portable workflow cannot downgrade reference to execution edge")
        t.check(portable.graph.nodes.allSatisfy {
            $0.configuration.draftReference == nil && $0.configuration.draftVideoID == nil
        }, "purpose: generation-only export removes nonportable draft identity params")
    } catch { t.check(false, "purpose: transaction/history/storage fixture: \(error)") }
}
