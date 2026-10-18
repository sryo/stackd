import Foundation

// MARK: ============================================================
// MARK: TrackpadSystemGestures — which finger counts macOS acts on
// MARK: ============================================================

/// Reads the trackpad and Dock preferences behind System Settings ›
/// Trackpad and reports the multi-finger gestures macOS itself handles, so
/// a gesture stack can tell which finger counts it would fight the system
/// for. Built-in trackpads read com.apple.AppleMultitouchTrackpad and
/// Bluetooth ones com.apple.driver.AppleBluetoothMultitouch.trackpad; a
/// gesture counts as claimed when either domain enables it. Missing keys
/// count as off, missing Dock switches as on (their macOS default).
enum TrackpadSystemGestures {
    struct Claim: Equatable {
        let gesture: String
        let fingers: Int
        let action: String
    }

    static let trackpadDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    static let dockDomain = "com.apple.dock"

    /// Value semantics: horizontal swipe 1 = page swipe, 2 = switch spaces;
    /// vertical swipe 2 = Mission Control (up) / App Exposé (down); pinch
    /// 2 = Launchpad / Show Desktop; right-edge swipe 3 = Notification Center.
    static func probe(read: (_ domain: String, _ key: String) -> Any?) -> [Claim] {
        func trackpad(_ key: String) -> Int {
            trackpadDomains.compactMap { (read($0, key) as? NSNumber)?.intValue }.max() ?? 0
        }
        func dockEnabled(_ key: String) -> Bool {
            (read(dockDomain, key) as? NSNumber)?.boolValue ?? true
        }

        var claims: [Claim] = []
        for (n, key) in [(3, "TrackpadThreeFingerHorizSwipeGesture"), (4, "TrackpadFourFingerHorizSwipeGesture")] {
            switch trackpad(key) {
            case 1: claims.append(Claim(gesture: "horizontalSwipe", fingers: n, action: "swipeBetweenPages"))
            case 2: claims.append(Claim(gesture: "horizontalSwipe", fingers: n, action: "switchSpaces"))
            default: break
            }
        }
        let missionControl = dockEnabled("showMissionControlGestureEnabled")
        let appExpose = dockEnabled("showAppExposeGestureEnabled")
        for (n, key) in [(3, "TrackpadThreeFingerVertSwipeGesture"), (4, "TrackpadFourFingerVertSwipeGesture")]
        where trackpad(key) == 2 {
            if missionControl { claims.append(Claim(gesture: "swipeUp", fingers: n, action: "missionControl")) }
            if appExpose { claims.append(Claim(gesture: "swipeDown", fingers: n, action: "appExpose")) }
        }
        if trackpad("TrackpadThreeFingerDrag") != 0 {
            claims.append(Claim(gesture: "drag", fingers: 3, action: "threeFingerDrag"))
        }
        let pinchActive = dockEnabled("showLaunchpadGestureEnabled") || dockEnabled("showDesktopGestureEnabled")
        for (n, key) in [(4, "TrackpadFourFingerPinchGesture"), (5, "TrackpadFiveFingerPinchGesture")]
        where pinchActive && trackpad(key) == 2 {
            claims.append(Claim(gesture: "pinch", fingers: n, action: "launchpad"))
        }
        if trackpad("TrackpadTwoFingerFromRightEdgeSwipeGesture") == 3 {
            claims.append(Claim(gesture: "edgeSwipe", fingers: 2, action: "notificationCenter"))
        }
        return claims
    }

    static func ownedFingerCounts(_ claims: [Claim]) -> [Int] {
        Array(Set(claims.map(\.fingers))).sorted()
    }

    /// Informational `stackd doctor` section.
    static func doctorLines(_ claims: [Claim]) -> [String] {
        guard !claims.isEmpty else {
            return ["ℹ️  trackpad: macOS handles no multi-finger swipes, drags or pinches"]
        }
        let counts = ownedFingerCounts(claims).map(String.init).joined(separator: ", ")
        var lines = ["ℹ️  trackpad: macOS handles these gestures (finger counts \(counts)); stacks recognizing the same ones compete with the system:"]
        for c in claims {
            lines.append("    \(c.fingers)-finger \(c.gesture) (\(c.action))")
        }
        return lines
    }

    static func liveRead(domain: String, key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
}
