import Foundation
import CoreGraphics

// Tests for `WindowOwnerLookup` and `WindowElementIndex` in
// `Sources/DataSources/Windows.swift` — resolving a CGWindowID's owning pid
// without walking the full CGWindowList: the AX element cache's reverse
// wid → pid map answers first, a single-window CGWindowList query only on a
// miss. The index is generic over the element so its bookkeeping runs on
// strings, without AX.

private func index(_ walks: [pid_t: [CGWindowID]]) -> WindowElementIndex<String> {
    var i = WindowElementIndex<String>()
    for (pid, wids) in walks {
        i.merge(pid: pid, Dictionary(uniqueKeysWithValues: wids.map { ($0, "\(pid)/\($0)") }))
    }
    return i
}

func registerWindowOwnerLookupTests() {
    test("WindowOwnerLookup.pid answers from the cache without querying") {
        var queried = false
        let pid = WindowOwnerLookup.pid(for: 200, cached: index([10: [100, 101], 20: [200]])) { _ in
            queried = true; return nil
        }
        try expect(pid == 20)
        try expect(!queried)
    }

    test("WindowOwnerLookup.pid falls back to the single-window query on a miss") {
        var queriedFor: CGWindowID?
        let pid = WindowOwnerLookup.pid(for: 300, cached: index([10: [100]])) { wid in queriedFor = wid; return 30 }
        try expect(pid == 30)
        try expect(queriedFor == 300)
    }

    test("WindowOwnerLookup.pid is nil when neither cache nor query knows the window") {
        let pid = WindowOwnerLookup.pid(for: 999, cached: WindowElementIndex<String>()) { _ in nil }
        try expect(pid == nil)
    }

    test("WindowElementIndex keeps windows a later walk of the same app leaves out") {
        // AXWindows can return different subsets across calls; a window
        // missing from one walk keeps its element and its owner.
        var i = index([10: [100, 101]])
        i.merge(pid: 10, [101: "fresh"])
        try expectEqual(i.element(windowID: 100, pid: 10), "10/100")
        try expectEqual(i.element(windowID: 101, pid: 10), "fresh", "the freshest element wins")
        try expectEqual(i.pid(for: 100), 10)
    }

    test("WindowElementIndex forgets a removed window's owner, and only that window's") {
        var i = index([10: [100, 101]])
        i.remove(pid: 10, windowID: 100)
        try expect(i.pid(for: 100) == nil, "a dropped window must fall back to the query")
        try expect(i.element(windowID: 100, pid: 10) == nil)
        try expectEqual(i.pid(for: 101), 10, "its sibling keeps its owner")
    }

    test("WindowElementIndex drops every window of a removed app") {
        var i = index([10: [100, 101], 20: [200]])
        i.remove(pid: 10)
        try expect(i.pid(for: 100) == nil)
        try expect(i.pid(for: 101) == nil)
        try expect(i.element(windowID: 101, pid: 10) == nil)
        try expectEqual(i.pid(for: 200), 20, "other apps are untouched")
        try expectEqual(i.pids, [20], "no empty entry is left for the removed app")
    }

    test("WindowElementIndex moves a window id another app's walk lists") {
        var i = index([10: [100]])
        i.merge(pid: 20, [100: "20/100"])
        try expectEqual(i.pid(for: 100), 20)
        try expect(i.element(windowID: 100, pid: 10) == nil, "the old owner no longer holds it")
        try expectEqual(i.pids, [20])
    }

    test("WindowElementIndex.removeAll empties both maps") {
        var i = index([10: [100], 20: [200]])
        i.removeAll()
        try expect(i.pid(for: 100) == nil)
        try expect(i.pid(for: 200) == nil)
        try expectEqual(i.pids, [])
    }
}
