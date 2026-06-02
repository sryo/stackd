import Foundation
import CoreLocation

// Tests for the testable surface of Location.swift.
//
// Surface reality: Location.swift exposes exactly ONE public entry point,
// `Location.snapshot() -> [String: Any]?`. Everything else
// (LocationObserver / LocationDelegate / CLLocationManager wiring) is
// either internal-state-only or talks directly to the system framework
// via methods that prompt the user (requestWhenInUseAuthorization).
//
// Out of scope by design:
//   - LocationObserver.install() — calls into CLLocationManager on the
//     main runloop and would trigger the macOS Location Services TCC
//     prompt (or the silent .denied transition on a bare CLI binary,
//     per the file header). Either way: side-effectful, not unit-testable.
//   - The CLLocation → dict mapping body (lat/lon/altitude/heading/...).
//     The mapping lives inside snapshot() and is gated by
//     LocationObserver.shared.lastFix, which is `fileprivate` and set
//     only by the CoreLocation delegate. There's no public seam to inject
//     a synthetic CLLocation without changing visibility — which the
//     task constraints forbid.
//   - The < 0 → NSNull sentinel coercion for altitude/heading/speed.
//     Same reason — gated behind lastFix.
//   - Authorization-status string mapping / accuracy clamps / geocoder
//     request parsing. The task prompt anticipated these, but they do
//     not exist in this file. The desiredAccuracy is hard-coded to
//     kCLLocationAccuracyThreeKilometers inside LocationDelegate.init
//     (no public knob), and there is no geocoder code path here.
//
// In scope (witness tests):
//   - snapshot() is callable without throwing/crashing.
//   - snapshot() returns nil when LocationObserver has never been
//     installed (i.e. lastFix is nil) — the documented "until
//     authorization is granted AND CoreLocation has delivered the
//     first fix" contract that JS consumers (Bridge.swift line 2439:
//     `Location.snapshot() ?? NSNull()`) depend on for the null path.
//   - LocationObserver.shared is a stable singleton (the .shared
//     instance returned by repeated access is the same object).

func registerLocationTests() {
    // MARK: - Location.snapshot() witness

    test("Location.snapshot() is callable and returns Optional<[String: Any]>") {
        // Smoke test: the only public entry point doesn't crash when
        // called cold (no observer install, no authorization). Catches
        // a regression where snapshot() force-unwraps lastFix or
        // touches CLLocationManager on the call path.
        let result = Location.snapshot()
        // Either nil (typical for a fresh process with no observer
        // installed) OR a dict (if some prior test/host state seeded
        // lastFix). Both are valid; the type contract is what matters.
        if let dict = result {
            // If we DO get a fix from ambient state, at minimum the
            // documented always-present keys must be there. Bridge.swift
            // hands this dict straight to JSContext via jsonify, so a
            // missing required key would break consumers.
            try expect(dict["lat"]       != nil, "snapshot dict missing 'lat'")
            try expect(dict["lon"]       != nil, "snapshot dict missing 'lon'")
            try expect(dict["accuracy"]  != nil, "snapshot dict missing 'accuracy'")
            try expect(dict["timestamp"] != nil, "snapshot dict missing 'timestamp'")
            // Nullable-but-present keys (NSNull when CLLocation sentinel
            // is negative). Presence is the contract; value type may be
            // Double or NSNull.
            try expect(dict["altitude"]  != nil, "snapshot dict missing 'altitude' key")
            try expect(dict["heading"]   != nil, "snapshot dict missing 'heading' key")
            try expect(dict["speed"]     != nil, "snapshot dict missing 'speed' key")
        }
        // result == nil is also a passing outcome — that's the
        // documented "no fix yet" path Bridge coerces to NSNull.
    }

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

    // MARK: - LocationObserver.shared singleton identity

    test("LocationObserver.shared is a stable singleton") {
        // RefCountedObserver subclasses rely on a single .shared instance
        // so that multiple subscribers share the same install/teardown
        // refcount. If .shared ever started returning a fresh instance
        // per access, the refcount would split across copies and tokens
        // would tear down the wrong manager.
        let a = LocationObserver.shared
        let b = LocationObserver.shared
        try expect(a === b, "LocationObserver.shared returned distinct instances")
    }

    // MARK: - Location.dictFromFix (CLLocation → JS dict mapping)
    //
    // 2026-06-02: the CLLocation-to-dict mapping moved out of snapshot()
    // into `dictFromFix(_ loc:)` (internal static) so the sentinel
    // handling for altitude/heading/speed is testable without going
    // through CLLocationManager + TCC. Construct a CLLocation with the
    // public initializer and assert the mapping.

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

    test("dictFromFix: negative verticalAccuracy coerces altitude to NSNull") {
        // CLLocation surfaces verticalAccuracy < 0 as the "altitude not
        // measured" sentinel. The mapping must turn that into JS null
        // (NSNull bridges to null via JSONSerialization), not bleed a
        // bogus altitude value into the dict.
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude:           0,
            horizontalAccuracy: 5.0,
            verticalAccuracy:   -1.0,
            course:              90.0,
            speed:               1.5,
            timestamp:           Date()
        )
        let dict = Location.dictFromFix(loc)
        try expect(dict["altitude"] is NSNull, "altitude must be NSNull when verticalAccuracy < 0")
        // heading + speed still come through since their sentinels weren't tripped.
        try expectEqual(dict["heading"] as? Double, 90.0)
        try expectEqual(dict["speed"]   as? Double, 1.5)
    }

    test("dictFromFix: negative course coerces heading to NSNull") {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude:           10,
            horizontalAccuracy: 5.0,
            verticalAccuracy:   3.0,
            course:             -1.0,
            speed:               1.5,
            timestamp:           Date()
        )
        let dict = Location.dictFromFix(loc)
        try expect(dict["heading"] is NSNull, "heading must be NSNull when course < 0")
        try expectEqual(dict["altitude"] as? Double, 10.0)
        try expectEqual(dict["speed"]    as? Double, 1.5)
    }

    test("dictFromFix: negative speed coerces speed to NSNull") {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude:           10,
            horizontalAccuracy: 5.0,
            verticalAccuracy:   3.0,
            course:              90.0,
            speed:              -1.0,
            timestamp:           Date()
        )
        let dict = Location.dictFromFix(loc)
        try expect(dict["speed"] is NSNull, "speed must be NSNull when speed < 0")
        try expectEqual(dict["altitude"] as? Double, 10.0)
        try expectEqual(dict["heading"]  as? Double, 90.0)
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
