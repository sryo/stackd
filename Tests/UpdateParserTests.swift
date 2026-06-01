import Foundation

// Tests for the pure `softwareupdate -l` stdout parser. The subprocess
// hop and caching aren't tested here — they're impure / require a Mac
// with pending updates to be meaningful. The parser is the bug surface
// (format drift across macOS versions) so it gets the coverage.

func registerUpdateParserTests() {
    test("parse empty input returns no updates") {
        try expectEqual(Update.parse("").count, 0)
    }

    test("parse 'No new software available' returns no updates") {
        let raw = """
        Software Update Tool

        Finding available software
        No new software available.
        """
        try expectEqual(Update.parse(raw).count, 0)
    }

    test("parse single update extracts label/title/version/size/recommended/restart") {
        let raw = """
        Software Update Tool

        Finding available software

        Software Update found the following new or updated software:
        * Label: macOS Sonoma 14.5-23F79
        \tTitle: macOS Sonoma 14.5, Version: 14.5, Size: 7159564KiB, Recommended: YES, Action: restart,
        """
        let updates = Update.parse(raw)
        try expectEqual(updates.count, 1)
        try expectEqual(updates[0]["label"]           as? String, "macOS Sonoma 14.5-23F79")
        try expectEqual(updates[0]["title"]           as? String, "macOS Sonoma 14.5")
        try expectEqual(updates[0]["version"]         as? String, "14.5")
        try expectEqual(updates[0]["sizeKiB"]         as? Int,    7159564)
        try expectEqual(updates[0]["recommended"]     as? Bool,   true)
        try expectEqual(updates[0]["requiresRestart"] as? Bool,   true)
    }

    test("parse update without restart action sets requiresRestart=false") {
        let raw = """
        Software Update found the following new or updated software:
        * Label: Safari17.5-23F79
        \tTitle: Safari, Version: 17.5, Size: 1234567KiB, Recommended: YES,
        """
        let updates = Update.parse(raw)
        try expectEqual(updates.count, 1)
        try expectEqual(updates[0]["requiresRestart"] as? Bool, false)
    }

    test("parse update with Recommended: NO sets recommended=false") {
        let raw = """
        Software Update found the following new or updated software:
        * Label: Beta-Junk-1.0
        \tTitle: Beta Junk, Version: 1.0, Size: 100KiB, Recommended: NO,
        """
        let updates = Update.parse(raw)
        try expectEqual(updates.count, 1)
        try expectEqual(updates[0]["recommended"] as? Bool, false)
    }

    test("parse multiple updates returns each as its own entry") {
        let raw = """
        Software Update found the following new or updated software:
        * Label: macOS Sonoma 14.5-23F79
        \tTitle: macOS Sonoma 14.5, Version: 14.5, Size: 7159564KiB, Recommended: YES, Action: restart,
        * Label: Safari17.5-23F79
        \tTitle: Safari, Version: 17.5, Size: 1234567KiB, Recommended: YES,
        """
        let updates = Update.parse(raw)
        try expectEqual(updates.count, 2)
        try expectEqual(updates[0]["label"] as? String, "macOS Sonoma 14.5-23F79")
        try expectEqual(updates[1]["label"] as? String, "Safari17.5-23F79")
    }

    test("parse leading-asterisk label without details block still produces an entry") {
        let raw = """
        Software Update found the following new or updated software:
        * Label: BareLabelOnly-1.0
        """
        let updates = Update.parse(raw)
        try expectEqual(updates.count, 1)
        try expectEqual(updates[0]["label"] as? String, "BareLabelOnly-1.0")
        // Missing details degrade to absent, not crash.
        try expect(updates[0]["title"]   == nil)
        try expect(updates[0]["version"] == nil)
        try expect(updates[0]["sizeKiB"] == nil)
    }

    test("parse ignores non-update preamble lines") {
        let raw = """
        Software Update Tool
        Some warning line.
        Finding available software
        Downloading nothing-relevant.

        Software Update found the following new or updated software:
        * Label: Real-1.0
        \tTitle: Real, Version: 1.0, Size: 10KiB, Recommended: YES,
        """
        let updates = Update.parse(raw)
        try expectEqual(updates.count, 1)
        try expectEqual(updates[0]["label"] as? String, "Real-1.0")
    }
}
