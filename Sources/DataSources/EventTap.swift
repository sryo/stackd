import ApplicationServices
import CoreGraphics
import Foundation

// MARK: ============================================================
// MARK: Events — CGEventTap read side + consume side
// MARK: ============================================================

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
// Gesture decoding lives in TrackpadGestures.swift — it's a non-trivial AppKit
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
        let key: String                  // Bridge.eventTapKey — rectsAny lookup
        let onMatch: (CGEvent) -> Void   // fires async to JS after a match
    }
    private var consumers: [CGEventType: [Int: Consumer]] = [:]
    private var nextConsumerId: Int = 1
    private var consumeTap: CFMachPort?
    private var consumeRunLoopSource: CFRunLoopSource?
    private var consumeMask: CGEventMask = 0          // mask the live tap was created with
    private var consumeTapEnabled = false

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

    // The single active trackpad-scroll claim (last claimant wins), decided
    // in the consuming tap. Owners that already have an unload cleanup.
    private(set) var scrollClaim: ScrollClaim?
    private var scrollClaimCleanupOwners: Set<String> = []

    private init() {}

    // MARK: - Scroll claim

    /// Swallow the current trackpad session of `senderId` (nil = any
    /// trackpad) until its next scroll begins. Needs the consuming tap;
    /// returns false when it can't be installed.
    func claimScroll(senderId: UInt64?, owner: String) -> Bool {
        guard ensureConsumeTap(adding: .scrollWheel) else { return false }
        scrollClaim = ScrollClaim(senderId: senderId, owner: owner)
        return true
    }

    /// Drop `owner`'s claim if it still holds it. Returns whether it did.
    @discardableResult
    func releaseScroll(owner: String) -> Bool {
        guard scrollClaim?.owner == owner else { return false }
        scrollClaim = nil
        disableConsumeTapIfIdle()
        return true
    }

    /// A Token that releases `owner`'s claim on unload — returned once per
    /// owner, nil on later calls, so repeated claims don't pile up tokens.
    func scrollClaimCleanup(owner: String) -> Token? {
        guard scrollClaimCleanupOwners.insert(owner).inserted else { return nil }
        return Token { [weak self] in
            self?.releaseScroll(owner: owner)
            self?.scrollClaimCleanupOwners.remove(owner)
        }
    }

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

        // Private gesture event type (NSEventTypeGesture = 29). See Gesture.
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

    /// What a CGEventTap needs so its interest mask matches what is registered.
    enum TapMaskAction: Equatable {
        case keep
        /// Nothing is registered any more; stop the tap from waking the run loop.
        case disable
        case enable
        /// The tap's mask is fixed at creation, so a different set of event
        /// types needs a new tap carrying exactly this mask.
        case reinstall(CGEventMask)
    }

    static func eventMask(_ types: some Sequence<CGEventType>) -> CGEventMask {
        types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
    }

    /// Event types the consuming tap must intercept: those with a registered
    /// consumer, plus scrollWheel while a scroll claim is held.
    static func neededConsumeMask(consumers: Set<CGEventType>, claim: ScrollClaim?) -> CGEventMask {
        eventMask(consumers) | (claim == nil ? 0 : eventMask([.scrollWheel]))
    }

    /// `installed` is the mask of the live tap (nil = none); `enabled` is
    /// whether it currently delivers events. A disabled tap comes back with
    /// the mask it was built with, so one that no longer matches the need is
    /// rebuilt rather than re-enabled.
    static func tapMaskAction(needed: CGEventMask, installed: CGEventMask?, enabled: Bool) -> TapMaskAction {
        if needed == 0 { return installed != nil && enabled ? .disable : .keep }
        guard let installed = installed else { return .reinstall(needed) }
        if enabled { return needed & ~installed == 0 ? .keep : .reinstall(needed) }
        return installed == needed ? .enable : .reinstall(needed)
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
            self?.disableConsumeTapIfIdle()
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

    private var neededConsumeMask: CGEventMask {
        EventTapRegistry.neededConsumeMask(consumers: Set(consumers.keys), claim: scrollClaim)
    }

    private func ensureConsumeTap(adding eventType: CGEventType) -> Bool {
        // The mask is fixed when the tap is created and CG has no "add event
        // type to existing tap" call, so widening it means a new tap. A tap
        // left disabled after its last consumer went away is switched back
        // on when it still matches; otherwise it is rebuilt.
        let needed = neededConsumeMask | EventTapRegistry.eventMask([eventType])
        let installed: CGEventMask? = consumeTap == nil ? nil : consumeMask
        switch EventTapRegistry.tapMaskAction(needed: needed, installed: installed, enabled: consumeTapEnabled) {
        case .keep, .disable:
            return true
        case .enable:
            if let t = consumeTap { CGEvent.tapEnable(tap: t, enable: true) }
            consumeTapEnabled = true
            return true
        case .reinstall(let mask):
            tearDownConsumeTap()
            return installConsumeTap(mask: mask)
        }
    }

    private func installConsumeTap(mask newMask: CGEventMask) -> Bool {
        // Same Accessibility gate as the observer tap. If we can't install the
        // observer side we can't install the consume side either.
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

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { (_, type, event, ctx) in
            guard let ctx = ctx else { return Unmanaged.passUnretained(event) }
            let registry = Unmanaged<EventTapRegistry>.fromOpaque(ctx).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // An idle tap was switched off on purpose; only a wanted one comes back.
                if let t = registry.consumeTap, registry.consumeTapEnabled {
                    CGEvent.tapEnable(tap: t, enable: true)
                }
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
        self.consumeTapEnabled = true
        log("CGEventTap (consume) installed mask=\(String(newMask, radix: 16))")
        return true
    }

    /// A blocking tap makes every event of its types wait on the main run
    /// loop, so it is switched off as soon as no consumer or claim needs it.
    private func disableConsumeTapIfIdle() {
        let installed: CGEventMask? = consumeTap == nil ? nil : consumeMask
        guard case .disable = EventTapRegistry.tapMaskAction(
            needed: neededConsumeMask, installed: installed, enabled: consumeTapEnabled),
              let t = consumeTap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        consumeTapEnabled = false
        log("CGEventTap (consume) idle; disabled")
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
        consumeMask = 0
        consumeTapEnabled = false
    }

    private func dispatchConsume(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .scrollWheel, let claim = scrollClaim {
            switch ScrollClaim.decide(claim: claim, ScrollWheel.read(event)) {
            case .swallow: return nil
            case .release:
                scrollClaim = nil
                disableConsumeTapIfIdle()
            case .pass:    break
            }
        }
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
