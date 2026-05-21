import Carbon
import Cocoa

// Global callback storage for Carbon event handler (C function pointer requirement)
fileprivate var gOnPaste: ((Int) -> Void)?
fileprivate var gOnSave: ((Int) -> Void)?

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
    let isPaste = hotKeyID.signature == 1
    DispatchQueue.main.async {
        if isPaste {
            gOnPaste?(slot)
        } else {
            gOnSave?(slot)
        }
    }
    return noErr
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

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

    func register(config: AppConfig, onPaste: @escaping (Int) -> Void, onSave: @escaping (Int) -> Void) {
        unregisterAll()

        gOnPaste = onPaste
        gOnSave = onSave

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonEventHandler,
            1, &eventType, nil, &eventHandlerRef
        )

        for slot in 1...config.slots {
            // Paste hotkey: signature=1
            if let (modifiers, keyCode) = parseKeybind(config.pasteKey, slot: slot) {
                let id = EventHotKeyID(signature: 1, id: UInt32(slot))
                var ref: EventHotKeyRef?
                RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
                if let ref = ref { hotKeyRefs.append(ref) }
            }
            // Save hotkey: signature=2
            if let (modifiers, keyCode) = parseKeybind(config.saveKey, slot: slot) {
                let id = EventHotKeyID(signature: 2, id: UInt32(slot))
                var ref: EventHotKeyRef?
                RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
                if let ref = ref { hotKeyRefs.append(ref) }
            }
        }
    }

    private func parseKeybind(_ pattern: String, slot: Int) -> (modifiers: Int, keyCode: Int)? {
        let expanded = pattern.replacingOccurrences(of: "{n}", with: String(slot))
        let parts = expanded.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }

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
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        gOnPaste = nil
        gOnSave = nil
    }
}
