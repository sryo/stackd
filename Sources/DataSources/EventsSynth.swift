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
              let keyCode = HotkeyRegistry.keyCode(for: token) else { return false }
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
