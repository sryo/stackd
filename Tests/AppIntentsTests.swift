import Foundation

// Tests for the pure helpers behind the `RunStackdBang` AppIntent.
//
// What we test: payload parsing, bang validation, error-message
// formatting. All deterministic, no I/O, no AppIntents runtime needed.
//
// What we DON'T test: `RunStackdBang.perform()` itself. AppIntents are
// only invokable inside a host process that owns the AppIntents runtime
// (Shortcuts.app, Spotlight, etc.). Standing one up in this Foundation
// test harness isn't possible. The IPC hop is tested elsewhere by the
// daemon's own `stackd bang` CLI path.

func registerAppIntentsTests() {
    test("isValidBang accepts well-formed names") {
        try expect(RunStackdBangHelpers.isValidBang("demo.clicked"))
        try expect(RunStackdBangHelpers.isValidBang("home.arrived"))
        try expect(RunStackdBangHelpers.isValidBang("foo_bar-baz"))
        try expect(RunStackdBangHelpers.isValidBang("a"))
    }

    test("isValidBang rejects empty, whitespace, NUL") {
        try expect(!RunStackdBangHelpers.isValidBang(""))
        try expect(!RunStackdBangHelpers.isValidBang("has space"))
        try expect(!RunStackdBangHelpers.isValidBang("tab\there"))
        try expect(!RunStackdBangHelpers.isValidBang("newline\nbang"))
        try expect(!RunStackdBangHelpers.isValidBang("nul\u{0}byte"))
    }

    test("parsePayload returns empty dict for nil / empty / whitespace") {
        try expectEqual(RunStackdBangHelpers.parsePayload(nil).count, 0)
        try expectEqual(RunStackdBangHelpers.parsePayload("").count, 0)
        try expectEqual(RunStackdBangHelpers.parsePayload("   ").count, 0)
        try expectEqual(RunStackdBangHelpers.parsePayload("\n\t  \n").count, 0)
    }

    test("parsePayload decodes flat string-valued JSON object") {
        let kv = RunStackdBangHelpers.parsePayload(#"{"hello":"world","foo":"bar"}"#)
        try expectEqual(kv.count, 2)
        try expectEqual(kv["hello"], "world")
        try expectEqual(kv["foo"], "bar")
    }

    test("parsePayload stringifies numbers and booleans") {
        let kv = RunStackdBangHelpers.parsePayload(#"{"count":42,"ratio":1.5,"on":true,"off":false}"#)
        try expectEqual(kv["count"], "42")
        try expectEqual(kv["ratio"], "1.5")
        try expectEqual(kv["on"], "true")
        try expectEqual(kv["off"], "false")
    }

    test("parsePayload keeps numeric 0 and 1 as numbers, not booleans") {
        let kv = RunStackdBangHelpers.parsePayload(#"{"one":1,"zero":0,"t":true,"f":false}"#)
        try expectEqual(kv["one"], "1")
        try expectEqual(kv["zero"], "0")
        try expectEqual(kv["t"], "true")
        try expectEqual(kv["f"], "false")
    }

    test("parsePayloadThrowing rejects non-object, malformed, and '='-keyed payloads") {
        // A key containing '=' is rejected because the CLI argv parser
        // splits on the first '=' and would deliver the wrong key=value.
        let bad = [
            "[1,2,3]",
            #""just a string""#,
            "{not json",
            #"{"a=b":"c"}"#,
        ]
        for payload in bad {
            var threw = false
            do { _ = try RunStackdBangHelpers.parsePayloadThrowing(payload) } catch { threw = true }
            try expect(threw, "expected throw for payload \(payload)")
            try expectEqual(RunStackdBangHelpers.parsePayload(payload).count, 0,
                            "non-throwing parsePayload should degrade to empty for \(payload)")
        }
    }

    test("parsePayload re-encodes nested objects and arrays as JSON strings") {
        let kv = RunStackdBangHelpers.parsePayload(#"{"list":[1,2],"obj":{"k":"v"}}"#)
        try expectEqual(kv["list"], "[1,2]")
        try expectEqual(kv["obj"], #"{"k":"v"}"#)
    }

    test("formatError produces a prefixed user-facing string") {
        let s = RunStackdBangHelpers.formatError("ipc failure", detail: "daemon not running")
        try expect(s.contains("stackd.appintents"))
        try expect(s.contains("ipc failure"))
        try expect(s.contains("daemon not running"))
    }
}
