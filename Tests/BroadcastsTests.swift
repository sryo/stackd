import Foundation

// Tests for Sources/DataSources/Broadcasts.swift.
//
// `observe(name:callback:)` registers on the system-wide
// DistributedNotificationCenter and delivers on `.main`; the harness doesn't
// pump the run loop, so delivery isn't exercised here. The testable seam is
// `Broadcasts.payload(from:)`, the Notification → JS-dict mapping. It is the
// security-relevant boundary: anything that survives the filter is handed to
// `Bridge.jsonify` and evaluated in a WKWebView, so a type leak (NSData,
// Date, arbitrary objects) would either crash JSONSerialization or arrive in
// JS as garbage.

func registerBroadcastsTests() {
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
        // Bridge.jsonify uses JSONSerialization, which raises an NSException
        // on Date / Data / custom NSObject — Swift `try?` can't catch that,
        // so these must be dropped before the payload reaches jsonify.
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
