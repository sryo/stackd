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
//   - Display.brightness(of:) → range when present (via all()), nil for an
//     unknown display ID.
//   - Appearance.current() → dict shape used by every theme-aware stack, and
//     the pure isDark(interfaceStyle:) / isDark(appearance:) mappings.
//     current() lazily creates a zero-width NSStatusItem to read the
//     menubar's appearance.

func registerDisplayTests() {
    // MARK: - Display.all() shape

    test("Display.all() returns one row per NSScreen with the documented keys and types") {
        // One call: each row reads brightness, which on external displays is
        // a live DDC/I²C round-trip. JS consumers (sd.display.all subscribers,
        // brightness HUDs) pattern-match on these keys and types.
        let rows = Display.all()
        try expectEqual(rows.count, NSScreen.screens.count)
        var builtinCount = 0
        for row in rows {
            try expect(row["displayID"] is Int,    "displayID should be Int: \(row)")
            try expect(row["uuid"]      is String, "uuid should be String: \(row)")
            try expect(row["name"]      is String, "name should be String: \(row)")
            try expect(row["builtin"]   is Bool,   "builtin should be Bool: \(row)")
            try expect(row["scale"]     is CGFloat, "scale should be CGFloat: \(row)")
            // Float when readable, NSNull when the panel has no getter
            // (most external monitors without DDC read support).
            let b = row["brightness"]
            try expect(b is Float || b is NSNull, "brightness should be Float or NSNull: \(row)")
            if let v = b as? Float {
                try expect(v >= 0.0 && v <= 1.0, "brightness out of range: \(v)")
            }
            // Top-left CG coords serialized as Int — matches sd.mouse /
            // sd.windows / hotcorners.
            guard let frame = row["frame"] as? [String: Int],
                  let visible = row["visibleFrame"] as? [String: Int] else {
                throw Expectation(message: "frame/visibleFrame should be [String: Int]: \(row)")
            }
            for key in ["x", "y", "w", "h"] {
                try expect(frame[key]   != nil, "frame missing '\(key)'")
                try expect(visible[key] != nil, "visibleFrame missing '\(key)'")
            }
            // The menu bar / dock only shrink the usable area, so
            // visibleFrame lies inside frame on every edge.
            try expect(visible["x"]! >= frame["x"]!, "visibleFrame left of frame")
            try expect(visible["y"]! >= frame["y"]!, "visibleFrame above frame")
            try expect(visible["w"]! <= frame["w"]!, "visibleFrame wider than frame")
            try expect(visible["h"]! <= frame["h"]!, "visibleFrame taller than frame")
            if row["builtin"] as? Bool == true { builtinCount += 1 }
        }
        try expect(builtinCount <= 1, "expected ≤1 builtin display, got \(builtinCount)")
    }

    // MARK: - Display.brightness(of:)

    test("Display.brightness(of:) returns nil for a bogus display ID") {
        // Display ID 0xDEADBEEF is overwhelmingly unlikely to be active.
        // DisplayServices returns non-zero for unknown IDs; DDC has nothing
        // to talk to. Either path must degrade to nil, not crash.
        let result = Display.brightness(of: CGDirectDisplayID(0xDEADBEEF))
        try expect(result == nil, "expected nil for bogus display ID, got \(String(describing: result))")
    }

    // MARK: - Appearance.current() shape

    test("Appearance.current() exposes dark/menubarDark/accent/accentHex/reduceMotion") {
        // Theme-aware stacks pattern-match these keys. The accent dict is
        // {r,g,b} 8-bit channels; accentHex is the same color in CSS form.
        let dict = Appearance.current()
        try expect(dict["dark"]         is Bool,   "dark should be Bool")
        try expect(dict["menubarDark"]  is Bool,   "menubarDark should be Bool")
        try expect(dict["reduceMotion"] is Bool,   "reduceMotion should be Bool")
        guard let accent = dict["accent"] as? [String: Int],
              let r = accent["r"], let g = accent["g"], let b = accent["b"] else {
            throw Expectation(message: "accent should be [String: Int] with r/g/b, got \(String(describing: dict["accent"]))")
        }
        for v in [r, g, b] {
            try expect(v >= 0 && v <= 255, "accent channel out of range: \(v)")
        }
        try expectEqual(dict["accentHex"] as? String, String(format: "#%02x%02x%02x", r, g, b))
    }

    test("Appearance.isDark(appearance:) reads the menubar's vibrant variants") {
        // The menubar reports VibrantLight / VibrantDark from the wallpaper
        // luminance under it, independent of the system light/dark setting.
        let dark  = NSAppearance(named: .vibrantDark)!
        let light = NSAppearance(named: .vibrantLight)!
        try expect(Appearance.isDark(appearance: dark), "vibrantDark should be dark")
        try expect(!Appearance.isDark(appearance: light), "vibrantLight should be light")
        try expect(Appearance.isDark(appearance: NSAppearance(named: .darkAqua)!), "darkAqua should be dark")
        try expect(!Appearance.isDark(appearance: NSAppearance(named: .aqua)!), "aqua should be light")
    }

    test("Appearance.isDark maps the AppleInterfaceStyle default") {
        // macOS writes exactly "Dark" while dark mode is active (manually
        // chosen or scheduled auto-switch) and deletes the key for light —
        // so absent means light, and no other value is ever written.
        try expect(Appearance.isDark(interfaceStyle: "Dark"), "\"Dark\" should be dark")
        try expect(!Appearance.isDark(interfaceStyle: nil), "absent key should be light")
        try expect(!Appearance.isDark(interfaceStyle: "Light"), "unknown value should be light")
    }

    // MARK: - DisplayObserver subscriber-gating
    //
    // DisplayObserver runs distributed-notification observers plus a safety
    // poll; it must stay idle until a stack subscribes. The generic
    // subscribe/debounce/teardown lifecycle is covered by
    // RefCountedObserverTests.

    test("DisplayObserver: inactive at startup (no subscribers)") {
        try expect(!DisplayObserver.shared.isActive,
                   "DisplayObserver must not be active before any stack subscribes")
    }
}
