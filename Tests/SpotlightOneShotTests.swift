import Foundation

// Tests for the one-shot side of `Sources/DataSources/Spotlight.swift` —
// `Spotlight.find(predicate:scopes:attributes:limit:completion:)`.
// SpotlightLiveTests covers the shared pure helpers and LiveQuery guards.
//
// Covered: the synchronous early-bail paths. A nil/empty predicate or one
// that fails to parse completes inline with `[]` before any NSMetadataQuery
// is created.
//
// Not covered: the gather path. It runs a real query against the host's
// Spotlight index, so results (and latency) depend on machine state;
// scope/limit forwarding only takes effect there.

func registerSpotlightOneShotTests() {
    test("find with nil or empty predicate completes inline, exactly once, with []") {
        // Exotic scopes/attributes/limit must not matter: the predicate guard
        // runs before any of them are read.
        for predicate in [nil, ""] as [String?] {
            var calls = 0
            var received: [[String: Any]]?
            Spotlight.find(predicate: predicate,
                           scopes: ["/nonexistent/path/that/should/be/ignored"],
                           attributes: ["kMDItemFSName", "kMDItemNotARealAttribute"],
                           limit: -42) { result in
                calls += 1
                received = result
            }
            try expectEqual(calls, 1, "completion must fire inline exactly once for \(String(describing: predicate))")
            try expect(received != nil, "expected [] (not nil) for \(String(describing: predicate))")
            try expectEqual(received?.count, 0)
        }
    }

    test("find with a malformed predicate completes inline with [] instead of raising") {
        // StackdSafeNSPredicate catches the NSException NSPredicate(format:)
        // raises; Swift `try?` can't, so without the wrap a user-authored bad
        // predicate would crash the daemon.
        var calls = 0
        var result: [[String: Any]]?
        Spotlight.find(predicate: "$$$ malformed predicate $$$",
                       scopes: nil, attributes: nil, limit: nil) { r in
            calls += 1
            result = r
        }
        try expectEqual(calls, 1, "completion should fire inline exactly once on a bad predicate")
        try expect(result != nil, "result should be [] not nil on bad predicate")
        try expectEqual(result?.count, 0, "bad predicate yields empty result set")
    }
}
