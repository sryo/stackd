import Foundation

func registerBridgeJsonifyTests() {
    test("jsonify string quotes and escapes") {
        let out = Bridge.jsonify("he said \"hi\"\nbye")
        try expectEqual(out, "\"he said \\\"hi\\\"\\nbye\"")
    }

    test("jsonify int and double as bare numbers") {
        try expectEqual(Bridge.jsonify(42), "42")
        try expectEqual(Bridge.jsonify(3.5), "3.5")
    }

    test("jsonify bool as true/false (not 0/1)") {
        try expectEqual(Bridge.jsonify(true), "true")
        try expectEqual(Bridge.jsonify(false), "false")
    }

    test("jsonify array of mixed scalars") {
        let out = Bridge.jsonify([1, "two", true] as [Any])
        try expectEqual(out, "[1,\"two\",true]")
    }

    test("jsonify dictionary keys are sorted, including nested dicts") {
        // Channel dedupe string-compares against the last pushed payload, so
        // two dicts with equal contents must serialize identically regardless
        // of insertion order.
        let out = Bridge.jsonify(["zeta": 1, "alpha": ["y": "b", "x": "a"]] as [String: Any])
        try expectEqual(out, "{\"alpha\":{\"x\":\"a\",\"y\":\"b\"},\"zeta\":1}")
    }

    test("jsonify NSNull becomes null") {
        try expectEqual(Bridge.jsonify(NSNull()), "null")
        // NOTE: passing a non-JSON-serializable value (e.g. Date) crashes the
        // process — JSONSerialization throws an NSException, which Swift `try?`
        // can't catch. The `guard … else { return "null" }` only catches the
        // Swift-error path. Callers must pre-convert custom types to JSON-safe
        // shapes before handing them to jsonify.
    }
}
