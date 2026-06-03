import AppKit
import ApplicationServices
import Carbon
import Carbon.HIToolbox
import CoreGraphics
import Foundation

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

/// Fires on every CGEvent mouse move. Replaces the 33 Hz `mouseTimer` poll
/// in Bridge — idle CPU drops to zero, active movement updates faster than
/// the old 30 Hz ceiling.
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
        return EventTapRegistry.shared.register(eventType: .mouseMoved) { [weak self] _ in
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

// Write side of the input-events stream. Originally split out of Events.swift
// to mirror the Camera.swift vs CameraCapture.swift separation pattern.
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
// contact-frame callback at ~80 Hz on a private dispatch queue with every
// finger's stable identity, normalized + absolute position, velocity,
// pressure, angle, and ellipsoid axes — strictly BELOW the layer where
// AppKit recognizes "swipe"/"pinch"/"rotate" gestures.
//
// Coalescing strategy: the MT callback's only job is to atomically swap a
// snapshot dict into `pendingFrame`. A Timer on main runs at 30 Hz, reads
// the snapshot under the lock, diffs against the last emitted frame, and
// pushes to JS only on change. This caps WKWebView eval traffic and lets
// JS-side recognizers (TTTaps, future heatmap stacks) stay responsive
// without saturating the JS thread.

enum TouchDevice {
    /// Latest coalesced frame snapshot, or nil if no frame has arrived yet
    /// (e.g. trackpad untouched since install). Used by Bridge for replay.
    static func snapshot() -> [String: Any]? {
        return TouchDeviceObserver.shared.latestFrame()
    }
}

// MTPathStage → consumer-friendly state name. asmagill exposes the raw enum
// label; we collapse to a smaller "began/stationary/moved/ended/cancelled/
// lifted" vocabulary that matches the Gesture wording (which TTTaps
// already speaks). MakeTouch=began, Touching=moved, BreakTouch=ended,
// OutOfRange=lifted, HoverInRange=stationary, StartInRange/LingerInRange
// are rare transient states — bucket them with the closest neighbor.
private func touchDeviceStateName(for stage: MTPathStage) -> String {
    switch stage {
    case MTPathStageMakeTouch:     return "began"
    case MTPathStageTouching:      return "moved"
    case MTPathStageBreakTouch:    return "ended"
    case MTPathStageOutOfRange:    return "lifted"
    case MTPathStageHoverInRange:  return "stationary"
    case MTPathStageStartInRange:  return "began"
    case MTPathStageLingerInRange: return "stationary"
    case MTPathStageNotTracking:   return "cancelled"
    default:                       return "cancelled"
    }
}

// Top-level C-convention callback — MultitouchSupport.framework can't call
// a Swift closure, and the refcon is the only safe way to reach the
// singleton without globals.
private func touchDeviceFrameCallback(_ device: UnsafeMutableRawPointer?,
                                      _ touches: UnsafeMutablePointer<MTTouch>?,
                                      _ numTouches: Int,
                                      _ timestamp: Double,
                                      _ frame: Int,
                                      _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let observer = Unmanaged<TouchDeviceObserver>.fromOpaque(refcon).takeUnretainedValue()
    var touchList: [[String: Any]] = []
    if let touches = touches, numTouches > 0 {
        touchList.reserveCapacity(numTouches)
        for i in 0..<numTouches {
            let t = touches[i]
            touchList.append([
                "identifier": Int(t.fingerID),
                "state":      touchDeviceStateName(for: t.stage),
                "x":          Double(t.normalizedVector.position.x),
                "y":          Double(t.normalizedVector.position.y),
                "vx":         Double(t.normalizedVector.velocity.x),
                "vy":         Double(t.normalizedVector.velocity.y),
                "angle":      Double(t.angle),
                "size":       Double(t.zTotal),
                "pressure":   Double(t.zPressure),
                "majorAxis":  Double(t.majorAxis),
                "minorAxis":  Double(t.minorAxis)
            ])
        }
    }
    let snapshot: [String: Any] = [
        "timestamp": timestamp,
        "frame":     frame,
        "touches":   touchList
    ]
    observer.acceptFrame(snapshot)
}

final class TouchDeviceObserver: RefCountedObserver {
    static let shared = TouchDeviceObserver()
    private override init() { super.init() }

    private let lock = NSLock()
    private var pendingFrame: [String: Any]?
    private var lastEmittedFrame: [String: Any]?

    private var device: UnsafeMutableRawPointer?
    private var coalescerTimer: Timer?
    /// Active coalescer interval in seconds. Defaults to 1/30s (30 Hz);
    /// `setCoalesceInterval` can drop it for stacks that don't need
    /// frame-rate gestures. Held under `lock` because the install path
    /// and any setInterval call can race.
    private var coalesceInterval: TimeInterval = 1.0 / 30.0

    // Keeps the singleton retained through Unmanaged.passRetained so the
    // refcon pointer the C callback receives is always valid — the install
    // path balances this with a passUnretained-style release on teardown.
    private var refconRetainer: Unmanaged<TouchDeviceObserver>?

    /// Called from the C callback on a private MT queue. Swaps the frame
    /// snapshot into pendingFrame under the lock; the main-thread timer
    /// drains it.
    func acceptFrame(_ snapshot: [String: Any]) {
        lock.lock()
        pendingFrame = snapshot
        lock.unlock()
    }

    func latestFrame() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return lastEmittedFrame ?? pendingFrame
    }

    override func install() -> Token? {
        guard let dev = MTDeviceCreateDefault() else { return nil }
        self.device = dev

        let retained = Unmanaged.passRetained(self)
        self.refconRetainer = retained
        let refcon = retained.toOpaque()

        guard MTRegisterContactFrameCallbackWithRefcon(dev, touchDeviceFrameCallback, refcon) else {
            retained.release()
            self.refconRetainer = nil
            MTDeviceRelease(dev)
            self.device = nil
            return nil
        }

        let startStatus = MTDeviceStart(dev, 0)
        if startStatus != 0 {
            _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
            retained.release()
            self.refconRetainer = nil
            MTDeviceRelease(dev)
            self.device = nil
            return nil
        }

        // Default 30 Hz coalescer; can be retuned via setCoalesceInterval
        // (wired from Bridge's channel.setInterval). Reads pendingFrame under
        // the lock, diffs against lastEmittedFrame, fires subscribers only
        // when the snapshot actually changes. Empty-touches frames still
        // count as a change when the previous frame had touches — that's
        // the "all fingers lifted" edge JS-side state machines need.
        startCoalescer()

        return Token { [weak self] in self?.teardown() }
    }

    /// Recreate the coalescer timer at a new interval. Safe to call before
    /// or after install(); only does anything when the observer is active.
    /// Multiple subscribers calling this is last-writer-wins for now —
    /// per-subscriber min-reduction is a planned follow-up.
    func setCoalesceInterval(ms: Int) {
        let clamped = max(8, min(1000, ms))   // clamp 8ms (~120Hz) to 1s
        lock.lock()
        coalesceInterval = TimeInterval(clamped) / 1000.0
        let hadTimer = coalescerTimer != nil
        lock.unlock()
        if hadTimer { startCoalescer() }
    }

    /// (Re)create the coalescer timer at the current `coalesceInterval`.
    /// Called from install() and setCoalesceInterval(). Cancels the prior
    /// timer first so a rapid sequence of setInterval calls doesn't pile
    /// up timers.
    private func startCoalescer() {
        lock.lock()
        coalescerTimer?.invalidate()
        let interval = coalesceInterval
        lock.unlock()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.coalesce()
        }
        RunLoop.main.add(timer, forMode: .common)
        lock.lock()
        coalescerTimer = timer
        lock.unlock()
    }

    private func coalesce() {
        lock.lock()
        let pending = pendingFrame
        lock.unlock()
        guard let pending = pending else { return }

        // Cheap structural diff: same touches count + same per-finger
        // (identifier, x, y, state) is "no meaningful change". JSON
        // serialization-and-compare would be more robust but ~3-4x more
        // CPU at 30 Hz with 5 fingers — this is the hot path.
        if !frameDiffersMaterially(pending, lastEmittedFrame) { return }

        lock.lock()
        lastEmittedFrame = pending
        lock.unlock()
        fire()
    }

    private func frameDiffersMaterially(_ a: [String: Any], _ b: [String: Any]?) -> Bool {
        guard let b = b else { return true }
        let ta = a["touches"] as? [[String: Any]] ?? []
        let tb = b["touches"] as? [[String: Any]] ?? []
        if ta.count != tb.count { return true }
        for i in 0..<ta.count {
            let ai = ta[i], bi = tb[i]
            if (ai["identifier"] as? Int) != (bi["identifier"] as? Int) { return true }
            if (ai["state"] as? String) != (bi["state"] as? String) { return true }
            // Use a small epsilon: trackpad coordinates jitter in the 5th
            // decimal even when the finger is "stationary".
            let ax = (ai["x"] as? Double) ?? 0
            let bx = (bi["x"] as? Double) ?? 0
            let ay = (ai["y"] as? Double) ?? 0
            let by = (bi["y"] as? Double) ?? 0
            if abs(ax - bx) > 0.0005 || abs(ay - by) > 0.0005 { return true }
        }
        return false
    }

    private func teardown() {
        if let t = coalescerTimer { t.invalidate() }
        coalescerTimer = nil

        // Teardown order from asmagill's userdata_gc (internal.m:1128-1134):
        //   Unregister callback → check IsRunning → Stop → Release.
        // Reordering crashes on the next-frame delivery the framework
        // queues internally between Stop and Release.
        if let dev = device {
            _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
            if MTDeviceIsRunning(dev) { _ = MTDeviceStop(dev) }
            MTDeviceRelease(dev)
        }
        device = nil

        if let retainer = refconRetainer {
            retainer.release()
            refconRetainer = nil
        }

        lock.lock()
        pendingFrame = nil
        lastEmittedFrame = nil
        lock.unlock()
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
            FileHandle.standardError.write(Data("stackd: hotkey unparsed: \(spec)\n".utf8))
            return nil
        }

        let id = nextId
        nextId += 1
        bindings[id] = Binding(callback: callback, mode: mode, apps: apps, excludeApps: excludeApps)

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
