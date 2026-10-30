#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runBatchGenerationProbe(directory: URL) async {
        guard let fixture = ProcessInfo.processInfo.environment["CLIPSLOTS_CRATE_FIXTURE"],
              FileManager.default.isExecutableFile(atPath: fixture),
              (try? CrateGenerationService.shared.resolveBinary()) == fixture else {
            let report: [String: Any] = ["passed": 0,
                "failures": ["Batch probe requires an explicit executable local CLI fixture; stopped before submission."]]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
            return
        }
        var passed = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failures.append(name) }
            NSLog("[BatchProbe] \(value ? "PASS" : "FAIL") \(name)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(160)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<1200 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return condition()
        }
        func elements(_ object: AnyObject, depth: Int = 0) -> [AnyObject] {
            guard depth < 35 else { return [] }
            let children = object.accessibilityChildren?() ?? []
            let fallback = (object as? NSView)?.subviews ?? []
            return [object] + (children.isEmpty ? fallback : children).flatMap {
                elements($0 as AnyObject, depth: depth + 1)
            }
        }
        func find(_ root: NSView, _ id: String) -> AnyObject? {
            elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        func press(_ root: NSView, _ id: String) -> Bool {
            guard let element = find(root, id) else { return false }
            if element.accessibilityPerformPress?() == true { return true }
            if let button = (element as? NSButton) ?? ((element as? NSCell)?.controlView as? NSButton),
               button.isEnabled {
                button.performClick(nil)
                return true
            }
            NSLog("[BatchProbe] no press %@ type %@", id, String(describing: type(of: element)))
            return false
        }
        func capture(_ root: NSView, _ name: String) {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        func frame(_ root: NSView, _ id: String) -> NSRect {
            find(root, id)?.accessibilityFrame?() ?? .zero
        }
        func aligned(_ root: NSView, _ ids: [String], _ name: String) {
            let frames = ids.map { frame(root, $0) }
            NSLog("[BatchProbe] geometry %@ %@", name, frames.map(NSStringFromRect).joined(separator: " | "))
            check(frames.allSatisfy { $0.width > 0 && abs($0.height - 32) <= 1 }
                  && frames.allSatisfy { abs($0.midY - frames[0].midY) <= 1 }, name)
        }
        func submissionCount() -> Int {
            let log = (try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"))) ?? ""
            return log.split(separator: "\n").filter { $0.contains("\"generate\"") }.count
        }
        let controller = BatchGenerationController.shared
        do {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!
            try png.write(to: directory.appendingPathComponent("fixture.png"))
            let p = try store.specialStorage.createPage(name: "批量·页面甲", withDefaultGroup: false)
            let q = try store.specialStorage.createPage(name: "批量·页面乙", withDefaultGroup: false)
            let a = try store.specialStorage.createSpecialSlot(name: "同名素材组", pageId: p.page.id)
            let b = try store.specialStorage.createSpecialSlot(name: "同名素材组", pageId: q.page.id)
            _ = try store.specialStorage.createSpecialSlot(name: "空组", pageId: q.page.id)
            check(store.specialStorage.set(1, content: .init(text: "柔光产品图"), in: a.id), "source A persisted")
            check(store.specialStorage.set(3, content: .init(text: "自然光海报"), in: b.id), "source B persisted")
            let originalCanvas = canvas.nodes, originalProject = canvas.activeProjectId
            let catalog = CrateModelCatalogStore.shared
            catalog.loadIfNeeded()
            await controller.loadLibrary(store: store)
            check(await wait { !catalog.imageModels.isEmpty }, "catalog from fixture")
            let displayedModels = catalog.imageModels
            catalog.reload()
            check(catalog.isLoading && catalog.imageModels == displayedModels,
                  "soft model refresh retains current picker choices")
            check(await wait { !catalog.isLoading }, "soft model refresh completes")
            NativeAccessibilityProbe.enable()
            await settle()
            guard let window = inputRouter.anchorView?.window, let root = window.contentView else {
                throw CocoaError(.coderInvalidValue)
            }
            check(press(root, "batch-generation-entry"), "native toolbar opens batch dialog")
            await settle()
            guard let sheet = window.sheets.first?.contentView else {
                throw CocoaError(.coderInvalidValue)
            }
            check(await wait { !controller.isLoading }, "dialog scans independently of active group")
            let rows = elements(sheet).map { node in
                ["type": String(describing: type(of: node)), "id": node.accessibilityIdentifier?() ?? "",
                 "label": node.accessibilityLabel?() ?? "",
                 "value": String(describing: (node as? NSAccessibilityProtocol)?.accessibilityValue() ?? "nil")]
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("batch-ax.json"))
            check(find(sheet, "batch-group-" + a.id) != nil && find(sheet, "batch-group-" + b.id) != nil,
                  "native dialog exposes duplicate names in separate pages")
            check(press(sheet, "batch-environment"), "batch opens environment setup without terminal")
            await settle()
            let setupPanel = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                .first { find($0, "environment-close") != nil }
            check(setupPanel != nil, "nested environment panel is reachable")
            if let setupPanel {
                check(press(setupPanel, "environment-close"), "environment panel returns to existing batch")
            }
            await settle()
            check(press(sheet, "batch-model-picker"), "batch opens shared model picker")
            await settle()
            let modelPanel = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                .first { find($0, "creative-model-search") != nil }
            check(modelPanel != nil, "batch model picker exposes search and catalog")
            if let panel = modelPanel, let first = catalog.imageModels.first {
                check(press(panel, "creative-model-" + first.id), "batch model choice applies")
            }
            await settle()
            check(press(sheet, "batch-aspect-picker"), "batch opens aspect grid")
            await settle()
            let ratioPanel = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                .first { find($0, "canvas-ratio-1:1") != nil }
            if let panel = ratioPanel {
                capture(panel, "batch-ratio-square.png")
                check(press(panel, "canvas-ratio-1:1"), "batch accepts square 1:1")
            } else { check(false, "batch square ratio available") }
            await settle()
            check(press(sheet, "batch-select-all"), "native select all")
            await settle()
            check((find(sheet, "batch-group-" + a.id)?.accessibilityLabel?() ?? "").hasSuffix("已选择"),
                  "native selected checkbox value")
            capture(sheet, "batch-selection-large.png")
            check(press(sheet, "batch-deselect-all"), "native deselect all")
            await settle()
            check((find(sheet, "batch-group-" + a.id)?.accessibilityLabel?() ?? "").hasSuffix("未选择"),
                  "native deselected checkbox value")
            check(press(sheet, "batch-page-" + p.page.id), "native page selection")
            check(press(sheet, "batch-group-" + b.id), "native individual group selection")
            await settle()
            let before = submissionCount()
            check(press(sheet, "batch-confirm"), "native confirm starts actual queue")
            await settle()
            guard let batch = controller.batches.first else { throw CocoaError(.coderInvalidValue) }
            check(!controller.start(batch, store: store, model: catalog.imageModels.first),
                  "duplicate start rejected while batch running")
            check(await wait { controller.runningID == nil }, "batch queue finishes")
            check(controller.batch(batch.id)?.completedCount == 2, "batch archives each selected group's output")
            let outputs = controller.batch(batch.id)?.items.compactMap(\.localFile).map { URL(fileURLWithPath: $0) } ?? []
            check(outputs.count == 2 && Set(outputs.map { $0.deletingLastPathComponent() }).count == 1,
                  "native queue archives the batch in one folder")
            check(outputs.allSatisfy { $0.deletingLastPathComponent().lastPathComponent.hasSuffix("_批次-001") },
                  "native queue persists readable date and batch folders")
            check(submissionCount() - before == 2, "exactly two paid submission boundaries simulated")
            check(store.specialStorage.get(1, in: a.id).plainText == "柔光产品图"
                && store.specialStorage.get(3, in: b.id).plainText == "自然光海报", "batch retains original prompts")
            check(store.specialStorage.get(1, in: a.id).attachments.isEmpty
                && store.specialStorage.get(3, in: b.id).attachments.isEmpty, "batch generates zero source attachments")
            check(batch.items.allSatisfy {
                GenerationRunStore.shared.load(project: originalProject, id: $0.runID)?.outputAttachmentIDs.isEmpty == true
            }, "batch journals claim no slot attachment output IDs")
            check(canvas.nodes == originalCanvas && canvas.activeProjectId == originalProject,
                  "batch needs no canvas nodes and does not switch projects")
            capture(sheet, "batch-progress-complete.png")
            _ = press(sheet, "batch-close")
            await settle()

            let config = CanvasNode(pageId: "", groupId: "", slot: 1, kind: .image, x: 0, y: 0)
            // Stop during submit, then create a fresh controller from disk and recover only the known ID.
            check(store.specialStorage.set(1, content: .init(text: "BATCH_SLOW stop"), in: a.id), "slow cancellation source")
            await controller.loadLibrary(store: store)
            var cancellable = controller.plan(projectID: originalProject, selected: [a.id, b.id],
                                               configuration: config, model: catalog.imageModels.first)
            cancellable.concurrency = 1
            let stopBefore = submissionCount()
            check(controller.start(cancellable, store: store, model: catalog.imageModels.first), "cancellation batch starts")
            check(await wait { controller.batch(cancellable.id)?.items.first?.status == .submitting }, "stop meets submission in flight")
            // Wait until the process has actually recorded the command, not just local submitting state.
            _ = await wait { submissionCount() > stopBefore }
            controller.stop(cancellable.id)
            check(await wait { controller.runningID == nil }, "stop drains in-flight response")
            let cancelled = controller.batch(cancellable.id)
            check(cancelled?.items.first?.taskID != nil, "stop preserves returned task ID")
            check(cancelled?.items.last?.taskID == nil && submissionCount() == stopBefore + 1,
                  "stop prevents next paid submission")
            let restored = BatchGenerationController()
            await restored.loadLibrary(store: store)
            let recoverBefore = submissionCount()
            restored.recover(cancellable.id, store: store)
            check(await wait { restored.runningID == nil }, "restart recovery completes")
            check(submissionCount() == recoverBefore && restored.batch(cancellable.id)?.completedCount == 1,
                  "restart recovery queries only old task")
            restored.recover(cancellable.id, store: store)
            await settle()
            check(submissionCount() == recoverBefore && store.specialStorage.get(1, in: a.id).attachments.isEmpty,
                  "repeat recovery adds no source attachment or submission")

            // Mutating one in-flight source and one queued source exercises both fences.
            _ = store.specialStorage.set(1, content: .init(text: "BATCH_SLOW conflict"), in: a.id)
            await controller.loadLibrary(store: store)
            var conflict = controller.plan(projectID: originalProject, selected: [a.id, b.id],
                                           configuration: config, model: catalog.imageModels.first)
            conflict.concurrency = 1
            let conflictBefore = submissionCount()
            _ = controller.start(conflict, store: store, model: catalog.imageModels.first)
            _ = await wait { submissionCount() > conflictBefore }
            _ = store.specialStorage.set(1, content: .init(text: "生成期间手改"), in: a.id)
            _ = store.specialStorage.set(3, content: .init(text: "排队期间手改"), in: b.id)
            check(await wait { controller.runningID == nil }, "conflict batch finishes")
            check(controller.batch(conflict.id)?.items.first?.status == .succeeded
                && controller.batch(conflict.id)?.items.last?.status == .skipped, "archive completes independently of edited source and skips stale queued source")
            check(store.specialStorage.get(1, in: a.id).plainText == "生成期间手改"
                && store.specialStorage.get(1, in: a.id).attachments.isEmpty, "conflict never overwrites manual content")
            check(submissionCount() == conflictBefore + 1, "stale queued source never submitted")

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_UNKNOWN"), in: a.id)
            await controller.loadLibrary(store: store)
            var unknown = controller.plan(projectID: originalProject, selected: [a.id, b.id], configuration: config, model: catalog.imageModels.first)
            unknown.concurrency = 1
            let unknownBefore = submissionCount()
            _ = controller.start(unknown, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "ambiguous submission settles")
            check(controller.batch(unknown.id)?.items.first?.status == .unknown, "ambiguous submission visibly requires reconciliation")
            check(controller.batch(unknown.id)?.items.last?.status == .stopped, "unknown submission stops window refill")
            controller.recover(unknown.id, store: store)
            await settle()
            check(submissionCount() == unknownBefore + 1, "ambiguous submission never auto-retried")
            check(!controller.retry(unknown.id, itemID: unknown.items[0].id, store: store, model: catalog.imageModels.first),
                  "unknown item explicitly rejects manual retry")

            for marker in ["BATCH_ACCEPTED_EXIT", "BATCH_ACCEPTED_TAIL", "BATCH_CONFLICTING_RECEIPTS"] {
                _ = store.specialStorage.set(1, content: .init(text: marker), in: a.id)
                await controller.loadLibrary(store: store)
                let receipt = controller.plan(projectID: originalProject, selected: [a.id],
                                              configuration: config, model: catalog.imageModels.first)
                let before = submissionCount()
                _ = controller.start(receipt, store: store, model: catalog.imageModels.first)
                check(await wait { controller.runningID == nil }, "\(marker) settles")
                let item = controller.batch(receipt.id)?.items.first
                let run = item.flatMap { GenerationRunStore.shared.load(project: originalProject, id: $0.runID) }
                if marker == "BATCH_CONFLICTING_RECEIPTS" {
                    check(item?.status == .unknown && run?.requiresSubmissionReconciliation == true,
                          "conflicting native process receipts stay unknown")
                } else {
                    check(item?.status == .succeeded && item?.taskID != nil,
                          "\(marker) retains accepted identity and retrieves result")
                    check(run?.attempts.last?.taskHandle?.context == .crate,
                          "\(marker) records original provider context")
                }
                check(submissionCount() == before + 1, "\(marker) executes only one submit")
                controller.recover(receipt.id, store: store)
                await settle()
                check(submissionCount() == before + 1, "\(marker) recovery never resubmits")
            }

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_FAIL"), in: a.id)
            await controller.loadLibrary(store: store)
            let failed = controller.plan(projectID: originalProject, selected: [a.id], configuration: config, model: catalog.imageModels.first)
            let failBefore = submissionCount()
            _ = controller.start(failed, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "remote failure settles")
            check(controller.batch(failed.id)?.items.first?.status == .failed && submissionCount() == failBefore + 1,
                  "remote failure does not resubmit")
            check(controller.batch(failed.id)?.items.first?.canRetry == true,
                  "remote terminal failure enables per-item regeneration")

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_FAIL_ONCE native-button"), in: a.id)
            await controller.loadLibrary(store: store)
            let retryBatch = controller.plan(projectID: originalProject, selected: [a.id, b.id],
                                             configuration: config, model: catalog.imageModels.first)
            let retryBefore = submissionCount()
            _ = controller.start(retryBatch, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "mixed success and failure batch settles")
            guard let mixed = controller.batch(retryBatch.id), let failedItem = mixed.items.first(where: \.canRetry),
                  let successfulItem = mixed.items.first(where: { $0.status == .succeeded }) else {
                throw CocoaError(.coderInvalidValue)
            }
            let successBytes = try Data(contentsOf: URL(fileURLWithPath: successfulItem.localFile!))
            check(press(root, "batch-generation-entry"), "open history for single-item retry")
            await settle()
            guard let retrySheet = window.sheets.first?.contentView else { throw CocoaError(.coderInvalidValue) }
            check(press(retrySheet, "batch-history"), "open mixed batch history")
            await settle()
            let history = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                .first { find($0, "batch-history-" + retryBatch.id.uuidString) != nil }
            check(history.map { press($0, "batch-history-" + retryBatch.id.uuidString) } == true,
                  "select mixed batch from real history")
            await settle()
            check(find(retrySheet, "batch-retry-" + failedItem.id.uuidString) != nil,
                  "failed item exposes native regenerate button")
            check(find(retrySheet, "batch-retry-" + successfulItem.id.uuidString) == nil,
                  "successful item exposes no regenerate action")
            capture(retrySheet, "batch-single-failure-retry.png")
            check(press(retrySheet, "batch-retry-" + failedItem.id.uuidString), "native single-item regenerate button submits")
            check(!controller.retry(retryBatch.id, itemID: failedItem.id, store: store, model: catalog.imageModels.first),
                  "double click is rejected before duplicate submission")
            check(await wait { controller.runningID == nil }, "single-item retry completes")
            let retried = controller.batch(retryBatch.id)!
            check(retried.completedCount == 2 && submissionCount() == retryBefore + 3,
                  "single failed item adds exactly one submission")
            let newItem = retried.items.first { $0.id == failedItem.id }!
            let retainedSuccessBytes = try Data(contentsOf: URL(fileURLWithPath: successfulItem.localFile!))
            check(newItem.runID != failedItem.runID && newItem.previousRunIDs == [failedItem.runID],
                  "retry retains original failure journal and records new run")
            check(retried.items.first { $0.id == successfulItem.id } == successfulItem
                  && retainedSuccessBytes == successBytes,
                  "retry leaves same-batch successful item and output bytes unchanged")
            check(store.specialStorage.get(1, in: a.id).attachments.isEmpty
                  && store.specialStorage.get(3, in: b.id).attachments.isEmpty,
                  "retry and success both write zero source attachments")
            check(Set(retried.items.compactMap(\.localFile).map { URL(fileURLWithPath: $0).deletingLastPathComponent() }).count == 1,
                  "retry output stays in original batch folder")
            capture(retrySheet, "batch-single-retry-complete.png")
            _ = press(retrySheet, "batch-close")
            await settle()

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_FAIL_ONCE live-queue"), in: a.id)
            _ = store.specialStorage.set(3, content: .init(text: "BATCH_SLOW live-queue"), in: b.id)
            await controller.loadLibrary(store: store)
            var live = controller.plan(projectID: originalProject, selected: [a.id, b.id], configuration: config,
                                       model: catalog.imageModels.first)
            live.concurrency = 2
            let liveBefore = submissionCount()
            _ = controller.start(live, store: store, model: catalog.imageModels.first)
            check(await wait { controller.batch(live.id)?.items.contains(where: \.canRetry) == true },
                  "early failed item is retryable while sibling is running")
            let liveFailed = controller.batch(live.id)!.items.first(where: \.canRetry)!
            check(controller.runningID == live.id, "live retry meets active same batch")
            check(!controller.retry(failed.id, itemID: failed.items[0].id, store: store, model: catalog.imageModels.first),
                  "different batch cannot retry during active generation")
            check(controller.retry(live.id, itemID: liveFailed.id, store: store, model: catalog.imageModels.first),
                  "active same batch accepts selected failure retry")
            check(await wait { controller.runningID == nil }, "rolling window drains appended retry")
            check(controller.batch(live.id)?.completedCount == 2 && submissionCount() == liveBefore + 3
                  && controller.peakActiveCount <= 2, "live retry runs once within configured concurrency")

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_QUERY_FAIL_ONCE"), in: a.id)
            await controller.loadLibrary(store: store)
            let query = controller.plan(projectID: originalProject, selected: [a.id], configuration: config,
                                        model: catalog.imageModels.first)
            let queryBefore = submissionCount()
            _ = controller.start(query, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "temporary task query failure settles")
            let queryItem = controller.batch(query.id)!.items[0]
            check(queryItem.canRecover && !queryItem.canRetry
                  && !controller.retry(query.id, itemID: queryItem.id, store: store, model: catalog.imageModels.first),
                  "query error permits retrieval and rejects paid resubmission")
            controller.recover(query.id, itemID: queryItem.id, store: store)
            check(await wait { controller.runningID == nil }, "single-item query recovery succeeds")
            check(controller.batch(query.id)?.completedCount == 1 && submissionCount() == queryBefore + 1,
                  "single-item recovery does not submit a second task")

            var referencedContent = SlotContent(text: "reference image preserved")
            var inputImage = SlotContent.SlotAttachment(name: "input.png", type: .image)
            inputImage.storagePath = directory.appendingPathComponent("fixture.png").path
            referencedContent.attachments = [inputImage]
            _ = store.specialStorage.set(1, content: referencedContent, in: a.id)
            let protectedSource = store.specialStorage.get(1, in: a.id)
            let protectedSourceJSON = try CanvasWorkflowSnapshot.jsonData(protectedSource)
            let protectedReferenceBytes = protectedSource.attachments.first!.resolveData()
            await controller.loadLibrary(store: store)
            let referenced = controller.plan(projectID: originalProject, selected: [a.id], configuration: config,
                                              model: catalog.imageModels.first)
            _ = controller.start(referenced, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "reference image batch completes")
            check(controller.batch(referenced.id)?.completedCount == 1
                  && (try? CanvasWorkflowSnapshot.jsonData(store.specialStorage.get(1, in: a.id))) == protectedSourceJSON
                  && store.specialStorage.get(1, in: a.id).attachments.first?.resolveData() == protectedReferenceBytes,
                  "batch preserves source content and existing reference attachment bytes")
            let wire = (try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"))) ?? ""
            check(wire.split(separator: "\n").contains { $0.contains("reference image preserved") && $0.contains("\"--image\"") },
                  "reference image remains part of generation request")
            try Data("local video fixture".utf8).write(to: directory.appendingPathComponent("fixture.mp4"))
            _ = store.specialStorage.set(1, content: .init(text: "video archive only"), in: a.id)
            await controller.loadLibrary(store: store)
            var videoConfig = config
            videoConfig.kind = .video; videoConfig.model = "seedance2-mini"
            let videoBatch = controller.plan(projectID: originalProject, selected: [a.id], configuration: videoConfig,
                                             model: catalog.videoModels.first)
            _ = controller.start(videoBatch, store: store, model: catalog.videoModels.first)
            check(await wait { controller.runningID == nil }, "video batch archive completes")
            check(controller.batch(videoBatch.id)?.completedCount == 1
                  && controller.batch(videoBatch.id)?.items[0].localFile?.hasSuffix(".mp4") == true
                  && store.specialStorage.get(1, in: a.id).attachments.isEmpty,
                  "video output is archived without source attachment insertion")

            var invalidConfig = config
            invalidConfig.model = "seedance2-mini"
            let invalid = controller.plan(projectID: originalProject, selected: [a.id],
                                          configuration: invalidConfig, model: nil)
            let invalidBefore = submissionCount()
            _ = controller.start(invalid, store: store, model: nil)
            check(await wait { controller.runningID == nil }, "latest model validation rejection settles")
            check(controller.batch(invalid.id)?.items[0].canRetry == true
                  && controller.batch(invalid.id)?.items[0].status == .failed
                  && submissionCount() == invalidBefore,
                  "request rejected before submission stays retryable without unknown task state")

            // Real controller + subprocess + HTTP download + on-disk output under a
            // deterministic LOCAL fixture. This is a scheduler test, not a cloud speed claim.
            var stressGroups = Set<String>()
            for g in 0..<4 {
                let group = try store.specialStorage.createSpecialSlot(name: "并发验证 \(g)", pageId: p.page.id)
                stressGroups.insert(group.id)
                for s in 1...10 {
                    _ = store.specialStorage.set(s, content: .init(text: "BATCH_PARALLEL \(g)-\(s)"), in: group.id)
                }
            }
            await controller.loadLibrary(store: store)
            let stress = controller.plan(projectID: originalProject, selected: stressGroups, configuration: config,
                                         model: catalog.imageModels.first)
            let stressBefore = submissionCount()
            let began = Date()
            _ = controller.start(stress, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "40-output parallel batch drains")
            check(controller.peakActiveCount == 32, "scheduler reaches but never exceeds configured maximum 32")
            let stressOutputs = controller.batch(stress.id)?.items.compactMap(\.localFile) ?? []
            check(stressOutputs.count == 40 && submissionCount() == stressBefore + 40,
                  "rolling window refills beyond first 32 without duplicate submits")
            check(Set(stressOutputs.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }).count == 1,
                  "40 parallel outputs share one batch folder")
            let hashes = stressOutputs.compactMap { try? LocalToolchain.sha256(URL(fileURLWithPath: $0)) }
            check(Set(hashes).count == 40, "40 independent fixture outputs retain unique image bytes")
            let parallelSeconds = Date().timeIntervalSince(began)
            for (g, group) in stressGroups.sorted().enumerated() {
                for slot in 1...10 {
                    _ = store.specialStorage.set(slot, content: .init(text: "BATCH_PARALLEL \(g)-\(slot)"), in: group)
                }
            }
            await controller.loadLibrary(store: store)
            var serial = controller.plan(projectID: originalProject, selected: stressGroups, configuration: config,
                                         model: catalog.imageModels.first)
            serial.concurrency = 1
            let serialStart = Date()
            _ = controller.start(serial, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "serial comparison fixture completes")
            let serialSeconds = Date().timeIntervalSince(serialStart)
            check(controller.batch(serial.id)?.completedCount == 40 && controller.peakActiveCount == 1,
                  "same 40-item fixture verifies serial setting")
            try JSONSerialization.data(withJSONObject: ["items": stressOutputs.count,
                "peak": 32, "seconds": parallelSeconds, "serial_seconds": serialSeconds,
                "fixture_speed_ratio": serialSeconds / parallelSeconds,
                "measurement": "local deterministic fixture; not remote performance"])
                .write(to: directory.appendingPathComponent("concurrency.json"))

            for group in stressGroups {
                for slot in 1...10 {
                    _ = store.specialStorage.set(slot, content: .init(text: "BATCH_SLOW concurrent stop \(slot)"), in: group)
                }
            }
            await controller.loadLibrary(store: store)
            let parallelStop = controller.plan(projectID: originalProject, selected: stressGroups, configuration: config,
                                               model: catalog.imageModels.first)
            let parallelStopBefore = submissionCount()
            _ = controller.start(parallelStop, store: store, model: catalog.imageModels.first)
            _ = await wait { submissionCount() > parallelStopBefore }
            controller.stop(parallelStop.id)
            check(await wait { controller.runningID == nil }, "parallel stop drains started submits")
            let stoppedItems = controller.batch(parallelStop.id)?.items ?? []
            let launched = submissionCount() - parallelStopBefore
            let known = stoppedItems.filter { $0.taskID != nil }.count
            check((1...4).contains(launched) && known == launched, "stop starts no queued CLI and preserves each in-flight task ID")
            check(!stoppedItems.contains { $0.status == .unknown }, "cancelled process waiters are stopped, never unknown submissions")
            let stoppedBeforeRecovery = submissionCount()
            controller.recover(parallelStop.id, store: store)
            check(await wait { controller.runningID == nil }, "parallel stopped tasks recover")
            check(submissionCount() == stoppedBeforeRecovery && controller.batch(parallelStop.id)?.completedCount == known,
                  "parallel recovery only queries known IDs")

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_RATE"), in: a.id)
            await controller.loadLibrary(store: store)
            let rate = controller.plan(projectID: originalProject, selected: [a.id], configuration: config,
                                       model: catalog.imageModels.first)
            let rateBefore = submissionCount()
            _ = controller.start(rate, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "explicit 429 retry settles")
            check(controller.batch(rate.id)?.completedCount == 1 && submissionCount() == rateBefore + 3,
                  "explicit 429 retries twice then succeeds")
            let attempts = GenerationRunStore.shared.load(project: originalProject, id: rate.items[0].runID)?.attempts ?? []
            check(attempts.count == 3 && attempts.dropLast().allSatisfy { $0.status == .rejected },
                  "429 attempts are recorded as rejected, not ambiguous")

            _ = store.specialStorage.set(1, content: .init(text: "BATCH_RATE_ALWAYS"), in: a.id)
            await controller.loadLibrary(store: store)
            var limited = controller.plan(projectID: originalProject, selected: [a.id, b.id], configuration: config,
                                          model: catalog.imageModels.first)
            limited.concurrency = 1
            let limitedBefore = submissionCount()
            _ = controller.start(limited, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "persistent 429 settles after bounded retries")
            check(submissionCount() == limitedBefore + 3 && controller.batch(limited.id)?.items.last?.status == .stopped,
                  "persistent 429 stops new submissions after two retries")

            // Keep the layout subject visible at the top of the lazy history list.
            _ = store.specialStorage.set(1, content: .init(text: "布局产物甲"), in: a.id)
            _ = store.specialStorage.set(3, content: .init(text: "布局产物乙"), in: b.id)
            await controller.loadLibrary(store: store)
            let layoutBatch = controller.plan(projectID: originalProject, selected: [a.id, b.id],
                                              configuration: config, model: catalog.imageModels.first)
            _ = controller.start(layoutBatch, store: store, model: catalog.imageModels.first)
            check(await wait { controller.runningID == nil }, "layout subject batch completes")
            check(controller.batch(layoutBatch.id)?.completedCount == 2, "layout subject has two archived outputs")
            for skin in AppSkin.allCases {
                AppSkinCenter.apply(skin)
                for dark in [false, true] {
                    for width in [CGFloat(480), 820] {
                        let size = CGSize(width: width, height: 650)
                        let suffix = "\(skin.rawValue)-\(dark ? "dark" : "light")-\(Int(width))"
                        let preview = NSHostingView(rootView:
                            BatchGenerationView(store: store, canvas: canvas, size: size)
                                .environment(\.colorScheme, dark ? .dark : .light))
                        let previewWindow = NSWindow(contentRect: .init(x: 20, y: 20,
                            width: min(740, width - 32), height: 602),
                            styleMask: [.titled], backing: .buffered, defer: false)
                        previewWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        previewWindow.isReleasedWhenClosed = false
                        previewWindow.contentView = preview
                        previewWindow.makeKeyAndOrderFront(nil)
                        await settle()
                        check(await wait { !controller.isLoading }, "responsive library loaded \(suffix)")
                        check(preview.bounds.width <= width && preview.bounds.height <= size.height,
                              "dialog fits available size \(suffix)")
                        aligned(preview, ["batch-history", "batch-close"], "header controls aligned at 32pt \(suffix)")
                        aligned(preview, ["batch-model-picker", "batch-aspect-picker"],
                                "model and ratio controls aligned at 32pt \(suffix)")
                        aligned(preview, ["batch-select-all", "batch-deselect-all"],
                                "selection controls aligned at 32pt \(suffix)")
                        capture(preview, "batch-selection-\(suffix).png")
                        check(press(preview, "batch-history"), "native history button opens \(suffix)")
                        await settle()
                        let historyPanel = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                            .first { find($0, "batch-history-" + layoutBatch.id.uuidString) != nil }
                        if let historyPanel {
                            capture(historyPanel, "batch-history-\(suffix).png")
                            check(press(historyPanel, "batch-history-" + layoutBatch.id.uuidString),
                                  "history switches to chosen completed batch \(suffix)")
                        } else { check(false, "history exposes saved batch \(suffix)") }
                        await settle()
                        let outputIDs = layoutBatch.items.map { "batch-output-" + $0.id.uuidString }
                        let outputFrames = outputIDs.map { frame(preview, $0) }
                        check(outputFrames.allSatisfy { $0.width > 0 && abs($0.height - 32) <= 1 }
                              && abs(outputFrames[0].minX - outputFrames[1].minX) <= 1,
                              "output buttons form one aligned column \(suffix)")
                        capture(preview, "batch-progress-\(suffix).png")
                        check(press(preview, "batch-new"), "new batch returns to selection \(suffix)")
                        await settle()
                        previewWindow.close()
                    }
                }
            }
            let allRuns = GenerationRunStore.shared.runs(project: originalProject)
            check(allRuns.reduce(0) { $0 + $1.attempts.filter { $0.detail != "未启动进程，已取消提交" }.count } == submissionCount(),
                  "every batch submit attempt has a real generation journal")
            let environmentResult = await runEnvironmentSetupProbe(directory: directory)
            passed += environmentResult.0
            failures += environmentResult.1
        } catch { check(false, "batch native exception: \(error)") }
        let report: [String: Any] = ["passed": passed, "failures": failures,
            "sessionLocked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        for window in NSApp.windows {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
        }
        // This probe only runs in the isolated fixture bundle; bypass sheet-driven
        // termination deferral after the report is on disk.
        exit(0)
    }
}
#endif
