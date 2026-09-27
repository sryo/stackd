import AppKit

// Haptic.perform actuates the user's trackpad, so only the pattern-name
// parsing is exercised here.

func registerHapticTests() {
    test("Haptic.pattern maps each documented name to its NSHapticFeedbackManager pattern") {
        try expectEqual(Haptic.pattern(named: "generic"),     .generic)
        try expectEqual(Haptic.pattern(named: "alignment"),   .alignment)
        try expectEqual(Haptic.pattern(named: "levelChange"), .levelChange)
    }

    test("Haptic.pattern defaults to generic when the name is missing") {
        try expectEqual(Haptic.pattern(named: nil), .generic)
    }

    test("Haptic.pattern rejects unknown names instead of guessing") {
        try expect(Haptic.pattern(named: "buzz") == nil, "unknown name should not map to a pattern")
        try expect(Haptic.pattern(named: "") == nil, "empty name should not map to a pattern")
    }

    test("Haptic.actuationID accepts positive whole numbers up to 255") {
        try expectEqual(Haptic.actuationID(from: 1), 1)
        try expectEqual(Haptic.actuationID(from: 16), 16)
        try expectEqual(Haptic.actuationID(from: 6.0), 6)
    }

    test("Haptic.actuationID rejects missing, fractional and out-of-range values") {
        try expect(Haptic.actuationID(from: nil) == nil, "nil should be rejected")
        try expect(Haptic.actuationID(from: 0) == nil, "0 should be rejected")
        try expect(Haptic.actuationID(from: -3) == nil, "negative should be rejected")
        try expect(Haptic.actuationID(from: 2.5) == nil, "fractional should be rejected")
        try expect(Haptic.actuationID(from: 256) == nil, "256 should be rejected")
        try expect(Haptic.actuationID(from: "3") == nil, "strings should be rejected")
    }

    test("haptic is a registered, inferable permission") {
        try expect(Permissions.all.contains("haptic"), "Permissions.all is missing haptic")
        try expect(Permissions.inferable.contains("haptic"), "Permissions.inferable is missing haptic")
    }
}
