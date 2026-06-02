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
}
