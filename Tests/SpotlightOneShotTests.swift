import Foundation

// Tests for the one-shot side of `Sources/DataSources/Spotlight.swift` —
// specifically `Spotlight.find(predicate:scopes:attributes:limit:completion:)`.
//
// SpotlightLiveTests already pins the pure helpers (defaultAttributes,
// normalizedAttributes, jsonableValue) and the LiveQuery init guards.
// This file deliberately does NOT re-test those — it covers the unique
// surface of `find()`:
//
//   - The early-bail predicate guard: when predicate is nil or empty,
//     find() short-circuits to `completion([]); return` BEFORE touching
//     NSMetadataQuery. That branch is the only piece of find() we can
//     exercise without spinning up a real Spotlight query.
//
// What we CANNOT test here (and don't):
//   - The async completion path. It runs after NSMetadataQuery.start() on
//     the main runloop, and the suite avoids RunLoop spins (see the
//     NetworkTests.swift preamble for the same contract).
//   - The NSPredicate parse path. A malformed format string raises an
//     ObjC exception we can't catch from Swift — the daemon's contract
//     is "caller validates" (see the inline comment in Spotlight.swift).
//   - Custom-scope / sort-key / limit forwarding into NSMetadataQuery.
//     Those parameters only take effect once start() runs, which is the
//     async branch we explicitly skip.
//
// The early-bail tests still earn their keep: the "empty predicate
// produces [] (not nil)" contract is what JS callers rely on to
// distinguish "no matches" from "predicate parse failure". Drift here
// would silently break every stack consuming sd.spotlight.find.
//
// Wire-up: orchestrator adds `registerSpotlightOneShotTests()` to
// Tests/main.swift and appends this file to TEST_SOURCES in tests.sh.

func registerSpotlightOneShotTests() {
    test("find with nil predicate invokes completion with empty array (not nil)") {
        // Contract: nil predicate means "match nothing" — the callback
        // gets `[]`, never nil. nil is reserved for "predicate failed to
        // parse" (documented in Spotlight.swift). Conflating the two
        // would force JS callers into a brittle `?? []` everywhere.
        var received: [[String: Any]]?? = nil
        Spotlight.find(predicate: nil, scopes: nil,
                       attributes: nil, limit: nil) { result in
            received = .some(result)
        }
        try expect(received != nil, "completion was not invoked synchronously on nil predicate")
        let result = received!
        try expect(result != nil, "completion received nil; expected empty array on nil predicate")
        try expectEqual(result!.count, 0)
    }

    test("find with empty predicate invokes completion with empty array (not nil)") {
        // Mirror of the nil branch — `predicate: ""` is the JS-side
        // equivalent (a caller building a query string conditionally and
        // ending up with no clauses). Same contract: `[]`, not nil.
        var received: [[String: Any]]?? = nil
        Spotlight.find(predicate: "", scopes: nil,
                       attributes: nil, limit: nil) { result in
            received = .some(result)
        }
        try expect(received != nil, "completion was not invoked synchronously on empty predicate")
        let result = received!
        try expect(result != nil, "completion received nil; expected empty array on empty predicate")
        try expectEqual(result!.count, 0)
    }

    test("find early-bail completion fires synchronously (before find returns)") {
        // The empty-predicate branch invokes `completion([]); return`
        // inline — no DispatchQueue.main.async hop, no NSMetadataQuery.
        // Pinning this matters because the async branch DOES hop to main,
        // and a refactor that "unifies" the two paths would change the
        // observable timing for JS callers that pass an empty predicate
        // as a no-op probe. A flag set after the find() call must still
        // be false when the callback fires.
        var fired = false
        var sawFlagSet = false
        Spotlight.find(predicate: "", scopes: nil,
                       attributes: nil, limit: nil) { _ in
            fired = true
            sawFlagSet = true  // captures the value of `flagSet` at call time
        }
        try expect(fired, "completion did not fire synchronously")
        // If completion had been deferred to a later runloop turn, the
        // `sawFlagSet` capture below would run AFTER we set it — so the
        // test would still pass. To distinguish inline vs deferred, we
        // observe `fired` BEFORE returning from find() (above) which is
        // the load-bearing assertion. The `sawFlagSet` read here is a
        // belt-and-suspenders sanity check that the closure actually ran.
        try expect(sawFlagSet)
    }

    test("find early-bail ignores scopes / attributes / limit parameters") {
        // The nil/empty predicate path short-circuits BEFORE reading
        // scopes, attributes, or limit. Passing exotic values on that
        // branch must not crash and must not influence the `[]` result.
        // Guards against a refactor that moves param validation above
        // the predicate guard.
        var received: [[String: Any]]?? = nil
        Spotlight.find(predicate: nil,
                       scopes: ["/nonexistent/path/that/should/be/ignored"],
                       attributes: ["kMDItemFSName", "kMDItemNotARealAttribute"],
                       limit: -42) { result in
            received = .some(result)
        }
        try expect(received != nil, "completion was not invoked on nil predicate with exotic params")
        try expectEqual(received!?.count, 0)
    }

    test("find early-bail completion is invoked exactly once") {
        // The nil-predicate branch is `completion([]); return` — single
        // call, no fallthrough into the async observer-registration code.
        // A double-invoke would mean both the early-bail AND the
        // notification path fired, which would double-deliver to JS
        // subscribers and break idempotent UI updates.
        var callCount = 0
        Spotlight.find(predicate: nil, scopes: nil,
                       attributes: nil, limit: nil) { _ in
            callCount += 1
        }
        try expectEqual(callCount, 1)
    }
}
