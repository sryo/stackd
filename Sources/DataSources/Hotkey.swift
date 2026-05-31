import AppKit
import Carbon.HIToolbox

final class HotkeyRegistry {
    static let shared = HotkeyRegistry()

    // Per-binding metadata. Carbon mints an id; we look up the Binding on
    // event dispatch and gate on mode + frontmost-app before firing the
    // callback. Keeping this struct private + value-type makes the dispatch
    // path branch-free: a single dict lookup, two guard checks, fire.
    private struct Binding {
        let callback: () -> Void
        let mode: String?          // nil = always fires; otherwise must match currentMode
        let apps: [String]?        // nil = no app gating; element "*" = always-match
    }

    private var bindings: [UInt32: Binding] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    // Active mode. skhd's "modal keymap" model: while a non-default mode is
    // active, only bindings declared for that mode (mode == currentMode) fire.
    // Bindings with mode == nil are mode-agnostic and always fire — useful
    // for the chord that exits the mode itself.
    //
    // Global by design (not per-stack): a mode owns the keyboard. Stack A
    // entering "command" suppresses stack B's default-mode bindings too,
    // matching how skhd treats the keyboard as a single resource.
    private(set) var currentMode: String = "default"

    private init() { installEventHandler() }

    /// Parse `"ctrl+alt+cmd+b"` → register Carbon hotkey. Optional `mode`
    /// gates dispatch on the active mode (nil = always fires). Optional
    /// `apps` gates on the frontmost app's bundle identifier (nil = always
    /// fires; `["*"]` = always fires; otherwise the bundleID must match an
    /// entry exactly). Returns a Token whose cancel unregisters; caller
    /// adopts it into a StackScope so stack unload cleans up.
    func bind(spec: String,
              mode: String? = nil,
              apps: [String]? = nil,
              callback: @escaping () -> Void) -> Token? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var mods: UInt32 = 0
        var keyToken: String?
        for p in parts {
            switch p {
            case "cmd", "command", "meta":   mods |= UInt32(cmdKey)
            case "ctrl", "control":          mods |= UInt32(controlKey)
            case "alt", "option", "opt":     mods |= UInt32(optionKey)
            case "shift":                    mods |= UInt32(shiftKey)
            // skhd aliases — composite modifiers users keep asking for.
            case "hyper":                    mods |= UInt32(cmdKey | controlKey | optionKey | shiftKey)
            case "meh":                      mods |= UInt32(controlKey | optionKey | shiftKey)
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
        bindings[id] = Binding(callback: callback, mode: mode, apps: apps)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x73645f6b /* "sd_k" */), id: id)
        let status = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            FileHandle.standardError.write(Data("stackd: RegisterEventHotKey failed for \(spec) status=\(status)\n".utf8))
            bindings.removeValue(forKey: id)
            return nil
        }
        refs[id] = ref
        FileHandle.standardError.write(Data("stackd: hotkey bound \(spec) id=\(id)\(mode.map { " mode=\($0)" } ?? "")\(apps.map { " apps=\($0)" } ?? "")\n".utf8))
        return Token { [weak self] in self?.unbind(id: id) }
    }

    /// Enter a named mode. While active, only bindings with the matching
    /// mode (or mode == nil) will fire. Idempotent — entering the current
    /// mode is a no-op. Mode names are arbitrary; "default" is the implicit
    /// initial mode.
    func enterMode(_ name: String) {
        guard currentMode != name else { return }
        currentMode = name
        FileHandle.standardError.write(Data("stackd: hotkey mode → \(name)\n".utf8))
    }

    /// Return to "default" mode. Idempotent.
    func exitMode() {
        enterMode("default")
    }

    private func unbind(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        bindings.removeValue(forKey: id)
    }

    fileprivate func dispatch(id: UInt32) {
        guard let b = bindings[id] else { return }
        if let m = b.mode, m != currentMode { return }
        if let apps = b.apps, !apps.contains("*") {
            let frontId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if !apps.contains(frontId) { return }
        }
        b.callback()
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
                    HotkeyRegistry.shared.dispatch(id: hkId.id)
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
        case "-", "minus":             return UInt32(kVK_ANSI_Minus)
        case "=", "equal", "equals":   return UInt32(kVK_ANSI_Equal)
        case ",", "comma":             return UInt32(kVK_ANSI_Comma)
        case ".", "period":            return UInt32(kVK_ANSI_Period)
        case "/", "slash":             return UInt32(kVK_ANSI_Slash)
        case ";", "semicolon":         return UInt32(kVK_ANSI_Semicolon)
        case "'", "quote":             return UInt32(kVK_ANSI_Quote)
        case "[", "leftbracket":       return UInt32(kVK_ANSI_LeftBracket)
        case "]", "rightbracket":      return UInt32(kVK_ANSI_RightBracket)
        case "\\", "backslash":        return UInt32(kVK_ANSI_Backslash)
        case "`", "grave":             return UInt32(kVK_ANSI_Grave)
        default: return nil
        }
    }
}
