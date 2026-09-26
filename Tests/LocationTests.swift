import Foundation
import CoreLocation

// Tests for Location.swift.
//
// LocationObserver.install() drives CLLocationManager and would trigger the
// Location Services TCC prompt, so it is never called here. The testable
// surface is:
//   - snapshot() returning nil while no fix has been delivered — the null
//     path Bridge hands to `sd.location.snapshot()`.
//   - dictFromFix(_:), the CLLocation → JS dict mapping, including the
//     "unmeasured" sentinels (< 0) that must become NSNull.

func registerLocationTests() {
    // MARK: - Location.snapshot()

    test("Location.snapshot() returns nil before any observer install") {
        // The .stack/JS contract: `sd.location.snapshot()` returns null
        // until the user has both granted authorization AND CoreLocation
        // has delivered ≥1 fix. In a unit-test process we install nothing
        // and never receive a delegate callback, so lastFix stays nil
        // and snapshot() MUST return nil. If this flips to non-nil
        // without an install, the lazy-init contract has regressed.
        //
        // Caveat: this only holds when no prior test in the run has
        // installed LocationObserver. We don't install it anywhere in
        // the test suite (it would prompt for TCC), so this should
        // remain stable. If a future test ever does install it, this
        // assertion is the witness that flags the leak.
        let result = Location.snapshot()
        try expect(result == nil,
                   "expected nil snapshot pre-install, got \(String(describing: result))")
    }

    // MARK: - Location.dictFromFix (CLLocation → JS dict mapping)

    test("dictFromFix: complete fix maps every documented key with correct types") {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude:           42.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy:   3.0,    // >= 0 → altitude is real
            course:             90.0,   // >= 0 → heading is real
            speed:              1.5,    // >= 0 → speed is real
            timestamp:          Date(timeIntervalSince1970: 1_700_000_000)
        )
        let dict = Location.dictFromFix(loc)
        try expectEqual(dict["lat"]      as? Double, 37.7749)
        try expectEqual(dict["lon"]      as? Double, -122.4194)
        try expectEqual(dict["accuracy"] as? Double, 5.0)
        try expectEqual(dict["altitude"] as? Double, 42.0)
        try expectEqual(dict["heading"]  as? Double, 90.0)
        try expectEqual(dict["speed"]    as? Double, 1.5)
        try expectEqual(dict["timestamp"] as? Double, 1_700_000_000.0)
    }

    test("dictFromFix: each sentinel nulls only its own field") {
        // verticalAccuracy gates altitude; course and speed carry their own
        // sentinels. Tripping one must not bleed into the others.
        func fix(verticalAccuracy: Double = 3.0, course: Double = 90.0, speed: Double = 1.5) -> [String: Any] {
            Location.dictFromFix(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                altitude: 10, horizontalAccuracy: 5.0, verticalAccuracy: verticalAccuracy,
                course: course, speed: speed, timestamp: Date()))
        }
        let noAltitude = fix(verticalAccuracy: -1)
        try expect(noAltitude["altitude"] is NSNull, "altitude must be NSNull when verticalAccuracy < 0")
        try expectEqual(noAltitude["heading"] as? Double, 90.0)
        try expectEqual(noAltitude["speed"]   as? Double, 1.5)

        let noHeading = fix(course: -1)
        try expect(noHeading["heading"] is NSNull, "heading must be NSNull when course < 0")
        try expectEqual(noHeading["altitude"] as? Double, 10.0)
        try expectEqual(noHeading["speed"]    as? Double, 1.5)

        let noSpeed = fix(speed: -1)
        try expect(noSpeed["speed"] is NSNull, "speed must be NSNull when speed < 0")
        try expectEqual(noSpeed["altitude"] as? Double, 10.0)
        try expectEqual(noSpeed["heading"]  as? Double, 90.0)
    }

    test("dictFromFix: all three sentinels tripped simultaneously") {
        // A stationary indoor fix with no altitude / heading / speed —
        // most realistic case where CoreLocation returns sentinels for
        // all three. The dict must still carry the keys (with NSNull),
        // not omit them — JS consumers do `dict.altitude ?? "n/a"` and
        // missing keys would surface as undefined rather than null.
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude:           0,
            horizontalAccuracy: 5.0,
            verticalAccuracy:   -1.0,
            course:             -1.0,
            speed:              -1.0,
            timestamp:           Date()
        )
        let dict = Location.dictFromFix(loc)
        try expect(dict["altitude"] is NSNull)
        try expect(dict["heading"]  is NSNull)
        try expect(dict["speed"]    is NSNull)
        try expect(dict["lat"]       != nil, "core fields still present")
        try expect(dict["lon"]       != nil, "core fields still present")
        try expect(dict["accuracy"]  != nil, "core fields still present")
        try expect(dict["timestamp"] != nil, "core fields still present")
    }
}
