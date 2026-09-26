import Foundation

// Tests for `TrackpadSystemGestures` in Sources/DataSources/Input.swift — the
// `stackd doctor` probe that reads the trackpad / Dock preference keys and
// reports which finger counts macOS itself acts on. Preferences are
// injected as a dictionary per domain; nothing reads the live defaults.
func registerTrackpadSystemGesturesTests() {
    let builtIn = "com.apple.AppleMultitouchTrackpad"
    let bluetooth = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    let dock = "com.apple.dock"

    func reader(_ prefs: [String: [String: Any]]) -> (String, String) -> Any? {
        { domain, key in prefs[domain]?[key] }
    }
    func probe(_ prefs: [String: [String: Any]]) -> [TrackpadSystemGestures.Claim] {
        TrackpadSystemGestures.probe(read: reader(prefs))
    }
    func claim(_ g: String, _ n: Int, _ a: String) -> TrackpadSystemGestures.Claim {
        TrackpadSystemGestures.Claim(gesture: g, fingers: n, action: a)
    }

    test("TrackpadSystemGestures: nothing set claims nothing") {
        try expectEqual(probe([:]), [])
        try expectEqual(TrackpadSystemGestures.ownedFingerCounts([]), [])
    }

    test("TrackpadSystemGestures: horizontal swipe values map to spaces and page swipes") {
        try expectEqual(probe([builtIn: ["TrackpadThreeFingerHorizSwipeGesture": 2]]),
                        [claim("horizontalSwipe", 3, "switchSpaces")])
        try expectEqual(probe([builtIn: ["TrackpadThreeFingerHorizSwipeGesture": 1]]),
                        [claim("horizontalSwipe", 3, "swipeBetweenPages")])
        try expectEqual(probe([builtIn: ["TrackpadFourFingerHorizSwipeGesture": 2]]),
                        [claim("horizontalSwipe", 4, "switchSpaces")])
        try expectEqual(probe([builtIn: ["TrackpadThreeFingerHorizSwipeGesture": 0,
                                         "TrackpadFourFingerHorizSwipeGesture": 0]]), [])
    }

    test("TrackpadSystemGestures: vertical swipes follow the Dock's Mission Control / App Exposé switches") {
        let four = [builtIn: ["TrackpadFourFingerVertSwipeGesture": 2] as [String: Any]]
        try expectEqual(probe(four), [claim("swipeUp", 4, "missionControl"),
                                      claim("swipeDown", 4, "appExpose")])
        var mcOnly = four
        mcOnly[dock] = ["showMissionControlGestureEnabled": 1, "showAppExposeGestureEnabled": 0]
        try expectEqual(probe(mcOnly), [claim("swipeUp", 4, "missionControl")])
        var neither = four
        neither[dock] = ["showMissionControlGestureEnabled": false, "showAppExposeGestureEnabled": false]
        try expectEqual(probe(neither), [])
    }

    test("TrackpadSystemGestures: either trackpad domain can claim a gesture") {
        try expectEqual(probe([builtIn: ["TrackpadThreeFingerHorizSwipeGesture": 0],
                               bluetooth: ["TrackpadThreeFingerHorizSwipeGesture": 2]]),
                        [claim("horizontalSwipe", 3, "switchSpaces")])
    }

    test("TrackpadSystemGestures: three-finger drag, pinches and the edge swipe") {
        let c = probe([builtIn: ["TrackpadThreeFingerDrag": true,
                                 "TrackpadFourFingerPinchGesture": 2,
                                 "TrackpadFiveFingerPinchGesture": 2,
                                 "TrackpadTwoFingerFromRightEdgeSwipeGesture": 3]])
        try expectEqual(c, [claim("drag", 3, "threeFingerDrag"),
                            claim("pinch", 4, "launchpad"),
                            claim("pinch", 5, "launchpad"),
                            claim("edgeSwipe", 2, "notificationCenter")])
        let gated = probe([builtIn: ["TrackpadFourFingerPinchGesture": 2],
                           dock: ["showLaunchpadGestureEnabled": 0, "showDesktopGestureEnabled": 0]])
        try expectEqual(gated, [])
    }

    test("TrackpadSystemGestures: owned finger counts are unique and sorted") {
        let c = [claim("horizontalSwipe", 4, "switchSpaces"), claim("swipeUp", 3, "missionControl"),
                 claim("swipeDown", 3, "appExpose")]
        try expectEqual(TrackpadSystemGestures.ownedFingerCounts(c), [3, 4])
    }

    test("TrackpadSystemGestures: doctor lines name every claim, or say the trackpad is free") {
        let lines = TrackpadSystemGestures.doctorLines([claim("horizontalSwipe", 3, "switchSpaces"),
                                                        claim("swipeUp", 4, "missionControl")])
        let text = lines.joined(separator: "\n")
        try expect(text.contains("3-finger horizontalSwipe (switchSpaces)"), text)
        try expect(text.contains("4-finger swipeUp (missionControl)"), text)
        try expect(text.contains("3, 4"), text)
        let free = TrackpadSystemGestures.doctorLines([]).joined()
        try expect(free.contains("no multi-finger"), free)
    }
}
