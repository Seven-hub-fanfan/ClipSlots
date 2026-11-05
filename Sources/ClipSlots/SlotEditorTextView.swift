import AppKit
import SwiftUI

@MainActor
final class SlotEditorTextBridge {
    weak var editor: NSTextView?
    var onCommit: ((String) -> Void)?
    nonisolated static func selectionRange(in text: String, selection: NSRange) -> NSRange? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.location < source.length,
              selection.length <= source.length - selection.location else { return nil }
        // The native selection is the source of truth. A wrapped line is not a
        // paragraph boundary; expanding it would select an entire single-block
        // prompt while the user is only dragging over a few words.
        return selection
    }
    func clearSelection() {
        guard let editor else { return }
        editor.setSelectedRange(NSRange(location: min(editor.selectedRange().location,
                                                      (editor.string as NSString).length), length: 0))
    }
    func commit() {
        guard let editor else { return }
        if editor.hasMarkedText() { editor.unmarkText() }
        onCommit?(editor.string)
    }
    func replace(_ text: String) {
        guard let editor else { return }
        editor.breakUndoCoalescing()
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.undoManager?.setActionName("接受 AI 修改")
        editor.breakUndoCoalescing()
    }
    func reveal(_ range: NSRange) {
        guard let editor, NSMaxRange(range) <= (editor.string as NSString).length else { return }
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        editor.window?.makeFirstResponder(editor)
    }
    func find() {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor?.performTextFinderAction(sender)
        if let editor { editor.window?.makeFirstResponder(editor) }
    }
    func undo() {
        guard let editor else { return }
        editor.undoManager?.undo()
        // Direct undo-manager calls can change native storage without sending
        // textDidChange. Synchronize before SwiftUI can restore a stale draft.
        onCommit?(editor.string)
    }
    func redo() {
        guard let editor else { return }
        editor.undoManager?.redo()
        onCommit?(editor.string)
    }
}

/// The same native editor stays mounted in windowed, preview and full-screen modes.
/// SwiftUI never replaces an IME marked buffer or owns the native undo history.
struct SlotEditorTextView: NSViewRepresentable {
    @Binding var text: String
    let bridge: SlotEditorTextBridge
    let fullScreen: Bool
    let html: Bool
    let onSelection: (NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Autoresizing applies the clip view's width delta to this initial frame.
        // Start at the same width, otherwise a fixed seed becomes a permanent
        // surplus that lets selection/autoscroll move the text out of view.
        let editor = Editor(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.textContainer?.replaceLayoutManager(SelectionLayoutManager())
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.loadPlainText(text, html: html)
        editor.setAccessibilityLabel(html ? "槽位 HTML 正文" : "槽位正文")
        editor.fullScreen = fullScreen
        editor.synchronizeAppearance()
        scroll.documentView = editor
        bridge.editor = editor
        bridge.onCommit = { value in if text != value { text = value } }
        DispatchQueue.main.async { [weak editor] in
            if let editor { editor.window?.makeFirstResponder(editor) }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        bridge.editor = editor
        bridge.onCommit = { value in if text != value { text = value } }
        if editor.string != text, !editor.hasMarkedText() {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        editor.fullScreen = fullScreen
        editor.updateInsets()
        editor.synchronizeAppearance()
        editor.synchronizeSelection()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SlotEditorTextView
        private var selectionQueued = false
        init(_ parent: SlotEditorTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? Editor else { return }
            editor.synchronizeSelection()
            guard !selectionQueued else { return }
            selectionQueued = true
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self else { return }
                self.selectionQueued = false
                if let editor { self.parent.onSelection(editor.selectedRange()) }
            }
        }
    }
    final class SelectionLayoutManager: NSLayoutManager {
        override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                              forCharacterRange charRange: NSRange, color: NSColor) {
            // AppKit replaces only the background of an inactive selection with
            // system gray. Keep our background paired with the chosen text color
            // when focus moves into the AI input, without changing selection.
            if let editor = firstTextView,
               NSIntersectionRange(charRange, editor.selectedRange()).length > 0,
               (color == .unemphasizedSelectedContentBackgroundColor
                    || color == .unemphasizedSelectedTextBackgroundColor),
               let background = editor.selectedTextAttributes[.backgroundColor] as? NSColor {
                NSGraphicsContext.saveGraphicsState()
                background.setFill()
                super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: background)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            }
        }
    }
    final class Editor: NSTextView {
        var fullScreen = false
        private var quoteRange: NSRange?
        private var darkSelection: Bool?

        func loadPlainText(_ text: String, html: Bool) {
            let font = NSFont.systemFont(ofSize: html ? 13 : 15, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = html ? 3 : 7
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor
            ]
            self.font = font
            defaultParagraphStyle = paragraph
            // A default/typing style alone does not give existing characters a
            // paragraph style. Persist the metrics before the very first layout,
            // so reference highlighting and focus changes cannot lose spacing.
            textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            typingAttributes = attributes
        }

        func synchronizeSelection() {
            let length = textStorage?.length ?? 0
            let valid = SlotEditorTextBridge.selectionRange(in: string, selection: selectedRange())
            guard quoteRange != valid else { return }
            if let previous = quoteRange {
                removeQuoteColors(in: NSIntersectionRange(previous, NSRange(location: 0, length: length)))
            }
            quoteRange = valid
            drawQuoteColors()
        }
        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                        stillSelecting flag: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
            synchronizeSelection()
        }

        private func removeQuoteColors(in range: NSRange) {
            guard range.length > 0 else { return }
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }

        private func drawQuoteColors() {
            guard let quoteRange, NSMaxRange(quoteRange) <= (textStorage?.length ?? 0) else { return }
            // Only drawing attributes; never rewrite font or paragraph metrics.
            layoutManager?.addTemporaryAttributes(selectedTextAttributes, forCharacterRange: quoteRange)
        }

        override func didChangeText() {
            // TextKit shifts temporary runs as text changes. Clear the shifted
            // run before SwiftUI supplies the new selection, including on undo.
            if quoteRange != nil {
                removeQuoteColors(in: NSRange(location: 0, length: textStorage?.length ?? 0))
                quoteRange = nil
            }
            super.didChangeText()
            synchronizeSelection()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateInsets()
        }
        func updateInsets() {
            let x = fullScreen ? max(34, (bounds.width - 820) / 2) : 20
            let inset = NSSize(width: x, height: fullScreen ? 30 : 20)
            if textContainerInset != inset { textContainerInset = inset }
        }
        func synchronizeAppearance() {
            if textColor != .labelColor { textColor = .labelColor }
            if insertionPointColor != .labelColor { insertionPointColor = .labelColor }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard darkSelection != dark else { return }
            darkSelection = dark
            selectedTextAttributes = [
                .backgroundColor: dark ? NSColor.white : NSColor.black,
                .foregroundColor: dark ? NSColor.black : NSColor.white
            ]
            drawQuoteColors()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            synchronizeAppearance()
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
