import Foundation
import ClipSlotsKit

func runGenerationPromptContractTests(_ t: TestRunner) {
    let prompt = " \t中文🙂 ' \" $() `literal`\n    缩进  双空格\n\n尾行 \t\n"
    let image = CrateImageRequest(model: " fixture ", prompt: prompt)
    let video = CrateVideoRequest(model: " fixture ", prompt: prompt)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        for (kind, args, record) in [
            ("image", try CrateGeneration.submitArguments(image), GenerationRequestRecord(image, resourceIDs: [:])),
            ("video", try CrateGeneration.submitArguments(video), GenerationRequestRecord(video, resourceIDs: [:]))
        ] {
            t.equal(args[args.firstIndex(of: "--prompt")! + 1], prompt, "\(kind) argv preserves exact prompt")
            t.equal(record.prompt, prompt, "\(kind) recorded prompt matches transmitted bytes")
            t.equal(try JSONDecoder().decode(GenerationRequestRecord.self, from: JSONEncoder().encode(record)).prompt,
                    prompt, "\(kind) record JSON preserves newline, indentation and Unicode")
            let node = CanvasNode(pageId: "p", groupId: "g", slot: 1, x: 0, y: 0)
            let fact = CanvasWorkflowFacts(node: node, title: "", body: prompt, bodyRevision: "", bodyAvailable: true)
            let snapshot = CanvasWorkflowSnapshot(projectID: "prompt-contract", facts: [fact], edges: [], selectionIDs: [])
            let context = GenerationRunContext(snapshot: snapshot, node: node, resourceIDs: [:])
            let store = GenerationRunStore(root: root)
            let id = try store.beginAttempt(context: context, requested: record, effective: record)
            try store.finishAttempt(context: context, attemptID: id, status: .accepted, taskID: "fixture-task")
            let reopened = GenerationRunStore(root: root).load(project: context.projectID, id: context.runID)
            t.equal(reopened?.requestedRequest.prompt, prompt, "\(kind) cold load preserves requested prompt")
            t.equal(reopened?.attempts.first?.effectiveRequest.prompt, prompt, "\(kind) cold load preserves effective prompt")
        }
        for blank in ["", " \t\r\n", "\u{3000}\n"] {
            t.check((try? CrateGeneration.submitArguments(CrateImageRequest(model: "m", prompt: blank))) == nil,
                    "image rejects whitespace-only prompt \(blank.debugDescription)")
            t.check((try? CrateGeneration.submitArguments(CrateVideoRequest(model: "m", prompt: blank))) == nil,
                    "video rejects whitespace-only prompt \(blank.debugDescription)")
        }
        let edge = CanvasEdge(fromNodeId: "source", toNodeId: "target", role: .prompt)
        for kind: CanvasNodeKind in [.text, .slot] {
            let resolved = CanvasEdgeInputs.resolve(incoming: [edge], upstreams: [
                "source": .init(nodeId: "source", kind: kind, text: prompt, assetPath: nil)
            ], downstreamKind: .image)
            t.equal(resolved.promptFragments, [prompt], "\(kind) reference preserves exact source text")
            t.equal(resolved.bindings.first?.text, prompt, "\(kind) reference binding agrees with prompt")
        }
        let prefix = "\n  共享风格 \n"
        t.equal(CanvasEdgeInputs.mergedPrompt(own: prompt, upstream: [prefix, " \n"]),
                prefix + "\n\n" + prompt, "merge preserves source order and inserts only the documented separator")
        t.equal(CanvasEdgeInputs.mergedPrompt(own: " \t", upstream: [" \n"]), "",
                "merge omits whitespace-only fragments")
    } catch {
        t.check(false, "prompt contract unexpected error: \(error)")
    }
}
