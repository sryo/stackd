import Foundation

// Tests for the pure helpers backing Spotlight.find / Spotlight.subscribe.
// The NSMetadataQuery dance is impure (main runloop + Spotlight index +
// notification center), so we can't drive it in isolation here. What we
// CAN test deterministically:
//
//   - defaultAttributes — the kMDItem* fallback list every caller inherits
//     when they don't pass `attributes`. Drift in this list breaks every
//     stack that relies on a default field, so it gets pinned.
//   - jsonableValue — the per-attribute coercion that turns NSDate → epoch
//     seconds (Double) and URL → path String. JSON-serialization survives
//     or fails on this single helper.
//   - normalizedAttributes — the "caller-passed attributes vs fallback"
//     decision the live + one-shot paths share. Both subscribe() and find()
//     need to default identically, so the helper exists to avoid drift.
//
// Test what's deterministic; leave the macOS subsystem to the live runtime.

func registerSpotlightLiveTests() {
    test("defaultAttributes contains the documented baseline set") {
        // Pin the contract: name, path, content-type, change date, creation
        // date, size. Stacks rely on these without passing `attributes`.
        let attrs = Set(Spotlight.defaultAttributes)
        try expect(attrs.contains("kMDItemFSName"))
        try expect(attrs.contains("kMDItemPath"))
        try expect(attrs.contains("kMDItemContentType"))
        try expect(attrs.contains("kMDItemFSContentChangeDate"))
        try expect(attrs.contains("kMDItemFSCreationDate"))
        try expect(attrs.contains("kMDItemFSSize"))
    }

    test("normalizedAttributes nil falls back to the default set") {
        let out = Spotlight.normalizedAttributes(nil)
        try expectEqual(out, Spotlight.defaultAttributes)
    }

    test("normalizedAttributes empty array falls back to the default set") {
        // Defensive: a caller passing `attributes: []` almost certainly
        // meant "use the defaults" rather than "return objects with no
        // fields". Mirror the nil branch.
        let out = Spotlight.normalizedAttributes([])
        try expectEqual(out, Spotlight.defaultAttributes)
    }

    test("normalizedAttributes preserves caller-supplied list verbatim") {
        let custom = ["kMDItemFSName", "kMDItemDisplayName"]
        let out = Spotlight.normalizedAttributes(custom)
        try expectEqual(out, custom)
    }

    test("jsonableValue converts NSDate to epoch seconds Double") {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let v = Spotlight.jsonableValue(d)
        try expectEqual(v as? Double, 1_700_000_000)
    }

    test("jsonableValue converts URL to path String") {
        let u = URL(fileURLWithPath: "/Users/me/Downloads/foo.pdf")
        let v = Spotlight.jsonableValue(u)
        try expectEqual(v as? String, "/Users/me/Downloads/foo.pdf")
    }

    test("jsonableValue passes through NSString / NSNumber unchanged") {
        // Most kMDItem* attribute values are NSString or NSNumber already
        // — JSON-able out of the box. The coercion helper is a pass-through
        // for anything that isn't a Date / URL.
        try expectEqual(Spotlight.jsonableValue("hello") as? String, "hello")
        try expectEqual(Spotlight.jsonableValue(42) as? Int, 42)
    }

    // ── LiveQuery construction guard ─────────────────────────────────────
    // The failable initializer's predicate guards are synchronous and run
    // before any NSMetadataQuery starts; a nil LiveQuery is what Bridge
    // uses to reject a subscription.
    test("LiveQuery init returns nil on nil or empty predicate") {
        let nilPred = Spotlight.LiveQuery(predicate: nil, scopes: nil,
                                          attributes: nil, limit: nil) { _ in }
        try expect(nilPred == nil, "expected nil LiveQuery for nil predicate")
        let emptyPred = Spotlight.LiveQuery(predicate: "", scopes: nil,
                                            attributes: nil, limit: nil) { _ in }
        try expect(emptyPred == nil, "expected nil LiveQuery for empty predicate")
    }

    test("LiveQuery init returns nil on a malformed predicate instead of raising") {
        // NSPredicate(format:) raises an ObjC exception on bad input; the
        // SafePredicate wrap turns that into a nil LiveQuery.
        let q = Spotlight.LiveQuery(predicate: "$$$ malformed predicate $$$", scopes: nil,
                                    attributes: nil, limit: nil) { _ in }
        try expect(q == nil, "expected nil LiveQuery for malformed predicate")
    }
}
