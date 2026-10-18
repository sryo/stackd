import Foundation

// Finder, Terminal, TextEdit and other AppKit apps with native tabs give each
// tab its own window id. Only the selected tab is on screen and visible to
// Accessibility; the others sit hidden at the same frame. They are not
// windows a user sees or tiles, so Windows.all() leaves them out.

private func row(_ id: Int, pid: Int = 10, onscreen: Bool, addressable: Bool,
                 minimized: Bool = false, w: Int = 600, h: Int = 800) -> [String: Any] {
    ["id": id, "pid": pid, "onscreen": onscreen, "addressable": addressable,
     "isMinimized": minimized, "isStandard": true,
     "frame": ["x": 100, "y": 50, "w": w, "h": h]]
}

func registerWindowTabsTests() {
    let sameSpace: (Int) -> Set<UInt64> = { _ in [1] }
    // Accessibility lists only the selected tab (id 1) and any minimized window.
    let selectedOnly: (Int) -> Set<Int>? = { _ in [1] }

    test("WindowTabs: a hidden window at a visible window's size that Accessibility does not list is its tab sibling") {
        let rows = [row(1, onscreen: true, addressable: true), row(2, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [2])
    }

    test("WindowTabs: every hidden tab of the group is a sibling") {
        let rows = [row(1, onscreen: true, addressable: true),
                    row(2, onscreen: false, addressable: false),
                    row(3, onscreen: false, addressable: false),
                    row(4, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [2, 3, 4])
    }

    test("WindowTabs: a same-size window on another Space is not a tab") {
        let rows = [row(1, onscreen: true, addressable: true), row(2, onscreen: false, addressable: false)]
        let spaces: (Int) -> Set<UInt64> = { $0 == 1 ? [1] : [2] }
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: spaces, axWindowIDs: selectedOnly), [])
    }

    test("WindowTabs: a hidden window of a different size is not a tab") {
        let rows = [row(1, onscreen: true, addressable: true),
                    row(2, onscreen: false, addressable: false, w: 900)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [])
    }

    test("WindowTabs: sizes within two points still match") {
        let rows = [row(1, onscreen: true, addressable: true),
                    row(2, onscreen: false, addressable: false, w: 601, h: 799)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [2])
    }

    test("WindowTabs: another app's window is not a tab") {
        let rows = [row(1, pid: 10, onscreen: true, addressable: true),
                    row(2, pid: 11, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [])
    }

    test("WindowTabs: a window already known to be minimized is not a tab") {
        let rows = [row(1, onscreen: true, addressable: true),
                    row(2, onscreen: false, addressable: true, minimized: true)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [])
    }

    test("WindowTabs: a stale readable verdict does not keep a hidden tab in the list") {
        // The addressability cache remembers the tab it once read.
        let rows = [row(1, onscreen: true, addressable: true), row(2, onscreen: false, addressable: true)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: selectedOnly), [2])
    }

    test("WindowTabs: a hidden window Accessibility lists is a real window, not a tab") {
        let rows = [row(1, onscreen: true, addressable: true), row(2, onscreen: false, addressable: true)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: { _ in [1, 2] }), [])
    }

    test("WindowTabs: when Accessibility cannot be read nothing is called a tab") {
        let rows = [row(1, onscreen: true, addressable: true), row(2, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: sameSpace, axWindowIDs: { _ in nil }), [])
    }

    test("WindowTabs: with no visible readable window there is no group to belong to") {
        let hiddenApp = [row(2, onscreen: false, addressable: false), row(3, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: hiddenApp, spacesOf: sameSpace, axWindowIDs: selectedOnly), [])
        let unreadableVisible = [row(1, onscreen: true, addressable: false), row(2, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: unreadableVisible, spacesOf: sameSpace, axWindowIDs: selectedOnly), [])
    }

    test("WindowTabs: a window with no known Space is left in the list") {
        let rows = [row(1, onscreen: true, addressable: true), row(2, onscreen: false, addressable: false)]
        try expectEqual(WindowTabs.siblingIDs(in: rows, spacesOf: { _ in [] }, axWindowIDs: selectedOnly), [])
    }

    test("Windows.decode leaves a hidden tab out of the list") {
        func cg(_ n: Int, onscreen: Int) -> [String: Any] {
            [kCGWindowNumber as String: n, kCGWindowLayer as String: 0,
             kCGWindowOwnerName as String: "Finder", kCGWindowOwnerPID as String: 4242,
             kCGWindowIsOnscreen as String: onscreen,
             kCGWindowBounds as String: ["X": 100.0, "Y": 50.0, "Width": 600.0, "Height": 800.0] as [String: CGFloat]]
        }
        let rows = Windows.decode([cg(1, onscreen: 1), cg(2, onscreen: 0)],
                                  probe: { _, wid in
                                      WindowAddressabilityCache.Probe(addressable: wid == 1, isStandard: true,
                                                                      isMinimized: false, ts: 0)
                                  },
                                  display: { _, _ in nil },
                                  spaces: { _ in [1] },
                                  axWindowIDs: { _ in [1] })
        try expectEqual(rows.compactMap { $0["id"] as? Int }, [1])
    }
}
