#if DEBUG
import AppKit

@MainActor
enum SlotEditorSelectionRegression {
    static func run(model: SlotEditorModel, window: NSWindow, root: URL,
                    check: (Bool, String) -> Void) async throws {
        guard let editor = model.textBridge.editor else { return }
        let original = editor.string
        let text = String(repeating: "雨后的小巷，暖色灯光映在湿润石板上。镜头缓慢推进，保留自然光影与真实材质。画面比例 16:9。", count: 6)
        check(paragraphSpacing(editor, expected: 7), "打开槽位时原始正文字符携带 7pt 行距")
        model.textBridge.replace(text)
        try await Task.sleep(for: .milliseconds(150))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)

        func lines() -> [[Double]] {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return [] }
            layout.ensureLayout(for: container)
            var result: [[Double]] = []
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
                rect, used, _, range, _ in
                result.append([rect.minX, rect.minY, rect.width, rect.height, used.width,
                               Double(range.location), Double(range.length)])
            }
            return result
        }
        func paragraphSpacing(_ view: NSTextView, expected: CGFloat) -> Bool {
            guard let storage = view.textStorage, storage.length > 0 else { return false }
            var valid = true
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
                style, _, _ in
                if (style as? NSParagraphStyle)?.lineSpacing != expected { valid = false }
            }
            return valid
        }
        func colorMatches(_ actual: Any?, _ expected: NSColor) -> Bool {
            guard let color = (actual as? NSColor)?.usingColorSpace(.sRGB),
                  let expected = expected.usingColorSpace(.sRGB) else { return false }
            return abs(color.redComponent - expected.redComponent) < 0.001
                && abs(color.greenComponent - expected.greenComponent) < 0.001
                && abs(color.blueComponent - expected.blueComponent) < 0.001
                && abs(color.alphaComponent - expected.alphaComponent) < 0.001
        }
        func capture(_ name: String, background: NSColor) throws {
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let point = editor.convert(NSPoint(x: editor.textContainerOrigin.x + 4,
                                               y: editor.textContainerOrigin.y + 1), to: view)
            let pixelX = Int((point.x - view.bounds.minX) * CGFloat(bitmap.pixelsWide) / view.bounds.width)
            let pixelY = Int((view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y)
                             * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            check(colorMatches(bitmap.colorAt(x: pixelX, y: pixelY), background),
                  "\(name) 实际像素保持正确选区背景")
            // Inspect actual glyph pixels too: background-only assertions miss
            // black text on black after AppKit changes inactive foreground.
            if let layout = editor.layoutManager, let container = editor.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 3),
                                              actualCharacterRange: nil)
                let glyphRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                let rect = editor.convert(glyphRect, to: view)
                let sx = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let sy = CGFloat(bitmap.pixelsHigh) / view.bounds.height
                let x0 = max(0, Int(rect.minX * sx)), x1 = min(bitmap.pixelsWide, Int(rect.maxX * sx))
                let y0 = max(0, Int((view.isFlipped ? rect.minY : view.bounds.maxY - rect.maxY) * sy))
                let y1 = min(bitmap.pixelsHigh, y0 + Int(rect.height * sy))
                let darkBackground = background == NSColor.black
                var foregroundPixels = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if darkBackground ? min(c.redComponent,c.greenComponent,c.blueComponent)>0.8
                            : max(c.redComponent,c.greenComponent,c.blueComponent)<0.2 { foregroundPixels += 1 }
                    }
                }
                check(foregroundPixels > 50, "\(name) 实际字形有足量反差像素，未出现全黑或全白")
            }
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: root.appendingPathComponent(name))
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(100))
        let baseline = lines()
        let storageBefore = editor.textStorage!.copy() as! NSAttributedString
        let couldUndo = editor.undoManager?.canUndo
        check(baseline.count > 3 && paragraphSpacing(editor, expected: 7), "正文初始字符携带 7pt 行距")
        var snapshots: [[String: Any]] = [["phase": "initial", "lines": baseline]]
        let range = NSRange(location: 0, length: 90)
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            editor.setSelectedRange(range)
            check(SlotEditorTextBridge.selectionRange(in: editor.string, selection: range) == range,
                  "\(mode) 无换行的长正文保留实际局部选择，不扩展为全文")
            window.makeFirstResponder(editor)
            try await Task.sleep(for: .milliseconds(120))
            check(model.quoteSelection && model.selectedRange == range, "\(mode) 选中文本自动进入局部引用状态")
            let background = dark ? NSColor.white : NSColor.black
            let foreground = dark ? NSColor.black : NSColor.white
            check(colorMatches(editor.selectedTextAttributes[.backgroundColor], background)
                && colorMatches(editor.selectedTextAttributes[.foregroundColor], foreground),
                  "\(mode) 正文选区黑白配色")
            try capture("selection-\(mode).png", background: background)
            model.quoteSelection = true
            try await Task.sleep(for: .milliseconds(120))
            let temporary = editor.layoutManager!.temporaryAttributes(atCharacterIndex: range.location, effectiveRange: nil)
            check(colorMatches(temporary[.backgroundColor], background)
                && colorMatches(temporary[.foregroundColor], foreground), "\(mode) 引用高亮黑白配色")
            let outside = editor.layoutManager!.temporaryAttributes(atCharacterIndex: NSMaxRange(range),
                                                                    effectiveRange: nil)
            check(outside[.backgroundColor] == nil && outside[.foregroundColor] == nil,
                  "\(mode) 选区后的正文不染色，不伪装为全选")
            check(lines() == baseline, "\(mode) 引用前后每行位置高度与换行点相同")
            snapshots.append(["phase": "quoted-\(mode)", "lines": lines()])
            model.inputFocus += 1
            try await Task.sleep(for: .milliseconds(150))
            check(window.firstResponder is NSTextView && window.firstResponder !== editor,
                  "\(mode) 引用后实际聚焦 AI 输入")
            check(lines() == baseline, "\(mode) 焦点转移后行距保持")
            try capture("quoted-\(mode).png", background: background)
            check(editor.selectedRange() == range && model.selectedRange == range,
                  "\(mode) 焦点转入 AI 输入后仍只引用原选中的部分")
            let narrower = NSRange(location: 5, length: 7)
            editor.setSelectedRange(narrower)
            let before = editor.layoutManager!.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)
            let after = editor.layoutManager!.temporaryAttributes(atCharacterIndex: NSMaxRange(narrower),
                                                                  effectiveRange: nil)
            check(before[.backgroundColor] == nil && after[.backgroundColor] == nil,
                  "\(mode) 缩小选区立即清除两侧旧高亮")
            editor.setSelectedRange(range)
            // Force fresh layout, as invalidation must not expose a missing
            // paragraph style hidden by previously cached line fragments.
            editor.layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: editor.textStorage!.length),
                actualCharacterRange: nil)
            check(lines() == baseline, "\(mode) 全部重新排版仍保持原行距")
            model.quoteSelection = false
            try await Task.sleep(for: .milliseconds(120))
            let cleared = editor.layoutManager!.temporaryAttributes(atCharacterIndex: range.location, effectiveRange: nil)
            check(cleared[.backgroundColor] == nil && cleared[.foregroundColor] == nil,
                  "\(mode) 取消引用完整清除高亮")
            check(!model.quoteSelection && editor.selectedRange().length == 0,
                  "\(mode) 引用全文同步清除原生选区")
            check(lines() == baseline, "\(mode) 取消引用后行距保持")
            check(editor.textStorage!.isEqual(to: storageBefore)
                && editor.undoManager?.canUndo == couldUndo, "\(mode) 引用与主题切换不修改正文属性或撤销栈")
        }
        // Exercise edits while a reference is visible, then clear the quote.
        editor.setSelectedRange(range)
        window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(120))
        // The async fixture has no physical NSEvents between these operations.
        // Start with an empty history so an open automatic event group cannot
        // combine this edit with the initial fixture replacement.
        editor.undoManager?.removeAllActions()
        editor.breakUndoCoalescing()
        editor.insertText("新文字", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        try await Task.sleep(for: .milliseconds(120))
        check(editor.string == "新文字" + text && model.draft == editor.string, "引用期间输入实际进入正文草稿")
        model.quoteSelection = false
        try await Task.sleep(for: .milliseconds(100))
        var hasHighlight = false
        var index = 0
        while index < editor.textStorage!.length {
            var effectiveRange = NSRange()
            let attributes = editor.layoutManager!.temporaryAttributes(atCharacterIndex: index,
                                                                       effectiveRange: &effectiveRange)
            if attributes[.backgroundColor] != nil || attributes[.foregroundColor] != nil { hasHighlight = true }
            index = max(index + 1, NSMaxRange(effectiveRange))
        }
        check(!hasHighlight && paragraphSpacing(editor, expected: 7), "引用期间输入后无残留高亮且新文字行距一致")
        model.textBridge.undo()
        check(editor.string == text && model.draft == text, "引用期间编辑可撤销并同步草稿")
        editor.setSelectedRange(NSRange(location: 4, length: 8))
        editor.setSelectedRange(NSRange(location: 22, length: 8))
        editor.setSelectedRange(NSRange(location: 24, length: 0))
        try await Task.sleep(for: .milliseconds(120))
        check(!model.quoteSelection && model.selectedRange == editor.selectedRange(),
              "快速选择后取消不会被排队旧事件恢复引用")
        let paragraphs = "第一段🙂文字\r\n第二段内容\n第三段"
        let source = paragraphs as NSString
        let middle = source.range(of: "第二段内容")
        let partial = NSRange(location: middle.location+1,length: 1)
        check(SlotEditorTextBridge.selectionRange(in: paragraphs, selection: partial) == partial,
              "含 emoji 和 CRLF 的文本保持实际 UTF16 选区")
        if let rewrite = SlotEditorTextBridge.selectionRange(in: paragraphs, selection: partial) {
            check(source.replacingCharacters(in: rewrite, with: "修改后")
                    == "第一段🙂文字\r\n第修改后段内容\n第三段",
                  "局部改写只替换选中字符，保留前后文字和换行")
        } else { check(false, "局部替换存在合法目标范围") }
        check(SlotEditorTextBridge.selectionRange(in: paragraphs,
                selection: NSRange(location: 0,length: middle.location))?.length == middle.location,
              "选区结束在下一段开头时不误引下一段")
        check(SlotEditorTextBridge.selectionRange(in: paragraphs,
                selection: NSRange(location: middle.location,length: 0)) == nil,
              "清空选择后引用范围为全文")
        editor.string = original
        model.draft = original

        let html = SlotEditorTextView.Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        html.isRichText = false
        html.loadPlainText("<div>\n  中文 HTML 正文\n</div>", html: true)
        check(paragraphSpacing(html, expected: 3), "HTML 正文初始字符携带 3pt 行距")
        NSApp.appearance = NSAppearance(named: .aqua)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.undoManager?.removeAllActions()
        try await Task.sleep(for: .milliseconds(120))
        try JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("selection-layout.json"))
    }
}
#endif
