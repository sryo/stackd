import AppKit
import ApplicationServices

// WindowHitTest is the pure core of sd.windows.at: which window a point lands
// on (front to back over CGWindowList rows, letting clicks through the layers
// that don't take them) and which part of it (resize edge, title bar, a
// control in the title bar, or content). The live path that feeds it rows and
// Accessibility reads is exercised at the bottom against the --ax-victim
// process when the environment can deliver one.

private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

private func row(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0, alpha: Double = 1,
                 owner: String = "App", bundleID: String? = "com.example.app", pid: pid_t = 100,
                 isOwn: Bool = false) -> HitTestRow {
    HitTestRow(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame,
               owner: owner, bundleID: bundleID, isOwn: isOwn)
}

private func top(_ rows: [HitTestRow], _ x: CGFloat, _ y: CGFloat, dockBar: CGRect? = nil) -> CGWindowID? {
    WindowHitTest.topWindow(rows: rows, at: CGPoint(x: x, y: y), screens: [screen], dockBar: { dockBar })?.id
}

func registerWindowsHitTestTests() {
    test("WindowHitTest.topWindow picks the frontmost window under the point") {
        let rows = [row(1, CGRect(x: 0, y: 0, width: 100, height: 100)),
                    row(2, CGRect(x: 50, y: 50, width: 400, height: 400)),
                    row(3, CGRect(x: 0, y: 0, width: 800, height: 800))]
        try expectEqual(top(rows, 200, 200), 2)
        try expectEqual(top(rows, 20, 20), 1)
        try expectEqual(top(rows, 700, 700), 3)
        try expectEqual(top(rows, 900, 900), nil)
    }

    test("WindowHitTest.topWindow counts the resize border just outside a window") {
        let rows = [row(1, CGRect(x: 100, y: 100, width: 300, height: 300)),
                    row(2, CGRect(x: 0, y: 0, width: 800, height: 800))]
        try expectEqual(top(rows, 97, 200), 1, "3pt outside the left edge is still the front window's resize zone")
        try expectEqual(top(rows, 90, 200), 2)
    }

    test("WindowHitTest.topWindow returns nil when a menu or panel covers the point") {
        let rows = [row(9, CGRect(x: 180, y: 180, width: 200, height: 300), layer: 101, owner: "App"),
                    row(1, CGRect(x: 0, y: 0, width: 800, height: 800))]
        try expectEqual(top(rows, 200, 200), nil)
        try expectEqual(top(rows, 600, 600), 1)
    }

    test("WindowHitTest.topWindow lets clicks through screen-sized overlays and invisible windows") {
        let rows = [row(8, screen, layer: 25, owner: "Dimmer", bundleID: "com.example.dimmer"),
                    row(7, CGRect(x: 0, y: 0, width: 800, height: 800), alpha: 0),
                    row(1, CGRect(x: 0, y: 0, width: 800, height: 800))]
        try expectEqual(top(rows, 200, 200), 1)
    }

    test("WindowHitTest.topWindow passes the Dock's screen layer except over the Dock bar") {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let bar = CGRect(x: 500, y: 940, width: 600, height: 60)
        let rows = [row(8, screen, layer: dockLevel, owner: "Dock", bundleID: "com.apple.dock"),
                    row(1, screen)]
        try expectEqual(top(rows, 200, 200, dockBar: bar), 1)
        try expectEqual(top(rows, 600, 970, dockBar: bar), nil)
        try expectEqual(top(rows, 200, 200, dockBar: nil), nil, "an unknown Dock bar blocks")
        let mission = [row(8, screen, layer: dockLevel + 1, owner: "Dock", bundleID: "com.apple.dock"), row(1, screen)]
        try expectEqual(top(mission, 200, 200, dockBar: bar), nil, "Mission Control's Dock layer blocks")
    }

    test("WindowHitTest.topWindow passes recorders' layers and blocks the login window") {
        let cursor = row(8, CGRect(x: 190, y: 190, width: 32, height: 32), layer: 2000, owner: "Window Server", bundleID: nil)
        let border = row(9, CGRect(x: 150, y: 150, width: 300, height: 4), layer: 1000, owner: "CleanShot X",
                         bundleID: "pl.maketheweb.cleanshotx")
        let tool = row(10, CGRect(x: 150, y: 150, width: 100, height: 100), layer: 1000, owner: "screencapture", bundleID: nil)
        let base = row(1, screen)
        try expectEqual(top([cursor, base], 200, 200), 1)
        try expectEqual(top([border, base], 200, 151), 1)
        try expectEqual(top([tool, base], 200, 200), 1)
        let login = row(11, screen, layer: 2000, owner: "loginwindow", bundleID: "com.apple.loginwindow")
        try expectEqual(top([login, base], 200, 200), nil)
        let menubar = row(12, CGRect(x: 0, y: 0, width: 1600, height: 33), layer: 24, owner: "Window Server", bundleID: nil)
        try expectEqual(top([menubar, base], 200, 10), nil, "the menu bar is Window Server's too, but large")
    }

    test("WindowHitTest.topWindow returns nil over one of stackd's own windows") {
        let rows = [row(5, CGRect(x: 0, y: 0, width: 400, height: 40), isOwn: true), row(1, screen)]
        try expectEqual(top(rows, 200, 20), nil)
        try expectEqual(top(rows, 200, 200), 1)
    }

    test("WindowHitTest.edges names the edges within the resize border") {
        let f = CGRect(x: 100, y: 100, width: 300, height: 200)
        try expectEqual(WindowHitTest.edges(of: f, at: CGPoint(x: 250, y: 200)), [])
        try expectEqual(WindowHitTest.edges(of: f, at: CGPoint(x: 102, y: 200)), [.left])
        try expectEqual(WindowHitTest.edges(of: f, at: CGPoint(x: 403, y: 200)), [.right])
        try expectEqual(WindowHitTest.edges(of: f, at: CGPoint(x: 250, y: 98)), [.top])
        try expectEqual(WindowHitTest.edges(of: f, at: CGPoint(x: 399, y: 299)), [.right, .bottom])
        try expectEqual(WindowHitTest.edges(of: f, at: CGPoint(x: 90, y: 200)), [], "outside the border is no edge")
    }

    test("WindowHitTest.titleBarHeight doubles the close button's distance from the top") {
        let f = CGRect(x: 100, y: 100, width: 600, height: 400)
        try expectEqual(WindowHitTest.titleBarHeight(frame: f, closeButton: CGRect(x: 108, y: 108, width: 12, height: 12)), 28)
        try expectEqual(WindowHitTest.titleBarHeight(frame: f, closeButton: CGRect(x: 120, y: 120, width: 14, height: 14)), 54)
        try expectEqual(WindowHitTest.titleBarHeight(frame: f, closeButton: CGRect(x: 108, y: 102, width: 12, height: 4)), nil,
                        "under 20pt is no title bar")
        try expectEqual(WindowHitTest.titleBarHeight(frame: f, closeButton: CGRect(x: 108, y: 200, width: 12, height: 12)), nil,
                        "over 120pt is no title bar")
        try expectEqual(WindowHitTest.titleBarHeight(frame: f, closeButton: CGRect(x: 8, y: 108, width: 12, height: 12)), nil,
                        "a close button outside the window belongs to something else")
    }

    test("WindowHitTest.isDraggable accepts only bare title bar paths up to the window") {
        try expect(WindowHitTest.isDraggable(roles: ["AXWindow"]))
        try expect(WindowHitTest.isDraggable(roles: ["AXStaticText", "AXGroup", "AXToolbar", "AXWindow"]))
        try expect(!WindowHitTest.isDraggable(roles: ["AXStaticText", "AXRadioButton", "AXTabGroup", "AXWindow"]),
                   "a Chromium tab title is a control")
        try expect(!WindowHitTest.isDraggable(roles: ["AXButton", "AXWindow"]))
        try expect(!WindowHitTest.isDraggable(roles: ["AXGroup", "AXGroup"]), "a path that never reaches the window")
        try expect(!WindowHitTest.isDraggable(roles: []))
    }

    test("WindowHitTest.region puts edges first, then the title bar, then content") {
        let f = CGRect(x: 100, y: 100, width: 600, height: 400)
        func region(_ x: CGFloat, _ y: CGFloat, bar: CGFloat?, draggable: Bool) -> HitRegion {
            WindowHitTest.region(frame: f, point: CGPoint(x: x, y: y), titleBarHeight: bar, draggable: draggable)
        }
        try expectEqual(region(102, 110, bar: 28, draggable: true), .edge)
        try expectEqual(region(300, 110, bar: 28, draggable: true), .titlebar)
        try expectEqual(region(300, 110, bar: 28, draggable: false), .control)
        try expectEqual(region(300, 200, bar: 28, draggable: true), .content)
        try expectEqual(region(300, 110, bar: nil, draggable: true), .content, "no close button, no title bar")
    }

    // Accessibility answers a hit test only for a point on a display, so the
    // victim hangs off the main display's bottom-right corner with a 48pt
    // strip showing, for about a second. The row comes straight from the
    // victim's CGWindowList entry: which window is on top is the pure tests'
    // job, and other processes' overlays would make it the environment's.
    test("WindowsByID.hitRegion reads the victim's title bar, content and edge") {
        let display = CGDisplayBounds(CGMainDisplayID())
        try withAXVictim(at: CGPoint(x: display.maxX - 400, y: display.maxY - 48)) { pid, _ in
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            guard let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }),
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else {
                throw Expectation(message: "victim window not in the window list")
            }
            let victim = row(CGWindowID(number), frame, pid: pid)
            func region(_ x: CGFloat, _ y: CGFloat) -> (HitRegion, [WindowEdge]) {
                WindowsByID.hitRegion(of: victim, at: CGPoint(x: x, y: y))
            }
            try expectEqual(region(frame.midX, frame.minY + 10).0, .titlebar)
            try expectEqual(region(frame.midX, frame.minY + 44).0, .content)
            try expectEqual(region(frame.maxX - 40, frame.minY + 14).0, .control,
                            "a part of the bar too deep to walk is still in the bar")
            let edge = region(frame.minX + 1, frame.minY + 20)
            try expectEqual(edge.0, .edge)
            try expectEqual(edge.1, [.left])
        }
    }
}
