import AppKit
import Carbon.HIToolbox
import CoreGraphics

// Read side of the input-events stream. The write side (EventsSynth) lives
// in EventsSynth.swift, mirroring the Camera.swift / CameraCapture.swift
// split pattern.
//
//   EventTapRegistry — read raw CGEvents (keyDown, mouseDown, scrollWheel,
//     gesture, etc.) via a single shared CGEventTap. Stacks register handlers
//     per CGEventType; each registration returns a Token whose cancel removes
//     just that handler (the tap itself stays alive — installing it requires
//     Accessibility and isn't cheap to repeat).
//
// Gesture decoding lives in its own file because it's a non-trivial AppKit
// post-processor for one specific CGEventType.

// MARK: - Read side: CGEventTap registry

/// Declarative gate evaluated synchronously inside the consuming CGEventTap
/// callback. JS-side per-event decisions would require an async hop into
/// WKWebView (the tap callback must return synchronously — CG drops events
/// after ~1s otherwise), so the manifest expresses the gate as data and the
/// Swift side evaluates it. Fields combine with AND; missing fields are
/// ignored. The consumer's JS callback still fires (async) once a match is
/// confirmed, so the stack sees every consumed event.
struct EventTapPredicate {
    var keyCodes: Set<Int64>?       // matches CGEventField.keyboardEventKeycode
    var flagsMask: UInt64?          // (event.flags.rawValue & flagsMask) == flagsMask
    var flagsAny: UInt64?           // (event.flags.rawValue & flagsAny) != 0
    /// Width of a band around any active display's corner. mouseMoved events
    /// inside the band match. The FrameCorners use case: consume mouseMoved
    /// when the cursor is in a 2 px band around any registered corner.
    var inCornerBand: CGFloat?

    var isEmpty: Bool {
        keyCodes == nil && flagsMask == nil && flagsAny == nil && inCornerBand == nil
    }

    func matches(_ event: CGEvent) -> Bool {
        if let codes = keyCodes {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if !codes.contains(kc) { return false }
        }
        let f = event.flags.rawValue
        if let mask = flagsMask, (f & mask) != mask { return false }
        if let any  = flagsAny,  (f & any)  == 0    { return false }
        if let band = inCornerBand {
            let loc = event.location
            var hit = false
            for screen in NSScreen.screens {
                guard let cgID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
                let b = CGDisplayBounds(cgID)
                let nearLeft   = loc.x >= b.minX && loc.x <= b.minX + band
                let nearRight  = loc.x <= b.maxX - 1 && loc.x >= b.maxX - 1 - band
                let nearTop    = loc.y >= b.minY && loc.y <= b.minY + band
                let nearBottom = loc.y <= b.maxY - 1 && loc.y >= b.maxY - 1 - band
                if (nearLeft || nearRight) && (nearTop || nearBottom) { hit = true; break }
            }
            if !hit { return false }
        }
        return true
    }
}

final class EventTapRegistry {
    static let shared = EventTapRegistry()

    private var handlers: [CGEventType: [Int: (CGEvent) -> Void]] = [:]
    private var nextHandlerId: Int = 1
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var promptShown = false

    // Consuming side — separate non-listenOnly tap, lazily installed on the
    // first registerConsumer() call. Kept distinct from the observer tap so
    // existing passive consumers (timetrail, keypress, gesture, ...) keep
    // their cheap listen-only dispatch path. Inserted head-first so it sees
    // events before the observer tap; returning nil from its callback drops
    // the event before the observer tap (and the rest of the system) ever
    // sees it.
    private struct Consumer {
        let predicate: EventTapPredicate
        let onMatch: (CGEvent) -> Void   // fires async to JS after a match
    }
    private var consumers: [CGEventType: [Int: Consumer]] = [:]
    private var nextConsumerId: Int = 1
    private var consumeTap: CFMachPort?
    private var consumeRunLoopSource: CFRunLoopSource?
    private var consumeMask: CGEventMask = 0

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

    // MARK: - Consume side

    /// Register a declarative consumer. The predicate is evaluated synchronously
    /// inside the CGEventTap callback; on a match the event is dropped (returned
    /// as nil) and `onMatch` fires async into the JS bridge. Predicates that
    /// don't match fall through to the observer tap.
    ///
    /// JS-side decision is intentionally not exposed here. WKWebView dispatch is
    /// async; a CGEventTap callback must return within ~1s or CG disables the
    /// tap, and even at sub-ms latency the answer arrives strictly *after* the
    /// event has been forwarded. If a future stack needs per-event JS gating
    /// (rare — most "swallow X under condition Y" cases are pure predicates),
    /// the escape hatch is a JSContext-backed sync bridge per consuming stack.
    func registerConsumer(eventType: CGEventType,
                          predicate: EventTapPredicate,
                          onMatch: @escaping (CGEvent) -> Void) -> Token? {
        guard ensureConsumeTap(adding: eventType) else { return nil }
        let id = nextConsumerId
        nextConsumerId += 1
        consumers[eventType, default: [:]][id] = Consumer(predicate: predicate, onMatch: onMatch)
        return Token { [weak self] in
            self?.consumers[eventType]?.removeValue(forKey: id)
            if self?.consumers[eventType]?.isEmpty == true {
                self?.consumers.removeValue(forKey: eventType)
            }
        }
    }

    private func ensureConsumeTap(adding eventType: CGEventType) -> Bool {
        // Same Accessibility gate as the observer tap. If we can't install the
        // observer side we can't install the consume side either.
        let bit: UInt64 = 1 << UInt64(eventType.rawValue)
        if consumeTap != nil {
            // Tap already running — re-creating it is the only way to widen its
            // mask. The mask is set once at tapCreate; CG has no "add event
            // type to existing tap" call. If the new type isn't already covered
            // we tear down + reinstall with the union.
            if (consumeMask & bit) != 0 { return true }
            tearDownConsumeTap()
        }

        let trusted: Bool = {
            let opts: [String: Bool] = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !promptShown
            ]
            promptShown = true
            return AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }()
        guard trusted else {
            log("Accessibility not granted; consuming CGEventTap disabled")
            return false
        }

        let newMask = consumeMask | bit
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { (_, type, event, ctx) in
            guard let ctx = ctx else { return Unmanaged.passUnretained(event) }
            let registry = Unmanaged<EventTapRegistry>.fromOpaque(ctx).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = registry.consumeTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return registry.dispatchConsume(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,        // non-listenOnly: returning nil drops the event
            eventsOfInterest: newMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            log("CGEvent.tapCreate (consume) failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        self.consumeTap = newTap
        self.consumeRunLoopSource = source
        self.consumeMask = newMask
        log("CGEventTap (consume) installed mask=\(String(newMask, radix: 16))")
        return true
    }

    private func tearDownConsumeTap() {
        if let src = consumeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let t = consumeTap {
            CGEvent.tapEnable(tap: t, enable: false)
        }
        consumeTap = nil
        consumeRunLoopSource = nil
        // consumeMask retained intentionally — ensureConsumeTap re-uses it as
        // the lower bound when widening for a new event type.
    }

    private func dispatchConsume(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let snap = consumers[type] else { return Unmanaged.passUnretained(event) }
        var matched = false
        // Same snapshot-then-iterate discipline as dispatch(). A consumer whose
        // onMatch synchronously unregistered itself would mutate consumers[type]
        // mid-iteration otherwise.
        for c in Array(snap.values) {
            if c.predicate.matches(event) {
                matched = true
                c.onMatch(event)
            }
        }
        if matched { return nil }       // drop
        return Unmanaged.passUnretained(event)
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

// MARK: - Write side
// EventsSynth lives in EventsSynth.swift.
