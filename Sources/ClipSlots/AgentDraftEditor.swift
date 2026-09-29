import AppKit
import SwiftUI

/// Plain multiline input with no persistent scrollbar gutter, including macOS 13.
struct AgentDraftEditor: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
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
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        editor.onSend = onSend
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
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
    }

    final class Editor: NSTextView {
        var onSend: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func keyDown(with event: NSEvent) {
            if (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.contains(.command), !hasMarkedText() {
                onSend?()
                return
            }
            super.keyDown(with: event)
        }
    }
}
