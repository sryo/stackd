import Foundation

/// Tests for `CrashBackoff` — the pure state machine behind StackWindow's
/// `webViewWebContentProcessDidTerminate` recovery. Mirrors the
/// FirstPaintGate testing approach: the decision logic is pure (injectable
/// clock), the WKWebView.reload() plumbing around it is impure and not
/// driven here.
///
/// Guarantees under test:
///   1. Consecutive crashes walk the delay ladder 0/2/5/15/30s.
///   2. The 6th consecutive crash gives up (no reload — crash loop).
///   3. A crash arriving after >= 60s of stable uptime resets the ladder.
///   4. Give-up persists for closely-spaced crashes, but stable uptime
///      re-enables recovery.
func registerCrashBackoffTests() {
    test("CrashBackoff: consecutive crashes walk the delay ladder") {
        var b = CrashBackoff()
        try expectEqual(b.crashed(now: 0), .reload(afterSeconds: 0))
        try expectEqual(b.crashed(now: 1), .reload(afterSeconds: 2))
        try expectEqual(b.crashed(now: 2), .reload(afterSeconds: 5))
        try expectEqual(b.crashed(now: 3), .reload(afterSeconds: 15))
        try expectEqual(b.crashed(now: 4), .reload(afterSeconds: 30))
    }

    test("CrashBackoff: sixth consecutive crash gives up") {
        var b = CrashBackoff()
        for t in 0..<5 {
            _ = b.crashed(now: TimeInterval(t))
        }
        try expectEqual(b.crashed(now: 5), .giveUp)
    }

    test("CrashBackoff: stable uptime resets the ladder") {
        var b = CrashBackoff()
        try expectEqual(b.crashed(now: 0), .reload(afterSeconds: 0))
        try expectEqual(b.crashed(now: 10), .reload(afterSeconds: 2))
        // 60s+ since the previous crash — webview proved stable; restart ladder.
        try expectEqual(b.crashed(now: 100), .reload(afterSeconds: 0))
        try expectEqual(b.crashed(now: 110), .reload(afterSeconds: 2))
    }

    test("CrashBackoff: just under the stable threshold does NOT reset") {
        var b = CrashBackoff()
        try expectEqual(b.crashed(now: 0), .reload(afterSeconds: 0))
        try expectEqual(b.crashed(now: 59.9), .reload(afterSeconds: 2))
    }

    test("CrashBackoff: give-up persists for closely-spaced crashes") {
        var b = CrashBackoff()
        for t in 0..<6 {
            _ = b.crashed(now: TimeInterval(t))
        }
        try expectEqual(b.crashed(now: 6), .giveUp)
        try expectEqual(b.crashed(now: 7), .giveUp)
    }

    test("CrashBackoff: stable uptime after give-up re-enables recovery") {
        var b = CrashBackoff()
        for t in 0..<6 {
            _ = b.crashed(now: TimeInterval(t))
        }
        try expectEqual(b.crashed(now: 6), .giveUp)
        try expectEqual(b.crashed(now: 70), .reload(afterSeconds: 0))
    }
}
