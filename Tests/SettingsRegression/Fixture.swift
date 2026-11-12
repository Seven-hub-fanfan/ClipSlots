import AppKit
import SwiftUI
import ClipSlotsKit

/// Linked against the production sources in an isolated bundle and data directory.
@MainActor enum SettingsRegression {
    static func run(root: URL) async {
        var passes: [String] = [], failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            (value ? print("PASS: \(name)") : print("FAIL: \(name)"))
            if value { passes.append(name) } else { failures.append(name) }
        }
        func settle() async { try? await Task.sleep(nanoseconds: 160_000_000) }
        func elements(_ root: AnyObject) -> [AnyObject] {
            var visited = Set<ObjectIdentifier>()
            func walk(_ node: AnyObject, _ depth: Int) -> [AnyObject] {
                guard depth < 40, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                let children = (node.accessibilityChildren?() ?? []) + ((node as? NSView)?.subviews ?? [])
                return [node] + children.flatMap { walk($0 as AnyObject, depth + 1) }
            }
            return walk(root, 0)
        }
        func find(_ host: NSView, _ id: String) -> AnyObject? {
            elements(host).first { $0.accessibilityIdentifier?() == id }
        }
        func press(_ host: NSView, _ id: String) -> Bool {
            find(host, id)?.accessibilityPerformPress?() == true
        }
        func visible(_ node: AnyObject?, _ host: NSView) -> Bool {
            guard let window = host.window, let rect = node?.accessibilityFrame?(),
                  rect.width > 2, rect.height > 2 else { return false }
            return window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -2, dy: -2).contains(rect)
        }
        func event(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code)!
        }
        let isolated = ProcessInfo.processInfo.environment["CLIPSLOTS_DATA_DIR"] ?? ""
        guard isolated.hasPrefix(root.path + "/") else { fatalError("Settings tests require isolated data") }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
        defaults.set(false, forKey: UserPreferenceKeys.skipBatchSaveConfirmation)
        defaults.set(true, forKey: UserPreferenceKeys.showSaveToast)
        defaults.set(true, forKey: UserPreferenceKeys.showCopyToast)
        defaults.set(true, forKey: UserPreferenceKeys.enableSlotConnection)

        for (raw, expected) in [("option+2", "option+{n}"), ("⌘+a", "cmd+{n}"),
                                ("ctrl+space", "ctrl+space"), ("cmd+left", "cmd+left"),
                                ("option+f1", "option+f1"), ("shift+cmd+cmd+2", "cmd+shift+{n}")] {
            check(HotkeyTemplateNormalizer.normalizedShortcut(raw, allowsSlotPlaceholder: true) == expected,
                  "normalize \(raw)")
        }
        check(HotkeyTemplateNormalizer.normalizedShortcut("cmd+a", allowsSlotPlaceholder: false) == "cmd+a",
              "radial shortcut keeps literal letter")
        check(ShortcutCaptureTextField.shortcutString(from: event(18, "1"), allowsSlotPlaceholder: true) == "cmd+{n}",
              "recorder creates slot template")
        check(ShortcutCaptureTextField.shortcutString(from: event(49, " ", [.control]), allowsSlotPlaceholder: true) == "ctrl+space",
              "recorder preserves named space key")
        check(ShortcutCaptureTextField.shortcutString(from: event(122, ""), allowsSlotPlaceholder: true) == "cmd+f1",
              "recorder preserves function key")
        check(ShortcutCaptureTextField.shortcutString(from: event(0, "a", []), allowsSlotPlaceholder: false).isEmpty,
              "recorder rejects unmodified typing")

        let window = NSWindow(contentRect: NSRect(x: 50, y: 60, width: 880, height: 660),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ClipSlots Settings Regression"
        window.makeKeyAndOrderFront(nil)
        for language in [AppInterfaceLanguage.chinese, .english] {
            for dark in [false, true] {
                for width in [720, 880] {
                    for category in SettingsCategory.allCases {
                        window.contentView = NSView()
                        await settle()
                        defaults.set(language.rawValue, forKey: AppInterfaceLanguage.preferenceKey)
                        defaults.set(dark ? "dark" : "light", forKey: "appearanceMode")
                        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        let host = NSHostingView(rootView: SettingsView(config: AppConfig(),
                            onSave: { _ in }, onClose: {}, initialCategory: category))
                        window.contentView = host
                        window.setContentSize(NSSize(width: width, height: 660))
                        await settle()
                        let tag = "\(language.rawValue)-\(dark ? "dark" : "light")-\(width)-\(category.rawValue)"
                        check(visible(find(host, "settings-save"), host) && visible(find(host, "settings-cancel"), host),
                              "\(tag) footer visible")
                        check(visible(find(host, "settings-category-\(category.rawValue)"), host), "\(tag) navigation visible")
                        if category == .shortcut {
                            let fields = elements(host).compactMap { $0 as? ShortcutCaptureTextField }
                            check(fields.count == 3 && fields.allSatisfy { $0.bounds.width >= 200 && $0.bounds.height >= 32 },
                                  "\(tag) three readable shortcut controls")
                        }
                        host.layoutSubtreeIfNeeded()
                        if width == 880, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(tag + ".png"))
                        }
                    }
                }
            }
        }
        window.contentView = NSView()
        await settle()
        defaults.set("zh-Hans", forKey: AppInterfaceLanguage.preferenceKey)
        defaults.set("light", forKey: "appearanceMode")
        var savedConfig: AppConfig?
        var closeCount = 0
        var host = NSHostingView(rootView: SettingsView(config: AppConfig(), onSave: { savedConfig = $0 },
            onClose: { closeCount += 1 }, initialCategory: .slot))
        window.contentView = host
        await settle()
        check(press(host, "settings-slot-count-6"), "slot count draft responds")
        await settle()
        check(savedConfig == nil, "draft does not call save")
        check(press(host, "settings-cancel") && closeCount == 1 && savedConfig == nil, "cancel discards configuration draft")

        window.contentView = NSView()
        await settle()
        host = NSHostingView(rootView: SettingsView(config: AppConfig(), onSave: { savedConfig = $0 },
            onClose: {}, initialCategory: .slot))
        window.contentView = host
        await settle()
        _ = press(host, "settings-slot-count-7")
        await settle()
        check(press(host, "settings-save"), "save action responds")
        check(savedConfig?.slots == 7, "save persists chosen slot count")

        window.contentView = NSView()
        await settle()
        host = NSHostingView(rootView: SettingsView(config: AppConfig(), onSave: { _ in },
            onClose: {}, initialCategory: .appearance))
        window.contentView = host
        await settle()
        check(press(host, "settings-appearance-dark"), "dark preview responds")
        await settle()
        check(defaults.string(forKey: "appearanceMode") == "dark", "appearance previews live")
        _ = press(host, "settings-cancel")
        await settle()
        check(defaults.string(forKey: "appearanceMode") == "light", "cancel restores appearance preview")
        _ = press(host, "settings-appearance-dark")
        await settle()
        window.contentView = NSView()
        await settle()
        check(defaults.string(forKey: "appearanceMode") == "light", "external dismissal restores appearance preview")

        defaults.set(true, forKey: UserPreferenceKeys.skipOverwriteConfirmation)
        defaults.set(false, forKey: UserPreferenceKeys.showSaveToast)
        host = NSHostingView(rootView: SettingsView(config: AppConfig(), onSave: { _ in },
            onClose: {}, initialCategory: .notification))
        window.contentView = host
        await settle()
        check(press(host, "settings-reset"), "notification reset changes current page draft")
        await settle()
        check(defaults.skipOverwriteConfirmation && !defaults.showSaveToast,
              "reset only changes draft preferences")
        _ = press(host, "settings-cancel")
        check(defaults.skipOverwriteConfirmation && !defaults.showSaveToast,
              "cancel after reset preserves persisted preferences")
        window.contentView = NSView()
        await settle()
        host = NSHostingView(rootView: SettingsView(config: AppConfig(), onSave: { _ in },
            onClose: {}, initialCategory: .notification))
        window.contentView = host
        await settle()
        _ = press(host, "settings-reset")
        await settle()
        check(press(host, "settings-save"), "save after notification reset responds")
        check(!defaults.skipOverwriteConfirmation && defaults.showSaveToast,
              "save commits restored notification defaults")
        window.contentView = NSView()
        await settle()

        host = NSHostingView(rootView: SettingsView(config: AppConfig(), onSave: { _ in },
            onClose: {}, initialCategory: .shortcut))
        window.contentView = host
        await settle()
        if let field = elements(host).compactMap({ $0 as? ShortcutCaptureTextField }).first(where: { $0.allowsSlotPlaceholder }) {
            let original = field.committedShortcut
            window.makeFirstResponder(field)
            field.flagsChanged(with: event(59, "", [.control]))
            check(field.committedShortcut == original, "modifier feedback does not change draft")
            field.keyDown(with: event(53, "", []))
            check(!field.isRecording && field.committedShortcut == original, "escape cancels recording")
            check(!field.stringValue.contains("…") || field.stringValue.contains("1…0"),
                  "escape removes partial modifier prompt")
            window.makeFirstResponder(field)
            field.keyDown(with: event(19, "2", [.control, .option]))
            await settle()
            check(field.committedShortcut == "ctrl+option+{n}" && !field.isRecording,
                  "capture commits to draft and ends recording")
            window.makeFirstResponder(field)
            field.keyDown(with: event(48, "\t", []))
            check(!field.isRecording && field.committedShortcut == "ctrl+option+{n}", "tab exits without replacing shortcut")
        } else { check(false, "native recorder accessible") }
        window.contentView = NSView()
        window.close()
        let report: [String: Any] = ["passed": failures.isEmpty, "passes": passes, "failures": failures,
            "screenshots": 32, "matrix": "8 pages × 2 languages × 2 themes × 2 widths", "isolated": true]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("settings-regression.json"))
        exit(failures.isEmpty ? 0 : 1)
    }
}

@main enum SettingsRegressionMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            await SettingsRegression.run(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        app.run()
    }
}
