#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

private actor SlotEditorFixtureBackend: AgentBackend {
    var safeContract = false
    var response = "只保留一个自然段。"
    func emptyResponse() { response = "" }
    func run(history: [AgentMessage], config: AgentConfig, tools: AgentToolExecuting?,
             onEvent: @escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        safeContract = tools == nil && config.taskPolicy == .textPolish && config.canvasPreviewOnly
            && history.last?.inputAttachments.first?.textSnapshot == "背景资料"
        return [.init(role: .assistant, content: response)]
    }
}

enum SlotEditorRegression {
    private static var controller: SlotEditorWindowController?
    @MainActor static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["CLIPSLOTS_EDITOR_REGRESSION"] else { return }
        guard folder.hasPrefix("/private/tmp/clipslots-editor-"),
              env["CLIPSLOTS_DATA_DIR"] == folder + "/data",
              env["CLIPSLOTS_CONFIG_PATH"] == folder + "/config.toml",
              Bundle.main.bundleIdentifier == "com.clipslots.app.editor-regression",
              Bundle.main.object(forInfoDictionaryKey: "ClipSlotsIsolatedCandidate") as? Bool == true else { exit(2) }
        let root = URL(fileURLWithPath: folder)
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            // Let SwiftUI finish App initialization before native text events.
            // Running a nested NSApplication loop from App.init can swallow
            // AppKit exceptions and strand the async test task.
            try? await Task.sleep(for: .milliseconds(600))
            var passes = 0, failures: [String] = []
            func check(_ condition: Bool, _ label: String) {
                if condition { passes += 1 } else { failures.append(label) }
            }
            do {
                if env["BATCH_STORAGE_PERF_ONLY"] == "1" {
                    try await BatchStoragePerformanceRegression.run(root: root)
                    exit(0)
                }
                if env["STORAGE_PERF_ONLY"] == "1" {
                    try await SlotStoragePerformanceRegression.run(root: root)
                    exit(0)
                }
                if env["FLICKER_ONLY"] == "1" {
                    try await SlotFlickerRegression.run(root: root)
                    exit(0)
                }
                try HeaderMascotAttentionRegression.run(root: root, check: check)
                try await HeaderMascotAttentionRegression.runScheduled(root: root, check: check)
                let backend = SlotEditorFixtureBackend()
                let output = try await SlotEditorAI.rewrite(text: "原文", instruction: "精简", html: false,
                    attachments: [.init(name: "资料.txt", type: .text, data: Data("背景资料".utf8))], service: backend)
                check(output == "只保留一个自然段。", "普通正文不按生图提示词规则改写")
                let safe = await backend.safeContract
                check(safe, "AI 禁用工具并只读取显式传入的附件快照")
                await backend.emptyResponse()
                do {
                    _ = try await SlotEditorAI.rewrite(text: "保留正文", instruction: "修改", html: false,
                        attachments: [], service: backend)
                    check(false, "AI 空结果拒绝")
                } catch { check(true, "AI 空结果拒绝") }
                let storage = SpecialSlotStorage()
                let group = storage.loadIndex().specialSlots[0]
                let sample = """
                # 雨后小巷

                ## 场景与氛围
                雨后的小巷，暖色灯光映在湿润石板上。
                保留自然的光影与真实材质，画面安静而有空间感。

                ## 镜头与构图
                镜头缓慢推进，沿着石板路进入小巷深处。
                让前景、主体与远处灯光形成清晰的层次。

                ## 画面约束
                画面比例 16:9，整体风格简洁。
                避免夸张光效、杂乱元素和不自然的材质。
                """
                var content = SlotContent(text: sample)
                // A small local image and text fixture; no production files are read.
                let png = root.appendingPathComponent("参考图.png")
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor(srgbRed: 0.83, green: 0.88, blue: 0.95, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 120)).fill()
                NSColor(srgbRed: 0.29, green: 0.37, blue: 0.49, alpha: 1).setFill()
                for i in 0..<6 { NSBezierPath(rect: NSRect(x: 18 + i * 49, y: 12, width: 32, height: 42 + i * 7)).fill() }
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])!.write(to: png)
                content.attachments = [.init(name: "参考图.png", type: .image, path: png.path),
                    .init(name: "镜头说明.txt", type: .text, data: Data("缓慢推进，保持 16:9。".utf8))]
                check(storage.set(9, content: content, in: group.id), "最小测试槽位创建")
                let snapshot = try storage.editorSnapshot(9, in: group.id)
                print("editor-regression: snapshot captured"); fflush(stdout)
                let model = try SlotEditorModel(snapshot: snapshot)
                print("editor-regression: model ready"); fflush(stdout)
                let parent = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 1100, height: 720),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                parent.title = "隔离测试主窗口"
                parent.makeKeyAndOrderFront(nil)
                controller = SlotEditorWindowController(model: model, parent: parent) { model in
                    _ = try storage.exchangeEditorContent(model.snapshot, body: model.body, attachments: model.attachments)
                }
                print("editor-regression: controller ready"); fflush(stdout)
                controller?.present()
                print("editor-regression: window presented"); fflush(stdout)
                // The NSHostingView mounts native representables on its first run-loop pass.
                try await Task.sleep(for: .milliseconds(250))
                guard let editor = model.textBridge.editor else { throw AgentOperationError("原生正文未挂载") }
                print("editor-regression: editor mounted"); fflush(stdout)
                controller?.window?.makeKeyAndOrderFront(nil)
                controller?.window?.makeFirstResponder(editor)
                check(controller?.window?.sheetParent == nil && parent.attachedSheet == nil,
                      "从主窗口打开即为独立编辑窗口")
                func checkWidth(_ label: String) {
                    guard let scroll = editor.enclosingScrollView else { check(false, label); return }
                    check(scroll.contentSize.width > 100
                        && abs(editor.frame.width - scroll.contentSize.width) < 1
                        && abs(scroll.contentView.bounds.origin.x) < 1, label)
                }
                checkWidth("初始正文等于可见宽度且无横向偏移")
                check(editor.string == sample, "初次打开快照正文无空帧")
                if let window = controller?.window {
                    try await SlotEditorSelectionRegression.run(model: model, window: window, root: root, check: check)
                }
                editor.setSelectedRange(NSRange(location: (sample as NSString).length, length: 0))
                editor.insertText("\n新增段落", replacementRange: editor.selectedRange())
                print("editor-regression: inserted"); fflush(stdout)
                check(model.draft.hasSuffix("新增段落"), "原生输入写入独立草稿")
                // Native typing groups close at the next event-loop turn.
                try await Task.sleep(for: .milliseconds(60))
                print("editor-regression: undo state before groups=\(editor.undoManager?.groupingLevel ?? -1) canUndo=\(editor.undoManager?.canUndo ?? false) native=\(editor.string.count) draft=\(model.draft.count)"); fflush(stdout)
                model.textBridge.undo()
                print("editor-regression: first undo"); fflush(stdout)
                print("editor-regression: undo state after groups=\(editor.undoManager?.groupingLevel ?? -1) native=\(editor.string.count) draft=\(model.draft.count) expected=\(sample.count)"); fflush(stdout)
                check(model.draft == sample, "原生撤销恢复文本")
                model.textBridge.redo()
                check(model.draft.hasSuffix("新增段落") && model.draft == editor.string,
                      "原生重做同步独立草稿")
                model.textBridge.undo()
                check(model.draft == sample && model.draft == editor.string,
                      "连续撤销重做后正文与草稿一致")
                try await Task.sleep(for: .milliseconds(60))
                editor.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0),
                                     replacementRange: NSRange(location: (sample as NSString).length, length: 0))
                print("editor-regression: marked"); fflush(stdout)
                check(editor.hasMarkedText(), "中文输入法候选保留")
                model.textBridge.commit()
                print("editor-regression: committed"); fflush(stdout)
                print("editor-regression: committed suffix=\(model.draft.suffix(20)) marked=\(editor.hasMarkedText())"); fflush(stdout)
                check(!editor.hasMarkedText() && model.draft.hasSuffix("中文候选"), "保存前提交输入法缓冲")
                editor.string = sample
                editor.undoManager?.removeAllActions()
                model.draft = sample
                let range = (sample as NSString).range(of: "雨后的小巷，暖色灯光映在湿润石板上。")
                model.proposal = .init(instruction: "增加画面感", originalDraft: sample, range: range,
                    original: (sample as NSString).substring(with: range), replacement: "暖灯照亮雨后的石板小巷。")
                model.acceptProposal()
                print("editor-regression: accepted"); fflush(stdout)
                check(model.draft.contains("暖灯照亮雨后的石板小巷。") && model.draft.contains("画面比例 16:9"),
                      "接受选区修改只替换目标段落")
                try await Task.sleep(for: .milliseconds(60))
                model.textBridge.undo()
                print("editor-regression: proposal undo"); fflush(stdout)
                print("editor-regression: proposal undo groups=\(editor.undoManager?.groupingLevel ?? -1) native=\(editor.string.count) draft=\(model.draft.count) expected=\(sample.count)"); fflush(stdout)
                check(model.draft == sample, "接受 AI 修改可原生撤销")
                model.proposal = .init(instruction: "修改", originalDraft: sample, range: range,
                    original: "旧文", replacement: "错误替换")
                editor.insertText("我的新编辑", replacementRange: NSRange(location: 0, length: 0))
                let changed = model.draft
                model.acceptProposal()
                check(model.draft == changed && model.error != nil, "AI 返回期间编辑不被覆盖")
                editor.string = sample; editor.undoManager?.removeAllActions()
                model.draft = sample; model.error = nil; model.proposal = nil
                model.instruction = "帮我把这段文字写得更有画面感"
                model.fullScreen = true; model.focused = true
                check(model.draft == sample && model.instruction.contains("画面感"), "模式切换保留正文和对话")
                model.fullScreen = false; model.focused = false
                check(storage.getOrUnknown(9, in: group.id)?.plainText == sample, "草稿编辑不提前写源槽位")
                let outline = SlotEditorModel.outline(in: sample)
                check(outline.contains(where: { $0.title == "镜头与构图" }), "大纲来自真实标题")
                check(SlotEditorModel.outline(in: "这是一段普通正文。\n\n这是第二段。").isEmpty
                    && SlotEditorModel.outline(in: String(repeating: "没有标题的长正文", count: 80)).isEmpty,
                      "无标题正文不伪造首行大纲")
                check(!model.showsPreviewPicker, "无 AI 建议时隐藏预览切换")
                // Capture real mounted AppKit/SwiftUI surfaces after transitions.
                func capture(_ name: String) throws {
                    guard let view = controller?.window?.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw AgentOperationError("编辑器截图不可用")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw AgentOperationError("编辑器截图编码失败")
                    }
                    try data.write(to: root.appendingPathComponent(name))
                }
                model.textBridge.reveal(NSRange(location: 0, length: 0))
                try await Task.sleep(for: .milliseconds(100))
                try capture("modal-light.png")
                controller?.toggleFullScreen()
                try await Task.sleep(for: .seconds(2))
                check(controller?.window?.styleMask.contains(.fullScreen) == true, "原生全屏进入")
                check(controller?.window?.styleMask.contains(.fullSizeContentView) == true
                    && controller?.window?.titlebarSeparatorStyle == NSTitlebarSeparatorStyle.none,
                      "全屏使用完整内容高度且移除系统标题栏灰边")
                checkWidth("全屏正文宽度跟随可见区域")
                check(model.textBridge.editor === editor && model.showsOutline,
                      "全屏保留原生编辑器并显示真实大纲")
                try capture("fullscreen-light.png")
                model.focused = true
                try await Task.sleep(for: .milliseconds(120))
                checkWidth("专注模式宽度跟随可见区域")
                try capture("focus-light.png")
                check(model.draft == sample && model.instruction.contains("画面感"), "专注布局保留草稿")
                NSApp.appearance = NSAppearance(named: .darkAqua)
                try await Task.sleep(for: .milliseconds(160))
                try capture("focus-dark.png")
                NSApp.appearance = NSAppearance(named: .aqua)
                model.focused = false
                controller?.toggleFullScreen()
                try await Task.sleep(for: .seconds(2))
                check(controller?.window?.styleMask.contains(.fullScreen) == false && !model.fullScreen,
                      "全屏退出恢复独立窗口")
                check(controller?.window?.styleMask.contains(.fullSizeContentView) == true
                    && controller?.window?.sheetParent == nil && parent.attachedSheet == nil,
                      "往返全屏保持无灰边布局且不重新挂接弹窗")
                checkWidth("退出全屏正文仍在可见区域")
                check(model.draft == sample && model.instruction.contains("画面感"), "全屏往返保留正文和输入")
                // Reproduce selection/autoscroll with long unbroken content, and
                // resize the actual hosting window rather than a mock text view.
                let longText = String(repeating: "正文连续文本1234567890", count: 240)
                model.textBridge.replace(longText)
                try await Task.sleep(for: .milliseconds(250))
                for width in [940.0, 1280.0, 980.0] {
                    controller?.window?.setContentSize(NSSize(width: width, height: 650))
                    try await Task.sleep(for: .milliseconds(120))
                    let tail = NSRange(location: (longText as NSString).length - 1, length: 1)
                    editor.setSelectedRange(tail)
                    editor.scrollRangeToVisible(tail)
                    checkWidth("长正文选区滚动与窗口缩放 \(Int(width))pt")
                    if let layout = editor.layoutManager, let container = editor.textContainer {
                        layout.ensureLayout(for: container)
                        let glyphs = layout.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
                        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                        check(editor.visibleRect.intersects(rect), "缩放后末尾文字实际可见 \(Int(width))pt")
                    } else { check(false, "长正文布局器存在") }
                }
                // Exercise the system's full-screen entry too (menu/keyboard),
                // so delegate state cannot depend only on our toolbar button.
                controller?.window?.toggleFullScreen(nil)
                try await Task.sleep(for: .seconds(2))
                check(model.fullScreen && !model.showsOutline && model.textBridge.editor === editor,
                      "系统全屏入口同步模式且自动收起无标题大纲")
                checkWidth("无标题全屏正文宽度正确")
                model.textBridge.reveal(NSRange(location: 0, length: 0))
                try capture("fullscreen-plain.png")
                model.proposal = .init(instruction: "精简", originalDraft: longText,
                    range: NSRange(location: 0, length: (longText as NSString).length),
                    original: longText, replacement: "简洁正文")
                model.preview = true
                try await Task.sleep(for: .milliseconds(120))
                check(model.showsPreviewPicker && model.textBridge.editor === editor,
                      "AI 建议出现时展示切换并保留原编辑器")
                try capture("proposal-preview.png")
                model.proposal = nil; model.preview = false; model.focused = true
                controller?.window?.toggleFullScreen(nil)
                try await Task.sleep(for: .seconds(2))
                check(!model.fullScreen && !model.focused && !model.showsPreviewPicker,
                      "系统退出全屏恢复附件栏且隐藏无建议的切换")
                checkWidth("长正文全屏往返后没有横向滚走")
                check(model.textBridge.editor === editor && model.draft == longText,
                      "多次全屏缩放正文与编辑器均保留")
                model.textBridge.undo()
                check(model.draft == sample, "全屏缩放后仍可撤销正文")
                model.textBridge.reveal(NSRange(location: 0, length: 0))
                try await Task.sleep(for: .milliseconds(200))
                try capture("returned-window.png")
                let store = SlotStoreObservable()
                store.reloadAll()
                let beforeEdit = try store.captureSlotEditor(slot: 9, groupID: group.id)
                try store.saveSlotEditor(beforeEdit, body: AgentSlotBody(text: "保存的新正文"), attachments: [])
                storage.set(2, content: SlotContent(text: "外部新写入"), in: group.id)
                store.undoLastClearIfPossible()
                check(storage.getOrUnknown(9, in: group.id)?.plainText == sample, "真实 Store 编辑保存可撤销")
                check(storage.getOrUnknown(9, in: group.id)?.attachments.count == 2,
                      "真实 Store 撤销恢复删除的附件")
                check(storage.getOrUnknown(2, in: group.id)?.plainText == "外部新写入",
                      "单槽撤销不覆盖其他槽位外部写入")
                store.redoLastUndoIfPossible()
                check(storage.getOrUnknown(9, in: group.id)?.plainText == "保存的新正文"
                    && storage.getOrUnknown(2, in: group.id)?.plainText == "外部新写入",
                      "单槽重做保持其他槽位")
                storage.set(9, content: beforeEdit.content, in: group.id)
                try await SlotFileEditorRegression.run(root: root, store: store, check: check)
                try await StorageResponsivenessRegression.run(root: root, store: store, check: check)
                let report: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
                    "scope": "isolated native editor, no live provider execution"]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("app-regression.json"))
                if env["CLIPSLOTS_EDITOR_SHOW_UI"] != "1" { exit(failures.isEmpty ? 0 : 1) }
                NSApplication.shared.activate(ignoringOtherApps: true)
            } catch {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "failures": [error.localizedDescription]])
                    .write(to: root.appendingPathComponent("app-regression.json"))
                exit(1)
            }
        }
    }
}
#endif
