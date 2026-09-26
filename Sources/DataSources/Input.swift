import AppKit
import ApplicationServices
import Carbon
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit

// MARK: ============================================================
// MARK: Input — keyboard layout (TIS)
// MARK: ============================================================

enum Input {
    static func currentLayout() -> [String: Any] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ["name": NSNull(), "id": NSNull()]
        }
        let name = cfStringProp(source, kTISPropertyLocalizedName) ?? ""
        let id   = cfStringProp(source, kTISPropertyInputSourceID) ?? ""
        return ["name": name, "id": id]
    }

    private static func cfStringProp(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

final class InputObserver: RefCountedObserver {
    static let shared = InputObserver()
    private override init() { super.init() }

    override func install() -> Token {
        // TIS notifications are CFNotifications via the local distributed center.
        return installNotifications([
            (DistributedNotificationCenter.default(),
             NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
        ])
    }
}

// MARK: ============================================================
// MARK: InputAX — curated AX reader/setters for the focused text element
// MARK: ============================================================

// Curated AX surface for "whatever has keyboard focus right now." Replaces
// the five-call sd.ax.* dance (focused → attribute → parameterizedAttribute →
// release) muse, palette, and text-expander stacks were doing for every
// transformation tick. System-wide focused element, 100ms messaging timeout
// (matches Apps.menu pattern), all reads/writes hop to main via Bridge's
// `.ax` dispatch — AX traffic deadlocks under cross-thread access.
//
// Coordinate convention: AX returns screen-points (top-left origin), same
// space sd.windows.byId.frame / sd.mouse.location report. No Y-flip.
//
// Known-slow apps (kAXSelectedTextAttribute returns nothing): Safari /
// Mail / Firefox WebViews. The reader still returns `text` + `selectedRange`
// in those cases, just with `selectedText` as the empty string.

enum InputAX {
    /// System-wide focused element snapshot. Returns nil when no AX-text
    /// element has focus (e.g. focus is on a button, or no app is frontmost).
    ///
    /// Shape:
    ///   { text, selectedText, selectedRange: {location, length},
    ///     caretRect: {x, y, w, h} | null,
    ///     role, subrole, value, pid, app }
    static func focusedText() -> [String: Any]? {
        guard let el = focusedElement() else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)

        let role    = stringAttr(el, kAXRoleAttribute) ?? ""
        let subrole = stringAttr(el, kAXSubroleAttribute) ?? ""
        let value   = stringAttr(el, kAXValueAttribute) ?? ""

        // selectedText is the substring the user has highlighted; absent or
        // empty when there's just a caret. WebViews (Safari/Mail/Firefox)
        // commonly leave this unset even when AXValue is populated.
        let selectedText = stringAttr(el, kAXSelectedTextAttribute) ?? ""

        var selectedRange: [String: Int] = ["location": 0, "length": 0]
        var caretRect: Any = NSNull()
        if let range = rangeAttr(el, kAXSelectedTextRangeAttribute) {
            selectedRange = ["location": range.location, "length": range.length]
            if let bounds = boundsForRange(el, range: range) {
                caretRect = [
                    "x": Double(bounds.origin.x),
                    "y": Double(bounds.origin.y),
                    "w": Double(bounds.size.width),
                    "h": Double(bounds.size.height)
                ] as [String: Double]
            }
        }

        // Resolve owning app via NSWorkspace.frontmost rather than walking
        // AXParent — the parent chain can be deep (input field → group → …
        // → AXApplication) and frontmostApplication is exact for "what app
        // owns the focused element" the same way HS's
        // hs.application.frontmostApplication() reports.
        let front = NSWorkspace.shared.frontmostApplication
        let pid: Int = front.map { Int($0.processIdentifier) } ?? 0
        let app: String = front?.localizedName ?? ""

        return [
            "text":          value,
            "selectedText":  selectedText,
            "selectedRange": selectedRange,
            "caretRect":     caretRect,
            "role":          role,
            "subrole":       subrole,
            "value":         value,
            "pid":           pid,
            "app":           app
        ]
    }

    /// Replace the current selection in the focused element with `value`.
    /// If there's no selection (just a caret), `value` is inserted at the
    /// caret. Returns false when there's no focused text element or the
    /// element rejects the write (kAXValueAttribute isn't settable on
    /// readonly fields — `selectedText` write fails silently in WebViews).
    @discardableResult
    static func setSelectedText(_ value: String) -> Bool {
        guard let el = focusedElement() else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, value as CFString) == .success
    }

    /// Move the selection (and caret) in the focused element. `length` 0
    /// places a caret at `location`; positive `length` selects the range.
    /// Returns false when there's no focused element or the field doesn't
    /// support kAXSelectedTextRangeAttribute.
    @discardableResult
    static func setSelectedRange(location: Int, length: Int) -> Bool {
        guard let el = focusedElement() else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        var range = CFRange(location: location, length: length)
        guard let axVal = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axVal) == .success
    }

    // MARK: - Internals

    /// System-wide AXFocusedUIElement (vs AX.focusedElement which goes
    /// frontmost-app → focused). System-wide handles edge cases where
    /// focus lives in a service window or accessibility-inspector style
    /// element that doesn't belong to NSWorkspace.frontmost.
    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let focused = ref else { return nil }
        // swiftlint:disable:next force_cast
        return (focused as! AXUIElement)
    }

    private static func stringAttr(_ el: AXUIElement, _ key: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func rangeAttr(_ el: AXUIElement, _ key: String) -> CFRange? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success,
              let value = ref else { return nil }
        // swiftlint:disable:next force_cast
        let axVal = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        return range
    }

    private static func boundsForRange(_ el: AXUIElement, range: CFRange) -> CGRect? {
        var inputRange = range
        guard let inputVal = AXValueCreate(.cfRange, &inputRange) else { return nil }
        var ref: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, inputVal, &ref)
        guard err == .success, let value = ref else { return nil }
        // swiftlint:disable:next force_cast
        let axVal = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axVal, .cgRect, &rect) else { return nil }
        return rect
    }
}

// MARK: ============================================================
// MARK: Mouse — pointer location + warp (read side)
// MARK: ============================================================

/// Fires on every CGEvent mouse move — event-driven, not polled, so idle
/// CPU is zero and active movement updates at the event rate rather than a
/// fixed poll ceiling.
///
/// Lazy: the CGEventTap handler is installed on first subscribe and removed
/// when the last unsubscribes (after the 5s debounce). The shared eventtap
/// itself stays — uninstalling it would force re-prompting for Accessibility.
final class MouseObserver: RefCountedObserver {
    static let shared = MouseObserver()
    private override init() { super.init() }

    override func install() -> Token? {
        // Returns nil when EventTapRegistry can't install (Accessibility
        // denied). The base class will retry on the next subscribe — so a
        // stack that's already subscribed when the user grants Accessibility
        // wakes up the moment the next signal subscribe arrives (or just
        // toggles itself off+on).
        return EventTapRegistry.shared.register(eventType: .mouseMoved) { [weak self] _, _ in
            self?.fire()
        }
    }
}

enum Mouse {
    // Cached primary screen height (for AppKit→CG Y-flip). Invalidates on screen change.
    private static var cachedPrimaryHeight: CGFloat?
    private static var screenChangeObserver: NSObjectProtocol? = {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in cachedPrimaryHeight = nil }
    }()

    static func isLeftButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    static func location() -> CGPoint {
        _ = screenChangeObserver
        let appkit = NSEvent.mouseLocation
        if cachedPrimaryHeight == nil {
            cachedPrimaryHeight = NSScreen.screens.first?.frame.size.height
        }
        guard let h = cachedPrimaryHeight else { return appkit }
        return CGPoint(x: appkit.x, y: h - appkit.y)
    }

    /// Move the cursor without clicking (CGWarpMouseCursorPosition). The
    /// missing primitive next to sd.events.click — a stack composing
    /// behaviors like mouse-follows-focus or radial gesture menus needs to
    /// move the cursor independently of a click.
    ///
    /// Coordinates are top-left origin (the same space CGWindowList /
    /// sd.windows.focused().frame report), matching every other geometry
    /// surface stackd exposes.
    @discardableResult
    static func warp(x: Double, y: Double) -> Bool {
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        // Re-associate cursor with input after a warp — macOS otherwise
        // applies a ~250ms suppression window where trackpad/mouse motion
        // doesn't move the cursor.
        CGAssociateMouseAndMouseCursorPosition(1)
        return true
    }
}

// MARK: ============================================================
// MARK: Cursor — write-side warp with display-local coords
// MARK: ============================================================

// Write-side counterpart to sd.mouse: warp the cursor. CGWarpMouseCursorPosition
// takes top-left global screen coordinates, same convention every other sd.*
// xy field uses (Mouse.location flips NSEvent.mouseLocation for the same
// reason). No event is synthesized — consumers that need a synthetic move
// for hit-testing should follow with sd.events.click at the same point.
//
// Consumers — EdgeHopper: wrap the cursor to the opposite edge of the focused
// display once the user "punches through". CloudPad: replaces the JXA
// CGWarpMouseCursorPosition shim under the pointer-mode continuous-move path
// (one Apple Event per move becomes one in-process CG call).

enum Cursor {
    /// `display` is an optional CGDirectDisplayID; if provided, (x, y) are
    /// interpreted as display-local point coordinates. Otherwise they're
    /// global (top-left of the primary screen = 0, 0).
    @discardableResult
    static func setPosition(x: Double, y: Double, display: CGDirectDisplayID?) -> Bool {
        var gx = CGFloat(x)
        var gy = CGFloat(y)
        if let id = display {
            let b = CGDisplayBounds(id)
            gx += b.origin.x
            gy += b.origin.y
        }
        let err = CGWarpMouseCursorPosition(CGPoint(x: gx, y: gy))
        // Re-associate the mouse to the new cursor position. Without this,
        // there's a ~250ms window where hardware moves are blended into the
        // warp target — visible as a "snap, then drift" under rapid warps.
        CGAssociateMouseAndMouseCursorPosition(1)
        return err == .success
    }

    /// Top-left global coords, same shape as the `mouse` channel.
    static func position() -> [String: Int] {
        let p = Mouse.location()
        return ["x": Int(p.x), "y": Int(p.y)]
    }
}

// MARK: ============================================================
// MARK: Events — CGEventTap read side + consume side
// MARK: ============================================================

// Read side of the input-events stream. The write side (EventsSynth) lives
// further below in this file, mirroring the Camera.swift / CameraCapture.swift
// split pattern.
//
//   EventTapRegistry — read raw CGEvents (keyDown, mouseDown, scrollWheel,
//     gesture, etc.) via a single shared CGEventTap. Stacks register handlers
//     per CGEventType; each registration returns a Token whose cancel removes
//     just that handler (the tap itself stays alive — installing it requires
//     Accessibility and isn't cheap to repeat).
//
// Gesture decoding lives further below — it's a non-trivial AppKit
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

    var isEmpty: Bool {
        keyCodes == nil && flagsMask == nil && flagsAny == nil
    }

    func matches(_ event: CGEvent) -> Bool {
        if let codes = keyCodes {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if !codes.contains(kc) { return false }
        }
        let f = event.flags.rawValue
        if let mask = flagsMask, (f & mask) != mask { return false }
        if let any  = flagsAny,  (f & any)  == 0    { return false }
        return true
    }
}

final class EventTapRegistry {
    static let shared = EventTapRegistry()

    // Observer handler with optional rect-gate key. nil key → no gate
    // (fires on every event of the type — original observer behavior).
    // Non-nil key looks up the same rectsByKey table consumers use, so
    // sd.events.setTapRects(callback, rects) gates both consume and observe
    // taps under the same `"<stackId>:<callback>"` key.
    //
    // `emitLeave` opts the handler into transition-aware dispatch (see
    // `rectGateTransition` below). When true, the handler is invoked with
    // `phase ∈ {"enter","move","leave"}` so JS-side state machines
    // (framemaster's hot corners) can drop polling sd.mouse at 30Hz.
    // When false (default), the handler is invoked with `phase == nil` and
    // gating follows the original "fire only when inside" semantics — no
    // payload field added, no behavior change for existing stacks.
    private struct ObserverHandler {
        let key: String?
        let emitLeave: Bool
        let fn: (CGEvent, String?) -> Void
    }
    private var handlers: [CGEventType: [Int: ObserverHandler]] = [:]
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
        let key: String                  // "\(stackId):\(callback)" — rectsAny lookup
        let onMatch: (CGEvent) -> Void   // fires async to JS after a match
    }
    private var consumers: [CGEventType: [Int: Consumer]] = [:]
    private var nextConsumerId: Int = 1
    private var consumeTap: CFMachPort?
    private var consumeRunLoopSource: CFRunLoopSource?
    private var consumeMask: CGEventMask = 0

    // Per-consumer cursor-rect gate. Keyed by Consumer.key. nil → no gate
    // (consume on predicate alone, original behavior). [] → empty gate
    // (consumer never matches — useful for "buttons not visible right now").
    // Non-empty → consume only when event location falls in any rect.
    // Mutated synchronously by Bridge via setConsumerRects so the predicate
    // can adapt to runtime state (windowscape pushes traffic-light rects on
    // focus change + drag-bracket close, then clears on display change).
    private var rectsByKey: [String: [CGRect]] = [:]

    // Per-key "was the cursor inside the gate at the previous event?" state,
    // used only by emitLeave-opted observer handlers. Tracked here (not in
    // the handler struct) because the state is per-rect-key — multiple
    // handlers under the same key share the same inside/outside answer.
    // Reset to false when the rects are cleared so a re-arm starts cold.
    private var insideByKey: [String: Bool] = [:]

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

        // Private gesture event type (NSEventTypeGesture = 29). See Gesture below.
        let gestureBit: UInt64 = 1 << UInt64(Gesture.cgEventType.rawValue)
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
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
    //
    // `emitLeave` requires `key != nil` (the leave is keyed off the rect
    // gate's inside/outside transition). Passing emitLeave with a nil key
    // is silently treated as false — without a rect gate, "leave" has no
    // boundary to fire against. The handler receives `phase` as a String?
    // — nil in the original observer mode, a phase name when emitLeave is
    // active. Bridge maps phase → a `phase` field in the JS payload.
    func register(eventType: CGEventType,
                  key: String? = nil,
                  emitLeave: Bool = false,
                  handler: @escaping (CGEvent, String?) -> Void) -> Token? {
        guard ensureTap() else { return nil }
        let id = nextHandlerId
        nextHandlerId += 1
        let effectiveEmitLeave = emitLeave && key != nil
        handlers[eventType, default: [:]][id] = ObserverHandler(
            key: key, emitLeave: effectiveEmitLeave, fn: handler)
        return Token { [weak self] in
            self?.handlers[eventType]?.removeValue(forKey: id)
            if self?.handlers[eventType]?.isEmpty == true {
                self?.handlers.removeValue(forKey: eventType)
            }
            if let key = key {
                self?.rectsByKey.removeValue(forKey: key)
                self?.insideByKey.removeValue(forKey: key)
            }
        }
    }

    /// Pure rect-gate predicate shared by the observe and consume paths.
    /// `rects == nil`  → no gate registered → always allow.
    /// `rects == []`   → empty gate (suppress until JS pushes real rects) → reject.
    /// `rects.count>0` → allow only when the event location is inside any rect.
    static func rectGateAllows(rects: [CGRect]?, point p: CGPoint) -> Bool {
        guard let rects = rects else { return true }
        for r in rects where r.contains(p) { return true }
        return false
    }

    /// Pure transition computation for emitLeave-opted observer handlers.
    /// Combines the inside-test with the wasInside state to classify the
    /// event into one of {enter, move, leave, suppressed}. Kept pure and
    /// static so the same logic that runs inside the CGEventTap callback
    /// can be unit-tested without installing a tap (which needs
    /// Accessibility TCC and a live run loop).
    ///
    /// Semantics:
    ///   - `rects == nil`  → no gate; degenerate case (caller should have
    ///                       set `emitLeave = false` since there's no
    ///                       boundary to transition against). Returns
    ///                       (fire: true, phase: "move", nowInside: true)
    ///                       so the handler still gets the event with a
    ///                       consistent shape, but no enter/leave is ever
    ///                       synthesized.
    ///   - `rects == []`   → empty gate; reject in BOTH directions. No
    ///                       phase, no fire — the same boot-state behavior
    ///                       as the plain rectGateAllows path. Resets
    ///                       wasInside to false so a later re-population
    ///                       of rects starts cold.
    ///   - point in rects, wasInside == false → enter (rising edge).
    ///   - point in rects, wasInside == true  → move (continuation).
    ///   - point NOT in rects, wasInside == true  → leave (falling edge).
    ///   - point NOT in rects, wasInside == false → suppress.
    ///
    /// `nowInside` is the bookkeeping value the caller stores into
    /// `insideByKey[key]` after firing — exposed in the tuple so the
    /// dispatcher doesn't have to recompute the contains() check.
    static func rectGateTransition(
        rects: [CGRect]?, point p: CGPoint, wasInside: Bool
    ) -> (fire: Bool, phase: String?, nowInside: Bool) {
        guard let rects = rects else {
            // Degenerate — caller shouldn't have emitLeave on without a
            // gate. Treat as a plain move so the handler still sees the
            // event and JS code paths don't crash on a missing phase.
            return (true, "move", true)
        }
        if rects.isEmpty {
            // Empty gate suppresses in both directions. Reset wasInside
            // so a subsequent gate population doesn't accidentally fire
            // "leave" on the first outside event.
            return (false, nil, false)
        }
        var inside = false
        for r in rects where r.contains(p) { inside = true; break }
        switch (wasInside, inside) {
        case (false, true):  return (true,  "enter", true)
        case (true,  true):  return (true,  "move",  true)
        case (true,  false): return (true,  "leave", false)
        case (false, false): return (false, nil,     false)
        }
    }

    private func observerGateAllows(key: String?, event: CGEvent) -> Bool {
        guard let key = key else { return true }
        return EventTapRegistry.rectGateAllows(rects: rectsByKey[key], point: event.location)
    }

    private func dispatch(type: CGEventType, event: CGEvent) {
        // Run loop source is on main; we're already main here.
        // Snapshot first: a handler that synchronously unregisters its own
        // Token (or triggers a stack unload whose scope drain cancels another
        // handler for the same eventType) would mutate handlers[type] mid-
        // iteration — undefined behavior in Swift.
        guard let snap = handlers[type] else { return }
        for h in Array(snap.values) {
            if h.emitLeave, let key = h.key {
                // Transition path — fires on enter/move/leave per the
                // rectGateTransition contract. The leave fire is the
                // important one: it's the only way the handler hears
                // about an event that lands OUTSIDE the gate (when the
                // previous event was inside). Bookkeeping is centralized
                // in insideByKey because multiple handlers under the
                // same rect-gate key must share inside/outside truth.
                let prev = insideByKey[key] ?? false
                let (fire, phase, nowInside) = EventTapRegistry.rectGateTransition(
                    rects: rectsByKey[key], point: event.location, wasInside: prev)
                if nowInside != prev { insideByKey[key] = nowInside }
                if !fire { continue }
                h.fn(event, phase)
            } else {
                if !observerGateAllows(key: h.key, event: event) { continue }
                h.fn(event, nil)
            }
        }
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
                          key: String,
                          onMatch: @escaping (CGEvent) -> Void) -> Token? {
        guard ensureConsumeTap(adding: eventType) else { return nil }
        let id = nextConsumerId
        nextConsumerId += 1
        consumers[eventType, default: [:]][id] = Consumer(predicate: predicate, key: key, onMatch: onMatch)
        return Token { [weak self] in
            self?.consumers[eventType]?.removeValue(forKey: id)
            if self?.consumers[eventType]?.isEmpty == true {
                self?.consumers.removeValue(forKey: eventType)
            }
            self?.rectsByKey.removeValue(forKey: key)
        }
    }

    /// Update (or clear) the cursor-rect gate for a consumer key.
    /// - `rects = nil`  → no gate; predicate decides alone (default).
    /// - `rects = []`   → empty gate; consumer never matches.
    /// - `rects = [..]` → consume only when CGEvent location is in any rect.
    /// Coordinates are top-left origin global screen coords, same space as
    /// `sd.windows.byId.frame` / `sd.windows.byId.buttonFrames`.
    func setConsumerRects(key: String, rects: [CGRect]?) {
        if let r = rects { rectsByKey[key] = r }
        else { rectsByKey.removeValue(forKey: key) }
        // Clear the transition bookkeeping — any wasInside state held
        // against the OLD rects is meaningless against the new set, and
        // would otherwise let the next event fire a spurious "leave" /
        // skip an "enter". Cheaper to reset than to recompute against
        // both old and new rects at the cursor's current position.
        insideByKey.removeValue(forKey: key)
    }

    /// Test/inspection accessor for the cursor-rect gate. nil = no gate set.
    func rectsForKey(_ key: String) -> [CGRect]? { rectsByKey[key] }

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
            if !c.predicate.matches(event) { continue }
            // Optional rect-any gate. nil → no gate (consume on predicate).
            // Empty array → never matches (callers use this to temporarily
            // suppress a consumer without unregistering it).
            if let rects = rectsByKey[c.key] {
                if rects.isEmpty { continue }
                let loc = event.location
                if !rects.contains(where: { $0.contains(loc) }) { continue }
            }
            matched = true
            c.onMatch(event)
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
        case "leftMouseUp":       return .leftMouseUp
        case "rightMouseDown":    return .rightMouseDown
        case "rightMouseUp":      return .rightMouseUp
        case "otherMouseDown":    return .otherMouseDown
        case "otherMouseUp":      return .otherMouseUp
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
        case .leftMouseUp:       return "leftMouseUp"
        case .rightMouseDown:    return "rightMouseDown"
        case .rightMouseUp:      return "rightMouseUp"
        case .otherMouseDown:    return "otherMouseDown"
        case .otherMouseUp:      return "otherMouseUp"
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

// MARK: ============================================================
// MARK: EventsSynth — synthesize keys/clicks/scrolls (write side)
// MARK: ============================================================

// Write side of the input-events stream.
//
// EventsSynth — type a string, fire a key combo, scroll, click. Posts
// CGEvents to the session tap so they target the user's foreground app.
// Reuses HotkeyRegistry's keycode map for chord parsing.

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

// MARK: ============================================================
// MARK: TouchDevice — raw MultitouchSupport per-finger frames
// MARK: ============================================================

// Raw per-finger trackpad frames via the private MultitouchSupport.framework.
// Port of asmagill's hs._asm.undocumented.touchdevice. The framework fires its
// contact-frame callback (~90 Hz while a finger is down) on a private thread
// with every finger's stable identity, normalized position, velocity,
// pressure, angle, and ellipsoid axes — strictly BELOW the layer where
// AppKit recognizes "swipe"/"pinch"/"rotate" gestures.
//
// Event-driven delivery: the callback copies each frame into compact
// TouchFrame structs and offers them to a lock-guarded TouchFrameMailbox.
// The first offer of a burst schedules exactly one main-thread drain; the
// drain pushes every pending frame to subscribers. There is no poll: while
// the main thread is busy, consecutive "changed" frames with the same finger
// count merge (newest wins) and began/ended edges queue behind them, so a
// slow main thread costs intermediate positions, never a touch or release.
// The only timer is the lift watchdog, armed only while a finger is down:
// when no frame arrives for 120ms it synthesizes a release, so consumers
// never see a stuck finger after a device drops its final empty frame.

enum TouchDevice {
    /// Latest emitted frame payload, or nil if no frame has arrived yet
    /// (e.g. trackpad untouched since install). Used by Bridge for replay.
    static func snapshot() -> [String: Any]? {
        return TouchDeviceObserver.shared.latestFrame()
    }
}

/// One finger in a MultitouchSupport contact frame. `stage` is the raw
/// MTPathStage value; floats stay Float to keep the MT-thread copy small.
struct TouchContact: Equatable {
    var id: Int32
    var stage: Int32
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var angle: Float
    var size: Float
    var pressure: Float
    var majorAxis: Float
    var minorAxis: Float
}

/// One contact frame from one device. `timestamp` is the framework's
/// seconds-since-boot stamp (the mach uptime clock). `synthetic` marks a
/// release the lift watchdog made up.
struct TouchFrame: Equatable {
    var device: UInt64
    var timestamp: Double
    var frame: Int
    var touches: [TouchContact]
    var synthetic: Bool = false

    /// MTPathStage → consumer-friendly state name. MakeTouch=began,
    /// Touching=moved, BreakTouch=ended, OutOfRange=lifted,
    /// HoverInRange=stationary; the rare StartInRange/LingerInRange
    /// transients bucket with their closest neighbor.
    static func stateName(_ stage: Int32) -> String {
        switch stage {
        case 3: return "began"        // MakeTouch
        case 4: return "moved"        // Touching
        case 5: return "ended"        // BreakTouch
        case 7: return "lifted"       // OutOfRange
        case 2: return "stationary"   // HoverInRange
        case 1: return "began"        // StartInRange
        case 6: return "stationary"   // LingerInRange
        default: return "cancelled"   // NotTracking + unknown
        }
    }

    /// Stages that start or end a finger. A frame holding one is an edge the
    /// mailbox never merges away.
    static func isEdgeStage(_ stage: Int32) -> Bool {
        stage != 2 && stage != 4 && stage != 6
    }

    /// The sd.touchdevice payload. `ageMs` is how long ago the hardware
    /// stamped the frame (null when the clocks disagree), and `emittedAt` is
    /// the epoch-ms wall clock at emit, so a stack can add its own delivery
    /// lag: `ageMs + (performance.timeOrigin + performance.now() - emittedAt)`.
    static func payload(_ f: TouchFrame, uptimeNow: Double, epochMsNow: Double) -> [String: Any] {
        var touches: [[String: Any]] = []
        touches.reserveCapacity(f.touches.count)
        for t in f.touches {
            touches.append([
                "identifier": Int(t.id),
                "state":      stateName(t.stage),
                "x":          Double(t.x),
                "y":          Double(t.y),
                "vx":         Double(t.vx),
                "vy":         Double(t.vy),
                "angle":      Double(t.angle),
                "size":       Double(t.size),
                "pressure":   Double(t.pressure),
                "majorAxis":  Double(t.majorAxis),
                "minorAxis":  Double(t.minorAxis)
            ])
        }
        let age = (uptimeNow - f.timestamp) * 1000
        var p: [String: Any] = [
            "timestamp": f.timestamp,
            "frame":     f.frame,
            "device":    f.device,
            "touches":   touches,
            "emittedAt": epochMsNow,
            "ageMs":     (age >= 0 && age < 10_000) ? age as Any : NSNull()
        ]
        if f.synthetic { p["synthetic"] = true }
        return p
    }
}

/// Hand-off between the MultitouchSupport callback thread and the main-thread
/// drain. All state sits behind one lock; `offer` runs on the MT thread,
/// `take` and `checkWatchdog` on main. Times passed as `now` must share one
/// monotonic clock (the observer uses ProcessInfo.systemUptime).
///
/// Policy per offered frame:
///   - an empty frame while the device is already idle is dropped;
///   - a frame is an edge when its finger count differs from the device's
///     last accepted frame or any finger is in a starting/ending stage;
///   - a non-edge frame within 0.0005 (normalized units) of the last
///     accepted frame is dropped as sensor jitter;
///   - a non-edge frame replaces a pending non-edge frame of the same device
///     and finger count at the tail of the queue; otherwise it is appended;
///   - past `capacity`, the oldest non-edge frame is evicted first.
/// `offer` returns true only for the offer that must schedule a drain; later
/// offers ride that drain until `take` runs.
final class TouchFrameMailbox {
    enum Watchdog: Equatable {
        case idle
        case rearm(at: Double)
        case fired
    }

    private struct Pending {
        var frame: TouchFrame
        var isEdge: Bool
    }

    private struct DeviceState {
        var lastAccepted: TouchFrame?
        var lastOfferAt: Double = 0
        var touching: Bool { !(lastAccepted?.touches.isEmpty ?? true) }
    }

    private let lock = NSLock()
    private let capacity: Int
    private let liftTimeout: Double
    private var pending: [Pending] = []
    private var devices: [UInt64: DeviceState] = [:]
    private var drainScheduled = false

    init(capacity: Int = 16, liftTimeout: Double = 0.12) {
        self.capacity = max(2, capacity)
        self.liftTimeout = liftTimeout
    }

    func offer(_ frame: TouchFrame, now: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var dev = devices[frame.device] ?? DeviceState()
        dev.lastOfferAt = now
        defer { devices[frame.device] = dev }

        let prevCount = dev.lastAccepted?.touches.count ?? 0
        if frame.touches.isEmpty && prevCount == 0 { return false }
        let isEdge = frame.touches.count != prevCount
            || frame.touches.contains { TouchFrame.isEdgeStage($0.stage) }
        if !isEdge, let last = dev.lastAccepted,
           !TouchFrameMailbox.differsMaterially(frame, last) {
            return false
        }
        dev.lastAccepted = frame
        enqueue(Pending(frame: frame, isEdge: isEdge))
        return scheduleDrainIfNeeded()
    }

    func take() -> [TouchFrame] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending.map(\.frame)
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        return out
    }

    /// Main-thread watchdog step. `.fired` means a synthetic release was
    /// queued for a device that went quiet mid-touch; the caller drains now.
    /// `.rearm(at:)` is the earliest time a quiet device could need one.
    func checkWatchdog(now: Double) -> Watchdog {
        lock.lock()
        defer { lock.unlock() }
        var fired = false
        var nextDeadline: Double?
        for (id, var dev) in devices where dev.touching {
            let deadline = dev.lastOfferAt + liftTimeout
            if now >= deadline, let last = dev.lastAccepted {
                let release = TouchFrame(device: id,
                                         timestamp: last.timestamp + (now - dev.lastOfferAt),
                                         frame: last.frame,
                                         touches: [],
                                         synthetic: true)
                dev.lastAccepted = release
                devices[id] = dev
                enqueue(Pending(frame: release, isEdge: true))
                fired = true
            } else {
                nextDeadline = min(nextDeadline ?? deadline, deadline)
            }
        }
        if fired { return .fired }
        if let d = nextDeadline { return .rearm(at: d) }
        return .idle
    }

    /// Forget a device (unplugged or unregistered) without emitting anything.
    func forget(device: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeValue(forKey: device)
        pending.removeAll { $0.frame.device == device }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        devices.removeAll()
        drainScheduled = false
    }

    private func enqueue(_ p: Pending) {
        if !p.isEdge, let i = pending.indices.last,
           !pending[i].isEdge,
           pending[i].frame.device == p.frame.device,
           pending[i].frame.touches.count == p.frame.touches.count {
            pending[i] = p
            return
        }
        if pending.count >= capacity {
            if let i = pending.firstIndex(where: { !$0.isEdge }) {
                pending.remove(at: i)
            } else {
                pending.removeFirst()
            }
        }
        pending.append(p)
    }

    private func scheduleDrainIfNeeded() -> Bool {
        guard !drainScheduled, !pending.isEmpty else { return false }
        drainScheduled = true
        return true
    }

    /// Same finger identities and states, and every finger within 0.0005 of
    /// its previous normalized position — trackpad coordinates jitter in the
    /// 5th decimal even when a finger rests.
    static func differsMaterially(_ a: TouchFrame, _ b: TouchFrame) -> Bool {
        if a.touches.count != b.touches.count { return true }
        for i in 0..<a.touches.count {
            let ta = a.touches[i], tb = b.touches[i]
            if ta.id != tb.id || ta.stage != tb.stage { return true }
            if abs(ta.x - tb.x) > 0.0005 || abs(ta.y - tb.y) > 0.0005 { return true }
        }
        return false
    }
}

/// Refcon for one MultitouchSupport registration. The pointer value itself
/// carries (generation, slot) and is never dereferenced, so a callback the
/// framework delivers after its device was unregistered decodes to a stale
/// generation and is dropped instead of touching freed memory.
enum TouchDeviceRefcon {
    static func encode(generation: UInt, slot: Int) -> UnsafeMutableRawPointer? {
        guard generation != 0, generation <= (UInt.max >> 8), (0..<256).contains(slot) else { return nil }
        return UnsafeMutableRawPointer(bitPattern: (generation << 8) | UInt(slot))
    }

    static func decode(_ refcon: UnsafeMutableRawPointer?) -> (generation: UInt, slot: Int)? {
        guard let refcon = refcon else { return nil }
        let v = UInt(bitPattern: refcon)
        return (v >> 8, Int(v & 0xFF))
    }
}

/// When to (re-)register multitouch devices. Sleep tears registrations
/// down; wake, unlock and IOKit hot-plug re-register after a settle delay
/// (devices re-enumerate for a moment after each); a registration that
/// finds no device or fails retries on a backoff, and any fresh signal
/// restarts an exhausted backoff.
struct TouchDeviceLifecycle {
    enum Event: Equatable {
        case sleep
        case wake
        case unlock
        case topologyChanged
        case registered(count: Int)
        case registerFailed
    }

    enum Action: Equatable {
        case cancelPending
        case teardown
        case register(after: Double)
    }

    let settleDelay: Double
    let retryDelays: [Double]
    private(set) var asleep = false
    private var failures = 0

    init(settleDelay: Double = 1.0, retryDelays: [Double] = [1, 2, 4, 8, 16]) {
        self.settleDelay = settleDelay
        self.retryDelays = retryDelays
    }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .sleep:
            asleep = true
            failures = 0
            return [.cancelPending, .teardown]
        case .wake, .unlock:
            asleep = false
            failures = 0
            return [.register(after: settleDelay)]
        case .topologyChanged:
            if asleep { return [] }
            failures = 0
            return [.register(after: settleDelay)]
        case .registered(let count) where count > 0:
            failures = 0
            return []
        case .registered, .registerFailed:
            if asleep || failures >= retryDelays.count { return [] }
            let delay = retryDelays[failures]
            failures += 1
            return [.register(after: delay)]
        }
    }
}

// Top-level C-convention callback — MultitouchSupport.framework can't call
// a Swift closure. Runs on the framework's thread: resolve the refcon to a
// device identity, copy into compact structs and hand off, nothing else.
private func touchDeviceFrameCallback(_ device: UnsafeMutableRawPointer?,
                                      _ touches: UnsafeMutablePointer<MTTouch>?,
                                      _ numTouches: Int,
                                      _ timestamp: Double,
                                      _ frame: Int,
                                      _ refcon: UnsafeMutableRawPointer?) {
    let observer = TouchDeviceObserver.shared
    guard let deviceId = observer.deviceId(for: refcon) else { return }
    var contacts: [TouchContact] = []
    if let touches = touches, numTouches > 0 {
        contacts.reserveCapacity(numTouches)
        for i in 0..<numTouches {
            let t = touches[i]
            contacts.append(TouchContact(
                id: t.fingerID,
                stage: Int32(bitPattern: t.stage.rawValue),
                x: t.normalizedVector.position.x,
                y: t.normalizedVector.position.y,
                vx: t.normalizedVector.velocity.x,
                vy: t.normalizedVector.velocity.y,
                angle: t.angle,
                size: t.zTotal,
                pressure: t.zPressure,
                majorAxis: t.majorAxis,
                minorAxis: t.minorAxis))
        }
    }
    observer.accept(TouchFrame(device: deviceId, timestamp: timestamp, frame: frame, touches: contacts))
}

// IOKit matching callback for AppleMultitouchDevice arrival/removal. The
// iterator must be drained to re-arm the notification.
private func touchDeviceTopologyCallback(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    TouchDeviceObserver.drain(iterator)
    TouchDeviceObserver.shared.handleLifecycle(.topologyChanged)
}

final class TouchDeviceObserver: RefCountedObserver {
    static let shared = TouchDeviceObserver()
    private override init() { super.init() }

    private let mailbox = TouchFrameMailbox()

    // Registration table read by the MT callback thread.
    private let registrationLock = NSLock()
    private var generation: UInt = 0
    private var slotIds: [UInt64] = []

    // Main-thread only.
    private var lastEmitted: TouchFrame?
    private var watchdog: DispatchSourceTimer?
    private var watchdogDeadline: Double?
    private var lifecycle = TouchDeviceLifecycle()
    private var pendingRegister: DispatchWorkItem?
    private var deviceList: CFArray?
    private var registeredDevices: [MTDeviceRef] = []
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var notifyPort: IONotificationPortRef?
    private var topologyIterators: [io_iterator_t] = []

    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Called from the C callback on the MT thread. nil for a refcon from a
    /// superseded registration.
    func deviceId(for refcon: UnsafeMutableRawPointer?) -> UInt64? {
        guard let (gen, slot) = TouchDeviceRefcon.decode(refcon) else { return nil }
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard gen == generation, slot < slotIds.count else { return nil }
        return slotIds[slot]
    }

    /// Called from the C callback on the MT thread.
    func accept(_ frame: TouchFrame) {
        if mailbox.offer(frame, now: TouchDeviceObserver.uptime()) {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }

    func latestFrame() -> [String: Any]? {
        guard let f = lastEmitted else { return nil }
        return TouchFrame.payload(f, uptimeNow: TouchDeviceObserver.uptime(),
                                  epochMsNow: Date().timeIntervalSince1970 * 1000)
    }

    func handleLifecycle(_ event: TouchDeviceLifecycle.Event) {
        for action in lifecycle.handle(event) {
            switch action {
            case .cancelPending:
                pendingRegister?.cancel()
                pendingRegister = nil
            case .teardown:
                unregisterDevices()
            case .register(let delay):
                pendingRegister?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingRegister = nil
                    self?.registerDevices()
                }
                pendingRegister = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    override func install() -> Token? {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            self?.watchdogDeadline = nil
            self?.runWatchdog()
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        watchdog = timer

        startLifecycleSignals()
        registerDevices()
        return Token { [weak self] in self?.teardown() }
    }

    // MARK: Device registration

    private func registerDevices() {
        unregisterDevices()
        guard let list = MTDeviceCreateList() else {
            handleLifecycle(.registerFailed)
            return
        }
        let count = min(CFArrayGetCount(list), 256)
        var devices: [MTDeviceRef?] = []
        var ids: [UInt64] = []
        for i in 0..<count {
            let dev = CFArrayGetValueAtIndex(list, i).map { UnsafeMutableRawPointer(mutating: $0) }
            devices.append(dev)
            ids.append(dev.map(TouchDeviceObserver.identity(of:)) ?? 0)
        }

        // Publish the slot table before registering so the first frame of
        // each device resolves.
        registrationLock.lock()
        generation = generation &+ 1
        if generation == 0 || generation > (UInt.max >> 8) { generation = 1 }
        let gen = generation
        slotIds = ids
        registrationLock.unlock()

        var registered: [MTDeviceRef] = []
        for (slot, dev) in devices.enumerated() {
            guard let dev = dev,
                  let refcon = TouchDeviceRefcon.encode(generation: gen, slot: slot),
                  MTRegisterContactFrameCallbackWithRefcon(dev, touchDeviceFrameCallback, refcon)
            else { continue }
            if MTDeviceStart(dev, 0) != 0 {
                _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
                continue
            }
            registered.append(dev)
        }
        registeredDevices = registered
        deviceList = list
        log("touchdevice: registered \(registered.count)/\(count) multitouch device(s)")
        handleLifecycle(.registered(count: registered.count))
    }

    /// Teardown order from asmagill's userdata_gc (internal.m:1128-1134):
    /// unregister callback → check IsRunning → stop → release. Reordering
    /// crashes on the next-frame delivery the framework queues internally
    /// between stop and release. A device mid-touch gets its release from
    /// the lift watchdog once its frames stop.
    private func unregisterDevices() {
        for dev in registeredDevices {
            _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
            if MTDeviceIsRunning(dev) { _ = MTDeviceStop(dev) }
        }
        registeredDevices = []
        registrationLock.lock()
        generation = generation &+ 1
        slotIds = []
        registrationLock.unlock()
        deviceList = nil
    }

    /// Stable identity for a device: the registry ID of the IOHIDEventService
    /// above its AppleMultitouchDevice — the same value IOHIDEventGetSenderID
    /// reports on that device's scroll and gesture CGEvents — falling back to
    /// the multitouch service's own registry ID.
    static func identity(of device: MTDeviceRef) -> UInt64 {
        let service = MTDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return 0 }
        if let sender = hidEventServiceId(above: service) { return sender }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : 0
    }

    private static func hidEventServiceId(above service: io_service_t) -> UInt64? {
        var current = service
        var owned = false
        defer { if owned { IOObjectRelease(current) } }
        for _ in 0..<16 {
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard kr == KERN_SUCCESS, parent != 0 else { return nil }
            if owned { IOObjectRelease(current) }
            current = parent
            owned = true
            if IOObjectConformsTo(current, "IOHIDEventService") != 0 {
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(current, &id) == KERN_SUCCESS, id != 0 else { return nil }
                return id
            }
        }
        return nil
    }

    // MARK: Lifecycle signals

    private func startLifecycleSignals() {
        let ws = NSWorkspace.shared.notificationCenter
        notificationTokens.append((ws, ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleLifecycle(.sleep) }))
        notificationTokens.append((ws, ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleLifecycle(.wake) }))
        let dnc = DistributedNotificationCenter.default()
        notificationTokens.append((dnc, dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.handleLifecycle(.unlock) }))

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("AppleMultitouchDevice"),
                touchDeviceTopologyCallback, nil, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            // Arms the notification; existing devices are not a change.
            TouchDeviceObserver.drain(iterator)
            topologyIterators.append(iterator)
        }
    }

    static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func stopLifecycleSignals() {
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens = []
        for it in topologyIterators { IOObjectRelease(it) }
        topologyIterators = []
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
    }

    // MARK: Drain + watchdog

    private func drain() {
        let frames = mailbox.take()
        for f in frames {
            lastEmitted = f
            fire()
        }
        runWatchdog()
    }

    /// Re-arm lazily: an armed deadline earlier than the new one is left
    /// alone and re-evaluated when it fires, so a streaming touch reschedules
    /// the timer about once per lift timeout rather than once per frame.
    private func runWatchdog() {
        switch mailbox.checkWatchdog(now: TouchDeviceObserver.uptime()) {
        case .fired:
            drain()
        case .rearm(let at):
            if let armed = watchdogDeadline, armed <= at { return }
            watchdogDeadline = at
            let delay = max(0, at - TouchDeviceObserver.uptime())
            watchdog?.schedule(deadline: .now() + delay)
        case .idle:
            break
        }
    }

    private func teardown() {
        pendingRegister?.cancel()
        pendingRegister = nil
        stopLifecycleSignals()
        unregisterDevices()
        lifecycle = TouchDeviceLifecycle()

        watchdog?.cancel()
        watchdog = nil
        watchdogDeadline = nil
        mailbox.reset()
        lastEmitted = nil
    }
}

// MARK: ============================================================
// MARK: Gesture — AppKit gesture-event decoding
// MARK: ============================================================

// Read-side decoding of trackpad gestures observed through a CGEventTap.
// CGEventType 29 = NSEventTypeGesture (private). NSEvent.subtype gives us
// the gesture kind (rotate/magnify/swipe/begin/end), and NSEvent.touches
// gives us live finger positions/phases. This is the path TTTaps used to
// dispatch 3/4/5-finger taps and drags.

enum Gesture {

    /// Private CGEventType for gesture-class events. Numeric value 29.
    static let cgEventType = CGEventType(rawValue: 29)!

    static func describe(cgEvent: CGEvent) -> [String: Any]? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        let subtype = Int(nsEvent.subtype.rawValue)

        // All touches currently on the trackpad (began/moved/stationary).
        let touchingSet = nsEvent.touches(matching: .touching, in: nil)
        let fingers = touchingSet.count

        // Per-touch detail for TTTaps-class consumers: stable identity, phase,
        // normalized position (0–1 trackpad-relative). Walk .any to include
        // .ended / .cancelled touches alongside the live ones.
        let touchesAll = nsEvent.touches(matching: .any, in: nil)
        var touches: [[String: Any]] = []
        var phases: [String: Int] = [:]
        for t in touchesAll {
            let phaseName: String
            switch t.phase {
            case .began:      phaseName = "began"
            case .moved:      phaseName = "moved"
            case .stationary: phaseName = "stationary"
            case .ended:      phaseName = "ended"
            case .cancelled:  phaseName = "cancelled"
            default:          phaseName = "other"
            }
            phases[phaseName, default: 0] += 1
            // .identity is an opaque NSCopying; String(describing:) yields a
            // stable repr that's unique per finger within the gesture lifetime —
            // same approach Hammerspoon uses for hs.eventtap touch identity.
            let id = String(describing: t.identity)
            // .touching covers began/moved/stationary; consumers checking the
            // count of "live" touches per-event mirror Hammerspoon's
            // touchCount = #event:getTouches().
            let touching = (t.phase == .began || t.phase == .moved || t.phase == .stationary)
            touches.append([
                "identity":  id,
                "phase":     phaseName,
                "touching":  touching,
                "normalizedPosition": [
                    "x": Double(t.normalizedPosition.x),
                    "y": Double(t.normalizedPosition.y)
                ]
            ])
        }

        return [
            "subtype": subtype,
            "subtypeName": subtypeName(subtype),
            "fingers": fingers,
            "phases": phases,
            "touches": touches
        ]
    }

    private static func subtypeName(_ s: Int) -> String {
        // Values from TouchEvents.h:
        //   0x05 rotate, 0x08 magnify, 0x0B gesture, 0x10 swipe,
        //   0x16 smartMagnify, 0x3D beginGesture, 0x3E endGesture
        switch s {
        case 0x05: return "rotate"
        case 0x08: return "magnify"
        case 0x0B: return "gesture"
        case 0x10: return "swipe"
        case 0x16: return "smartMagnify"
        case 0x3D: return "beginGesture"
        case 0x3E: return "endGesture"
        default:   return "subtype-\(s)"
        }
    }
}

// MARK: ============================================================
// MARK: ScrollWheel — scroll-event field decoding
// MARK: ============================================================

// CoreGraphics private SPI. CGEventCopyIOHIDEvent returns the IOHIDEvent a
// CGEvent was built from (+1, nil for synthesized events);
// IOHIDEventGetSenderID returns the IORegistry entry ID of the HID service
// that produced it, which is the same ID for every scroll, momentum and
// gesture event of one physical device.
@_silgen_name("CGEventCopyIOHIDEvent")
private func CGEventCopyIOHIDEvent(_ event: CGEvent) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetSenderID")
private func IOHIDEventGetSenderID(_ event: CFTypeRef) -> UInt64

enum ScrollWheel {

    /// Raw scroll fields of one scrollWheel CGEvent. Axis 1 is vertical and
    /// axis 2 horizontal; signs are the raw CoreGraphics values, so they
    /// already include the user's natural-scrolling preference.
    struct Fields: Equatable {
        var pointDeltaX: Double
        var pointDeltaY: Double
        var fixedDeltaX: Double
        var fixedDeltaY: Double
        /// CGScrollPhase: 1 began, 2 changed, 4 ended, 8 cancelled,
        /// 128 mayBegin. 0 for wheel mice and momentum events.
        var phase: Int64
        /// CGMomentumScrollPhase: 0 none, 1 begin, 2 continue, 3 end.
        var momentumPhase: Int64
        var isContinuous: Bool
        /// HID sender (0 = unknown / synthesized).
        var senderId: UInt64
    }

    static func read(_ event: CGEvent) -> Fields {
        Fields(
            pointDeltaX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            pointDeltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixedDeltaX: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            fixedDeltaY: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            senderId: senderId(of: event))
    }

    static func senderId(of event: CGEvent) -> UInt64 {
        guard let hid = CGEventCopyIOHIDEvent(event)?.takeRetainedValue() else { return 0 }
        return IOHIDEventGetSenderID(hid)
    }

    /// Payload keys merged into a scrollWheel eventtap callback.
    static func payload(_ f: Fields) -> [String: Any] {
        [
            "deltaX": f.pointDeltaX,
            "deltaY": f.pointDeltaY,
            "fixedDeltaX": f.fixedDeltaX,
            "fixedDeltaY": f.fixedDeltaY,
            "scrollPhase": phaseName(f.phase),
            "momentumPhase": momentumPhaseName(f.momentumPhase),
            "isContinuous": f.isContinuous,
            "senderId": f.senderId == 0 ? NSNull() : f.senderId as Any
        ]
    }

    static func phaseName(_ raw: Int64) -> String {
        switch raw {
        case 0:   return "none"
        case 1:   return "began"
        case 2:   return "changed"
        case 4:   return "ended"
        case 8:   return "cancelled"
        case 128: return "mayBegin"
        default:  return "unknown"
        }
    }

    static func momentumPhaseName(_ raw: Int64) -> String {
        switch raw {
        case 0:  return "none"
        case 1:  return "began"
        case 2:  return "changed"
        case 3:  return "ended"
        default: return "unknown"
        }
    }
}

// MARK: ============================================================
// MARK: Hotkey — Carbon hotkey registry + modal modes
// MARK: ============================================================

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
            log("hotkey unparsed: \(spec)")
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

    fileprivate func dispatch(id: UInt32) {
        guard let b = bindings[id] else { return }
        if let m = b.mode, m != currentMode { return }
        let frontId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if let apps = b.apps, !apps.contains("*"), !apps.contains(frontId) { return }
        if let exclude = b.excludeApps, exclude.contains(frontId) { return }
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
