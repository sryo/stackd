import Foundation

// Tests for Sources/DataSources/Broadcasts.swift.
//
// Coverage reality: Broadcasts.swift is a 38-line single-function module
// (`observe(name:callback:) -> Token`) that wraps
// `DistributedNotificationCenter.default().addObserver(...)`. Everything
// observable from the public surface beyond "did it hand back a Token"
// is impure:
//
//   • The registry it mutates is the *system* distributed notification
//     center, owned by distnoted, shared across all processes on the Mac.
//     We can't snapshot it, count its observers, or assert "this name is
//     subscribed" — there's no API for that.
//
//   • Delivery is dispatched onto `.main` (per the source). The test
//     harness (Tests/Harness.swift) runs bodies synchronously with no
//     RunLoop pumping, so a `postNotificationName` from inside a test
//     would enqueue the callback to a queue that never drains during the
//     test's lifetime. We'd be asserting on a side effect that hasn't
//     happened yet.
//
//   • The payload-filtering branch (only forward String / NSNumber / Bool
//     userInfo values, drop NSData and other objects) lives inside the
//     observer closure — unreachable without firing the callback, which
//     per the bullet above we can't synchronously await.
//
// What IS testable through the public surface:
//   1. `observe` returns a non-nil Token for any name string (including
//      empty / unicode / dotted reverse-DNS — DistributedNotificationCenter
//      accepts any string as a name).
//   2. The returned Token's `cancel` closure is invokable without crashing,
//      i.e. the token captures a valid observer reference that
//      `removeObserver` accepts.
//   3. Compile-time signature witness: `(String, @escaping ([String: Any])
//      -> Void) -> Token`. If the signature drifts the file stops building
//      and the harness flags it.
//
// What's NOT covered here and would need either an integration harness
// (distnoted + RunLoop pump) or a refactor extracting the payload-filter
// branch into a pure helper:
//   • Callback delivery with `name` populated from `Notification.name.rawValue`.
//   • `object` forwarded only when it's a String (not arbitrary NSObject).
//   • userInfo filter: keep String / NSNumber / Bool, drop everything else
//     (NSData, arrays, dicts, custom NSObjects) so Bridge.jsonify can
//     serialize the payload to WKWebView.
//   • Token lifetime: a dropped-without-adopt Token leaks until manually
//     cancelled (matches StackScope contract).
//
// If/when the payload-filter logic is extracted into something like
// `Broadcasts.sanitizedPayload(from: Notification) -> [String: Any]`,
// that's where the filter tests land. For now the registration plumbing
// is the only deterministic surface, and we cover it below.

func registerBroadcastsTests() {
    test("Broadcasts.observe is reachable as a static member with the documented signature") {
        // Compile-time witness: if the signature drifts (e.g. callback
        // shape changes, return type changes) this file stops building
        // and the harness surfaces it as a build failure.
        let _: (String, @escaping ([String: Any]) -> Void) -> Token = Broadcasts.observe
        try expect(true)
    }

    test("Broadcasts.observe returns a Token for a reverse-DNS notification name") {
        // Reverse-DNS is the conventional shape (e.g. com.apple.screenIsLocked).
        // We register, immediately cancel, and assert we got a Token back.
        let token = Broadcasts.observe(name: "com.example.stackd.test.broadcast") { _ in }
        token.cancel()
        try expect(true, "observe handed back a non-nil Token")
    }

    test("Broadcasts.observe returns a Token even for an empty name string") {
        // DistributedNotificationCenter doesn't reject "" — neither should
        // we. The bridge layer (Bridge.swift:1727) already guards
        // `body["name"] as? String` before reaching here, so an empty
        // string is the worst input that gets through.
        let token = Broadcasts.observe(name: "") { _ in }
        token.cancel()
        try expect(true, "observe with empty name still returns a Token")
    }

    test("Broadcasts.observe Token cancel is invokable without crashing") {
        // Witnesses that the token captured a real observer reference and
        // `removeObserver` accepts it. If the closure captured something
        // bogus (e.g. a stale token from a different center) this would
        // trap. Single cancel only — repeated cancel on an already-removed
        // observer is not part of the contract.
        let token = Broadcasts.observe(name: "com.example.stackd.test.cancel") { _ in }
        token.cancel()
        try expect(true, "token.cancel() completed without crashing")
    }

    // MARK: - payload(from:) — pure Notification → JS-dict mapping
    //
    // 2026-06-02: the payload-filter logic moved out of the observer closure
    // into `Broadcasts.payload(from:)` (internal static). The mapping is
    // the security-relevant boundary — anything that survives this filter
    // ends up in `Bridge.jsonify` and gets serialized into a WKWebView eval.
    // A type-leak here (e.g. forwarding NSData as a userInfo value) would
    // either crash JSONSerialization or arrive in JS as garbage.

    test("payload: includes the notification name") {
        let n = Notification(name: Notification.Name("com.example.test"), object: nil, userInfo: nil)
        let p = Broadcasts.payload(from: n)
        try expectEqual(p["name"] as? String, "com.example.test")
    }

    test("payload: forwards String object, drops non-String object") {
        // Per the docstring: only String objects are forwarded as `object`.
        // A non-String object (e.g. NSDictionary, NSData, custom NSObject)
        // would arrive in JS as "[object Object]" via jsonify — better to
        // omit entirely than send garbage.
        let withString = Notification(name: Notification.Name("x"),
                                      object: "source-app", userInfo: nil)
        try expectEqual(Broadcasts.payload(from: withString)["object"] as? String, "source-app")

        let withNonString = Notification(name: Notification.Name("x"),
                                         object: NSObject(), userInfo: nil)
        try expect(Broadcasts.payload(from: withNonString)["object"] == nil,
                   "non-String object should be dropped, not forwarded")
    }

    test("payload: forwards JSON-able userInfo values (String, NSNumber, Bool)") {
        let info: [String: Any] = [
            "title":      "hello",
            "count":      NSNumber(value: 42),
            "isActive":   true,
            "longCount":  NSNumber(value: Int64(1_000_000))
        ]
        let n = Notification(name: Notification.Name("x"), object: nil, userInfo: info)
        let p = Broadcasts.payload(from: n)
        try expectEqual(p["title"]     as? String,   "hello")
        try expectEqual(p["count"]     as? Int,      42)
        try expectEqual(p["isActive"]  as? Bool,     true)
        try expectEqual(p["longCount"] as? Int64,    1_000_000)
    }

    test("payload: drops userInfo values that aren't JSON-able") {
        // Bridge.jsonify uses JSONSerialization, which throws NSException
        // on Date / Data / custom NSObject (caught by Bridge.jsonify's
        // own guard, but the cleaner choice is to drop these at the source
        // so the payload is well-formed before it reaches jsonify).
        let info: [String: Any] = [
            "title":  "ok",
            "blob":   Data([0xCA, 0xFE]),
            "when":   Date(),
            "custom": NSObject()
        ]
        let n = Notification(name: Notification.Name("x"), object: nil, userInfo: info)
        let p = Broadcasts.payload(from: n)
        try expectEqual(p["title"] as? String, "ok")
        try expect(p["blob"]   == nil, "Data must be filtered out")
        try expect(p["when"]   == nil, "Date must be filtered out")
        try expect(p["custom"] == nil, "arbitrary NSObject must be filtered out")
    }

    test("payload: drops userInfo entries whose key isn't a String") {
        // Notification.userInfo is typed [AnyHashable: Any] — keys could
        // technically be ints or custom hashables. JS dict keys must be
        // strings; anything else is dropped at the source.
        let info: [AnyHashable: Any] = [
            "stringKey":  "kept",
            42:           "dropped (Int key)",
            NSNumber(value: 1): "dropped (NSNumber key)"
        ]
        let n = Notification(name: Notification.Name("x"), object: nil, userInfo: info)
        let p = Broadcasts.payload(from: n)
        try expectEqual(p["stringKey"] as? String, "kept")
        // Hard to assert "no Int key" directly since [String:Any] subscripting
        // wouldn't see Int keys anyway. Witness via key count: the only
        // keys that should make it through are `name` + `stringKey`.
        try expectEqual(p.count, 2, "only name + stringKey should be present, got keys: \(Array(p.keys).sorted())")
    }
}
