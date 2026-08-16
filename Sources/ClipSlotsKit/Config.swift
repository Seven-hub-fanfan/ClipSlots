import Foundation

public struct AppConfig: Codable {
    public var slots: Int = 10
    public var verbose: Bool = true
    // v2.9.10: default save shortcut is Option+{n} (no Cmd). Users can still change them in Settings.
    public var saveKey: String = "option+{n}"
    public var pasteKey: String = "cmd+{n}"
    public var radialKey: String = "ctrl+space"
    public var hotkeyTemplate: HotkeyTemplate = HotkeyTemplate(kind: .numeric)
    /// UNDO-3 (v2.10.97): 每个槽位组保留的撤销/重做步数（设置面板「高级 → 操作历史」）。
    /// 合法范围 1~100，默认 10；写入时统一经 `SlotUndoStack.clampLimit` 夹取。
    public var undoSteps: Int = SlotUndoStack.defaultLimitPerGroup

    public init() {}

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clipslots/config.toml")

    public static func load() -> AppConfig {
        guard let content = try? String(contentsOf: Self.configURL, encoding: .utf8) else {
            return AppConfig()
        }
        return parseTOML(content)
    }

    public func save() {
        let dir = Self.configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let customKeysStr = hotkeyTemplate.customKeys.joined(separator: ",")
        let lines = [
            "# ClipSlots Configuration",
            "",
            "# Number of slots (1-10)",
            "slots = \(slots)",
            "",
            "# Show daemon logs in terminal (true/false)",
            "# Logs save/paste actions, startup info, errors, etc.",
            "verbose = \(verbose)",
            "",
            "# Undo/redo steps kept per slot group (1-100)",
            "undo_steps = \(undoSteps)",
            "",
            "# Keybind configuration",
            "# Use {n} as placeholder for the slot number",
            "#",
            "# Available modifiers: ctrl, option, cmd, shift",
            "# Available keys: 0-9, a-z, f1-f12",
            "#",
            "# Examples:",
            "#   \"ctrl+option+{n}\"   → Ctrl+Option+1 for slot 1",
            "#   \"cmd+shift+{n}\"     → Cmd+Shift+1 for slot 1",
            "[keybinds]",
            "save = \"\(saveKey)\"",
            "paste = \"\(pasteKey)\"",
            "radial = \"\(radialKey)\"",
            "template = \"\(hotkeyTemplate.kind.rawValue)\"",
            "custom_keys = \"\(customKeysStr)\"",
        ]
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: Self.configURL, atomically: true, encoding: .utf8)
    }

    private static func parseTOML(_ content: String) -> AppConfig {
        var config = AppConfig()
        var inKeybinds = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "[keybinds]" {
                inKeybinds = true
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inKeybinds = false
                continue
            }
            if !trimmed.contains("=") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            var value = parts[1]
            // DS-4 (v2.10.30): strip a trailing inline `#` comment BEFORE parsing. Previously
            // `slots = 10  # ten slots` kept the value as `10  # ten slots`; `Int()` then failed
            // and the key was silently dropped (config quietly reverted to the default). A `#`
            // inside a quoted string stays literal.
            value = Self.stripInlineComment(value).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if inKeybinds {
                if key == "save" { config.saveKey = value }
                else if key == "paste" { config.pasteKey = value }
                else if key == "radial" { config.radialKey = value }
                else if key == "template" { config.hotkeyTemplate.kind = HotkeyTemplateKind(rawValue: value) ?? .numeric }
                else if key == "custom_keys" {
                    let keys = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                    if keys.count == 10 { config.hotkeyTemplate.customKeys = keys }
                }
            } else {
                if key == "slots", let v = Int(value) { config.slots = max(1, min(10, v)) }
                else if key == "verbose" { config.verbose = value.lowercased() == "true" }
                else if key == "undo_steps", let v = Int(value) { config.undoSteps = SlotUndoStack.clampLimit(v) }
            }
        }
        return config
    }

    /// DS-4 (v2.10.30): remove a trailing inline `#` comment from a TOML value, treating `#`
    /// inside single/double quotes as literal.
    private static func stripInlineComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        var result = ""
        for ch in s {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#" && !inSingle && !inDouble { break }
            result.append(ch)
        }
        return result
    }
}
