import AppKit
import Carbon.HIToolbox
import CoreGraphics

// Two halves of the same input-events stream:
//
//   EventTapRegistry — read raw CGEvents (keyDown, mouseDown, scrollWheel,
//     gesture, etc.) via a single shared CGEventTap. Stacks register handlers
//     per CGEventType; each registration returns a Token whose cancel removes
//     just that handler (the tap itself stays alive — installing it requires
//     Accessibility and isn't cheap to repeat).
//
//   EventsSynth — write side. Type a string, fire a key combo, scroll, click.
//     Posts CGEvents to the session tap so they target the user's foreground
//     app. Reuses HotkeyRegistry's keycode map for chord parsing.
//
// Gesture decoding lives in its own file because it's a non-trivial AppKit
// post-processor for one specific CGEventType.

// MARK: - Read side: CGEventTap registry

final class EventTapRegistry {
    static let shared = EventTapRegistry()

    private var handlers: [CGEventType: [Int: (CGEvent) -> Void]] = [:]
    private var nextHandlerId: Int = 1
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var promptShown = false

    private init() {}

    // Returns false if Accessibility isn't granted. Idempotent.
    @discardableResult
    func ensureTap() -> Bool {
        if tap != nil { return true }

        let trusted: Bool = {
            // Only prompt once per process; otherwise repeated calls spam.
            let opts: [String: Bool] = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !promptShown
            ]
            promptShown = true
            return AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }()

        guard trusted else {
            log("Accessibility not granted; CGEventTap disabled")
            return false
        }

        // Private gesture event type (NSEventTypeGesture = 29). See Gesture.swift.
        let gestureBit: UInt64 = 1 << UInt64(Gesture.cgEventType.rawValue)
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            gestureBit

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { (_, type, event, ctx) in
            guard let ctx = ctx else { return Unmanaged.passUnretained(event) }
            // Re-enable tap if disabled by timeout / user input
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let registry = Unmanaged<EventTapRegistry>.fromOpaque(ctx).takeUnretainedValue()
                if let t = registry.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let registry = Unmanaged<EventTapRegistry>.fromOpaque(ctx).takeUnretainedValue()
            registry.dispatch(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            log("CGEvent.tapCreate failed (Accessibility likely)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        self.tap = newTap
        self.runLoopSource = source
        log("CGEventTap installed")
        return true
    }

    // Returns nil if Accessibility is denied (no tap installed). Caller adopts
    // the Token into their StackScope; cancel removes just this handler. The
    // CGEventTap itself stays installed once created — cheaper than tearing
    // down + reinstalling on every stack reload.
    func register(eventType: CGEventType, handler: @escaping (CGEvent) -> Void) -> Token? {
        guard ensureTap() else { return nil }
        let id = nextHandlerId
        nextHandlerId += 1
        handlers[eventType, default: [:]][id] = handler
        return Token { [weak self] in
            self?.handlers[eventType]?.removeValue(forKey: id)
            if self?.handlers[eventType]?.isEmpty == true {
                self?.handlers.removeValue(forKey: eventType)
            }
        }
    }

    private func dispatch(type: CGEventType, event: CGEvent) {
        // Run loop source is on main; we're already main here.
        // Snapshot first: a handler that synchronously unregisters its own
        // Token (or triggers a stack unload whose scope drain cancels another
        // handler for the same eventType) would mutate handlers[type] mid-
        // iteration — undefined behavior in Swift.
        guard let snap = handlers[type] else { return }
        for cb in Array(snap.values) { cb(event) }
    }

    // MARK: - String ↔ CGEventType

    static func parse(_ name: String) -> CGEventType? {
        switch name {
        case "keyDown":         return .keyDown
        case "keyUp":           return .keyUp
        case "flagsChanged":    return .flagsChanged
        case "leftMouseDown":     return .leftMouseDown
        case "rightMouseDown":    return .rightMouseDown
        case "otherMouseDown":    return .otherMouseDown
        case "leftMouseDragged":  return .leftMouseDragged
        case "rightMouseDragged": return .rightMouseDragged
        case "mouseMoved":        return .mouseMoved
        case "scrollWheel":     return .scrollWheel
        case "gesture":         return Gesture.cgEventType
        default: return nil
        }
    }

    static func name(for type: CGEventType) -> String {
        switch type {
        case .keyDown:         return "keyDown"
        case .keyUp:           return "keyUp"
        case .flagsChanged:    return "flagsChanged"
        case .leftMouseDown:     return "leftMouseDown"
        case .rightMouseDown:    return "rightMouseDown"
        case .otherMouseDown:    return "otherMouseDown"
        case .leftMouseDragged:  return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .mouseMoved:        return "mouseMoved"
        case .scrollWheel:     return "scrollWheel"
        default:
            if type.rawValue == Gesture.cgEventType.rawValue { return "gesture" }
            return "unknown"
        }
    }
}

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
