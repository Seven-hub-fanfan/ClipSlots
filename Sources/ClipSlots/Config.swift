import Foundation

struct AppConfig: Codable {
    var slots: Int = 10
    var verbose: Bool = true
    // v2.7.23: default shortcuts use Cmd. Users can still change them in Settings.
    var saveKey: String = "cmd+option+{n}"
    var pasteKey: String = "cmd+{n}"
    var radialKey: String = "ctrl+space"
    var hotkeyTemplate: HotkeyTemplate = HotkeyTemplate(kind: .numeric)

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clipslots/config.toml")

    static func load() -> AppConfig {
        guard let content = try? String(contentsOf: Self.configURL, encoding: .utf8) else {
            return AppConfig()
        }
        return parseTOML(content)
    }

    func save() {
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
            }
        }
        return config
    }
}
