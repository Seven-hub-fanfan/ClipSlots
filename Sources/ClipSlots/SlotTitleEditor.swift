import AppKit
import SwiftUI
import ClipSlotsKit

/// Only the title has group identity; the expensive card and thumbnail stay reusable.
struct SlotTitleEditor: NSViewRepresentable {
    let label: String
    let groupID: String
    let slot: Int
    let onCommit: (String) -> Bool
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SlotTitleTextField {
        let field = SlotTitleTextField()
        field.delegate = context.coordinator
        field.stringValue = label
        field.font = SlotTypography.titleFont
        field.textColor = .labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("slot-title-\(groupID)-\(slot)")
        updateInterfaceLabels(field)
        return field
    }

    func updateNSView(_ field: SlotTitleTextField, context: Context) {
        context.coordinator.parent = self
        updateInterfaceLabels(field)
        // Thumbnail refreshes and watcher reloads must not replace a live draft.
        if context.coordinator.session == nil { field.stringValue = label }
    }

    private func updateInterfaceLabels(_ field: SlotTitleTextField) {
        let language = AppInterfaceLanguage.resolve(languageRaw)
        field.placeholderString = AppInterfaceStrings.format("槽位 %ld", language: language, arguments: [slot])
        field.setAccessibilityLabel(AppInterfaceStrings.format("槽位 %ld 标题", language: language, arguments: [slot]))
        field.toolTip = AppInterfaceStrings.text("单击重命名 · 回车或点击空白保存 · Esc 取消", language: language)
    }

    static func dismantleNSView(_ field: SlotTitleTextField, coordinator: Coordinator) {
        coordinator.finish(field, save: true)
        field.stopOutsideClickCommit()
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        struct Session {
            let original: String
            let groupID: String
            let slot: Int
            let commit: (String) -> Bool
        }
        var parent: SlotTitleEditor
        var session: Session?
        init(_ parent: SlotTitleEditor) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? SlotTitleTextField, session == nil else { return }
            session = Session(original: field.stringValue, groupID: parent.groupID,
                              slot: parent.slot, commit: parent.onCommit)
            field.setEditingAppearance(true)
            field.startOutsideClickCommit { [weak self, weak field] in
                guard let self, let field else { return true }
                return self.finish(field, save: true)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? SlotTitleTextField else { return }
            finish(field, save: true)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? SlotTitleTextField else { return false }
            // Let the input method confirm/cancel its composition before ending the title.
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(field, save: false)
                field.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if finish(field, save: true) { field.window?.makeFirstResponder(nil) }
                return true
            }
            // Tab/Shift+Tab retain AppKit key-view traversal; end-edit notification saves.
            return false
        }

        @discardableResult func finish(_ field: SlotTitleTextField, save: Bool) -> Bool {
            guard let edit = session else { return true }
            let draft = (field.currentEditor()?.string ?? field.stringValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Clear first: persistence can synchronously publish and dismantle this field.
            session = nil
            field.stopOutsideClickCommit()
            let success = !save || draft == edit.original || edit.commit(draft)
            field.stringValue = save && success ? draft : edit.original
            field.currentEditor()?.string = field.stringValue
            field.setEditingAppearance(false)
            if !success, field.currentEditor() != nil {
                session = edit
                field.currentEditor()?.string = draft
                field.stringValue = draft
                field.setEditingAppearance(true)
                field.startOutsideClickCommit { [weak self, weak field] in
                    guard let self, let field else { return true }
                    return self.finish(field, save: true)
                }
            }
            return success
        }
    }
}

final class SlotTitleTextField: NSTextField {
    private var outsideClickMonitor: Any?

    deinit { stopOutsideClickCommit() }

    /// SwiftUI blank backgrounds need not take first responder. Commit before
    /// forwarding their click, while keeping clicks within this editor untouched.
    func startOutsideClickCommit(_ commit: @escaping () -> Bool) {
        stopOutsideClickCommit()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.currentEditor() != nil,
                  !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            // Confirm marked text first, as AppKit does on normal focus changes.
            if let editor = self.currentEditor() as? NSTextView, editor.hasMarkedText() {
                editor.unmarkText()
            }
            guard commit() else { return nil }
            window.makeFirstResponder(nil)
            return event
        }
    }

    func stopOutsideClickCommit() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if currentEditor() == nil, window?.makeFirstResponder(self) == true {
            selectText(nil)
            return
        }
        super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                guard let self, let editor = self.currentEditor() else { return }
                editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
            }
        }
        return accepted
    }
    func setEditingAppearance(_ editing: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = editing ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = editing ? NSColor.textBackgroundColor.cgColor : nil
    }
}
