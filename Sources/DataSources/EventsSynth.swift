import AppKit
import Carbon.HIToolbox
import CoreGraphics

// Write side of the input-events stream. Split out of Events.swift to mirror
// the Camera.swift vs CameraCapture.swift separation pattern — read-side
// registry stays in Events.swift, this file is the synthesize-events half.
//
// EventsSynth — type a string, fire a key combo, scroll, click. Posts
// CGEvents to the session tap so they target the user's foreground app.
// Reuses HotkeyRegistry's keycode map for chord parsing.

// MARK: - Write side: synthesize events

enum EventsSynth {

    /// Inject arbitrary text — works regardless of keyboard layout, doesn't
    /// require mapping each character to a virtual key. Uses CGEvent's
    /// keyboardSetUnicodeString.
    static func type(_ s: String) {
        let utf16 = Array(s.utf16)
        utf16.withUnsafeBufferPointer { buf in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// Fire a key combo like "cmd+v" or "ctrl+alt+space".
    @discardableResult
    static func key(_ spec: String) -> Bool {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags = CGEventFlags()
        var keyToken: String?
        for p in parts {
            switch p {
            case "cmd", "command", "meta":  flags.insert(.maskCommand)
            case "ctrl", "control":         flags.insert(.maskControl)
            case "alt", "option", "opt":    flags.insert(.maskAlternate)
            case "shift":                   flags.insert(.maskShift)
            case "fn":                      flags.insert(.maskSecondaryFn)
            default: keyToken = p
            }
        }
        guard let token = keyToken,
              let keyCode = extendedKeyCode(for: token) ?? HotkeyRegistry.keyCode(for: token) else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
        else { return false }
        down.flags = flags
        up.flags   = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Scroll in pixel units. Positive dy scrolls UP, positive dx scrolls RIGHT,
    /// matching the natural-scrolling direction users expect.
    @discardableResult
    static func scroll(dx: Int32, dy: Int32) -> Bool {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ) else { return false }
        ev.post(tap: .cgSessionEventTap)
        return true
    }

    /// Extra name→virtual-keycode mappings layered on top of HotkeyRegistry.keyCode(for:).
    /// Names mirror `hs.keycodes.map` (see hammerspoon extensions/keycodes/libkeycodes.m)
    /// so muscle-memory transfers from HS configs. F-keys, navigation cluster, keypad, help.
    ///
    /// NOT included: media (mediaPlay/mediaNext/mediaPrev) and brightness (brightnessUp/Down).
    /// Those are HID Consumer-page events (NX_KEYTYPE_PLAY, NX_KEYTYPE_BRIGHTNESS_UP, …) posted
    /// via NSEvent.otherEvent(.systemDefined, subtype: 8, …), not CGEvent virtual keycodes —
    /// the lookup-table path here can't reach them. Tracked as a separate primitive.
    private static func extendedKeyCode(for token: String) -> UInt32? {
        switch token {
        // Function keys (F1–F20)
        case "f1":  return UInt32(kVK_F1);  case "f2":  return UInt32(kVK_F2)
        case "f3":  return UInt32(kVK_F3);  case "f4":  return UInt32(kVK_F4)
        case "f5":  return UInt32(kVK_F5);  case "f6":  return UInt32(kVK_F6)
        case "f7":  return UInt32(kVK_F7);  case "f8":  return UInt32(kVK_F8)
        case "f9":  return UInt32(kVK_F9);  case "f10": return UInt32(kVK_F10)
        case "f11": return UInt32(kVK_F11); case "f12": return UInt32(kVK_F12)
        case "f13": return UInt32(kVK_F13); case "f14": return UInt32(kVK_F14)
        case "f15": return UInt32(kVK_F15); case "f16": return UInt32(kVK_F16)
        case "f17": return UInt32(kVK_F17); case "f18": return UInt32(kVK_F18)
        case "f19": return UInt32(kVK_F19); case "f20": return UInt32(kVK_F20)
        // Navigation cluster
        case "home":          return UInt32(kVK_Home)
        case "end":           return UInt32(kVK_End)
        case "pageup":        return UInt32(kVK_PageUp)
        case "pagedown":      return UInt32(kVK_PageDown)
        case "forwarddelete": return UInt32(kVK_ForwardDelete)
        case "help":          return UInt32(kVK_Help)
        // Numeric keypad
        case "pad.", "paddecimal":  return UInt32(kVK_ANSI_KeypadDecimal)
        case "pad*", "padmultiply": return UInt32(kVK_ANSI_KeypadMultiply)
        case "pad+", "padplus":     return UInt32(kVK_ANSI_KeypadPlus)
        case "pad/", "paddivide":   return UInt32(kVK_ANSI_KeypadDivide)
        case "pad-", "padminus":    return UInt32(kVK_ANSI_KeypadMinus)
        case "pad=", "padequals":   return UInt32(kVK_ANSI_KeypadEquals)
        case "pad0": return UInt32(kVK_ANSI_Keypad0)
        case "pad1": return UInt32(kVK_ANSI_Keypad1)
        case "pad2": return UInt32(kVK_ANSI_Keypad2)
        case "pad3": return UInt32(kVK_ANSI_Keypad3)
        case "pad4": return UInt32(kVK_ANSI_Keypad4)
        case "pad5": return UInt32(kVK_ANSI_Keypad5)
        case "pad6": return UInt32(kVK_ANSI_Keypad6)
        case "pad7": return UInt32(kVK_ANSI_Keypad7)
        case "pad8": return UInt32(kVK_ANSI_Keypad8)
        case "pad9": return UInt32(kVK_ANSI_Keypad9)
        case "padclear": return UInt32(kVK_ANSI_KeypadClear)
        case "padenter": return UInt32(kVK_ANSI_KeypadEnter)
        default: return nil
        }
    }

    /// Click at a point (in CG coords). button: "left" | "right" | "other".
    @discardableResult
    static func click(x: Double, y: Double, button: String = "left") -> Bool {
        let pt = CGPoint(x: x, y: y)
        let (downT, upT, b): (CGEventType, CGEventType, CGMouseButton)
        switch button {
        case "right": (downT, upT, b) = (.rightMouseDown, .rightMouseUp, .right)
        case "other": (downT, upT, b) = (.otherMouseDown, .otherMouseUp, .center)
        default:      (downT, upT, b) = (.leftMouseDown,  .leftMouseUp,  .left)
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downT, mouseCursorPosition: pt, mouseButton: b),
              let up   = CGEvent(mouseEventSource: nil, mouseType: upT,   mouseCursorPosition: pt, mouseButton: b)
        else { return false }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
