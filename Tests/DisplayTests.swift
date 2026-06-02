import Foundation
import AppKit
import CoreGraphics

// Tests for the read-only surface of Display.swift.
//
// Out of scope by design:
//   - setBrightness(displayID:_:) — mutates the user's actual panel brightness
//     on both the built-in (DisplayServices SPI) and external (DDC/CI over
//     IOAVService) paths. Calling it during a test run would visibly dim or
//     brighten the user's monitors. The 0..1 clamp lives inside the setter,
//     so it can't be exercised through the public API without mutating
//     state — left uncovered intentionally.
//   - CGDisplayCapture / CGConfigure* — would steal the user's display.
//   - DisplayObserver / DisplayHotplug — observer lifecycle drives real
//     CG reconfiguration callbacks. Covered by integration reality.
//   - DisplaySnapshot.capture — async ScreenCaptureKit call that requires
//     screen-recording TCC consent; covered by PrivacyRecordingTests pattern.
//   - DisplayLink — would start a real CVDisplayLink against the active
//     CG displays. Snapshot is nil before vsync arrives so a sync read
//     returns no contract beyond "nil".
//
// In scope:
//   - Display.all() → list-of-dicts shape contract (keys + types) that JS
//     consumers depend on. Real values come from the user's hardware, so
//     we assert shape only, never resolutions or display names.
//   - Display.brightness(of:) → Float? probe. Real values come from the
//     panel; we assert range when present, nothing when absent.
//   - Appearance.current() → dict shape (dark/accent/accentHex/reduceMotion)
//     used by every theme-aware stack.

func registerDisplayTests() {
    // MARK: - Display.all() shape

    test("Display.all() returns one row per NSScreen") {
        // The function maps NSScreen.screens 1:1. If headless CI ever runs
        // this it would return [], which is still a valid mapping — so we
        // only assert count parity, not non-empty.
        let rows = Display.all()
        try expectEqual(rows.count, NSScreen.screens.count)
    }

    test("Display.all() rows expose the documented key set") {
        // JS consumers (sd.display.all subscribers, brightness HUD stacks)
        // pattern-match on these keys. A renamed key silently breaks the UI.
        for row in Display.all() {
            try expect(row["displayID"]    != nil, "missing 'displayID'")
            try expect(row["uuid"]         != nil, "missing 'uuid'")
            try expect(row["name"]         != nil, "missing 'name'")
            try expect(row["frame"]        != nil, "missing 'frame'")
            try expect(row["visibleFrame"] != nil, "missing 'visibleFrame'")
            try expect(row["scale"]        != nil, "missing 'scale'")
            try expect(row["builtin"]      != nil, "missing 'builtin'")
            try expect(row["brightness"]   != nil, "missing 'brightness'")
        }
    }

    test("Display.all() row types match the JS contract") {
        // Stacks treat these as Int/Bool/CGFloat/dict. A regression to
        // NSNumber-wrapped Bool, or a brightness arriving as Double, would
        // silently break consumers.
        for row in Display.all() {
            try expect(row["displayID"]! is Int,    "displayID should be Int, got \(type(of: row["displayID"]!))")
            try expect(row["uuid"]!      is String, "uuid should be String, got \(type(of: row["uuid"]!))")
            try expect(row["name"]!      is String, "name should be String, got \(type(of: row["name"]!))")
            try expect(row["builtin"]!   is Bool,   "builtin should be Bool, got \(type(of: row["builtin"]!))")
            try expect(row["scale"]!     is CGFloat, "scale should be CGFloat, got \(type(of: row["scale"]!))")
            // brightness is Float when readable, NSNull when the panel doesn't
            // expose a getter (most external monitors without DDC read support).
            let b = row["brightness"]!
            try expect(b is Float || b is NSNull,
                       "brightness should be Float or NSNull, got \(type(of: b))")
        }
    }

    test("Display.all() frame + visibleFrame are {x,y,w,h} Int dicts") {
        // Top-left CG coords serialized as Int — matches sd.mouse / sd.windows
        // / hotcorners. A regression to CGFloat or to a y-flipped frame would
        // break every coordinate-comparing stack.
        for row in Display.all() {
            guard let frame = row["frame"] as? [String: Int],
                  let visible = row["visibleFrame"] as? [String: Int] else {
                try expect(false, "frame/visibleFrame should be [String: Int]")
                return
            }
            for key in ["x", "y", "w", "h"] {
                try expect(frame[key]   != nil, "frame missing '\(key)'")
                try expect(visible[key] != nil, "visibleFrame missing '\(key)'")
            }
            // visibleFrame is always inset-or-equal to frame on every axis
            // (the menu bar / dock can only shrink, never grow, the usable
            // area). If this flips we've miscomputed the inset diff.
            try expect(visible["w"]! <= frame["w"]!, "visibleFrame wider than frame")
            try expect(visible["h"]! <= frame["h"]!, "visibleFrame taller than frame")
        }
    }

    test("Display.all() exactly one row is builtin on a Mac with an internal panel") {
        // CGDisplayIsBuiltin is a per-display bit. On any Mac there's at most
        // one built-in panel (the laptop lid or the iMac/Studio Display).
        // Headless or external-only setups report zero; we assert ≤1, not ==1.
        let builtinCount = Display.all().filter { ($0["builtin"] as? Bool) == true }.count
        try expect(builtinCount <= 1, "expected ≤1 builtin display, got \(builtinCount)")
    }

    // MARK: - Display.brightness(of:)

    test("Display.brightness(of:) returns Float in 0...1 when readable") {
        // The built-in panel exposes a getter through DisplayServices; most
        // external monitors don't implement the DDC read side. Either way,
        // a non-nil return must be a normalized brightness — values outside
        // 0..1 mean we've mis-scaled the DDC percent or mis-read the SPI.
        for row in Display.all() {
            guard let id = row["displayID"] as? Int else { continue }
            if let b = Display.brightness(of: CGDirectDisplayID(id)) {
                try expect(b >= 0.0 && b <= 1.0,
                           "brightness out of range: \(b) for display \(id)")
            }
        }
    }

    test("Display.brightness(of:) returns nil for a bogus display ID") {
        // Display ID 0xDEADBEEF is overwhelmingly unlikely to be active.
        // DisplayServices returns non-zero for unknown IDs; DDC has nothing
        // to talk to. Either path must degrade to nil, not crash.
        let result = Display.brightness(of: CGDirectDisplayID(0xDEADBEEF))
        try expect(result == nil, "expected nil for bogus display ID, got \(String(describing: result))")
    }

    // MARK: - Appearance.current() shape

    test("Appearance.current() exposes dark/accent/accentHex/reduceMotion") {
        // Theme-aware stacks pattern-match these keys. The accent dict is
        // {r,g,b} Int triples; accentHex is the convenience CSS form.
        let dict = Appearance.current()
        try expect(dict["dark"]         is Bool,   "dark should be Bool")
        try expect(dict["reduceMotion"] is Bool,   "reduceMotion should be Bool")
        try expect(dict["accentHex"]    is String, "accentHex should be String")
        guard let accent = dict["accent"] as? [String: Int] else {
            try expect(false, "accent should be [String: Int]")
            return
        }
        for key in ["r", "g", "b"] {
            guard let v = accent[key] else {
                try expect(false, "accent missing '\(key)'")
                return
            }
            // 8-bit channels — anything outside 0..255 means we forgot to
            // round / clamp when converting from sRGB CGFloat.
            try expect(v >= 0 && v <= 255, "accent.\(key) out of range: \(v)")
        }
    }

    // MARK: - DisplayObserver subscriber-gating
    //
    // 2026-06-02: DisplayObserver added distributed-notification observers
    // for brightness change (BezelUI / BezelServices / com.apple.brightness)
    // plus a tightened 1s safety-net poll. The contract that makes any of
    // that worthwhile is RefCountedObserver gating — if a future refactor
    // wires the timer at module-load time, idle CPU regresses silently.

    test("DisplayObserver: inactive at startup (no subscribers)") {
        try expect(!DisplayObserver.shared.isActive,
                   "DisplayObserver must not be active before any stack subscribes")
    }

    test("DisplayObserver: activates on subscribe, deactivates after debounce") {
        let token = DisplayObserver.shared.subscribe { }
        try expect(DisplayObserver.shared.isActive,
                   "subscribe should activate the observer")
        token.cancel()
        // 5s teardown debounce per RefCountedObserver. Spin the runloop
        // past it so the asyncAfter work item fires.
        let deadline = Date().addingTimeInterval(5.2)
        while DisplayObserver.shared.isActive && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        try expect(!DisplayObserver.shared.isActive,
                   "DisplayObserver must deactivate ≤5.2s after last unsubscribe")
    }
}
