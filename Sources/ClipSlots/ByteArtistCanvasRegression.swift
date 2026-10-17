#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor BACanvasNativeFixture {
    let directory: URL
    let port: String
    var submits = 0
    var queries = 0
    var ambiguous = false
    var officialOutput = false
    let reference = """
    # BA 原生联调
    > workflow id: `123456789012345678`

    ## 输入
    | 名称 | internal_name | format | 输入描述 | 默认值 | 限制 | 节点来源 |
    | --- | --- | --- | --- | --- | --- | --- |
    | prompt | prompt | input | 画面描述 | | | Test:prompt |
    | steps | steps | input_number | 步数 | 12 | | Test:steps |

    ## 输出
    | 名称 | internal_name | format | 节点来源 |
    | --- | --- | --- | --- |
    | images | images | image | Test:images |

    ## 输入 Schema
    ```json
    {"type":"object","additionalProperties":false,"properties":{"prompt":{"type":"string","minLength":1},"steps":{"type":"integer","default":12,"minimum":1,"maximum":20}}}
    ```
    """
    init(directory: URL, port: String) { self.directory = directory; self.port = port }
    func setAmbiguous() { ambiguous = true }
    func setOfficialOutput() { officialOutput = true }
    func execute(_ call: GenerationCLIInvocation) async throws -> ToolProcess.Output {
        if call.arguments == ["--version"] { return .init(status: 0, stdout: "1.1.5", stderr: "") }
        let value: JSONValue
        if call.submitting {
            submits += 1
            try await Task.sleep(for: .milliseconds(180))
            if ambiguous { return .init(status: 1, stdout: "", stderr: "") }
            value = ["event": "task_created", "task_id": .string("native-\(submits)")]
        } else if call.arguments.contains("auth") { value = ["loggedIn": true] }
        else if call.arguments.contains("skill") { value = ["markdown": .string(reference)] }
        else if call.arguments.contains("references") {
            value = [["workflow_id": "123456789012345678", "title": "BA 原生联调",
                      "file_path": .string((call.environment["BA_REFERENCES_DIR"] ?? directory.path) + "/workflow-123456789012345678.md"),
                      "content": .string(reference)]]
        } else if call.arguments.contains("list") {
            value = ["data": ["total": 61, "workflows": [
                ["id": "123456789012345678", "name": "BA 原生联调", "description": "按提示词生成图片"],
                ["id": "987654321", "name": "未导入能力", "description": "选择后核对契约"]]]]
        } else {
            queries += 1
            let index = call.arguments.firstIndex(of: "task")!
            let output: JSONValue = officialOutput
                ? [["slot_key": "102#images#0", "node_key": "images", "format": "image",
                    "value": .string("http://127.0.0.1:\(port)/ba-one.png")]]
                : [["images": [.string("http://127.0.0.1:\(port)/ba-one.png"),
                               .string("http://127.0.0.1:\(port)/ba-two.png")]]]
            value = ["task_id": .string(call.arguments[index + 1]), "status": "finished", "output_result": output]
        }
        return .init(status: 0, stdout: try value.encodedText(), stderr: "")
    }
}

private struct BAProbeBar: View {
    @ObservedObject var canvas: CanvasStore
    let id: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("生成画面").font(.system(size: 14, weight: .semibold))
            Text("雾中的森林与柔和的晨光").font(.system(size: 12))
            if let node = canvas.node(id: id) {
                CanvasNodeActionBar(node: node, canvas: canvas, catalog: CrateModelCatalogStore.shared,
                    upstreamCount: 0, onRun: {}, onSpawnDownstream: {}, onRevealAsset: { _ in },
                    canArchive: false, onArchive: {}, onOpenFullscreen: nil, onCopyText: nil)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CanvasTheme.canvasChromeSurface)
    }
}

extension CanvasWorkspaceView {
    @MainActor func runByteArtistCanvasProbe(directory: URL, check: (Bool, String) -> Void) async {
        func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
        func elements(_ node: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 30 else { return [] }
            let children = node.accessibilityChildren?() ?? []
            let fallback = (node as? NSView)?.subviews ?? []
            return [node] + (children.isEmpty ? fallback : children).flatMap { elements($0 as AnyObject, depth: depth + 1) }
        }
        let catalog = ByteArtistCatalogStore.shared
        let fixture = BACanvasNativeFixture(directory: directory,
            port: ProcessInfo.processInfo.environment["CLIPSLOTS_FIXTURE_PORT"]!)
        do {
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!
            try bytes.write(to: directory.appendingPathComponent("ba-one.png"))
            try bytes.write(to: directory.appendingPathComponent("ba-two.png"))
            let runtime = try ByteArtistRuntime(root: directory.appendingPathComponent("ba"),
                                               executor: { try await fixture.execute($0) })
            catalog.fixtureRuntime = runtime
            defer { catalog.fixtureRuntime = nil }
            try await runtime.adapter.refreshReference(id: "123456789012345678")
            catalog.reload()
            for _ in 0..<50 { if !catalog.busy { break }; await settle() }
            guard let capability = catalog.capabilities.first,
                  let source = createNode(kind: .image, at: CGPoint(x: 300, y: 300),
                                          parentNodeId: nil, beginEditing: false, quiet: true) else {
                check(false, "BA fixture initialization"); return
            }
            canvas.updateNode(id: source.id) { $0.mediaRole = .generation }
            commitEdit(source, text: "雾中的森林与柔和的晨光")
            var config = ByteArtistCanvasConfiguration(); config.select(capability)
            canvas.updateNodeProvider(id: source.id, provider: .byteartist, configuration: config)
            let crateModel = source.model
            let first = generateAdjacentResults(canvas.node(id: source.id)!)
            for _ in 0..<40 { if await fixture.submits > 0 { break }; await settle() }
            canvas.updateNodeProvider(id: source.id, provider: .crate)
            await first?.value
            guard var current = canvas.node(id: source.id) else {
                check(false, "probe node was removed during native test"); return
            }
            check(current.generationProvider == .crate && current.generationTask?.context.provider == .byteartist,
                  "switching selection during submit retains immutable BA task")
            check(current.model == crateModel && current.generationRawOutput != nil && current.needsGenerationRecovery,
                  "BA outputs persist for selection without changing Crate draft")
            check(await fixture.submits == 1, "one actual BA invocation through canvas")
            let run = GenerationRunStore.shared.latest(project: canvas.activeProjectId, node: current)
            check(run?.attempts.last?.taskHandle == current.generationTask, "canvas history persists provider task")
            canvas.updateNodeProvider(id: source.id, provider: .byteartist)
            let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 600, height: 160),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: BAProbeBar(canvas: canvas, id: source.id))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let originalSkin = AppSkinCenter.current
            defer { AppSkinCenter.apply(originalSkin) }
            for skin in [AppSkin.minimal, .colorful] {
                AppSkinCenter.apply(skin)
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    canvas.updateNodeProvider(id: source.id, provider: .byteartist)
                    await settle()
                    let button = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "canvas-ba-workflow" }
                    _ = button?.accessibilityPerformPress?()
                    await settle()
                    let all = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
                    check(all.contains { ($0.accessibilityIdentifier?() ?? "") == "creative-model-search" }
                          && all.contains { ($0.accessibilityIdentifier?() ?? "") == "creative-model-987654321" },
                          "BA searchable library includes not-yet-imported online ability \(skin.rawValue) \(dark)")
                    if let view = NSApp.windows.compactMap(\.contentView).first(where: {
                        elements($0).contains { ($0.accessibilityIdentifier?() ?? "") == "creative-model-search" }
                    }), let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        try image.representation(using: .png, properties: [:])?.write(to:
                            directory.appendingPathComponent("ba-library-\(skin.rawValue)-\(dark).png"))
                    }
                    let selected = all.first { ($0.accessibilityIdentifier?() ?? "") == "creative-model-123456789012345678" }
                    _ = selected?.accessibilityPerformPress?()
                    await settle()
                    check(canvas.node(id: source.id)?.byteArtist.workflowID == capability.id &&
                          !NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap({ elements($0) }).contains {
                              ($0.accessibilityIdentifier?() ?? "") == "creative-model-search"
                          }, "BA choice commits and closes picker \(skin.rawValue) \(dark)")
                }
            }
            for skin in [AppSkin.minimal, .colorful] {
                AppSkinCenter.apply(skin)
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    for provider in [GenerationProviderID.crate, .byteartist] {
                        canvas.updateNodeProvider(id: source.id, provider: provider)
                        await settle()
                        let nodes = elements(host)
                        let control = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-generation-source" }
                        let runButton = nodes.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-generate" }
                        let frame = control?.accessibilityFrame?()
                        let bounds = window.convertToScreen(host.bounds)
                        check(frame.map { $0.width > 15 && bounds.contains($0) } == true && runButton != nil,
                              "\(provider.rawValue) source and run visible \(skin.rawValue) \(dark)")
                        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: image)
                            try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("ba-\(provider.rawValue)-\(skin.rawValue)-\(dark).png"))
                        }
                    }
                }
            }
            canvas.updateNodeProvider(id: source.id, provider: .byteartist)
            await settle()
            let workflow = elements(host).first { ($0.accessibilityIdentifier?() ?? "") == "canvas-ba-configuration" }
            _ = workflow?.accessibilityPerformPress?()
            await settle()
            let popoverNodes = NSApp.windows.compactMap(\.contentView).flatMap { elements($0) }
            check(popoverNodes.contains { ($0.accessibilityIdentifier?() ?? "") == "canvas-ba-workflow-picker" },
                  "workflow popover opens from action bar")
            check(popoverNodes.contains { ($0.accessibilityIdentifier?() ?? "") == "canvas-ba-input-steps" },
                  "schema number field visible in native UI")
            let output = popoverNodes.first { ($0.accessibilityIdentifier?() ?? "") == "canvas-ba-output-/0/images/0" }
            check(output != nil, "unmapped output exposes actionable field choice")
            canvas.recoverGenerationAction = { node in _ = recoverGeneration(node) }
            _ = output?.accessibilityPerformPress?()
            for _ in 0..<40 {
                if case .succeeded = canvas.node(id: source.id)?.state { break }
                await settle()
            }
            current = canvas.node(id: source.id)!
            check(current.generationTask?.outputBindings.count == 1 &&
                  current.byteArtist.draft.outputBindings.count == 1, "native output choice updates task and future draft")
            if case .succeeded = current.state { check(true, "confirm output performs recovery without another click") }
            else { check(false, "confirm output performs recovery without another click") }
            canvas.updateNodeProvider(id: source.id, provider: .crate)
            await recoverGeneration(canvas.node(id: source.id)!)?.value
            current = canvas.node(id: source.id)!
            let files = store.canvasSlotAttachments(groupId: current.groupId, slot: current.slot)
                .filter { current.outputAttachmentIds.contains($0.id.uuidString) }
            check(files.count == 2 && files.allSatisfy { $0.storagePath.map { FileManager.default.fileExists(atPath: $0) } == true },
                  "BA recovery downloads every selected output to actual slot storage")
            if case .succeeded = current.state { check(true, "BA node succeeds after saving outputs") }
            else { check(false, "BA node succeeds after saving outputs \(current.state)") }
            check(await fixture.submits == 1, "recovery after Crate selection never submits again")
            await recoverGeneration(current)?.value
            check(canvas.node(id: source.id)?.outputAttachmentIds.count == 2, "repeated recovery is idempotent")
            canvas.updateNodeProvider(id: source.id, provider: .byteartist)
            canvas.updateNodeGeneration(id: source.id, count: 3)
            let before = Set(canvas.nodes.map(\.id))
            await generateAdjacentResults(canvas.node(id: source.id)!)?.value
            let siblings = canvas.nodes.filter { !before.contains($0.id) }
            check(siblings.count == 2 && siblings.allSatisfy {
                $0.generationTask?.context.provider == .byteartist && $0.outputAttachmentIds.count == 2
            }, "BA batch creates two siblings with separate task handles and media")
            check(await fixture.submits == 4, "BA batch submits exactly once per result node")
            canvas.flushSave()
            let restored = CanvasStorage().load(projectId: canvas.activeProjectId).nodes.first { $0.id == source.id }
            check(restored?.generationTask == canvas.node(id: source.id)?.generationTask &&
                  restored?.byteArtist == canvas.node(id: source.id)?.byteArtist, "disk reload retains BA drafts and ownership")
            var invalid = canvas.node(id: source.id)!.byteArtist
            invalid.draft.fields["steps"] = "99"
            canvas.updateNodeProvider(id: source.id, configuration: invalid)
            let count = canvas.nodes.count
            check(generateAdjacentResults(canvas.node(id: source.id)!) == nil && canvas.nodes.count == count,
                  "invalid BA input does not allocate batch siblings")
            invalid.draft.fields["steps"] = "12"
            canvas.updateNodeProvider(id: source.id, configuration: invalid)
            canvas.updateNodeGeneration(id: source.id, count: 1)
            await fixture.setAmbiguous()
            await generateAdjacentResults(canvas.node(id: source.id)!)?.value
            check(GenerationRunStore.shared.latest(project: canvas.activeProjectId, node: source)?
                .requiresSubmissionReconciliation == true, "unknown BA submit persists retry barrier")
            check(generateAdjacentResults(canvas.node(id: source.id)!) == nil, "repeat click cannot resubmit ambiguous task")
            // Recover an old no-binding task with the actual official format/value shape.
            await fixture.setOfficialOutput()
            let legacy = createNode(kind: .image, at: CGPoint(x: 900, y: 300), parentNodeId: nil,
                beginEditing: false, quiet: true)!
            let handle = try GenerationTaskHandle(context: .byteartist, taskID: "legacy-existing",
                capabilityID: capability.id, kind: .image)
            canvas.updateNode(id: legacy.id) {
                $0.mediaRole = .generation; $0.taskId = handle.taskID; $0.generationTask = handle
                $0.generationProvider = .crate; $0.state = .failed(reason: "old unknown status")
            }
            await recoverGeneration(canvas.node(id: legacy.id)!)?.value
            let recovered = canvas.node(id: legacy.id)!
            check(recovered.outputAttachmentIds.count == 1 && recovered.generationDiagnostic?.stage == "succeeded",
                  "legacy task with no mappings automatically saves official media after Crate selection")
            check(catalog.entries.count == 2 && catalog.total == 61,
                  "online and imported candidates coexist with account total")
        } catch { check(false, "BA native error: \(error)") }
    }
}
#endif
