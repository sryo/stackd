import Foundation

// Tests for Sources/DataSources/Notify.swift.
//
// `Notify.show` spawns `/usr/bin/osascript -e 'display notification ...'`;
// calling it here would post a real banner on every run, so it stays
// untested. `Notify.escape` is the one place stack-author input flows into
// that subprocess's AppleScript source, so its quote/backslash handling is
// pinned here — a regression would let a stack title break out of the
// string literal and inject arbitrary AppleScript.

func registerNotifyTests() {
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

    test("escape: AppleScript injection attempt stays inside one string literal") {
        // Adversarial stack title trying to close the string and run
        // arbitrary AppleScript. Every embedded quote must come out escaped;
        // newlines pass through (AppleScript allows them inside literals).
        let attack = "\"\nbeep\ndisplay alert \"pwned"
        try expectEqual(Notify.escape(attack),
                        "\"\\\"\nbeep\ndisplay alert \\\"pwned\"")
    }
}
