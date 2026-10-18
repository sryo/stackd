import Foundation

// A fed channel (`Bridge.startChannel`) fans one observer fire out to every
// stack holding the permission. The snapshot and its JSON are produced once
// per fire and shared, so N stacks don't pay N reads of the same state
// (battery's IOKit reads, the mouse hit test) — and a snapshot that diffs
// against its previous call (host.load's CPU ticks) gives every stack the
// same reading.

private final class ManualObserver: RefCountedObserver {
    override func install() -> Token? { Token {} }
}

private func pushedValue(_ page: BridgedPage, _ channel: String, equals json: String) -> Bool {
    page.waitFor("window.__pushes[\(Bridge.jsString(channel))] === \(Bridge.jsString(json)) ? 'ok' : ''") == "ok"
}

func registerChannelFanoutTests() {
    test("fan-out: one fire reads a fed channel's snapshot once for every subscribed stack") {
        let obs = ManualObserver()
        var reads = 0
        var value = 1
        let pages = try (0..<3).map { _ in try BridgedPage() }
        for page in pages {
            page.bridge.startChannel(name: "fanoutProbe", observer: obs) { reads += 1; return ["v": value] }
        }
        defer { for page in pages { page.bridge.scope.drain() } }

        value = 2
        reads = 0
        obs.fire()
        try expectEqual(reads, 1)
        for page in pages {
            try expectEqual(page.bridge.lastState["fanoutProbe"], #"{"v":2}"#)
            try expect(pushedValue(page, "fanoutProbe", equals: #"{"v":2}"#), "stack never received the fire's value")
        }
    }

    test("fan-out: a stack started after a fire is primed from a fresh snapshot") {
        let obs = ManualObserver()
        var value = 1
        let first = try BridgedPage()
        first.bridge.startChannel(name: "fanoutProbe", observer: obs) { ["v": value] }
        defer { first.bridge.scope.drain() }
        obs.fire()

        value = 2
        let late = try BridgedPage()
        late.bridge.startChannel(name: "fanoutProbe", observer: obs) { ["v": value] }
        defer { late.bridge.scope.drain() }
        try expectEqual(late.bridge.lastState["fanoutProbe"], #"{"v":2}"#)
        try expect(pushedValue(late, "fanoutProbe", equals: #"{"v":2}"#), "late stack was never primed")
    }

    test("fan-out: a nil snapshot still skips the push for every stack") {
        let obs = ManualObserver()
        var reads = 0
        let pages = try (0..<2).map { _ in try BridgedPage() }
        for page in pages {
            page.bridge.startChannel(name: "fanoutProbe", observer: obs) { reads += 1; return nil }
        }
        defer { for page in pages { page.bridge.scope.drain() } }
        reads = 0
        obs.fire()
        try expectEqual(reads, 1)
        for page in pages { try expectEqual(page.bridge.lastState["fanoutProbe"], nil) }
    }

    // The starters that emit a list plus its delta channel share the list
    // read the same way; each stack still diffs against its own previous list.

    func display(_ id: Int, x: Int) -> [String: Any] {
        ["displayID": id, "frame": ["x": x, "y": 0, "w": 100, "h": 100], "brightness": Float(0.5)]
    }

    test("fan-out: one display fire reads the display list once; every stack gets it and its displays.changed delta") {
        let obs = ManualObserver()
        var reads = 0
        var displays = [display(1, x: 0)]
        let pages = try (0..<3).map { _ in try BridgedPage() }
        for page in pages {
            page.bridge.startDisplay(observer: obs) { reads += 1; return displays }
        }
        defer { for page in pages { page.bridge.scope.drain() } }

        displays = [display(1, x: 10), display(2, x: 0)]
        reads = 0
        obs.fire()
        try expectEqual(reads, 1)
        let listJSON = Bridge.jsonify(displays)
        let deltaJSON = Bridge.jsonify([
            "added": [display(2, x: 0)], "removed": [[String: Any]](), "changed": [display(1, x: 10)],
        ] as [String: Any])
        for page in pages {
            try expectEqual(page.bridge.lastState["displays"], listJSON)
            try expectEqual(page.bridge.lastState["displaysChanged"], deltaJSON)
            try expect(pushedValue(page, "displays", equals: listJSON), "stack never received the display list")
            try expect(pushedValue(page, "displaysChanged", equals: deltaJSON), "stack never received displays.changed")
        }
    }

    func app(_ bundleId: String, active: Bool) -> [String: Any] {
        ["bundleId": bundleId, "name": bundleId, "active": active, "hidden": false]
    }

    test("fan-out: one apps fire reads the running apps once; every stack gets them and its apps.changed delta") {
        let obs = ManualObserver()
        var reads = 0
        var apps = [app("com.a", active: true)]
        let pages = try (0..<3).map { _ in try BridgedPage() }
        for page in pages {
            page.bridge.startApps(observer: obs) { reads += 1; return apps }
        }
        defer { for page in pages { page.bridge.scope.drain() } }

        apps = [app("com.a", active: false), app("com.b", active: true)]
        reads = 0
        obs.fire()
        try expectEqual(reads, 1)
        let listJSON = Bridge.jsonify(apps)
        let deltaJSON = Bridge.jsonify([
            "added": [app("com.b", active: true)], "removed": [[String: Any]](), "changed": [app("com.a", active: false)],
        ] as [String: Any])
        for page in pages {
            try expectEqual(page.bridge.lastState["apps"], listJSON)
            try expect(pushedValue(page, "apps", equals: listJSON), "stack never received the app list")
            try expect(pushedValue(page, "appsChanged", equals: deltaJSON), "stack never received apps.changed")
        }
    }

    func item(_ title: String, x: Double) -> [String: Any] {
        ["owner": "Owner", "title": title, "x": x, "width": 20.0, "hidden": false]
    }

    test("fan-out: one menubar fire reads the menubar items once; every stack gets them and its menubar.changed delta") {
        let obs = ManualObserver()
        var reads = 0
        var items = [item("a", x: 0)]
        let pages = try (0..<3).map { _ in try BridgedPage() }
        for page in pages {
            page.bridge.startMenubarItems(observer: obs) { reads += 1; return items }
        }
        defer { for page in pages { page.bridge.scope.drain() } }

        items = [item("a", x: 5), item("b", x: 30)]
        reads = 0
        obs.fire()
        try expectEqual(reads, 1)
        let listJSON = Bridge.jsonify(items)
        let deltaJSON = Bridge.jsonify([
            "added": [item("b", x: 30)], "removed": [[String: Any]](), "changed": [item("a", x: 5)],
        ] as [String: Any])
        for page in pages {
            try expectEqual(page.bridge.lastState["menubarItems"], listJSON)
            try expectEqual(page.bridge.lastState["menubarChanged"], deltaJSON)
            try expect(pushedValue(page, "menubarItems", equals: listJSON), "stack never received the menubar items")
            try expect(pushedValue(page, "menubarChanged", equals: deltaJSON), "stack never received menubar.changed")
        }
    }

    test("fan-out: one network fire reads each sd.net snapshot once for every stack") {
        let obs = ManualObserver()
        var reads: [String: Int] = [:]
        var n = 1
        var pathReady = false
        let snapshots: [(channel: String, snapshot: () -> Any?)] = [
            ("netLan",  { reads["netLan", default: 0] += 1; return ["ipv4": "10.0.0.\(n)"] }),
            ("netWifi", { reads["netWifi", default: 0] += 1; return ["ssid": "net\(n)"] }),
            ("netPath", { reads["netPath", default: 0] += 1; return pathReady ? ["status": "satisfied"] : nil }),
        ]
        let pages = try (0..<3).map { _ in try BridgedPage() }
        for page in pages {
            page.bridge.startNetwork(observer: obs, snapshots: snapshots)
        }
        defer { for page in pages { page.bridge.scope.drain() } }
        for page in pages { try expectEqual(page.bridge.lastState["netPath"], nil) }

        n = 2
        pathReady = true
        reads = [:]
        obs.fire()
        try expectEqual(reads, ["netLan": 1, "netWifi": 1, "netPath": 1])
        for page in pages {
            try expectEqual(page.bridge.lastState["netLan"], #"{"ipv4":"10.0.0.2"}"#)
            try expectEqual(page.bridge.lastState["netWifi"], #"{"ssid":"net2"}"#)
            try expectEqual(page.bridge.lastState["netPath"], #"{"status":"satisfied"}"#)
            try expect(pushedValue(page, "netPath", equals: #"{"status":"satisfied"}"#), "stack never received net.path")
        }
    }
}
