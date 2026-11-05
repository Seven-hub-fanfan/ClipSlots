#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

enum AttachmentTransferRegression {
    private static var fixtureWindow: NSWindow?
    private static func waitFor(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 1))
            }
        }
    }
    @MainActor static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["CLIPSLOTS_ATTACHMENT_REGRESSION"] else { return }
        guard folder.hasPrefix("/private/tmp/clipslots-editor-"),
              env["CLIPSLOTS_DATA_DIR"] == folder + "/data",
              env["CLIPSLOTS_CONFIG_PATH"] == folder + "/config.toml",
              Bundle.main.bundleIdentifier == "com.clipslots.app.attachment-regression",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true else { exit(2) }
        if let crashStage = env["CLIPSLOTS_ATTACHMENT_CRASH_STAGE"].flatMap(Int.init),
           let groupID = env["CLIPSLOTS_ATTACHMENT_CRASH_GROUP"] {
            do {
                let storage = SpecialSlotStorage()
                let snapshot = try storage.editorSnapshot(5, in: groupID)
                let source = SlotFileMove(snapshot: snapshot, attachment: snapshot.content.attachments[0])
                _ = try storage.moveFile(source, from: storage, to: 6, groupID: groupID,
                    destination: .attachments, checkpoint: { if $0 == crashStage { _exit(77) } })
                exit(3)
            } catch { exit(4) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            let root = URL(fileURLWithPath: folder)
            var passes = 0, failures: [String] = []
            func check(_ value: Bool, _ name: String) {
                if value { passes += 1 } else { failures.append(name) }
            }
            do {
                let store = SlotStoreObservable()
                let storage = store.specialStorage
                let first = storage.loadIndex().specialSlots[0]
                let second = try storage.createSpecialSlot(name: "拖入目标组")
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let png = bitmap.representation(using: .png, properties: [:])!
                let file = root.appendingPathComponent("多字节 空格.txt")
                let bytes = Data("源文件内容🙂".utf8)
                try bytes.write(to: file)
                let image = root.appendingPathComponent("图片.png")
                try png.write(to: image)
                let source = SlotContent(items: [
                    [.init(type: "public.file-url", data: Data(file.absoluteString.utf8)),
                     .init(type: "com.apple.icns", data: png)],
                    [.init(type: "public.file-url", data: Data(image.absoluteString.utf8))]],
                    attachments: [.init(name: "已存在附件", type: .text, data: Data("保留".utf8))])
                check(storage.set(1, content: source, in: first.id), "建立文件主体")
                check(storage.set(2, content: SlotContent(text: "目标主体"), in: second.id), "建立目标主体")
                check(AttachmentTransfer.body(source).map(\.name) == [file.lastPathComponent, image.lastPathComponent],
                      "文件主体不把 Finder 图标或原附件重复拖入，保持文件顺序")
                let inline = SlotContent(items: [[.init(type: "public.png", data: png),
                                                   .init(type: "public.tiff", data: png)]])
                check(AttachmentTransfer.body(inline).count == 1, "多种位图表示只生成一个附件")
                check(AttachmentTransfer.canDrag(SlotContent(text: "普通正文")), "纯文本正文支持拖动")
                check(!AttachmentTransfer.canDrag(SlotContent()), "空槽位不生成拖拽内容")

                func load(_ providers: [NSItemProvider]) async -> AttachmentTransfer.Loaded? {
                    await withCheckedContinuation { continuation in
                        if !AttachmentTransfer.receive(providers, completion: { continuation.resume(returning: $0) }) {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                try await SlotTextTransferRegression.run(root: root, store: store, png: png, check: check)
                try await AttachmentBundleRegression.run(root: root, store: store, check: check)
                // Saved MD bodies are managed files. Labeled slots force the
                // manifest label-read path that used to deadlock move staging.
                let mdGroup = try storage.createSpecialSlot(name: "已编辑 Markdown 来源")
                let mdTarget = try storage.createSpecialSlot(name: "已编辑 Markdown 目标")
                let mdURL = root.appendingPathComponent("已编辑 中文.md")
                let mdBytes = Data([0xEF, 0xBB, 0xBF]) + Data("# 原文\r\n正文🙂\r\n".utf8)
                try mdBytes.write(to: mdURL)
                var mdContent = SlotContent(items: [[.init(type: "public.file-url",
                    data: Data(mdURL.absoluteString.utf8))]],
                    attachments: [.init(name: "保留附件", type: .text, data: Data("keep".utf8))])
                mdContent.label = "来源标签"
                check(storage.set(1, content: mdContent, in: mdGroup.id), "建立带标签 Markdown 主体")
                storage.setLabel(1, label: "来源标签", in: mdGroup.id)
                let mdSnapshot = try store.captureSlotEditor(slot: 1, groupID: mdGroup.id)
                let mdModel = try SlotEditorModel(snapshot: mdSnapshot)
                mdModel.draft = "# 保存后\r\n**已编辑**🙂\r\n"
                let mdDocument = mdModel.markdown!
                let editedMD = try mdDocument.encoded(mdModel.draft)
                try store.saveSlotEditor(mdSnapshot, body: mdModel.body,
                    attachments: mdModel.attachments, markdownEdit: mdModel.markdownEdit)
                check(storage.get(1, in: mdGroup.id).primaryFileURL?.lastPathComponent == mdURL.lastPathComponent,
                      "Markdown 编辑保存保留文件名")
                var mdCurrentGroup = mdGroup.id
                var mdCurrentSlot = 1
                var moveDurations: [Double] = []
                for step in 1...6 {
                    let destinationGroup = step.isMultiple(of: 2) ? mdGroup.id : mdTarget.id
                    let destinationSlot = step + 1
                    var destinationContent = SlotContent()
                    destinationContent.label = "目标标签 \(step)"
                    destinationContent.attachments = [
                        .init(name: "目标附件 \(step)", type: .text, data: Data("target".utf8))]
                    check(storage.set(destinationSlot, content: destinationContent, in: destinationGroup),
                          "建立带标签目标 \(step)")
                    storage.setLabel(destinationSlot, label: destinationContent.label, in: destinationGroup)
                    let drag = store.fileMoveSource(groupID: mdCurrentGroup, slot: mdCurrentSlot)!
                    let payload = await load([AttachmentTransfer.provider(drag)])
                    let start = ProcessInfo.processInfo.systemUptime
                    check(payload.map { store.acceptTransfer($0, groupID: destinationGroup,
                        slot: destinationSlot, destination: .body) } == true, "保存后 MD 跨组移动 \(step)")
                    moveDurations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    let moved = SpecialSlotStorage().get(destinationSlot, in: destinationGroup)
                    check(moved.primaryFileURL?.lastPathComponent == mdURL.lastPathComponent
                        && moved.primaryFileURL.flatMap { try? Data(contentsOf: $0) } == editedMD,
                        "跨组移动 \(step) 冷读保留编辑字节与文件名")
                    check(storage.get(mdCurrentSlot, in: mdCurrentGroup).hasEmptyBody
                        && storage.get(mdCurrentSlot, in: mdCurrentGroup).attachments.count == 1
                        && moved.attachments.count == 1
                        && storage.getLabel(destinationSlot, in: destinationGroup) == destinationContent.label,
                        "跨组移动 \(step) 保留双方附件与目标标签")
                    mdCurrentGroup = destinationGroup
                    mdCurrentSlot = destinationSlot
                }
                check(moveDurations.allSatisfy { $0 < 1000 }, "保存后 MD 每次移动在一秒内返回")
                check(try Data(contentsOf: mdURL) == mdBytes, "MD 连续移动保留 Finder 原文件")
                let busyMove = SlotFileMove(snapshot: try storage.editorSnapshot(mdCurrentSlot, in: mdCurrentGroup))
                let lockHeld = DispatchSemaphore(value: 0)
                let releaseLock = DispatchSemaphore(value: 0)
                let lockFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    try? StorageLock.shared.withLock {
                        lockHeld.signal()
                        _ = releaseLock.wait(timeout: .now() + 2)
                    }
                    lockFinished.signal()
                }
                let acquired = await waitFor(lockHeld)
                check(acquired == .success, "建立进程内存储繁忙场景")
                let busyStart = ProcessInfo.processInfo.systemUptime
                do {
                    _ = try storage.moveFile(busyMove, from: storage, to: 9, groupID: mdTarget.id,
                                             destination: .body)
                    check(false, "进程内锁繁忙时拒绝移动")
                } catch { check(true, "进程内锁繁忙时拒绝移动") }
                let busyMilliseconds = (ProcessInfo.processInfo.systemUptime - busyStart) * 1000
                releaseLock.signal()
                let released = await waitFor(lockFinished)
                check(released == .success, "繁忙验证释放存储锁")
                check(busyMilliseconds < 500, "进程内锁等待有界，不阻塞界面")
                check(storage.get(mdCurrentSlot, in: mdCurrentGroup).primaryFileURL.flatMap {
                    try? Data(contentsOf: $0)
                } == editedMD && storage.get(9, in: mdTarget.id).hasEmptyBody,
                      "繁忙移动不改变来源和目标")
                try JSONSerialization.data(withJSONObject: [
                    "move_ms": moveDurations, "busy_lock_ms": busyMilliseconds
                ], options: [.prettyPrinted])
                    .write(to: root.appendingPathComponent("markdown-move-timing.json"), options: .atomic)
                let selfSource = try storage.editorSnapshot(1, in: first.id)
                let move = SlotFileMove(snapshot: selfSource)
                let provider = AttachmentTransfer.provider(move)
                let selfMove = await load([provider])
                check(selfMove.map { store.acceptTransfer($0, groupID: first.id, slot: 1) } == true,
                      "主体移动到自身附件")
                let afterSelf = storage.get(1, in: first.id)
                check(afterSelf.items.isEmpty && afterSelf.attachments.count == 3,
                      "自身移动清除文件主体，保留原有附件")
                check(afterSelf.attachments[1].resolveData() == bytes && afterSelf.attachments[2].resolveData() == png,
                      "文件与图片原字节落入目标自有存储")
                let rawAttachments = try JSONDecoder().decode([SlotContent.SlotAttachment].self,
                    from: Data(contentsOf: storage.storageRoot.appendingPathComponent("\(first.id)/1/attachments.json")))
                check(rawAttachments.allSatisfy { $0.storagePath.map { FileManager.default.fileExists(atPath: $0) } ?? true },
                      "原始附件元数据直接指向最终文件路径")
                let repeated = await load([provider])
                check(repeated.map { store.acceptTransfer($0, groupID: first.id, slot: 1) } == false,
                      "重复投递旧拖拽不重复创建附件")
                check(FileManager.default.fileExists(atPath: file.path), "外部文件引用不删除 Finder 原文件")

                let attachmentMove = SlotFileMove(snapshot: try storage.editorSnapshot(1, in: first.id),
                    attachment: afterSelf.attachments[1])
                let delayed = NSItemProvider()
                delayed.registerDataRepresentation(forTypeIdentifier: AttachmentTransfer.bodyType.identifier,
                                                   visibility: .ownProcess) { completion in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                        completion(try? JSONEncoder().encode(attachmentMove), nil)
                    }
                    return nil
                }
                let targetGroup = second.id
                let operation = Task { @MainActor in
                    let loaded = await load([delayed])
                    return loaded.map { store.acceptTransfer($0, groupID: targetGroup, slot: 2) } == true
                }
                store.switchSpecialSlot(id: first.id, fromNavigation: true)
                // Another storage instance modifies the destination while the provider resolves.
                _ = try SpecialSlotStorage().appendTransferredAttachments(
                    [.init(name: "并发附件", type: .text, data: Data("并发".utf8))], slot: 2, groupID: second.id)
                check(await operation.value, "延迟载入期间切组仍写入原定目标")
                let cross = storage.get(2, in: second.id)
                check(cross.attachments.count == 2 && cross.attachments.first?.name == "并发附件"
                    && cross.preview == "目标主体", "跨组移动保留并发附件和目标主体")
                check(cross.attachments.last?.id == afterSelf.attachments[1].id
                    && storage.get(1, in: first.id).attachments.count == 2,
                    "附件移动保留身份，来源条目与字节移除")
                check(!FileManager.default.fileExists(atPath: afterSelf.attachments[1].storagePath!),
                      "来源附件自有文件已移出")
                try FileManager.default.removeItem(at: file)
                try FileManager.default.removeItem(at: image)
                check(cross.attachments.last?.resolveData() == bytes
                    && storage.get(1, in: first.id).attachments.last?.resolveData() == png,
                      "删除外部文件后移动的内容仍完整")

                let promoted = SlotFileMove(snapshot: try storage.editorSnapshot(2, in: second.id),
                    attachment: cross.attachments.last!)
                check(store.acceptTransfer(.move(promoted), groupID: first.id, slot: 4, destination: .body),
                      "附件可跨组移动到空槽位主体")
                let promotedBody = storage.get(4, in: first.id)
                let rawBodyDirectory = storage.storageRoot.appendingPathComponent("\(first.id)/4")
                let rawURLBytes = try Data(contentsOf: rawBodyDirectory.appendingPathComponent("item_0/public.file-url.bin"))
                let rawURL = String(data: rawURLBytes, encoding: .utf8).flatMap(URL.init(string:))
                check(rawURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                      "主体文件 URL 落盘后直接指向最终目录")
                check(promotedBody.detectedFileURLs.first.flatMap { try? Data(contentsOf: $0) } == bytes
                    && storage.get(2, in: second.id).attachments.count == 1,
                      "附件提升主体后文件仍可读取且来源已清除")
                var edited = promotedBody
                edited.attachments.append(.init(name: "新附件", type: .text, data: Data("keep".utf8)))
                check(storage.set(4, content: edited, in: first.id), "后续编辑保留主体文件")
                let cold = SpecialSlotStorage()
                check(cold.get(4, in: first.id).detectedFileURLs.first.flatMap { try? Data(contentsOf: $0) } == bytes,
                      "重启冷读及后续原子写不使主体文件断链")
                let bodyAgain = SlotFileMove(snapshot: try storage.editorSnapshot(4, in: first.id))
                check(store.acceptTransfer(.move(bodyAgain), groupID: first.id, slot: 5),
                      "自有文件主体可再次移动到附件")
                check(storage.get(4, in: first.id).items.isEmpty
                    && storage.get(4, in: first.id).attachments.count == 1
                    && storage.get(5, in: first.id).attachments.first?.resolveData() == bytes,
                      "连续移动保持字节和非来源附件")

                let rollbackSource = SlotFileMove(snapshot: try storage.editorSnapshot(5, in: first.id),
                    attachment: storage.get(5, in: first.id).attachments[0])
                let beforeSource = storage.get(5, in: first.id)
                let beforeTarget = storage.get(6, in: first.id)
                for failAfter in [1, 2] {
                    do {
                        _ = try storage.moveFile(rollbackSource, from: storage, to: 6, groupID: first.id,
                            destination: .attachments, checkpoint: { stage in
                                if stage == failAfter { throw AgentCanvasError.writeFailed }
                            })
                        check(false, "中途失败回滚 \(failAfter)")
                    } catch {
                        let restoredSource = SpecialSlotStorage().get(5, in: first.id)
                        let restoredTarget = SpecialSlotStorage().get(6, in: first.id)
                        check(restoredSource.attachments == beforeSource.attachments
                            && restoredTarget.attachments == beforeTarget.attachments
                            && restoredSource.attachments[0].resolveData() == bytes,
                            "交换第 \(failAfter) 个槽位后失败完整回滚")
                    }
                }
                for crashAfter in [1, 2] {
                    let child = Process()
                    child.executableURL = Bundle.main.executableURL
                    var childEnvironment = env
                    childEnvironment.removeValue(forKey: "CLIPSLOTS_ATTACHMENT_SHOW_UI")
                    childEnvironment["CLIPSLOTS_ATTACHMENT_CRASH_STAGE"] = String(crashAfter)
                    childEnvironment["CLIPSLOTS_ATTACHMENT_CRASH_GROUP"] = first.id
                    child.environment = childEnvironment
                    child.standardOutput = FileHandle.nullDevice
                    child.standardError = FileHandle.nullDevice
                    try child.run()
                    child.waitUntilExit()
                    let restored = SpecialSlotStorage() // startup recovery before any UI reads
                    storage.invalidateContentCaches()
                    check(child.terminationStatus == 77
                        && restored.get(5, in: first.id).attachments == beforeSource.attachments
                        && restored.get(6, in: first.id).attachments == beforeTarget.attachments
                        && restored.get(5, in: first.id).attachments[0].resolveData() == bytes,
                        "进程在第 \(crashAfter) 个槽位交换后退出，重启恢复完整来源和目标")
                }
                let unchanged = SlotFileMove(snapshot: try storage.editorSnapshot(5, in: first.id),
                    attachment: beforeSource.attachments[0])
                check(storage.get(5, in: first.id).attachments == beforeSource.attachments,
                      "拖动开始但取消不写入任何内容")
                check(!store.acceptTransfer(.move(unchanged), groupID: second.id, slot: 2, destination: .body),
                      "非空主体落点不覆盖原内容")
                var concurrent = storage.get(5, in: first.id)
                concurrent.attachments[0].name = "已修改来源"
                _ = storage.set(5, content: concurrent, in: first.id)
                check(!store.acceptTransfer(.move(unchanged), groupID: first.id, slot: 6),
                      "拖动期间来源被编辑则拒绝旧载荷")
                let groupMove = SlotFileMove(snapshot: try storage.editorSnapshot(5, in: first.id),
                    attachment: storage.get(5, in: first.id).attachments[0])
                check(store.dropFilesIntoGroup([AttachmentTransfer.provider(groupMove)], groupID: second.id),
                      "组按钮接收附件拖入")
                try await Task.sleep(for: .milliseconds(200))
                check(storage.get(1, in: second.id).detectedFileURLs.first.flatMap { try? Data(contentsOf: $0) } == bytes
                    && storage.get(5, in: first.id).attachments.isEmpty,
                      "拖到组按钮后移动到第一个空主体槽位")
                check(CompactFileDrag.image(thumbnail: nil).size == NSSize(width: 88, height: 64),
                      "拖影限定为 88×64")
                let click = ClickHandleNSView()
                check(click.acceptsFirstMouse(for: nil), "文件拖动首按可直接命中")
                do {
                    _ = try storage.appendTransferredAttachments(AttachmentTransfer.body(source), slot: 2, groupID: second.id)
                    check(false, "源文件消失时拒绝空壳附件")
                } catch { check(true, "源文件消失时拒绝空壳附件") }
                let removed = try storage.createSpecialSlot(name: "已删除目标")
                try storage.deleteSpecialSlot(id: removed.id)
                do {
                    _ = try storage.appendTransferredAttachments(AttachmentTransfer.body(inline), slot: 1, groupID: removed.id)
                    check(false, "拖放不能重建已删除的组")
                } catch { check(true, "拖放不能重建已删除的组") }

                let pb = NSPasteboard.withUniqueName()
                defer { pb.releaseGlobally() }
                pb.writeObjects([image as NSURL])
                pb.setData(png, forType: .tiff)
                check(AttachmentTransfer.clipboard(pb).isEmpty, "无效文件不降级为 Finder 图标")
                pb.clearContents()
                pb.setData(png, forType: .png)
                let clipboardImage = AttachmentTransfer.clipboard(pb)
                check(clipboardImage.count == 1 && clipboardImage[0].data == png, "截图剪贴板按原字节接收")
                pb.clearContents()
                pb.setString("https://example.com/path", forType: .string)
                check(AttachmentTransfer.clipboard(pb).first?.type == .url, "粘贴链接")
                pb.clearContents()
                pb.setString("粘贴的文本🙂", forType: .string)
                check(AttachmentTransfer.clipboard(pb).first?.type == .text, "粘贴普通文本")

                let panelContent = AttachmentManagerPopover(slot: 3, store: store, groupId: first.id)
                let hosting = AttachmentManagerHostingView(rootView: panelContent)
                hosting.attachmentPasteboard = pb
                let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 360, height: 480),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "附件交互隔离验证"
                window.contentView = hosting
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(hosting)
                check(window.firstResponder === hosting, "附件面板可取得键盘焦点")
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
                check(hosting.performKeyEquivalent(with: event), "面板 Cmd+V 由原生响应链接收")
                for _ in 0..<100 {
                    if storage.get(3, in: first.id).attachments.first?.resolveTextString() == "粘贴的文本🙂" { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                check(storage.get(3, in: first.id).attachments.first?.resolveTextString() == "粘贴的文本🙂",
                      "面板 Cmd+V 实际追加文本附件")
                let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
                field.isEditable = true
                hosting.addSubview(field)
                window.makeFirstResponder(field)
                let before = storage.get(3, in: first.id).attachments.count
                _ = hosting.performKeyEquivalent(with: event)
                check(storage.get(3, in: first.id).attachments.count == before, "输入框中的粘贴不额外生成附件")
                field.removeFromSuperview()
                window.makeFirstResponder(hosting)
                let anchor = AttachmentButtonScreenAnchor()
                let anchorView = NSView(frame: NSRect(x: 30, y: 80, width: 50, height: 22))
                hosting.addSubview(anchorView)
                anchor.view = anchorView
                let panel = AttachmentManagerPanelController.shared
                panel.show(anchor: anchor, slot: 3, store: store, groupId: first.id, onClose: {})
                panel.show(anchor: anchor, slot: 4, store: store, groupId: first.id, onClose: {})
                panel.close()
                try await Task.sleep(for: .milliseconds(250))
                check(!panel.isVisible, "切组关闭面板时同时取消淡出期间挂起的旧组面板")
                anchorView.removeFromSuperview()
                try await Task.sleep(for: .milliseconds(120))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("attachment-panel.png"))
                }
                window.orderOut(nil)

                let dwell = GroupDragDwell()
                var switches = 0
                dwell.enter(action: { switches += 1 }, isDragging: { true })
                try await Task.sleep(for: .milliseconds(150))
                check(switches == 0, "快速经过组按钮不切组")
                dwell.cancel()
                try await Task.sleep(for: .milliseconds(510))
                check(switches == 0, "离开组按钮取消待切换")
                dwell.enter(action: { switches += 1 }, isDragging: { true })
                try await Task.sleep(for: .milliseconds(680))
                check(switches == 1, "悬停 0.6 秒只切换一次")
                dwell.enter(action: { switches += 1 }, isDragging: { false })
                try await Task.sleep(for: .milliseconds(680))
                check(switches == 1 && !dwell.isTargeted, "结束拖动后不触发迟到切组")
                if env["CLIPSLOTS_ATTACHMENT_SHOW_UI"] == "1" {
                    try bytes.write(to: file)
                    try png.write(to: image)
                    var fixtureSource = storage.get(mdCurrentSlot, in: mdCurrentGroup)
                    fixtureSource.attachments = [.init(name: image.lastPathComponent, type: .image, path: image.path)]
                    _ = storage.set(1, content: fixtureSource, in: first.id)
                    _ = storage.set(2, content: inline, in: first.id)
                    var labeledEmpty = SlotContent()
                    labeledEmpty.label = "带标签空槽"
                    _ = storage.set(3, content: labeledEmpty, in: first.id)
                    storage.setLabel(3, label: labeledEmpty.label, in: first.id)
                    for slot in 1...3 { _ = storage.set(slot, content: SlotContent(), in: second.id) }
                    store.switchSpecialSlot(id: first.id, fromNavigation: true)
                    store.reloadAll()
                    let fixture = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1080, height: 660),
                        styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
                    fixture.title = "附件拖拽隔离测试 · 可操作"
                    fixture.contentView = NSHostingView(rootView: AttachmentTransferFixtureView(store: store,
                        firstGroup: first.id, secondGroup: second.id))
                    fixture.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    fixtureWindow = fixture
                }
            } catch { failures.append(String(describing: error)) }
            let report: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
                "scope": "isolated native paste responder, provider transfer, persisted bytes, dwell timer; not physical mouse drag"]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("app-regression.json"))
            if env["CLIPSLOTS_ATTACHMENT_SHOW_UI"] != "1" || !failures.isEmpty {
                exit(failures.isEmpty ? 0 : 1)
            }
        }
    }
}

private struct AttachmentTransferFixtureView: View {
    @ObservedObject var store: SlotStoreObservable
    let firstGroup: String
    let secondGroup: String
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                GroupTabButton(name: "来源组", isCurrent: store.currentSpecialSlotId == firstGroup,
                    action: { store.switchSpecialSlot(id: firstGroup, fromNavigation: true) },
                    onDropFiles: { store.dropFilesIntoGroup($0, groupID: firstGroup) })
                GroupTabButton(name: "目标组", isCurrent: store.currentSpecialSlotId == secondGroup,
                    action: { store.switchSpecialSlot(id: secondGroup, fromNavigation: true) },
                    onDropFiles: { store.dropFilesIntoGroup($0, groupID: secondGroup) })
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(1...3, id: \.self) { slot in
                    SlotCardView(slot: slot, content: store.slots[slot] ?? SlotContent(),
                        specialSlotId: store.displayedSpecialSlotId,
                        onPaste: {}, onCopy: {}, onSave: {}, onClear: {}, onSetLabel: { _ in }, store: store)
                }
            }
            Spacer()
        }.padding(28).background(Color(NSColor.windowBackgroundColor))
    }
}
#endif
