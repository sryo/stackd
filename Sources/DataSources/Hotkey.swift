import AppKit
import Carbon
import Foundation

// MARK: ============================================================
// MARK: Hotkey — Carbon hotkey registry + modal modes
// MARK: ============================================================

/// A parsed `"ctrl+alt+cmd+b"` chord: a Carbon virtual keycode and modifier mask.
struct HotkeySpec: Equatable {
    enum ParseError: Error, Equatable {
        /// Carbon hot keys have no fn modifier; dropping it would bind the bare key.
        case unsupportedModifier(String)
        case missingKey
        case unknownKey(String)
    }

    var keyCode: UInt32
    var modifiers: UInt32

    /// `+`-separated, case-insensitive. Everything that is not a modifier name
    /// is the key; the last one wins.
    static func parse(_ spec: String) -> Result<HotkeySpec, ParseError> {
        var mods: UInt32 = 0
        var keyToken: String?
        for part in spec.lowercased().split(separator: "+") {
            let p = part.trimmingCharacters(in: .whitespaces)
            switch p {
            case "cmd", "command", "meta":   mods |= UInt32(cmdKey)
            case "ctrl", "control":          mods |= UInt32(controlKey)
            case "alt", "option", "opt":     mods |= UInt32(optionKey)
            case "shift":                    mods |= UInt32(shiftKey)
            case "fn":                       return .failure(.unsupportedModifier(p))
            default:                         keyToken = p
            }
        }
        guard let token = keyToken else { return .failure(.missingKey) }
        guard let keyCode = HotkeyRegistry.keyCode(for: token) else { return .failure(.unknownKey(token)) }
        return .success(HotkeySpec(keyCode: keyCode, modifiers: mods))
    }
}

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
        let excludeApps: [String]? // nil = no blacklist; otherwise matching bundleID is suppressed
    }

    private var bindings: [UInt32: Binding] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    // Ref-counting for identical keyCode+mods combos so N per-display stack
    // instances share one process-global Carbon registration (see bind()).
    private var hotkeyIdByCombo: [UInt64: UInt32] = [:]
    private var comboRefCounts: [UInt64: Int] = [:]

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
              excludeApps: [String]? = nil,
              callback: @escaping () -> Void) -> Token? {
        let keyCode: UInt32
        let mods: UInt32
        switch HotkeySpec.parse(spec) {
        case .success(let parsed):
            keyCode = parsed.keyCode
            mods = parsed.modifiers
        case .failure(let error):
            log("hotkey unparsed: \(spec) (\(error))")
            return nil
        }

        // Carbon registers hot keys process-globally (GetApplicationEventTarget),
        // so one keyCode+mods combo can be live only once. A stack rendered on
        // N displays spawns N Bridge instances that each bind the manifest's
        // hotkeys; the 2nd..Nth RegisterEventHotKey then returned
        // eventHotKeyExistsErr (-9878) and left the chord owned by whichever
        // instance won the race (fragile under display hot-plug). Ref-count
        // identical combos: the first bind owns the Carbon registration and the
        // dispatch Binding, later binds share it, and only the last release
        // unregisters.
        let combo = (UInt64(keyCode) << 32) | UInt64(mods)
        if let ownerId = hotkeyIdByCombo[combo] {
            comboRefCounts[combo, default: 0] += 1
            log("hotkey bound \(spec) id=\(ownerId) (shared refs=\(comboRefCounts[combo]!))")
            return Token { [weak self] in self?.releaseCombo(combo) }
        }

        let id = nextId
        nextId += 1
        bindings[id] = Binding(callback: callback, mode: mode, apps: apps, excludeApps: excludeApps)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x73645f6b /* "sd_k" */), id: id)
        let status = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            log("RegisterEventHotKey failed for \(spec) status=\(status)")
            bindings.removeValue(forKey: id)
            return nil
        }
        refs[id] = ref
        hotkeyIdByCombo[combo] = id
        comboRefCounts[combo] = 1
        log("hotkey bound \(spec) id=\(id)\(mode.map { " mode=\($0)" } ?? "")\(apps.map { " apps=\($0)" } ?? "")")
        return Token { [weak self] in self?.releaseCombo(combo) }
    }

    /// Enter a named mode. While active, only bindings with the matching
    /// mode (or mode == nil) will fire. Idempotent — entering the current
    /// mode is a no-op. Mode names are arbitrary; "default" is the implicit
    /// initial mode.
    func enterMode(_ name: String) {
        guard currentMode != name else { return }
        currentMode = name
        log("hotkey mode → \(name)")
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

    // Decrement a combo's ref-count; the last release tears down the shared
    // Carbon registration. Every Token minted by bind() routes here.
    private func releaseCombo(_ combo: UInt64) {
        guard let n = comboRefCounts[combo] else { return }
        if n > 1 {
            comboRefCounts[combo] = n - 1
            return
        }
        comboRefCounts.removeValue(forKey: combo)
        if let id = hotkeyIdByCombo.removeValue(forKey: combo) {
            unbind(id: id)
        }
    }

    /// Whether a binding's mode and app gates let it fire. `frontmost` (the
    /// frontmost app's bundle id) is only asked for when an app list or an
    /// exclusion list is set, and at most once.
    static func gateAllows(mode: String?, currentMode: String, apps: [String]?,
                           excludeApps: [String]?, frontmost: () -> String) -> Bool {
        if let mode = mode, mode != currentMode { return false }
        let appListed = apps.map { !$0.contains("*") } ?? false
        guard appListed || excludeApps != nil else { return true }
        let frontId = frontmost()
        if appListed, let apps = apps, !apps.contains(frontId) { return false }
        if let exclude = excludeApps, exclude.contains(frontId) { return false }
        return true
    }

    fileprivate func dispatch(id: UInt32) {
        guard let b = bindings[id] else { return }
        let allowed = HotkeyRegistry.gateAllows(
            mode: b.mode, currentMode: currentMode, apps: b.apps, excludeApps: b.excludeApps,
            frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" })
        if allowed { b.callback() }
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

    /// Name → US-keyboard virtual keycode, shared by hotkey binding and key
    /// synthesis (EventsSynth). Function-key, navigation and keypad names
    /// mirror `hs.keycodes.map` so Hammerspoon muscle memory transfers.
    ///
    /// Media (mediaPlay/mediaNext/mediaPrev) and brightness keys are absent:
    /// those are HID Consumer-page events (NX_KEYTYPE_*) posted through
    /// NSEvent.otherEvent(.systemDefined, subtype: 8, ...), not virtual keycodes.
    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "tab": kVK_Tab,
        "return": kVK_Return, "enter": kVK_Return,
        "escape": kVK_Escape, "esc": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal, "equals": kVK_ANSI_Equal,
        ",": kVK_ANSI_Comma, "comma": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "period": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "slash": kVK_ANSI_Slash,
        ";": kVK_ANSI_Semicolon, "semicolon": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "quote": kVK_ANSI_Quote,
        "[": kVK_ANSI_LeftBracket, "leftbracket": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "rightbracket": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, "backslash": kVK_ANSI_Backslash,
        "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "forwarddelete": kVK_ForwardDelete, "help": kVK_Help,
        "pad.": kVK_ANSI_KeypadDecimal, "paddecimal": kVK_ANSI_KeypadDecimal,
        "pad*": kVK_ANSI_KeypadMultiply, "padmultiply": kVK_ANSI_KeypadMultiply,
        "pad+": kVK_ANSI_KeypadPlus, "padplus": kVK_ANSI_KeypadPlus,
        "pad/": kVK_ANSI_KeypadDivide, "paddivide": kVK_ANSI_KeypadDivide,
        "pad-": kVK_ANSI_KeypadMinus, "padminus": kVK_ANSI_KeypadMinus,
        "pad=": kVK_ANSI_KeypadEquals, "padequals": kVK_ANSI_KeypadEquals,
        "pad0": kVK_ANSI_Keypad0, "pad1": kVK_ANSI_Keypad1, "pad2": kVK_ANSI_Keypad2,
        "pad3": kVK_ANSI_Keypad3, "pad4": kVK_ANSI_Keypad4, "pad5": kVK_ANSI_Keypad5,
        "pad6": kVK_ANSI_Keypad6, "pad7": kVK_ANSI_Keypad7, "pad8": kVK_ANSI_Keypad8,
        "pad9": kVK_ANSI_Keypad9,
        "padclear": kVK_ANSI_KeypadClear, "padenter": kVK_ANSI_KeypadEnter,
    ]

    static func keyCode(for token: String) -> UInt32? {
        keyCodes[token].map { UInt32($0) }
    }
}
