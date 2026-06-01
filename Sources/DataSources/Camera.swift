import AppKit
import AVFoundation

// Video capture devices: enumeration + per-device in-use signal.
//
// Enumeration is metadata-only. AVCaptureDevice.DiscoverySession reads the
// public device list (uniqueID, localizedName, position, isInUse) without
// ever opening a video stream — so stackd does NOT trigger the TCC camera
// prompt. The TCC prompt fires only when an app actually requests video
// data (e.g. AVCaptureSession.startRunning with a video input). We never do.
//
// The "isInUseByAnotherApplication" signal is what powers the green-dot /
// red-dot "your camera is on" indicators. We observe it via KVO on each
// known device; when devices come and go (connect/disconnect notifications)
// we rebuild the KVO set.

enum Camera {
    /// Snapshot used by Bridge to push the initial signal value. Walks the
    /// discovery session every call — cheap (sub-ms) and avoids any cache
    /// staleness when KVO hasn't fired yet for a transient in-use flip.
    static func snapshot() -> [[String: Any]] {
        return discover().map(describe)
    }

    /// Modern enumeration path. The deprecated AVCaptureDevice.devices(for:)
    /// returns nothing on macOS 14+; DiscoverySession is what Apple ships now.
    /// .external + .deskViewCamera + .continuityCamera cover the modern
    /// non-built-in surface area (Continuity Camera from iPhone, Desk View,
    /// plus any USB/Thunderbolt webcam).
    static func discover() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .deskViewCamera, .continuityCamera])
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    fileprivate static func describe(_ device: AVCaptureDevice) -> [String: Any] {
        var entry: [String: Any] = [
            "id":       device.uniqueID,
            "name":     device.localizedName,
            "position": positionString(device.position),
            "isInUse":  device.isInUseByAnotherApplication
        ]
        let mfr = device.manufacturer
        if !mfr.isEmpty { entry["manufacturer"] = mfr }
        return entry
    }

    fileprivate static func positionString(_ pos: AVCaptureDevice.Position) -> String {
        switch pos {
        case .front:       return "front"
        case .back:        return "back"
        case .unspecified: return "unspecified"
        @unknown default:  return "unspecified"
        }
    }
}

final class CameraObserver: RefCountedObserver {
    static let shared = CameraObserver()
    private override init() { super.init() }

    // Per-device KVO observers live on a private NSObject so the KVO context
    // pointer + observer identity match across add/remove. Keyed by uniqueID
    // so device-list refresh can diff old vs new without reinstalling KVO on
    // devices that were already being watched.
    private final class InUseWatcher: NSObject {
        let device: AVCaptureDevice
        let onChange: () -> Void
        init(device: AVCaptureDevice, onChange: @escaping () -> Void) {
            self.device = device
            self.onChange = onChange
            super.init()
            device.addObserver(self, forKeyPath: "inUseByAnotherApplication",
                               options: [.new], context: nil)
        }
        deinit {
            device.removeObserver(self, forKeyPath: "inUseByAnotherApplication")
        }
        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            onChange()
        }
    }

    private var watchers: [String: InUseWatcher] = [:]

    override func install() -> Token? {
        let nc = NotificationCenter.default
        rebindKVO()

        let onChange: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            // Device list churn: refresh KVO subscriptions before firing so
            // subscribers see the new device's isInUse immediately on attach.
            self.rebindKVO()
            self.fire()
        }
        let ncToken = installNotifications([
            (nc, .AVCaptureDeviceWasConnected, onChange),
            (nc, .AVCaptureDeviceWasDisconnected, onChange)
        ])

        return Token { [weak self] in
            ncToken.cancel()
            self?.watchers.removeAll()
        }
    }

    private func rebindKVO() {
        let current = Camera.discover()
        let currentIds = Set(current.map { $0.uniqueID })

        // Drop watchers for devices that disappeared (deinit removes KVO).
        for (id, _) in watchers where !currentIds.contains(id) {
            watchers.removeValue(forKey: id)
        }
        // Add watchers for new devices. KVO callback hops to main and fires
        // every subscriber via the base class — same shape as other observers.
        for device in current where watchers[device.uniqueID] == nil {
            watchers[device.uniqueID] = InUseWatcher(device: device) { [weak self] in
                DispatchQueue.main.async { self?.fire() }
            }
        }
    }
}
