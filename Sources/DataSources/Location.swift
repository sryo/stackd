import CoreLocation
import Foundation

// Current device location via CoreLocation. Observer lazily creates one
// CLLocationManager, requests When-In-Use authorization on first subscribe,
// and forwards fixes through fire(). Snapshot returns nil until authorization
// is granted AND CoreLocation delivers the first fix — typically a few
// seconds after the user accepts the system prompt.
//
// Authorization caveat: stackd currently ships as a raw CLI binary
// (.build/stackd). macOS Location Services normally requires the requesting
// app to provide NSLocationUsageDescription in its Info.plist, which a bare
// executable doesn't have. The framework will still create the manager and
// the delegate calls will fire, but authorizationStatus tends to settle at
// .denied / .restricted with no system prompt presented. Once stackd ships
// as a .app bundle (Contents/Info.plist with the usage description string),
// the standard When-In-Use authorization flow will succeed and snapshot()
// will return real fixes. Reduced accuracy (~5km) is fine for weather-grade
// consumers and avoids the precise-location prompt entirely.
enum Location {
    /// Current location. Returns nil until authorization is granted and
    /// CoreLocation has delivered at least one fix. Numeric fields use
    /// CoreLocation's "missing" sentinels (negative speed/heading/altitude
    /// mean "not measured" — see CLLocation docs); we coerce those to NSNull.
    static func snapshot() -> [String: Any]? {
        guard let loc = LocationObserver.shared.lastFix else { return nil }
        return dictFromFix(loc)
    }

    /// Map a CLLocation into the JS-side dict shape. Extracted so the
    /// sentinel-handling (CLLocation surfaces "unmeasured" as < 0 for
    /// altitude / heading / speed) is hammerable without authorization
    /// + a live CLLocationManager.
    internal static func dictFromFix(_ loc: CLLocation) -> [String: Any] {
        var dict: [String: Any] = [
            "lat":       loc.coordinate.latitude,
            "lon":       loc.coordinate.longitude,
            "accuracy":  loc.horizontalAccuracy,
            "timestamp": loc.timestamp.timeIntervalSince1970
        ]
        // CLLocation surfaces these as < 0 when unmeasured (verticalAccuracy
        // is the gate for altitude; course/speed have their own sentinels).
        dict["altitude"] = loc.verticalAccuracy >= 0 ? loc.altitude : NSNull()
        dict["heading"]  = loc.course           >= 0 ? loc.course   : NSNull()
        dict["speed"]    = loc.speed            >= 0 ? loc.speed    : NSNull()
        return dict
    }
}

final class LocationObserver: RefCountedObserver {
    static let shared = LocationObserver()
    private override init() { super.init() }

    // The private delegate holds the CLLocationManager + forwards didUpdate /
    // didChangeAuthorization callbacks via closures. Pattern mirrors
    // AudioObserver: native handle lives on a tiny class, observer forwards
    // through closures so RefCountedObserver doesn't have to conform to a
    // delegate protocol with @objc methods.
    private var delegate: LocationDelegate?
    fileprivate var lastFix: CLLocation?

    override func install() -> Token? {
        let d = LocationDelegate()
        d.onFix = { [weak self] loc in
            self?.lastFix = loc
            self?.fire()
        }
        // CLLocationManager methods must be touched on a thread with an
        // active runloop. Main is the safe choice for a daemon — matches
        // every other observer that schedules native plumbing.
        DispatchQueue.main.async { d.start() }
        self.delegate = d

        return Token { [weak self] in
            DispatchQueue.main.async {
                self?.delegate?.stop()
                self?.delegate = nil
            }
            // Keep lastFix around briefly so a hot-reload within the 5s
            // debounce window still has a value to replay; it gets cleared
            // only when the observer is fully torn down and a new install()
            // produces a fresh delegate.
        }
    }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onFix: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // 3km is plenty for weather / timezone / "where am I roughly" use
        // cases. kCLLocationAccuracyReducedAccuracy is iOS-only — on macOS
        // the coarsest tier in the public CLLocation constants is 3km. Bump
        // to kCLLocationAccuracyHundredMeters later if a consumer needs
        // city-block precision.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func start() {
        // requestWhenInUseAuthorization is the right entry point for a
        // foreground-style app (no background monitoring). On macOS it surfaces
        // the standard Location Services prompt IF the app bundle declares
        // NSLocationUsageDescription; otherwise it transitions straight to
        // .denied with no UI (see top-of-file note).
        manager.requestWhenInUseAuthorization()
        // Continuous updates rather than requestLocation(): the latter is
        // single-shot and would need our own re-trigger timer. CoreLocation
        // already throttles delivery to "significant" movement at reduced
        // accuracy, so battery cost is negligible.
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        onFix?(loc)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // On grant, kick updates so the first fix arrives without waiting for
        // the user to re-trigger anything. On deny, do nothing — snapshot()
        // will keep returning nil until authorization changes again.
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        FileHandle.standardError.write(Data("stackd: LocationObserver — \(error.localizedDescription)\n".utf8))
    }
}
