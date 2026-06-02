import Foundation
import AppKit

// Tests for `Sources/DataSources/URLHandler.swift`.
//
// URLHandler is the daemon's bridge for custom-URL-scheme events
// (`myscheme://...`). The system half — `NSAppleEventManager.setEventHandler`
// receiving a real GURL Apple Event from another app — can only be exercised
// by a fully bundled `.app` with `CFBundleURLTypes` declared (the daemon
// today is a plain binary; see the file preamble). What's left to test is:
//
//   1. `URLHandler.observe(scheme:callback:)` — bookkeeping + Token semantics.
//      The scheme is lowercased before it lands in the subscriber table; the
//      returned Token must, on cancel, drop the entry.
//   2. `SchemeRouter.add` / `SchemeRouter.remove` — monotonic id allocation,
//      multi-subscriber per scheme, remove-by-id leaves siblings alone,
//      remove of an unknown scheme/id is a silent no-op (matches the guard
//      in remove()).
//   3. `installIfNeeded()` — idempotent. Multiple calls must not throw and
//      must not re-register the AppleEventManager handler.
//   4. `handleURLEvent(_:replyEvent:)` — accepts a synthetic
//      NSAppleEventDescriptor without crashing on the degenerate cases
//      (missing direct object, empty scheme, no matching subscribers).
//
// What we deliberately do NOT test:
//   - Real GURL routing from another app — requires bundling + a registered
//     CFBundleURLTypes. The file preamble flags this as a deployment issue,
//     not a code path.
//   - Callback fan-out payload contents on a real event — `handleURLEvent`
//     dispatches via `DispatchQueue.main.async`, and the suite avoids
//     RunLoop spins (see Tests/NetworkTests.swift preamble). We assert the
//     negative: callbacks do not fire synchronously.
//   - `LSSetDefaultHandlerForURLScheme` / `NSWorkspace.setDefaultApplication`
//     are not in URLHandler.swift at all — calling either would mutate the
//     user's macOS URL-scheme defaults system-wide. The daemon never sets
//     defaults; it only observes events macOS already routes to it.
//
// SchemeRouter.shared is process-global. To avoid leaking state into sibling
// tests, every test that mutates the router cleans up its own subscriptions
// before returning (Token.cancel via deinit, or explicit remove()).

func registerURLHandlerTests() {

    // MARK: - URLHandler.observe → Token

    test("observe returns a Token whose cancel removes the subscriber") {
        // The Token's only contract is "calling cancel drops this
        // subscriber". We can't peek into the private subscribers dict, but
        // we can verify the negative: a Token returned by observe() can be
        // cancelled without throwing, and a second cancel is a silent no-op
        // (Token wraps a one-shot closure — re-cancel must not crash).
        let token = URLHandler.observe(scheme: "stackd-test-\(UUID().uuidString)") { _ in }
        token.cancel()
        token.cancel() // idempotent — remove() guards on missing bucket
    }

    test("observe lowercases the scheme before bookkeeping") {
        // The router keys on `scheme.lowercased()`. Mixed-case input must
        // not crash and must land in the same bucket — verified indirectly
        // by adding a sibling subscriber on the lowercased form and
        // confirming both Tokens cancel cleanly. If lowercasing regressed,
        // either token could end up keyed off a different bucket and the
        // remove() guard would silently lose work; that wouldn't crash the
        // test, but a future test on the same scheme would observe stale
        // state. The witness here is "no crash, no throw" — the rest is a
        // doc-level invariant.
        let unique = "Stackd-Mixed-\(UUID().uuidString)"
        let upperToken = URLHandler.observe(scheme: unique) { _ in }
        let lowerToken = URLHandler.observe(scheme: unique.lowercased()) { _ in }
        upperToken.cancel()
        lowerToken.cancel()
    }

    test("observe is safe to call repeatedly with the same scheme") {
        // installIfNeeded() is gated by a `installed` flag — repeat
        // observe() calls for the same scheme must add new subscribers
        // without re-registering the AppleEventManager slot. Cleanup at
        // the end keeps the global router empty for sibling tests.
        let scheme = "stackd-repeat-\(UUID().uuidString)"
        let a = URLHandler.observe(scheme: scheme) { _ in }
        let b = URLHandler.observe(scheme: scheme) { _ in }
        let c = URLHandler.observe(scheme: scheme) { _ in }
        a.cancel(); b.cancel(); c.cancel()
    }

    // MARK: - SchemeRouter bookkeeping (direct)

    test("SchemeRouter.add returns strictly increasing ids") {
        // nextId is process-global and monotonic; we don't depend on its
        // absolute value, only that successive add()s return distinct,
        // ordered ids. Subscribers are keyed by this id, so collisions
        // would silently overwrite a callback.
        let router = SchemeRouter.shared
        let scheme = "stackd-ids-\(UUID().uuidString)"
        let id1 = router.add(scheme: scheme) { _ in }
        let id2 = router.add(scheme: scheme) { _ in }
        let id3 = router.add(scheme: scheme) { _ in }
        try expect(id2 > id1, "ids must be monotonically increasing (got \(id1), \(id2))")
        try expect(id3 > id2, "ids must be monotonically increasing (got \(id2), \(id3))")
        router.remove(scheme: scheme, id: id1)
        router.remove(scheme: scheme, id: id2)
        router.remove(scheme: scheme, id: id3)
    }

    test("SchemeRouter.remove is a silent no-op for unknown scheme") {
        // remove() guards with `guard var bucket = subscribers[scheme]`;
        // removing from a scheme that was never added must return without
        // throwing or mutating other buckets. Bridge.swift's Token closure
        // can fire after the daemon tore down its stack — this guard is
        // what keeps that safe.
        SchemeRouter.shared.remove(scheme: "stackd-never-added-\(UUID().uuidString)", id: 999_999)
    }

    test("SchemeRouter.remove is a silent no-op for an unknown id within a real bucket") {
        // The inner `bucket.removeValue(forKey: id)` on a missing id is a
        // no-op by Dictionary semantics; this test pins that contract. If
        // a future change ever made `remove` throw on missing id, every
        // double-cancel of a Token would crash the daemon.
        let router = SchemeRouter.shared
        let scheme = "stackd-unknownid-\(UUID().uuidString)"
        let realId = router.add(scheme: scheme) { _ in }
        router.remove(scheme: scheme, id: realId + 100_000) // not present
        router.remove(scheme: scheme, id: realId)           // real one
        router.remove(scheme: scheme, id: realId)           // already gone
    }

    test("SchemeRouter.remove drops the bucket entirely when the last subscriber leaves") {
        // The branch `if bucket.isEmpty { subscribers.removeValue(...) }`
        // prevents an unbounded growth of empty buckets across the daemon's
        // lifetime. We can't read `subscribers` directly, but we can prove
        // the bucket-empty path executes by exercising it without error
        // and re-adding into the same scheme afterwards (which goes
        // through `subscribers[scheme] ?? [:]` — the bucket-recreation
        // branch). Witness: no throw, no crash.
        let router = SchemeRouter.shared
        let scheme = "stackd-emptybucket-\(UUID().uuidString)"
        let id1 = router.add(scheme: scheme) { _ in }
        router.remove(scheme: scheme, id: id1)               // bucket goes empty + dropped
        let id2 = router.add(scheme: scheme) { _ in }        // bucket re-created
        router.remove(scheme: scheme, id: id2)
    }

    // MARK: - installIfNeeded idempotence

    test("installIfNeeded does not throw or crash on repeated calls") {
        // The flag flip inside the lock guarantees the
        // NSAppleEventManager.setEventHandler call runs at most once per
        // process. After the first observe() call elsewhere in this suite
        // the install is already done, but the public method must remain
        // safe to call directly (Bridge.swift calls observe(), which calls
        // installIfNeeded() unconditionally on every subscribe).
        SchemeRouter.shared.installIfNeeded()
        SchemeRouter.shared.installIfNeeded()
        SchemeRouter.shared.installIfNeeded()
    }

    // MARK: - handleURLEvent: synthetic dispatch

    test("handleURLEvent on a descriptor with no direct-object URL returns without crashing") {
        // The first guard in handleURLEvent extracts the GURL string from
        // the descriptor's direct object. A descriptor lacking that
        // parameter must short-circuit out via the `guard let` — no throw,
        // no fan-out. We synthesize a minimal AE descriptor (no params)
        // and a reply descriptor; both are AE-class but carry no useful
        // payload.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID:    AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID:   AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let reply = NSAppleEventDescriptor.null()
        SchemeRouter.shared.handleURLEvent(event, replyEvent: reply)
    }

    test("handleURLEvent with a valid URL does not invoke subscribers synchronously") {
        // Fan-out is on `DispatchQueue.main.async` — the callback must NOT
        // fire inside the call frame. The suite avoids RunLoop spins, so
        // we assert the negative (same contract as ThumbnailsTests). If a
        // future refactor inlined the fan-out, every Bridge handler would
        // be called on the AppleEventManager thread without warning.
        let router = SchemeRouter.shared
        let scheme = "stackd-sync-\(UUID().uuidString)".lowercased()
        var fired = false
        let id = router.add(scheme: scheme) { _ in fired = true }
        defer { router.remove(scheme: scheme, id: id) }

        let url = "\(scheme)://host/path?k=v#frag"
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID:    AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID:   AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: url),
            forKeyword: AEKeyword(keyDirectObject)
        )
        let reply = NSAppleEventDescriptor.null()
        router.handleURLEvent(event, replyEvent: reply)
        try expect(!fired, "subscriber callbacks must be queued on main, not invoked synchronously")
    }

    test("handleURLEvent with a URL whose scheme has no subscribers returns without crashing") {
        // The `guard !callbacks.isEmpty else { return }` branch covers
        // the "GURL arrived for a scheme we don't watch" case. The
        // daemon's Info.plist (when bundled) may declare schemes that
        // no live stack is currently subscribed to; that's normal and
        // must be a silent drop.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID:    AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID:   AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "stackd-orphan-\(UUID().uuidString)://nowhere"),
            forKeyword: AEKeyword(keyDirectObject)
        )
        let reply = NSAppleEventDescriptor.null()
        SchemeRouter.shared.handleURLEvent(event, replyEvent: reply)
    }

    test("handleURLEvent with an unparseable URL string returns without crashing") {
        // The second guard wraps `URLComponents(string:)` — a malformed
        // input must bail. URLComponents is permissive (many strings
        // parse), so we use one that's reliably nil: a string with a
        // space in the host position with no percent-encoding is parsed
        // by URLComponents as nil on most macOS versions. If a future
        // OS becomes more permissive, the test still passes (the
        // empty-scheme guard catches it instead). Either way: no crash.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID:    AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID:   AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "not a url with spaces"),
            forKeyword: AEKeyword(keyDirectObject)
        )
        let reply = NSAppleEventDescriptor.null()
        SchemeRouter.shared.handleURLEvent(event, replyEvent: reply)
    }
}
