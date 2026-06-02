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
}
