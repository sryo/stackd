import Foundation
import CoreGraphics

// Tests for `WindowOwnerLookup` in `Sources/DataSources/Windows.swift` —
// resolving a CGWindowID's owning pid without walking the full
// CGWindowList: the per-pid AX element cache answers first, a single-window
// CGWindowList query only on a miss.

func registerWindowOwnerLookupTests() {
    test("WindowOwnerLookup.pid answers from the cache without querying") {
        var queried = false
        let cache: [pid_t: Set<CGWindowID>] = [10: [100, 101], 20: [200]]
        let pid = WindowOwnerLookup.pid(for: 200, cached: cache) { _ in queried = true; return nil }
        try expect(pid == 20)
        try expect(!queried)
    }

    test("WindowOwnerLookup.pid falls back to the single-window query on a miss") {
        var queriedFor: CGWindowID?
        let cache: [pid_t: Set<CGWindowID>] = [10: [100]]
        let pid = WindowOwnerLookup.pid(for: 300, cached: cache) { wid in queriedFor = wid; return 30 }
        try expect(pid == 30)
        try expect(queriedFor == 300)
    }

    test("WindowOwnerLookup.pid is nil when neither cache nor query knows the window") {
        let pid = WindowOwnerLookup.pid(for: 999, cached: [:]) { _ in nil }
        try expect(pid == nil)
    }
}
