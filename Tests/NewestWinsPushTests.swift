import Foundation

// Tests for `NewestWinsPush` in `Sources/DataSources/Overlay.swift` — the
// one-in-flight rule for the per-tick `sd.target` push into an overlay's
// WebView: while an evaluateJavaScript is outstanding, newer payloads
// replace each other and only the newest is sent when it completes.

func registerNewestWinsPushTests() {
    test("NewestWinsPush: the first payload goes out immediately") {
        var p = NewestWinsPush()
        try expectEqual(p.offer("a"), "a")
        try expect(p.inFlight)
    }

    test("NewestWinsPush: payloads offered in flight are held, and completion sends only the newest") {
        var p = NewestWinsPush()
        _ = p.offer("a")
        try expect(p.offer("b") == nil, "held, not sent")
        try expect(p.offer("c") == nil, "held, not sent")
        try expectEqual(p.complete(), "c", "intermediate 'b' is dropped")
        try expect(p.inFlight, "the held payload is now the one in flight")
        try expect(p.complete() == nil)
        try expect(!p.inFlight)
    }

    test("NewestWinsPush: completion with nothing held goes idle") {
        var p = NewestWinsPush()
        _ = p.offer("a")
        try expect(p.complete() == nil)
        try expect(!p.inFlight)
        try expectEqual(p.offer("b"), "b", "idle again, so the next payload goes out at once")
    }

    test("NewestWinsPush: a stray completion while idle stays idle") {
        var p = NewestWinsPush()
        try expect(p.complete() == nil)
        try expect(!p.inFlight)
    }
}
