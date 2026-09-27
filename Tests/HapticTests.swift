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

    test("haptic is a registered, inferable permission") {
        try expect(Permissions.all.contains("haptic"), "Permissions.all is missing haptic")
        try expect(Permissions.inferable.contains("haptic"), "Permissions.inferable is missing haptic")
    }
}
