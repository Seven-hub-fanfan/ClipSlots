import AppKit
import SwiftUI

/// Plain multiline input with no persistent scrollbar gutter, including macOS 13.
struct AgentDraftEditor: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var placeholder = "随心输入"
    var completion: AgentComposerCompletion? = nil
    var completionItems: [AgentComposerItem] = []
    var onCompletion: (AgentComposerItem.Action) -> Void = { _ in }
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        let editor = Editor()
        editor.delegate = context.coordinator
        editor.string = text
        editor.font = .systemFont(ofSize: 13)
        editor.placeholder = placeholder
        editor.placeholderColor = NSColor(TapSkin.faintInk)
        editor.textColor = NSColor(TapSkin.ink)
        editor.insertionPointColor = NSColor(TapSkin.ink)
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 5
        editor.setAccessibilityLabel("Agent 输入")
        editor.onSend = onSend
        configureCompletion(editor)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        editor.onSend = onSend
        configureCompletion(editor)
        editor.placeholder = placeholder
        editor.placeholderColor = NSColor(TapSkin.faintInk)
        editor.textColor = NSColor(TapSkin.ink)
        editor.insertionPointColor = NSColor(TapSkin.ink)
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            editor.needsDisplay = true
        }
        // Updating SwiftUI state during representable reconciliation is invalid.
        DispatchQueue.main.async { [weak editor] in editor?.updateCompletion() }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
    }

    private func configureCompletion(_ editor: Editor) {
        editor.completion = completion
        editor.completionItems = completionItems
        editor.onCompletion = onCompletion
        completion?.editor = editor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentDraftEditor
        var lastFocusRequest: Int?
        init(_ parent: AgentDraftEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? Editor else { return }
            DispatchQueue.main.async { [weak editor] in editor?.updateCompletion() }
        }
    }

    final class Editor: NSTextView {
        var onSend: (() -> Void)?
        weak var completion: AgentComposerCompletion?
        var completionItems: [AgentComposerItem] = []
        var onCompletion: ((AgentComposerItem.Action) -> Void)?
        var placeholder = "" {
            didSet { if oldValue != placeholder { needsDisplay = true } }
        }
        var placeholderColor = NSColor.placeholderTextColor {
            didSet { if oldValue != placeholderColor { needsDisplay = true } }
        }

        // 输入法的 marked text 尚未提交给 SwiftUI Binding，必须以原生编辑缓冲区为准。
        var isPlaceholderVisible: Bool { string.isEmpty && !hasMarkedText() }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard isPlaceholderVisible else { return }
            let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                                 y: textContainerOrigin.y)
            (placeholder as NSString).draw(at: origin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: placeholderColor
            ])
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
            updateCompletion()
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            needsDisplay = true
            updateCompletion()
        }

        override func unmarkText() {
            super.unmarkText()
            needsDisplay = true
            updateCompletion()
        }

        func updateCompletion() {
            completion?.update(text: string, selection: selectedRange(),
                               marked: hasMarkedText(), items: completionItems)
        }

        func accept(_ item: AgentComposerItem, range: NSRange) {
            guard !hasMarkedText(), NSMaxRange(range) <= (string as NSString).length,
                  AgentComposerCompletion.token(in: string, selection: selectedRange())?.range == range else { return }
            insertText(item.action == .skills ? "$" : "", replacementRange: range)
            if item.action != .skills { completion?.dismiss() }
            window?.makeFirstResponder(self)
            onCompletion?(item.action)
        }

        func openSkills() {
            guard !hasMarkedText() else { return }
            let token = AgentComposerCompletion.token(in: string, selection: selectedRange())
            let selection = selectedRange()
            let needsSpace = selection.location > 0
                && (string as NSString).substring(to: selection.location).last?.isWhitespace == false
            insertText(token == nil && needsSpace ? " $" : "$", replacementRange: token?.range ?? selection)
            window?.makeFirstResponder(self)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func keyDown(with event: NSEvent) {
            // IME owns Return while choosing a candidate; never submit that keystroke.
            guard !hasMarkedText() else { super.keyDown(with: event); return }
            let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
            updateCompletion()
            if completion?.isOpen == true, flags.isEmpty {
                switch event.keyCode {
                case 125: completion?.move(1); return
                case 126: completion?.move(-1); return
                case 53: completion?.dismiss(); return
                case 36, 76, 48:
                    if !event.isARepeat { completion?.accept() }
                    return
                default: break
                }
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if flags == .shift {
                    insertNewline(nil)
                    return
                }
                if flags.isEmpty || flags == .command {
                    if !event.isARepeat { onSend?() }
                    return
                }
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection([.shift, .command, .control, .option]) == .command,
               window?.firstResponder === self {
                keyDown(with: event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
