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

    test("parsePayloadThrowing rejects non-object JSON") {
        do {
            _ = try RunStackdBangHelpers.parsePayloadThrowing("[1,2,3]")
            try expect(false, "expected throw for array payload")
        } catch {
            try expect(true)
        }
        do {
            _ = try RunStackdBangHelpers.parsePayloadThrowing(#""just a string""#)
            try expect(false, "expected throw for scalar payload")
        } catch {
            try expect(true)
        }
    }

    test("parsePayloadThrowing rejects malformed JSON") {
        do {
            _ = try RunStackdBangHelpers.parsePayloadThrowing("{not json")
            try expect(false, "expected throw for malformed JSON")
        } catch {
            try expect(true)
        }
    }

    test("parsePayloadThrowing rejects keys containing '='") {
        // CLI argv parser splits on first '=', so an embedded '=' in the
        // key would silently send the wrong key=value to the bang handler.
        do {
            _ = try RunStackdBangHelpers.parsePayloadThrowing(#"{"a=b":"c"}"#)
            try expect(false, "expected throw for '=' in key")
        } catch {
            try expect(true)
        }
    }

    test("formatError produces a prefixed user-facing string") {
        let s = RunStackdBangHelpers.formatError("ipc failure", detail: "daemon not running")
        try expect(s.contains("stackd.appintents"))
        try expect(s.contains("ipc failure"))
        try expect(s.contains("daemon not running"))
    }
}
