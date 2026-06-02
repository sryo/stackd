import Foundation

// Tests for the Objective-C trampoline at Sources/C/SafePredicate.m which
// wraps `NSPredicate.predicateWithFormat:` in @try/@catch. The reason this
// exists: NSPredicate raises NSInvalidArgumentException on malformed
// format strings, and Swift `try?` doesn't catch NSExceptions. Without
// the trampoline a single bad user-authored Spotlight query would crash
// the whole daemon. So these tests pin the exact contract callers rely on:
//   - valid format → non-nil NSPredicate (round-trippable via .predicateFormat)
//   - malformed format → nil, errorOut populated with NSException reason
//   - nil errorOut parameter is allowed and doesn't crash
//
// Verified production callers in Spotlight.swift:60 + :135 both use the
// non-throwing trampoline form; if either path stops using it, this file
// is still the first place a regression would surface.
func registerSafePredicateTests() {
    test("SafePredicate: valid format returns a non-nil predicate") {
        var error: NSString? = nil
        let p = StackdSafeNSPredicate("kMDItemFSName == 'test'", &error)
        try expect(p != nil, "expected non-nil predicate for valid format")
        try expect(error == nil, "errorOut should not be populated on success, got: \(error ?? "")")
    }

    test("SafePredicate: malformed format returns nil") {
        // `kMDItemFSName == ==` is syntactically invalid — predicateWithFormat
        // raises NSInvalidArgumentException, which the trampoline catches.
        var error: NSString? = nil
        let p = StackdSafeNSPredicate("kMDItemFSName == ==", &error)
        try expect(p == nil, "expected nil predicate for malformed format")
    }

    test("SafePredicate: malformed format populates errorOut with the NSException reason") {
        var error: NSString? = nil
        _ = StackdSafeNSPredicate("$$$ totally not a predicate $$$", &error)
        try expect(error != nil, "errorOut should carry the NSException reason on failure")
        // Don't pin the exact message — Foundation's format-parser wording is
        // not API. Just confirm it's non-empty so callers have something to log.
        try expect((error?.length ?? 0) > 0, "errorOut message should be non-empty")
    }

    test("SafePredicate: nil errorOut pointer is allowed on malformed input") {
        // Spotlight's callers pass non-nil errorOut today, but the contract
        // declares `errorOut` Nullable. A future caller that doesn't care
        // about the reason should be able to pass nil without crashing.
        let p = StackdSafeNSPredicate("kMDItemFSName == ==", nil)
        try expect(p == nil, "expected nil predicate, nil errorOut is allowed")
    }

    test("SafePredicate: empty format raises but is caught (returns nil)") {
        // Empty-string predicate is its own NSInvalidArgumentException path
        // ("Unable to parse the format string"). Production code short-
        // circuits empty predicates before reaching the trampoline, but the
        // safety net should still work if someone removes that guard.
        var error: NSString? = nil
        let p = StackdSafeNSPredicate("", &error)
        try expect(p == nil, "expected nil predicate for empty format")
        try expect(error != nil, "errorOut should carry the reason")
    }

    test("SafePredicate: predicate evaluates against an NSDictionary on success") {
        // Witness that the returned object IS a usable NSPredicate, not just
        // a stand-in. Spotlight ultimately hands the predicate to
        // NSMetadataQuery which evaluates it — proving evaluatability here
        // catches a regression where the wrapper returns an opaque proxy.
        var error: NSString? = nil
        guard let p = StackdSafeNSPredicate("name == 'demo'", &error) else {
            throw Expectation(message: "predicate construction failed: \(error ?? "")")
        }
        try expect(p.evaluate(with: ["name": "demo"]),  "predicate should match the target dict")
        try expect(!p.evaluate(with: ["name": "other"]), "predicate should reject non-matching dict")
    }
}
