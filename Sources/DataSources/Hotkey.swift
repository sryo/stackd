import AppKit
import Carbon.HIToolbox

final class HotkeyRegistry {
    static let shared = HotkeyRegistry()

    private var handlers: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    private init() { installEventHandler() }

    func unbindAll() {
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        handlers.removeAll()
        nextId = 1
    }

    // Parse "ctrl+alt+cmd+b" → (keyCode, modifierFlags).
    func bind(spec: String, callback: @escaping () -> Void) -> UInt32? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var mods: UInt32 = 0
        var keyToken: String?
        for p in parts {
            switch p {
            case "cmd", "command", "meta":   mods |= UInt32(cmdKey)
            case "ctrl", "control":          mods |= UInt32(controlKey)
            case "alt", "option", "opt":     mods |= UInt32(optionKey)
            case "shift":                    mods |= UInt32(shiftKey)
            case "fn":                       break // No Carbon support; skip.
            default: keyToken = p
            }
        }
        guard let token = keyToken, let keyCode = HotkeyRegistry.keyCode(for: token) else {
            FileHandle.standardError.write(Data("stackd: hotkey unparsed: \(spec)\n".utf8))
            return nil
        }

        let id = nextId
        nextId += 1
        handlers[id] = callback

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x73645f6b /* "sd_k" */), id: id)
        let status = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            FileHandle.standardError.write(Data("stackd: RegisterEventHotKey failed for \(spec) status=\(status)\n".utf8))
            handlers.removeValue(forKey: id)
            return nil
        }
        refs.append(ref)
        FileHandle.standardError.write(Data("stackd: hotkey bound \(spec) id=\(id)\n".utf8))
        return id
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
            { _, eventRef, _ in
                var hkId = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hkId)
                if err == noErr {
                    HotkeyRegistry.shared.handlers[hkId.id]?()
                }
                return noErr
            },
            1, &spec, nil, &eventHandler)
    }

    // Minimal name → US-keyboard virtual-keycode map. Letters/digits/common keys.
    static func keyCode(for token: String) -> UInt32? {
        switch token {
        case "a": return UInt32(kVK_ANSI_A); case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C); case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E); case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G); case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I); case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K); case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M); case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O); case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q); case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S); case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U); case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W); case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y); case "z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0); case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2); case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4); case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6); case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8); case "9": return UInt32(kVK_ANSI_9)
        case "space": return UInt32(kVK_Space)
        case "return", "enter": return UInt32(kVK_Return)
        case "escape", "esc":   return UInt32(kVK_Escape)
        case "tab":             return UInt32(kVK_Tab)
        case "delete", "backspace": return UInt32(kVK_Delete)
        case "left":  return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "up":    return UInt32(kVK_UpArrow)
        case "down":  return UInt32(kVK_DownArrow)
        default: return nil
        }
    }
}
