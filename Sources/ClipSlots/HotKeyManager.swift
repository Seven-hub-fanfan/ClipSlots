import Carbon
import Cocoa

// Global callback storage for Carbon event handler (C function pointer requirement)
fileprivate var gOnPaste: ((Int) -> Void)?
fileprivate var gOnSave: ((Int) -> Void)?
fileprivate var gOnRadial: (() -> Void)?
fileprivate var gOnPrevious: (() -> Void)?
fileprivate var gOnNext: (() -> Void)?

fileprivate func carbonEventHandler(_ handler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return noErr }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event,
                      EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil,
                      MemoryLayout<EventHotKeyID>.size,
                      nil,
                      &hotKeyID)
    let slot = Int(hotKeyID.id)
    // v2.4.1: switch on signature to prevent new signatures from falling through to save
    DispatchQueue.main.async {
        switch hotKeyID.signature {
        case 1: gOnPaste?(slot)
        case 2: gOnSave?(slot)
        case 3: gOnRadial?()
        case 4: gOnPrevious?()
        case 5: gOnNext?()
        default: break
        }
    }
    return noErr
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var radialHotKeyRef: EventHotKeyRef?

    private let keyCodeMap: [String: Int] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3,
        "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
        "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
        "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
        "space": 49, "tab": 48, "return": 36, "escape": 53,
        "left": 123, "right": 124, "up": 126, "down": 125,
    ]

    private let modifierMap: [String: Int] = [
        "ctrl": controlKey,
        "control": controlKey,
        "option": optionKey,
        "alt": optionKey,
        "cmd": cmdKey,
        "command": cmdKey,
        "shift": shiftKey,
    ]

    @discardableResult
    func register(config: AppConfig,
                  onPaste: @escaping (Int) -> Void,
                  onSave: @escaping (Int) -> Void,
                  onRadial: @escaping () -> Void,
                  onPrevious: @escaping () -> Void = {},
                  onNext: @escaping () -> Void = {}) -> [String] {
        unregisterAll()

        var failures: [String] = []

        gOnPaste = onPaste
        gOnSave = onSave
        gOnRadial = onRadial
        gOnPrevious = onPrevious
        gOnNext = onNext

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonEventHandler,
            1, &eventType, nil, &eventHandlerRef
        )
        if installStatus != noErr {
            NSLog("[ClipSlots] ERROR: InstallEventHandler failed (status: \(installStatus))")
            failures.append("系统事件处理器注册失败")
        }

        // Radial menu hotkey: signature=3, single keybind (no {n} placeholder)
        if let (modifiers, keyCode) = parseSimpleKeybind(config.radialKey) {
            let id = EventHotKeyID(signature: 3, id: 0)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                radialHotKeyRef = ref
                hotKeyRefs.append(ref)
                NSLog("[ClipSlots] RADIAL hotkey registered: mod=\(modifiers) key=\(keyCode)")
            } else {
                NSLog("[ClipSlots] ERROR: RADIAL hotkey FAILED mod=\(modifiers) key=\(keyCode) status=\(status)")
                failures.append("圆盘菜单快捷键 (\(config.radialKey)) 注册失败")
            }
        }

        // v2.4.1: slot group navigation — Cmd+Left / Cmd+Right
        if let (mods, keyCode) = parseSimpleKeybind("cmd+left") {
            let id = EventHotKeyID(signature: 4, id: 0)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                hotKeyRefs.append(ref)
                NSLog("[ClipSlots] PREVIOUS hotkey registered: mod=\(mods) key=\(keyCode)")
            } else {
                NSLog("[ClipSlots] ERROR: PREVIOUS hotkey FAILED status=\(status)")
                failures.append("切换上一个槽位组快捷键 (Cmd+Left) 注册失败")
            }
        }
        if let (mods, keyCode) = parseSimpleKeybind("cmd+right") {
            let id = EventHotKeyID(signature: 5, id: 0)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                hotKeyRefs.append(ref)
                NSLog("[ClipSlots] NEXT hotkey registered: mod=\(mods) key=\(keyCode)")
            } else {
                NSLog("[ClipSlots] ERROR: NEXT hotkey FAILED status=\(status)")
                failures.append("切换下一个槽位组快捷键 (Cmd+Right) 注册失败")
            }
        }

        let template = config.hotkeyTemplate
        for slot in 1...config.slots {
            // Paste hotkey: signature=1
            if let (modifiers, keyCode) = parseKeybind(config.pasteKey, slot: slot, template: template) {
                let id = EventHotKeyID(signature: 1, id: UInt32(slot))
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref = ref {
                    hotKeyRefs.append(ref)
                    NSLog("[ClipSlots] PASTE hotkey registered: slot=\(slot) mod=\(modifiers) key=\(keyCode)")
                } else {
                    let keyStr = config.pasteKey.replacingOccurrences(of: "{n}", with: keyToken(for: slot, template: template))
                    NSLog("[ClipSlots] ERROR: PASTE hotkey FAILED slot=\(slot) mod=\(modifiers) key=\(keyCode) status=\(status)")
                    failures.append("粘贴快捷键 (\(keyStr)) 注册失败，可能被其他应用占用")
                }
            }
            // Save hotkey: signature=2
            if let (modifiers, keyCode) = parseKeybind(config.saveKey, slot: slot, template: template) {
                let id = EventHotKeyID(signature: 2, id: UInt32(slot))
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref = ref {
                    hotKeyRefs.append(ref)
                    NSLog("[ClipSlots] SAVE hotkey registered: slot=\(slot) mod=\(modifiers) key=\(keyCode)")
                } else {
                    let keyStr = config.saveKey.replacingOccurrences(of: "{n}", with: keyToken(for: slot, template: template))
                    NSLog("[ClipSlots] ERROR: SAVE hotkey FAILED slot=\(slot) mod=\(modifiers) key=\(keyCode) status=\(status)")
                    failures.append("保存快捷键 (\(keyStr)) 注册失败，可能被其他应用占用")
                }
            }
        }

        return failures
    }

    private func keyToken(for slot: Int, template: HotkeyTemplate) -> String {
        return template.keyToken(for: slot) ?? String(slot)
    }

    private func parseKeybind(_ pattern: String, slot: Int, template: HotkeyTemplate) -> (modifiers: Int, keyCode: Int)? {
        let expanded = pattern.replacingOccurrences(of: "{n}", with: keyToken(for: slot, template: template))
        return parseSimpleKeybind(expanded)
    }

    private func parseSimpleKeybind(_ pattern: String) -> (modifiers: Int, keyCode: Int)? {
        let parts = pattern.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }

        var modifiers: Int = 0
        var keyCode: Int?

        for part in parts {
            if let mod = modifierMap[part] {
                modifiers |= mod
            } else if let code = keyCodeMap[part] {
                keyCode = code
            }
        }

        guard let keyCode = keyCode, modifiers != 0 else { return nil }
        return (modifiers, keyCode)
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        radialHotKeyRef = nil
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        gOnPaste = nil
        gOnSave = nil
        gOnRadial = nil
        gOnPrevious = nil
        gOnNext = nil
        NSLog("[ClipSlots] All hotkeys unregistered")
    }
}
