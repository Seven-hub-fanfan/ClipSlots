#if DEBUG
import AppKit
import SwiftUI
import CryptoKit
import ImageIO
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor
    func runImageIndependenceProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        var submissions = 0
        var records: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) {
            if value { passed += 1 } else { failures.append(title) }
            NSLog("[ImageIndependence] \(value ? "PASS" : "FAIL") \(title)")
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func save(_ complete: Bool) {
            let result: [String: Any] = ["passed": passed, "failures": failures, "complete": complete,
                "expectedCrateSubmissions": submissions, "observations": records,
                "scope": "real app with installed CLI parameter builder, distinct local fixture images"]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
        }
        func screenshot(_ name: String) {
            guard let content = inputRouter.anchorView?.window?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        var seen = Set<String>()
        func verify(_ node: CanvasNode, label: String) async {
            guard let media = previewableMedia(of: node), let url = media.canvasLocalURL,
                  let data = try? Data(contentsOf: url), let taskID = node.taskId else {
                check(false, "\(label) preview exists"); return
            }
            let hash = digest(data)
            check(seen.insert(hash).inserted, "\(label) content differs from earlier task")
            let original = directory.appendingPathComponent(taskID + ".png")
            check((try? Data(contentsOf: original)) == data, "\(label) stored bytes match task original without UI")
            check(!canArchiveToLibrary(node), "\(label) has no image archive action")
            let expected = directory.appendingPathComponent("downloads/ClipSlots", isDirectory: true)
            let exported = ((try? FileManager.default.contentsOfDirectory(at: expected,
                includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.contains(taskID) }
            check(exported.count == 1, "\(label) auto-download already exists without user action")
            check(exported.first.flatMap { try? Data(contentsOf: $0) } == data,
                  "\(label) downloaded bytes are exact original")
            if let download = try? await CanvasImageDownloads.shared.save(file: url, taskID: taskID) {
                check(download.standardizedFileURL.path == exported.first?.standardizedFileURL.path,
                      "\(label) repeated save is idempotent")
            } else { check(false, "\(label) repeated save succeeds") }
            let after = ((try? FileManager.default.contentsOfDirectory(at: expected,
                includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.contains(taskID) }
            check(after.count == 1, "\(label) recovery does not duplicate downloads")
            let inputs = inputImagePaths(for: node)
            check(inputs.isEmpty, "\(label) produced file never becomes implicit self reference")
            records.append(["node": node.id, "task": taskID, "sha256": hash,
                "bytes": data.count, "download": exported.first?.lastPathComponent ?? ""])
        }
        let prompt = createNode(kind: .text, at: CGPoint(x: 180, y: 360),
            parentNodeId: nil, beginEditing: false, quiet: true)!
        commitEdit(prompt, text: "INDEPENDENCE shared prompt")
        let source = createNode(kind: .image, at: CGPoint(x: 580, y: 360),
            parentNodeId: prompt.id, beginEditing: false, quiet: true)!
        canvas.updateNode(id: source.id) { $0.mediaRole = .generation }
        commitEdit(source, text: "INDEPENDENCE four independent images")
        canvas.updateNodeGeneration(id: source.id, model: "seedream45", ratio: "9:16", count: 4, resolution: "2K")
        let before = Set(canvas.nodes.map(\.id))
        let task = generateAdjacentResults(canvas.node(id: source.id)!)
        check(task != nil, "count four starts")
        if task != nil { submissions += 4 }
        await task?.value
        let children = canvas.nodes.filter { !before.contains($0.id) }.sorted { $0.x < $1.x }
        check(children.count == 3, "batch contains source and exactly three siblings")
        check(children.allSatisfy { canvas.incomingEdges(of: $0.id).map(\.fromNodeId) == [prompt.id] },
              "batch siblings connect to shared text, never first image")
        for (index, node) in ([canvas.node(id: source.id)!] + children).enumerated() {
            await verify(node, label: "batch \(index + 1)")
            let plan = CanvasWorkflowCapture.plan(node: node, canvas: canvas, store: store)
            check(plan.imageRequest?.imagePaths.isEmpty == true, "batch \(index + 1) has no leaked reference image")
            check(plan.imageRequest?.prompt == "INDEPENDENCE shared prompt\n\nINDEPENDENCE four independent images",
                  "batch \(index + 1) retains independent prompt")
            check(plan.imageRequest?.width == 1440 && plan.imageRequest?.height == 2560,
                  "batch \(index + 1) retains 9:16 2K parameters")
        }
        canvas.clearSelection()
        pan = CGSize(width: -70, height: 50); zoom = 0.6
        try? await Task.sleep(for: .milliseconds(650))
        screenshot("four-independent-results")
        // Four later user actions must not pick up the previous outputs.
        canvas.updateNodeGeneration(id: source.id, count: 1)
        for attempt in 1...4 {
            commitEdit(canvas.node(id: source.id)!, text: "INDEPENDENCE sequential action \(attempt)")
            if let task = generateAdjacentResults(canvas.node(id: source.id)!) {
                submissions += 1
                await task.value
            } else { check(false, "sequential \(attempt) starts") }
            await verify(canvas.node(id: source.id)!, label: "sequential \(attempt)")
        }
        let reference = createNode(kind: .image, at: CGPoint(x: 140, y: 800),
            parentNodeId: nil, beginEditing: false, quiet: true)!
        var input = SlotContent.SlotAttachment(name: "fixture.png", type: .image)
        input.storagePath = directory.appendingPathComponent("fixture.png").path
        check(store.writeCanvasSlotAttachments(groupId: reference.groupId, slot: reference.slot,
                                               attachments: [input]), "explicit reference fixture saves")
        let target = createNode(kind: .image, at: CGPoint(x: 600, y: 800),
            parentNodeId: reference.id, beginEditing: false, quiet: true)!
        commitEdit(target, text: "INDEPENDENCE explicit reference remains")
        let plan = CanvasWorkflowCapture.plan(node: target, canvas: canvas, store: store)
        check(plan.imageRequest?.imagePaths.count == 1, "intentional image reference remains supported")
        // A recovery save must preserve a download modified by the user.
        if let latest = canvas.node(id: source.id), let taskID = latest.taskId,
           let file = previewableMedia(of: latest)?.canvasLocalURL,
           let downloaded = try? await CanvasImageDownloads.shared.save(file: file, taskID: taskID) {
            let edited = Data("user edited download".utf8)
            try? edited.write(to: downloaded)
            let fresh = try? await CanvasImageDownloads.shared.save(file: file, taskID: taskID)
            check((try? Data(contentsOf: downloaded)) == edited,
                  "recovery never overwrites an edited local download")
            check(fresh?.path != downloaded.path &&
                  fresh.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: file)),
                  "recovery creates another exact original when the local file changed")
        }
        let invalid = directory.appendingPathComponent("invalid-image.bin")
        try? Data("invalid image".utf8).write(to: invalid)
        do {
            _ = try await CanvasImageDownloads.shared.save(file: invalid, taskID: "invalid")
            check(false, "corrupt image cannot be advertised as downloaded")
        } catch { check(true, "corrupt image cannot be advertised as downloaded") }
        // The new download entry is external to the image; retain clean cards on hover.
        canvas.select(id: source.id, additive: false)
        pan = CGSize(width: -70, height: 50); zoom = 0.6
        hoverHoldNodeId = source.id
        try? await Task.sleep(for: .milliseconds(500))
        screenshot("generated-image-hover")
        let samples = [canvas.node(id: source.id)!] + children
        if let content = inputRouter.anchorView?.window?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            for (index, node) in samples.enumerated() {
                if let region = controlRegions["canvas-image-pixels-\(node.id)"],
                   let file = previewableMedia(of: node)?.canvasLocalURL,
                   let bytes = try? Data(contentsOf: file),
                   let original = NSBitmapImageRep(data: bytes),
                   let expected = original.colorAt(x: 3, y: 3)?.usingColorSpace(.sRGB) {
                    let point = CGPoint(x: region.minX + region.width * 0.12,
                                        y: region.minY + region.height * 0.15)
                    let actual = bitmap.colorAt(
                        x: Int(point.x * CGFloat(bitmap.pixelsWide) / content.bounds.width),
                        y: Int(point.y * CGFloat(bitmap.pixelsHigh) / content.bounds.height))?.usingColorSpace(.sRGB)
                    let red = abs((actual?.redComponent ?? 100) - expected.redComponent)
                    let green = abs((actual?.greenComponent ?? 100) - expected.greenComponent)
                    let blue = abs((actual?.blueComponent ?? 100) - expected.blueComponent)
                    let delta = red + green + blue
                    check(delta < 0.12, "batch \(index + 1) screen pixels belong to its own task")
                } else { check(false, "batch \(index + 1) exposes original and rendered pixels") }
            }
        }
        if let actions = controlRegions["selection-actions"] {
            check(([canvas.node(id: source.id)!] + children).allSatisfy {
                !screenFrame(of: $0).intersects(actions)
            }, "selected toolbar does not cover any batch image")
        }
        check(controlRegions["node-chips-\(source.id)"] == nil, "generated image has no chips covering pixels")
        check(controlRegions["canvas-footer-toolbar"] != nil, "footer control region remains mounted")
        if let window = inputRouter.anchorView?.window {
            for width in [CGFloat(780), 960, 1440] {
                window.setContentSize(CGSize(width: width, height: 850))
                canvas.isLibraryExpanded = true
                try? await Task.sleep(for: .milliseconds(350))
                // Async View values snapshot @State, so read actual registered geometry.
                if let toolbar = controlRegions["canvas-footer-toolbar"],
                   let navigation = controlRegions["canvas-navigation"] {
                    check(!toolbar.intersects(navigation), "footer width \(Int(width)) has no overlapping controls")
                } else { check(false, "footer width \(Int(width)) exposes measured geometry") }
                screenshot("footer-\(Int(width))")
            }
        }
        save(true)
        NSApp.terminate(nil)
    }
}
#endif
