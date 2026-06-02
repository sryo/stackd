import Foundation

// Tests for the two CLI helpers that were refactored to internal static so
// they're hammerable without constructing a StackHost:
//
//   - CLI.isSafeId(_:)      — input validation for `stackd new <name>`.
//                             Stack IDs become the host of `sd://<id>/`, so
//                             they must be ASCII-only.
//   - CLI.matchStacks(...)  — selector → candidate-list filter. Used by
//                             `set <selector> --css X=Y` and `bang …`. A
//                             bug that mass-matches every stack would
//                             silently apply CSS to all of them.
//
// What we DON'T test here: the full CLI.dispatch round-trip. That needs a
// StackHost + windows, which means StackWindow / WKWebView / NSPanel —
// none of which are unit-testable in a Foundation harness. CLI's verb
// surface is exercised by integration use (the real daemon runs them
// thousands of times a day).
func registerCLITests() {
    // MARK: - isSafeId

    test("isSafeId: simple ASCII identifier is accepted") {
        try expect(CLI.isSafeId("hello"))
        try expect(CLI.isSafeId("h_e-l-l-o_2"))
        try expect(CLI.isSafeId("a"))
        try expect(CLI.isSafeId("FooBar123"))
    }

    test("isSafeId: empty string is rejected") {
        try expect(!CLI.isSafeId(""))
    }

    test("isSafeId: leading dot is rejected (dotfile collision)") {
        try expect(!CLI.isSafeId(".hidden"))
        try expect(!CLI.isSafeId("."))
    }

    test("isSafeId: ASCII letters / digits / dash / underscore are the full allowed set") {
        // Sample of each allowed class plus their boundaries.
        try expect(CLI.isSafeId("abc-def_123"))
        try expect(!CLI.isSafeId("abc def"),  "space disallowed")
        try expect(!CLI.isSafeId("abc/def"),  "slash disallowed")
        try expect(!CLI.isSafeId("abc.def"),  "dot disallowed (would mid-string collide with extension-style names)")
        try expect(!CLI.isSafeId("abc@def"),  "@ disallowed")
        try expect(!CLI.isSafeId("abc!def"),  "! disallowed")
    }

    test("isSafeId: rejects Unicode letters (CJK / accented / emoji-letter)") {
        // The original bug: `c.isLetter` accepted these. Stack IDs become
        // the host of `sd://<id>/`, and RFC 3986 hosts must be ASCII —
        // non-ASCII hosts silently break the WKURLSchemeHandler lookup.
        try expect(!CLI.isSafeId("日本語"),  "CJK letters rejected")
        try expect(!CLI.isSafeId("café"),   "Latin-1 accented rejected")
        try expect(!CLI.isSafeId("emoji😀"), "emoji rejected")
        try expect(!CLI.isSafeId("Москва"), "Cyrillic rejected")
    }

    // MARK: - matchStacks

    test("matchStacks: literal selector matches exactly that id") {
        let candidates = ["battery", "cursor", "menu"]
        try expectEqual(CLI.matchStacks(selector: "cursor",  candidates: candidates), ["cursor"])
        try expectEqual(CLI.matchStacks(selector: "missing", candidates: candidates), [])
    }

    test("matchStacks: /regex/ selector matches the pattern") {
        let candidates = ["cursor", "cursor-test", "menu", "battery"]
        // /^c/ — every id starting with 'c'.
        try expectEqual(CLI.matchStacks(selector: "/^c/", candidates: candidates),
                        ["cursor", "cursor-test"])
        // /test$/ — every id ending with 'test'.
        try expectEqual(CLI.matchStacks(selector: "/test$/", candidates: candidates),
                        ["cursor-test"])
    }

    test("matchStacks: // (empty regex) matches NOTHING, not everything") {
        // The original bug: NSRegularExpression(pattern: "") compiles fine
        // and matches at every position, so `set // --css X=Y` would
        // silently mass-apply to every stack on disk. Fix: explicit empty-
        // pattern guard returns []. Use `/.*/` if you really want "all".
        let candidates = ["cursor", "battery", "menu"]
        try expectEqual(CLI.matchStacks(selector: "//", candidates: candidates), [])
    }

    test("matchStacks: invalid regex pattern returns empty list") {
        // Unmatched ( raises NSError from NSRegularExpression — the function
        // catches via try? and returns [] rather than crashing. This pins
        // the safety net.
        let candidates = ["cursor", "battery"]
        try expectEqual(CLI.matchStacks(selector: "/[invalid(/", candidates: candidates), [])
    }

    test("matchStacks: empty candidate list returns empty regardless of selector") {
        try expectEqual(CLI.matchStacks(selector: "cursor", candidates: []), [])
        try expectEqual(CLI.matchStacks(selector: "/.*/",   candidates: []), [])
    }
}
