import AppKit
import SwiftUI

/// Plain multiline input with no persistent scrollbar gutter, including macOS 13.
struct AgentDraftEditor: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var conversationID: UUID? = nil
    var sourceID: ObjectIdentifier? = nil
    var replacementID: UUID? = nil
    var isEditable = true
    var placeholder = "随心输入"
    var completion: AgentComposerCompletion? = nil
    var completionItems: [AgentComposerItem] = []
    var onCompletion: (AgentComposerItem.Action) -> Void = { _ in }
    let onSend: () -> Void

    /// Page changes must commit the native IME buffer to the outgoing model
    /// before the representable starts observing the destination conversation.
    static func commitFocusedDraft(sourceID: ObjectIdentifier? = nil) {
        func belongsToSource(_ editor: Editor) -> Bool {
            sourceID == nil || (editor.delegate as? Coordinator)?.sourceID == sourceID
        }
        if let editor = NSApp.keyWindow?.firstResponder as? Editor, belongsToSource(editor) {
            editor.commitDraftBuffer()
            return
        }
        // Programmatic page switches also happen while the app is inactive.
        // Commit only the requesting project's responder, never another writer.
        guard sourceID != nil else { return }
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            guard let editor = window.firstResponder as? Editor, belongsToSource(editor) else { continue }
            editor.commitDraftBuffer()
            return
        }
    }

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
        editor.synchronizeAppearance()
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isEditable = isEditable
        editor.allowsUndo = true
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
        editor.onCommitDraft = { value in if text != value { text = value } }
        _ = configureCompletion(editor)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        editor.onSend = onSend
        if !editor.reconciliationOptimizationsEnabled || editor.isEditable != isEditable {
            editor.isEditable = isEditable
        }
        let changedCompletion = configureCompletion(editor)
        if editor.placeholder != placeholder { editor.placeholder = placeholder }
        editor.synchronizeAppearance()
        let changedConversation = context.coordinator.conversationID != conversationID
            || context.coordinator.sourceID != sourceID
        if changedConversation {
            editor.unmarkText()
            editor.undoManager?.removeAllActions()
        }
        context.coordinator.parent = self
        var changedText = false
        if editor.string != text && !editor.hasMarkedText() {
            changedText = true
            if !changedConversation, context.coordinator.replacementID != replacementID {
                editor.breakUndoCoalescing()
                editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                editor.undoManager?.setActionName("AI 润色")
                editor.breakUndoCoalescing()
            } else {
                editor.string = text
                editor.undoManager?.removeAllActions()
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            editor.needsDisplay = true
        }
        context.coordinator.conversationID = conversationID
        context.coordinator.sourceID = sourceID
        context.coordinator.replacementID = replacementID
        editor.onCommitDraft = { value in if text != value { text = value } }
        // Updating SwiftUI state during representable reconciliation is invalid.
        if !editor.reconciliationOptimizationsEnabled || changedCompletion || changedText || changedConversation {
            editor.scheduleCompletionUpdate()
        }
        if isEditable, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
    }

    private func configureCompletion(_ editor: Editor) -> Bool {
        let changed = editor.completion !== completion || editor.completionItems != completionItems
        if editor.completion !== completion {
            if editor.completion?.editor === editor { editor.completion?.editor = nil }
            editor.completion = completion
        }
        if editor.completionItems != completionItems { editor.completionItems = completionItems }
        editor.onCompletion = onCompletion
        if completion?.editor !== editor { completion?.editor = editor }
        return changed
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentDraftEditor
        var lastFocusRequest: Int?
        var conversationID: UUID?
        var sourceID: ObjectIdentifier?
        var replacementID: UUID?
        init(_ parent: AgentDraftEditor) {
            self.parent = parent
            conversationID = parent.conversationID
            sourceID = parent.sourceID
            replacementID = parent.replacementID
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? Editor else { return }
            editor.scheduleCompletionUpdate()
        }
    }

    final class Editor: NSTextView {
        private static let legacyUpdatesRequested: Bool = {
            #if DEBUG
            return ProcessInfo.processInfo.environment["CLIPSLOTS_PROBE_LEGACY_EDITOR_UPDATES"] == "1"
            #else
            return false
            #endif
        }()
        var reconciliationOptimizationsEnabled: Bool {
            !Self.legacyUpdatesRequested
        }
        private static let ink = NSColor(TapSkin.ink)
        private static let faintInk = NSColor(TapSkin.faintInk)
        private var completionUpdatePending = false
        var onSend: (() -> Void)?
        weak var completion: AgentComposerCompletion?
        var completionItems: [AgentComposerItem] = []
        var onCompletion: ((AgentComposerItem.Action) -> Void)?
        var onCommitDraft: ((String) -> Void)?
        func synchronizeAppearance() {
            guard reconciliationOptimizationsEnabled else {
                placeholderColor = NSColor(TapSkin.faintInk)
                textColor = NSColor(TapSkin.ink)
                insertionPointColor = NSColor(TapSkin.ink)
                return
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let ink = Self.ink.usingColorSpace(.deviceRGB) ?? Self.ink
                let faintInk = Self.faintInk.usingColorSpace(.deviceRGB) ?? Self.faintInk
                if placeholderColor != faintInk { placeholderColor = faintInk }
                if textColor != ink { textColor = ink }
                if insertionPointColor != ink { insertionPointColor = ink }
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            synchronizeAppearance()
        }
        func scheduleCompletionUpdate() {
            if !reconciliationOptimizationsEnabled {
                DispatchQueue.main.async { [weak self] in self?.updateCompletion() }
                return
            }
            guard !completionUpdatePending else { return }
            completionUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.completionUpdatePending = false
                self.updateCompletion()
            }
        }
        func commitDraftBuffer() {
            if hasMarkedText() { unmarkText() }
            onCommitDraft?(string)
        }
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
