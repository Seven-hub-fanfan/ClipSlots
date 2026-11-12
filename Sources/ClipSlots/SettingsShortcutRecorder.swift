import AppKit
import SwiftUI
import ClipSlotsKit

struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var shortcut: String
    var allowsSlotPlaceholder: Bool
    var slotLabel = "1…10"
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var languageRaw = AppInterfaceLanguage.chinese.rawValue

    func makeNSView(context: Context) -> ShortcutCaptureTextField {
        let field = ShortcutCaptureTextField()
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.alignment = .center
        field.wantsLayer = true
        configure(field)
        return field
    }
    func updateNSView(_ field: ShortcutCaptureTextField, context: Context) { configure(field) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutCaptureTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 208, height: 34)
    }
    private func configure(_ field: ShortcutCaptureTextField) {
        field.onShortcut = { shortcut = $0 }
        field.allowsSlotPlaceholder = allowsSlotPlaceholder
        field.slotLabel = slotLabel
        field.recordingPrompt = AppInterfaceStrings.text("按下组合键…", language: AppInterfaceLanguage.resolve(languageRaw))
        field.toolTip = AppInterfaceStrings.text("点击录入快捷键；Esc 取消", language: AppInterfaceLanguage.resolve(languageRaw))
        field.committedShortcut = shortcut
        if !field.isRecording { field.showCommittedValue() }
        field.updateBorder()
    }
}

final class ShortcutCaptureTextField: NSTextField {
    var onShortcut: ((String) -> Void)?
    var allowsSlotPlaceholder = false
    var slotLabel = "1…10"
    var recordingPrompt = ""
    var committedShortcut = ""
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHidden && isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 208, height: 34) }
    override func becomeFirstResponder() -> Bool {
        isRecording = true
        stringValue = recordingPrompt
        updateBorder()
        return true
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        showCommittedValue()
        updateBorder()
        return true
    }
    func updateBorder() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(isRecording ? 0.45 : 0.12).cgColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBorder() }
    func showCommittedValue() {
        stringValue = HotkeyTemplateNormalizer.displayShortcut(committedShortcut, slotLabel: slotLabel)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Center the single line vertically without increasing the click target.
        let offset = max(0, (bounds.height - (font?.boundingRectForFont.height ?? 16)) / 2)
        cell?.draw(withFrame: bounds.insetBy(dx: 8, dy: offset), in: self)
    }
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self { _ = becomeFirstResponder() }
        else { window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        if event.keyCode == 48 {
            let next = event.modifierFlags.contains(.shift) ? previousValidKeyView : nextValidKeyView
            window?.makeFirstResponder(nil)
            if let next, next !== self { window?.makeFirstResponder(next) }
            return
        }
        let value = Self.shortcutString(from: event, allowsSlotPlaceholder: allowsSlotPlaceholder)
        guard !value.isEmpty else { NSSound.beep(); return }
        committedShortcut = value
        onShortcut?(value)
        window?.makeFirstResponder(nil)
        showCommittedValue()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let modifiers = Self.modifierParts(event.modifierFlags)
        stringValue = modifiers.isEmpty ? recordingPrompt :
            HotkeyTemplateNormalizer.displayShortcut(modifiers.joined(separator: "+"), slotLabel: slotLabel) + " …"
    }
    private static func modifierParts(_ flags: NSEvent.ModifierFlags) -> [String] {
        [("cmd", NSEvent.ModifierFlags.command), ("ctrl", .control), ("option", .option), ("shift", .shift)]
            .compactMap { flags.contains($0.1) ? $0.0 : nil }
    }
    static func shortcutString(from event: NSEvent, allowsSlotPlaceholder: Bool) -> String {
        let modifiers = modifierParts(event.modifierFlags)
        // A global shortcut must not consume ordinary typing.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false else { return "" }
        let key: String
        switch event.keyCode {
        case 49: key = "space"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 122: key = "f1"
        case 120: key = "f2"
        case 99: key = "f3"
        case 118: key = "f4"
        case 96: key = "f5"
        case 97: key = "f6"
        case 98: key = "f7"
        case 100: key = "f8"
        case 101: key = "f9"
        case 109: key = "f10"
        case 103: key = "f11"
        case 111: key = "f12"
        default:
            let typed = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard typed.count == 1, typed.range(of: "^[a-z0-9]$", options: .regularExpression) != nil else { return "" }
            key = allowsSlotPlaceholder ? "{n}" : typed
        }
        return (modifiers + [key]).joined(separator: "+")
    }
}

enum HotkeyTemplateNormalizer {
    static func normalizedShortcut(_ raw: String, allowsSlotPlaceholder: Bool) -> String {
        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var modifiers: Set<String> = []
        var key = ""
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": modifiers.insert("cmd")
            case "ctrl", "control", "⌃": modifiers.insert("ctrl")
            case "option", "opt", "alt", "⌥": modifiers.insert("option")
            case "shift", "⇧": modifiers.insert("shift")
            case "{n}", "n", "数字": key = allowsSlotPlaceholder ? "{n}" : "n"
            default:
                // Named keys such as space, left and f1 are never slot placeholders.
                key = allowsSlotPlaceholder && part.range(of: "^[a-z0-9]$", options: .regularExpression) != nil
                    ? "{n}" : part
            }
        }
        return (["cmd", "ctrl", "option", "shift"].filter { modifiers.contains($0) } + [key])
            .filter { !$0.isEmpty }.joined(separator: "+")
    }
    static func displayShortcut(_ raw: String, slotLabel: String) -> String {
        let glyphs = ["cmd": "⌘", "ctrl": "⌃", "option": "⌥", "shift": "⇧",
                      "left": "←", "right": "→", "up": "↑", "down": "↓",
                      "space": "Space", "tab": "⇥", "{n}": slotLabel]
        return raw.split(separator: "+").map { glyphs[String($0)] ?? $0.uppercased() }.joined(separator: "  ")
    }
}
