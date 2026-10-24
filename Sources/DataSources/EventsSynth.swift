import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: ============================================================
// MARK: EventsSynth — synthesize keys/clicks/scrolls (write side)
// MARK: ============================================================

// Write side of the input-events stream.
//
// EventsSynth — type a string, fire a key combo, scroll, click. Posts
// CGEvents to the session tap so they target the user's foreground app.
// Reuses HotkeyRegistry's keycode map for chord parsing.

enum EventsSynth {
    /// Stamped into `eventSourceUserData` of every event stackd posts, so a
    /// tap (stackd's own included) can tell them from the user's input.
    static let marker: Int64 = 0x7374_6B64 // "stkd"

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Inject arbitrary text — works regardless of keyboard layout, doesn't
    /// require mapping each character to a virtual key. Uses CGEvent's
    /// keyboardSetUnicodeString.
    static func type(_ s: String) {
        send(typeEvents(s))
    }

    /// Fire a key combo like "cmd+v" or "ctrl+alt+space".
    @discardableResult
    static func key(_ spec: String) -> Bool {
        guard let events = keyEvents(spec) else { return false }
        send(events)
        return true
    }

    /// Scroll in pixel units. Positive dy scrolls UP, positive dx scrolls RIGHT,
    /// matching the natural-scrolling direction users expect.
    @discardableResult
    static func scroll(dx: Int32, dy: Int32) -> Bool {
        guard let events = scrollEvents(dx: dx, dy: dy) else { return false }
        send(events)
        return true
    }

    /// Click at a point (in CG coords). button: "left" | "right" | "other".
    @discardableResult
    static func click(x: Double, y: Double, button: String = "left") -> Bool {
        guard let events = clickEvents(x: x, y: y, button: button) else { return false }
        send(events)
        return true
    }

    // MARK: - Builders: the marked events each verb posts, in order

    static func typeEvents(_ s: String) -> [CGEvent] {
        let utf16 = Array(s.utf16)
        return utf16.withUnsafeBufferPointer { buf -> [CGEvent] in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return [] }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            return marked([down, up])
        }
    }

    /// nil when the spec names no key.
    static func keyEvents(_ spec: String) -> [CGEvent]? {
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
              let keyCode = HotkeyRegistry.keyCode(for: token),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
        else { return nil }
        down.flags = flags
        up.flags   = flags
        return marked([down, up])
    }

    static func scrollEvents(dx: Int32, dy: Int32) -> [CGEvent]? {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ) else { return nil }
        return marked([ev])
    }

    static func clickEvents(x: Double, y: Double, button: String) -> [CGEvent]? {
        let pt = CGPoint(x: x, y: y)
        let (downT, upT, b): (CGEventType, CGEventType, CGMouseButton)
        switch button {
        case "right": (downT, upT, b) = (.rightMouseDown, .rightMouseUp, .right)
        case "other": (downT, upT, b) = (.otherMouseDown, .otherMouseUp, .center)
        default:      (downT, upT, b) = (.leftMouseDown,  .leftMouseUp,  .left)
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downT, mouseCursorPosition: pt, mouseButton: b),
              let up   = CGEvent(mouseEventSource: nil, mouseType: upT,   mouseCursorPosition: pt, mouseButton: b)
        else { return nil }
        return marked([down, up])
    }

    private static func marked(_ events: [CGEvent]) -> [CGEvent] {
        for e in events { e.setIntegerValueField(.eventSourceUserData, value: marker) }
        return events
    }

    private static func send(_ events: [CGEvent]) {
        for e in events { e.post(tap: .cgSessionEventTap) }
    }
}
