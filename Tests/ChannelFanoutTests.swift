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
}
