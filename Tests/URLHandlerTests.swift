import Foundation
import AppKit

// Tests for `Sources/DataSources/URLHandler.swift`.
//
// Real GURL routing from another app needs a bundled `.app` declaring
// CFBundleURLTypes, so these tests drive `SchemeRouter.handleURLEvent`
// directly with synthetic Apple Event descriptors. Fan-out is queued on
// main, so assertions spin the main run loop with a deadline.
//
// SchemeRouter.shared is process-global: every test uses a UUID-suffixed
// scheme and cancels/removes its own subscriptions.

private func urlEvent(_ url: String?) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kInternetEventClass),
        eventID:    AEEventID(kAEGetURL),
        targetDescriptor: nil,
        returnID:   AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID)
    )
    if let url = url {
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
    }
    return event
}

private func deliver(_ url: String?) {
    SchemeRouter.shared.handleURLEvent(urlEvent(url), replyEvent: NSAppleEventDescriptor.null())
}

private func urlSpin(timeout: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func registerURLHandlerTests() {
    test("handleURLEvent parses the URL and delivers the payload on main, not inline") {
        // observe() lowercases the scheme, and so does the event side, so a
        // mixed-case subscription still receives a mixed-case URL.
        let scheme = "Stackd-Parse-\(UUID().uuidString)"
        var payloads: [[String: Any]] = []
        var onMain = false
        let token = URLHandler.observe(scheme: scheme) { p in
            payloads.append(p)
            onMain = Thread.isMainThread
        }
        defer { token.cancel() }

        let url = "\(scheme.uppercased())://host.example/some/path?k=v&k=w&flag#frag"
        deliver(url)
        try expect(payloads.isEmpty, "subscriber callbacks must be queued on main, not invoked synchronously")
        urlSpin(timeout: 2) { !payloads.isEmpty }
        try expectEqual(payloads.count, 1)
        try expect(onMain, "callback must run on main")
        let p = payloads[0]
        try expectEqual(p["url"] as? String, url)
        try expectEqual(p["scheme"] as? String, scheme.lowercased())
        try expectEqual(p["host"] as? String, "host.example")
        try expectEqual(p["path"] as? String, "/some/path")
        try expectEqual(p["fragment"] as? String, "frag")
        // Repeated keys collapse last-write-wins; valueless keys map to "".
        try expectEqual(p["query"] as? [String: String], ["k": "w", "flag": ""])
    }

    test("handleURLEvent fans out to every subscriber of the scheme and skips cancelled ones") {
        let scheme = "stackd-fanout-\(UUID().uuidString)"
        var hitsA = 0, hitsB = 0, hitsC = 0
        let a = URLHandler.observe(scheme: scheme) { _ in hitsA += 1 }
        let b = URLHandler.observe(scheme: scheme) { _ in hitsB += 1 }
        let c = URLHandler.observe(scheme: scheme) { _ in hitsC += 1 }
        defer { a.cancel(); c.cancel() }
        b.cancel()
        b.cancel() // idempotent

        deliver("\(scheme)://x")
        urlSpin(timeout: 2) { hitsA > 0 && hitsC > 0 }
        urlSpin(timeout: 0.05) { false }
        try expectEqual(hitsA, 1)
        try expectEqual(hitsB, 0, "cancelled subscriber must not be called")
        try expectEqual(hitsC, 1)
    }

    test("a scheme re-subscribed after its last subscriber left still receives events") {
        // Removing the last subscriber drops the scheme's bucket; a later
        // add must recreate it.
        let scheme = "stackd-rebucket-\(UUID().uuidString)"
        URLHandler.observe(scheme: scheme) { _ in }.cancel()
        var hits = 0
        let token = URLHandler.observe(scheme: scheme) { _ in hits += 1 }
        defer { token.cancel() }
        deliver("\(scheme)://again")
        urlSpin(timeout: 2) { hits > 0 }
        try expectEqual(hits, 1)
    }

    test("handleURLEvent drops events without a URL, with an unparseable URL, or for another scheme") {
        let scheme = "stackd-drop-\(UUID().uuidString)"
        var hits = 0
        let token = URLHandler.observe(scheme: scheme) { _ in hits += 1 }
        defer { token.cancel() }
        deliver(nil)
        deliver("not a url with spaces")
        deliver("stackd-orphan-\(UUID().uuidString)://nowhere")
        urlSpin(timeout: 0.1) { hits > 0 }
        try expectEqual(hits, 0)
    }

    test("SchemeRouter.add returns strictly increasing ids") {
        // Subscribers are keyed by this id; a collision would silently
        // overwrite a callback.
        let router = SchemeRouter.shared
        let scheme = "stackd-ids-\(UUID().uuidString)"
        let id1 = router.add(scheme: scheme) { _ in }
        let id2 = router.add(scheme: scheme) { _ in }
        let id3 = router.add(scheme: scheme) { _ in }
        defer {
            router.remove(scheme: scheme, id: id1)
            router.remove(scheme: scheme, id: id2)
            router.remove(scheme: scheme, id: id3)
        }
        try expect(id2 > id1, "ids must be monotonically increasing (got \(id1), \(id2))")
        try expect(id3 > id2, "ids must be monotonically increasing (got \(id2), \(id3))")
    }

    test("SchemeRouter.remove of an unknown scheme or id leaves existing subscribers intact") {
        // Token cancels can run after a stack is torn down; stray removes
        // must neither crash nor drop a live subscriber.
        let router = SchemeRouter.shared
        let scheme = "stackd-unknownid-\(UUID().uuidString)".lowercased()
        var hits = 0
        let id = router.add(scheme: scheme) { _ in hits += 1 }
        defer { router.remove(scheme: scheme, id: id) }
        router.remove(scheme: "stackd-never-added-\(UUID().uuidString)", id: id)
        router.remove(scheme: scheme, id: id + 100_000)
        deliver("\(scheme)://still-here")
        urlSpin(timeout: 2) { hits > 0 }
        try expectEqual(hits, 1)
    }
}
