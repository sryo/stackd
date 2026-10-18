import Foundation

// Tests for `PendingPageEval` in `Sources/DataSources/OverlayPolicy.swift`:
// the overlay.eval / overlay.region.eval buffer. WebKit only takes scripts
// once the overlay page has loaded, so every script sent before that is
// held, in order, and run as one when the load lands.

func registerPendingPageEvalTests() {
    test("PendingPageEval: scripts before the load are held in order and flushed once") {
        var e = PendingPageEval()
        try expect(!e.loaded)
        try expect(e.offer("a()") == nil, "held until the page loads")
        try expect(e.offer("b()") == nil, "held until the page loads")
        try expectEqual(e.pageLoaded(), ";a();b()")
        try expect(e.loaded)
        try expect(e.pageLoaded() == nil, "a second load has nothing left to flush")
    }

    test("PendingPageEval: a load with nothing held flushes nothing") {
        var e = PendingPageEval()
        try expect(e.pageLoaded() == nil)
        try expect(e.loaded)
    }

    test("PendingPageEval: once loaded, scripts run straight away") {
        var e = PendingPageEval()
        _ = e.pageLoaded()
        try expectEqual(e.offer("c()"), "c()")
        try expect(e.pageLoaded() == nil, "nothing was held")
    }
}
