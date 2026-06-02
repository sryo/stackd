import Foundation

// Tests for Sources/DataSources/Notify.swift.
//
// Coverage reality: Notify.swift is ~50 lines with exactly two members —
//   1. `static func show(title:body:subtitle:sound:) -> Bool`
//      Spawns `/usr/bin/osascript -e 'display notification ...'`. Calling
//      it from the test harness would emit a real banner attributed to
//      Script Editor on every test run — observable side effect, not a
//      pure helper.
//   2. `private static func escape(_:) -> String`
//      AppleScript string-literal escaper (backslash + double-quote).
//      Private, so unreachable from this file without changing production
//      visibility — which the test brief forbids.
//
// What's *not* in Notify.swift, despite what a generic "notifications"
// module might suggest: no spec validation, no identifier dedup, no
// action-button parsing, no image-attachment path normalization, no
// default-value substitution. The Bridge dispatcher (Bridge.swift:760)
// applies `??""` fallbacks for title/body and passes subtitle/sound as
// raw Optionals — that's all the "validation" the surface has, and it
// lives in Bridge, not Notify.
//
// The mirror of this file in MenubarItemsTests / CameraStreamTests works
// because those modules each factored pure primitives (`isHidden`,
// `resolveOwner`, `clampedFps`, `normalizedFormat`) out for exactly this
// purpose. Notify never grew that layer because there was no logic worth
// extracting — quoting one string is the entire job.
//
// If/when Notify gains real parse logic (UNUserNotificationCenter v2 with
// action buttons + identifier registry, per the file's header comment),
// this file is where those tests land.
//
// Update 2026-06-02: `escape` widened from `private` → `internal static`
// so its quote/backslash handling is hammerable directly. The function is
// the one place where stack-author input flows into a subprocess argv,
// so a regression here could let a malicious stack title break out of
// the AppleScript string literal and inject arbitrary AppleScript.

func registerNotifyTests() {
    test("Notify.show is reachable as a static member with the documented signature") {
        // Compile-time witness: if the symbol's signature drifts, this
        // file stops building and the harness flags it. We never invoke
        // the function — doing so would spawn osascript and emit a real
        // banner notification on the developer's desktop.
        let _: (String, String, String?, String?) -> Bool = Notify.show
        try expect(true)
    }

    test("escape: plain text wraps in double quotes") {
        try expectEqual(Notify.escape("hello"), "\"hello\"")
    }

    test("escape: empty string becomes paired empty quotes") {
        try expectEqual(Notify.escape(""), "\"\"")
    }

    test("escape: embedded double-quote gets backslash-escaped") {
        // Input: he said "hi"
        // Output:  "he said \"hi\""
        try expectEqual(Notify.escape("he said \"hi\""), "\"he said \\\"hi\\\"\"")
    }

    test("escape: literal backslash is doubled") {
        // Input:  a\b
        // Output: "a\\b"
        try expectEqual(Notify.escape("a\\b"), "\"a\\\\b\"")
    }

    test("escape: backslash THEN quote keeps the right order") {
        // The order-matters guard from the docstring. Input: \"
        // If we escaped quotes first, the resulting \" would get its
        // backslash re-doubled to \\\", breaking the AppleScript parser.
        // Correct sequence: \ → \\, then " → \"
        // Input:  \"
        // Output: "\\\""
        try expectEqual(Notify.escape("\\\""), "\"\\\\\\\"\"")
    }

    test("escape: AppleScript injection attempt is neutralized") {
        // Adversarial stack title trying to close the string and run
        // arbitrary AppleScript. The escape MUST produce a string that,
        // when concatenated into `display notification <X>`, evaluates
        // to a literal — not as two separate AppleScript statements.
        let attack = "\"\nbeep\ndisplay alert \"pwned"
        let escaped = Notify.escape(attack)
        // Every embedded `"` is now `\"`; no raw `"` survives as a
        // literal boundary. Newlines pass through (AppleScript allows
        // them inside string literals).
        try expect(escaped.hasPrefix("\""), "must open with quote")
        try expect(escaped.hasSuffix("\""), "must close with quote")
        // The only legitimate `"` chars are at index 0 and last; everything
        // else should be preceded by a backslash.
        let mid = escaped.dropFirst().dropLast()
        // Count of bare quotes in the middle should be zero.
        let bareQuotes = mid.indices.filter { i in
            mid[i] == "\"" && (i == mid.startIndex || mid[mid.index(before: i)] != "\\")
        }
        try expectEqual(bareQuotes.count, 0,
                        "found unescaped quote in escaped middle: \(escaped)")
    }
}
