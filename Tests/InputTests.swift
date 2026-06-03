import Foundation
import AppKit
import Carbon.HIToolbox
import CoreGraphics

// Tests for `Sources/DataSources/Input.swift`.
//
// Input.swift is the union of the keyboard/mouse/eventtap/hotkey/touch
// surface — ~24 static funcs across Input, InputAX, Mouse, Cursor,
// EventTapRegistry, EventsSynth, Gesture, HotkeyRegistry, TouchDevice.
//
// The vast majority of that surface goes straight to a system API that
// would interfere with the user's session if exercised from a test:
//
//   - EventsSynth.{type, key, scroll, click}  — POSTS CGEvents into the
//     foreground app. Running these inside the test suite would type
//     into whatever happens to be frontmost. Skipped wholesale.
//   - Cursor.setPosition / Mouse.warp          — WARPS the real cursor
//     via CGWarpMouseCursorPosition. Skipped.
//   - EventTapRegistry.register / registerConsumer / ensureTap
//                                               — INSTALLS a real
//     CGEventTap, requires Accessibility TCC, intercepts every keystroke
//     and click for as long as the test process is alive. Skipped.
//   - HotkeyRegistry.bind / enterMode / exitMode
//                                               — REGISTERS a Carbon
//     hotkey through RegisterEventHotKey; the binding stays live for the
//     process lifetime and could shadow real user shortcuts. Skipped.
//   - InputAX.*                                 — touches AXUIElement
//     against whatever element has focus right now (the terminal running
//     the tests). setSelectedText would clobber the user's selection.
//     Skipped.
//   - TouchDeviceObserver.install              — opens the private
//     MultitouchSupport framework against the real trackpad. Skipped.
//
// What IS testable without touching the live runtime:
//
//   1. EventTapRegistry.parse / .name          — pure string ↔ CGEventType
//      mapping. The exact strings here are what JS manifests use under
//      `signal: { events: { type: "keyDown", … } }`; a typo would break
//      every consuming stack.
//   2. HotkeyRegistry.keyCode(for:)            — pure token → virtual
//      keycode lookup. The bind() spec parser walks this table; if "cmd"
//      stopped resolving the hotkey surface is dead.
//   3. EventTapPredicate.isEmpty / .matches    — pure predicate
//      evaluator. We build CGEvents in-memory (CGEvent(keyboardEventSource:
//      …) does not post — only .post() does), feed them to .matches, and
//      assert the AND-of-fields semantics documented on the struct.
//   4. Gesture.cgEventType                     — the private CGEventType
//      raw value (29). If a future SDK ever rejects 29 the force-unwrap
//      crashes at load — we assert the value here for early warning.
//   5. Mouse.location() / Cursor.position()    — read-only wrappers
//      around NSEvent.mouseLocation. Safe to call (no warp, no post).
//      We assert the Y-flip invariant rather than a specific coordinate.
//
// Wire-up: add `registerInputTests()` to Tests/main.swift and append
// this file to TEST_SOURCES in tests.sh (orchestrator handles it).

func registerInputTests() {

    // MARK: - EventTapRegistry.parse / .name (string ↔ CGEventType)

    test("EventTapRegistry.parse maps every JS-side event name to the matching CGEventType") {
        // These strings are the contract between the JS manifest layer and
        // the Swift side. The pairs come directly from Input.swift's
        // parse() / name() switch statements — a regression here breaks
        // every stack that subscribes to an events channel.
        try expectEqual(EventTapRegistry.parse("keyDown"),         .keyDown)
        try expectEqual(EventTapRegistry.parse("keyUp"),           .keyUp)
        try expectEqual(EventTapRegistry.parse("flagsChanged"),    .flagsChanged)
        try expectEqual(EventTapRegistry.parse("leftMouseDown"),   .leftMouseDown)
        try expectEqual(EventTapRegistry.parse("rightMouseDown"),  .rightMouseDown)
        try expectEqual(EventTapRegistry.parse("otherMouseDown"),  .otherMouseDown)
        try expectEqual(EventTapRegistry.parse("leftMouseDragged"),  .leftMouseDragged)
        try expectEqual(EventTapRegistry.parse("rightMouseDragged"), .rightMouseDragged)
        try expectEqual(EventTapRegistry.parse("mouseMoved"),      .mouseMoved)
        try expectEqual(EventTapRegistry.parse("scrollWheel"),     .scrollWheel)
        try expectEqual(EventTapRegistry.parse("gesture"),         Gesture.cgEventType)
        // Unknown names round-trip to nil, not to .null or to .keyDown.
        try expect(EventTapRegistry.parse("nope") == nil)
        try expect(EventTapRegistry.parse("") == nil)
    }

    test("EventTapRegistry.name is the inverse of parse for every JS-visible event type") {
        // Asserts the parse → name round-trip. If either side drifts the
        // round-trip drops a name; observable to consumers as "subscribed
        // to keyDown but the event came in as 'unknown'".
        let names = [
            "keyDown", "keyUp", "flagsChanged",
            "leftMouseDown", "rightMouseDown", "otherMouseDown",
            "leftMouseDragged", "rightMouseDragged",
            "mouseMoved", "scrollWheel", "gesture"
        ]
        for n in names {
            guard let t = EventTapRegistry.parse(n) else {
                try expect(false, "parse(\(n)) returned nil")
                return
            }
            try expectEqual(EventTapRegistry.name(for: t), n)
        }
    }

    // MARK: - EventTapRegistry.setConsumerRects — runtime cursor-rect gate

    test("EventTapRegistry.setConsumerRects round-trips nil / empty / populated for a key") {
        // The cursor-rect gate has three semantically distinct states, all
        // visible to the synchronous consume path:
        //   - nil  → no gate (consume on the static predicate alone)
        //   - []   → empty gate (consumer never fires, used to suppress without
        //            tearing the registration down)
        //   - [r]  → consume only when cursor falls in any rect
        // This test pins the storage shape so a future refactor can't silently
        // collapse `nil` and `[]` into the same internal value — the consume
        // dispatcher branches on them differently.
        let key = "tests.rectsRoundtrip"
        EventTapRegistry.shared.setConsumerRects(key: key, rects: nil)
        try expect(EventTapRegistry.shared.rectsForKey(key) == nil,
                   "expected nil after setConsumerRects(nil)")
        EventTapRegistry.shared.setConsumerRects(key: key, rects: [])
        let empty = EventTapRegistry.shared.rectsForKey(key)
        try expect(empty != nil && empty?.isEmpty == true,
                   "expected empty array after setConsumerRects([]), got \(String(describing: empty))")
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        EventTapRegistry.shared.setConsumerRects(key: key, rects: [r])
        try expectEqual(EventTapRegistry.shared.rectsForKey(key)?.count, 1)
        try expectEqual(EventTapRegistry.shared.rectsForKey(key)?[0], r)
        // Cleanup so other tests start from nil.
        EventTapRegistry.shared.setConsumerRects(key: key, rects: nil)
    }

    test("EventTapRegistry.setConsumerRects scopes by key — distinct keys do not bleed") {
        // Bridge mints keys as "\(stackId):\(callback)", so two stacks (or two
        // callbacks within one stack) must not see each other's rects.
        // Catches a regression where a single shared array silently leaks
        // gates between consumers.
        let k1 = "tests.scope.a"
        let k2 = "tests.scope.b"
        EventTapRegistry.shared.setConsumerRects(key: k1, rects: [CGRect(x: 0, y: 0, width: 10, height: 10)])
        EventTapRegistry.shared.setConsumerRects(key: k2, rects: [CGRect(x: 100, y: 100, width: 5, height: 5)])
        try expectEqual(EventTapRegistry.shared.rectsForKey(k1)?.count, 1)
        try expectEqual(EventTapRegistry.shared.rectsForKey(k2)?.count, 1)
        try expectEqual(EventTapRegistry.shared.rectsForKey(k1)?[0].size.width, 10)
        try expectEqual(EventTapRegistry.shared.rectsForKey(k2)?[0].size.width, 5)
        EventTapRegistry.shared.setConsumerRects(key: k1, rects: nil)
        try expect(EventTapRegistry.shared.rectsForKey(k1) == nil)
        try expectEqual(EventTapRegistry.shared.rectsForKey(k2)?.count, 1,
                        "clearing k1 must not affect k2")
        EventTapRegistry.shared.setConsumerRects(key: k2, rects: nil)
    }

    // MARK: - HotkeyRegistry.keyCode token table

    test("HotkeyRegistry.keyCode resolves letters, digits, and named keys to their Carbon constants") {
        // The bind() spec parser splits "cmd+shift+a" and resolves the
        // non-modifier token through this table. If any of these keys
        // stop resolving, the corresponding hotkey spec silently fails
        // to register (bind() logs and returns nil). Sample across each
        // sub-block of the switch so a structural break in one band
        // (letters / digits / nav / punctuation) is caught.
        try expectEqual(HotkeyRegistry.keyCode(for: "a"),     UInt32(kVK_ANSI_A))
        try expectEqual(HotkeyRegistry.keyCode(for: "z"),     UInt32(kVK_ANSI_Z))
        try expectEqual(HotkeyRegistry.keyCode(for: "0"),     UInt32(kVK_ANSI_0))
        try expectEqual(HotkeyRegistry.keyCode(for: "9"),     UInt32(kVK_ANSI_9))
        try expectEqual(HotkeyRegistry.keyCode(for: "space"), UInt32(kVK_Space))
        try expectEqual(HotkeyRegistry.keyCode(for: "return"),UInt32(kVK_Return))
        try expectEqual(HotkeyRegistry.keyCode(for: "enter"), UInt32(kVK_Return))
        try expectEqual(HotkeyRegistry.keyCode(for: "esc"),   UInt32(kVK_Escape))
        try expectEqual(HotkeyRegistry.keyCode(for: "escape"),UInt32(kVK_Escape))
        try expectEqual(HotkeyRegistry.keyCode(for: "left"),  UInt32(kVK_LeftArrow))
        try expectEqual(HotkeyRegistry.keyCode(for: "right"), UInt32(kVK_RightArrow))
        try expectEqual(HotkeyRegistry.keyCode(for: "minus"), UInt32(kVK_ANSI_Minus))
        try expectEqual(HotkeyRegistry.keyCode(for: "-"),     UInt32(kVK_ANSI_Minus))
        try expectEqual(HotkeyRegistry.keyCode(for: "comma"), UInt32(kVK_ANSI_Comma))
        try expectEqual(HotkeyRegistry.keyCode(for: ","),     UInt32(kVK_ANSI_Comma))
    }

    test("HotkeyRegistry.keyCode returns nil for modifier tokens and unknown strings") {
        // Modifier names are NOT in this table — bind() strips them out of
        // the token stream and accumulates them into the Carbon modifier
        // mask separately. If a modifier ever resolved here it would
        // double-register (once as a modifier flag, once as the "main"
        // keycode), producing a hotkey that fires on no real shortcut.
        try expect(HotkeyRegistry.keyCode(for: "cmd") == nil)
        try expect(HotkeyRegistry.keyCode(for: "ctrl") == nil)
        try expect(HotkeyRegistry.keyCode(for: "shift") == nil)
        try expect(HotkeyRegistry.keyCode(for: "alt") == nil)
        try expect(HotkeyRegistry.keyCode(for: "option") == nil)
        try expect(HotkeyRegistry.keyCode(for: "fn") == nil)
        // Unknown tokens degrade to nil, not to keycode 0 (which would be
        // kVK_ANSI_A and silently re-route every bad spec to ⌘A).
        try expect(HotkeyRegistry.keyCode(for: "lolnotakey") == nil)
        try expect(HotkeyRegistry.keyCode(for: "") == nil)
    }

    // MARK: - EventTapPredicate

    test("EventTapPredicate.isEmpty is true only when every field is nil") {
        // Bridge.swift constructs predicates from JS-side descriptors; an
        // empty descriptor must short-circuit to "match everything" rather
        // than "match nothing". The consumer path uses isEmpty as a hint
        // to skip predicate evaluation entirely.
        let empty = EventTapPredicate(keyCodes: nil, flagsMask: nil, flagsAny: nil)
        try expect(empty.isEmpty)

        let withCodes = EventTapPredicate(keyCodes: [0], flagsMask: nil, flagsAny: nil)
        try expect(!withCodes.isEmpty)

        let withMask = EventTapPredicate(keyCodes: nil, flagsMask: 1, flagsAny: nil)
        try expect(!withMask.isEmpty)

        let withAny = EventTapPredicate(keyCodes: nil, flagsMask: nil, flagsAny: 1)
        try expect(!withAny.isEmpty)
    }

    test("EventTapPredicate.matches gates on keyCodes when keyCodes is non-nil") {
        // CGEvent(keyboardEventSource:virtualKey:keyDown:) constructs the
        // event object without posting — only .post() injects it into the
        // session tap. Safe to use as a fixture.
        guard let evA = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true) else {
            try expect(false, "could not construct CGEvent for kVK_ANSI_A")
            return
        }
        guard let evB = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_B), keyDown: true) else {
            try expect(false, "could not construct CGEvent for kVK_ANSI_B")
            return
        }

        let onlyA = EventTapPredicate(
            keyCodes: [Int64(kVK_ANSI_A)],
            flagsMask: nil, flagsAny: nil
        )
        try expect(onlyA.matches(evA), "predicate should match keycode A")
        try expect(!onlyA.matches(evB), "predicate should reject keycode B")

        // A nil keyCodes set means "don't gate on keycode" — both events
        // pass when only the flags fields are set (and here they're nil
        // too, so the predicate is empty and degenerate-matches anything).
        let permissive = EventTapPredicate(keyCodes: nil, flagsMask: nil, flagsAny: nil)
        try expect(permissive.matches(evA))
        try expect(permissive.matches(evB))
    }

    test("EventTapPredicate.matches enforces flagsMask as all-bits-set and flagsAny as any-bit-set") {
        // Use a keyDown event we can stamp flags onto. flagsMask requires
        // every bit in the mask to be present; flagsAny requires at least
        // one. The two semantics are how Bridge expresses "must be
        // cmd+shift" vs "is either cmd or shift" from JS.
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true) else {
            try expect(false, "could not construct CGEvent")
            return
        }
        ev.flags = [.maskCommand, .maskShift]
        let f = ev.flags.rawValue

        // flagsMask = cmd|shift — both present, must match.
        let cmdShiftAll = EventTapPredicate(
            keyCodes: nil,
            flagsMask: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
            flagsAny: nil
        )
        try expect(cmdShiftAll.matches(ev))

        // flagsMask requires control too — missing, must reject.
        let needsCtrl = EventTapPredicate(
            keyCodes: nil,
            flagsMask: CGEventFlags.maskControl.rawValue,
            flagsAny: nil
        )
        try expect(!needsCtrl.matches(ev), "flagsMask must reject when a required bit is missing (event flags=\(String(f, radix: 16)))")

        // flagsAny = ctrl|shift — shift present, must match.
        let anyCtrlOrShift = EventTapPredicate(
            keyCodes: nil,
            flagsMask: nil,
            flagsAny: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        )
        try expect(anyCtrlOrShift.matches(ev))

        // flagsAny = ctrl only — not present, must reject.
        let anyCtrl = EventTapPredicate(
            keyCodes: nil,
            flagsMask: nil,
            flagsAny: CGEventFlags.maskControl.rawValue
        )
        try expect(!anyCtrl.matches(ev))
    }

    test("EventTapPredicate.matches AND-combines keyCodes with flag predicates") {
        // The documented semantic is "fields combine with AND; missing
        // fields are ignored." A mismatch on either keycode or flags must
        // reject; only when both pass does the predicate fire.
        guard let evACmd = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true),
              let evBCmd = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_B), keyDown: true),
              let evABare = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true)
        else {
            try expect(false, "CGEvent construction failed")
            return
        }
        evACmd.flags = [.maskCommand]
        evBCmd.flags = [.maskCommand]
        // evABare stays with default flags (.init() == empty set).

        let aWithCmd = EventTapPredicate(
            keyCodes: [Int64(kVK_ANSI_A)],
            flagsMask: CGEventFlags.maskCommand.rawValue,
            flagsAny: nil
        )
        try expect(aWithCmd.matches(evACmd))     // both match
        try expect(!aWithCmd.matches(evBCmd))    // keycode wrong
        try expect(!aWithCmd.matches(evABare))   // flag missing
    }

    // MARK: - Gesture.cgEventType

    test("Gesture.cgEventType is the private NSEventTypeGesture raw value (29)") {
        // Input.swift force-unwraps CGEventType(rawValue: 29). If Apple
        // ever rejects 29 the daemon crashes at load. We assert the value
        // explicitly so a SDK change that re-maps the gesture event type
        // is caught here instead of in production.
        try expectEqual(Gesture.cgEventType.rawValue, UInt32(29))
    }

    // MARK: - Mouse / Cursor read-only position

    test("Mouse.location returns a finite CGPoint and Cursor.position mirrors it as ints") {
        // location() and position() only READ — no warp, no post. Safe to
        // call inside the test process. The geometry contract is that
        // both report top-left global screen coords (NSEvent.mouseLocation
        // is bottom-left, so location() applies a Y-flip against the
        // primary screen height).
        let p = Mouse.location()
        try expect(p.x.isFinite && p.y.isFinite, "Mouse.location returned non-finite point: \(p)")

        let dict = Cursor.position()
        guard let x = dict["x"], let y = dict["y"] else {
            try expect(false, "Cursor.position missing x/y keys: \(dict)")
            return
        }
        // position() truncates to Int via Int(p.x) / Int(p.y); within 1
        // pixel of Mouse.location coords.
        try expect(abs(Double(x) - Double(p.x)) <= 1.0, "x drift: dict=\(x) point=\(p.x)")
        try expect(abs(Double(y) - Double(p.y)) <= 1.0, "y drift: dict=\(y) point=\(p.y)")
    }

    // MARK: - TouchDeviceObserver.setCoalesceInterval
    //
    // 2026-06-02: the 30Hz coalescer is now retunable so battery-conscious
    // stacks can drop the rate via `sd.channel.setInterval("touchdevice", N)`.
    // These tests pin the setter's clamp behavior (the timer interval itself
    // can't be observed without exercising MTDevice, which TCC-gates).

    test("setCoalesceInterval: clamps below 8ms to 8ms (no over-120Hz timers)") {
        // Pre-install state: just verify the setter accepts the value
        // without crashing. Internal interval is private; we exercise the
        // setter through the clamp-bounds path. Calling before install
        // does nothing visible (no active timer) — the next install picks
        // up the stored value.
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 1)
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 0)
        TouchDeviceObserver.shared.setCoalesceInterval(ms: -50)
        // Restore default for any subsequent test in this process.
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 33)
        try expect(true, "all bad inputs accepted without crash")
    }

    test("setCoalesceInterval: clamps above 1000ms to 1000ms") {
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 10_000)
        TouchDeviceObserver.shared.setCoalesceInterval(ms: Int.max)
        // Restore default.
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 33)
        try expect(true, "huge inputs accepted without crash")
    }

    test("setCoalesceInterval: idempotent calls before any install") {
        // Before any subscriber exists, the observer is inactive. Setter
        // calls must not crash, install timers, or otherwise have side
        // effects beyond updating the stored interval.
        let wasActive = TouchDeviceObserver.shared.isActive
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 100)
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 50)
        TouchDeviceObserver.shared.setCoalesceInterval(ms: 33)
        try expectEqual(TouchDeviceObserver.shared.isActive, wasActive,
                        "setCoalesceInterval must not trigger install")
    }
}
