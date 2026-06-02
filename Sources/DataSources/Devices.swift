import AppKit
import AVFoundation
import CoreImage
import DiskArbitration
import Foundation
import IOBluetooth
import IOKit
import IOKit.usb

// "What hardware is attached" — consolidates USB enumeration + observation,
// paired Bluetooth peripherals, AVCapture video devices + one-shot frame
// grab, and DiskArbitration mount/unmount lifecycle into a single domain
// file. Each former source is preserved verbatim below behind its own
// MARK; the enum / observer names (USB, USBObserver, Bluetooth, Camera,
// CameraObserver, Disks, DisksHotplug) are unchanged — Bridge dispatch
// continues to route by name.

// MARK: - USB

enum USB {
    /// Snapshot of currently-attached USB devices. Walks the IORegistry every
    /// call — cheap (<1ms even with a dozen devices) and avoids stale caches
    /// when the observer hasn't fired yet (initial Bridge replay).
    static func snapshot() -> [[String: Any]] {
        // kIOUSBDeviceClassName ("IOUSBDevice") is the legacy class — modern
        // macOS (10.11+) publishes devices under "IOUSBHostDevice" instead.
        // IOServiceMatching on the new name covers built-in + plugged devices;
        // the legacy name only finds nothing on Apple Silicon hardware.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }
        var out: [[String: Any]] = []
        while case let dev = IOIteratorNext(iter), dev != 0 {
            if let entry = USB.describe(device: dev) { out.append(entry) }
            IOObjectRelease(dev)
        }
        return out
    }

    /// Read the standard USB property bag off a single io_object_t.
    /// Vendor/product names + serial are optional — USB hubs and many
    /// internal devices ship without them.
    fileprivate static func describe(device: io_object_t) -> [String: Any]? {
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        guard let vid = prop("idVendor")  as? Int,
              let pid = prop("idProduct") as? Int else { return nil }
        var entry: [String: Any] = [
            "vendorID":  vid,
            "productID": pid
        ]
        if let loc = prop("locationID") as? Int { entry["locationID"] = loc }
        if let n = prop("USB Vendor Name")  as? String, !n.isEmpty { entry["vendorName"]   = n }
        if let n = prop("USB Product Name") as? String, !n.isEmpty { entry["productName"]  = n }
        if let s = prop("USB Serial Number") as? String, !s.isEmpty { entry["serialNumber"] = s }
        return entry
    }
}

final class USBObserver: RefCountedObserver {
    static let shared = USBObserver()
    private override init() { super.init() }

    override func install() -> Token? {
        // IONotificationPort owns the runloop source that delivers add/remove
        // callbacks. One port handles both iterators (publish + terminate).
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            FileHandle.standardError.write(Data("stackd: USBObserver — IONotificationPortCreate failed\n".utf8))
            return nil
        }
        guard let src = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            IONotificationPortDestroy(port)
            FileHandle.standardError.write(Data("stackd: USBObserver — runloop source unavailable\n".utf8))
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // The matching dict is consumed by IOServiceAddMatchingNotification —
        // we need a fresh one per call. CF retain counts handle the rest.
        let matchPublish = IOServiceMatching("IOUSBHostDevice")
        let matchTerm    = IOServiceMatching("IOUSBHostDevice")

        let cb: IOServiceMatchingCallback = { ptr, iterator in
            guard let ptr = ptr else { return }
            let me = Unmanaged<USBObserver>.fromOpaque(ptr).takeUnretainedValue()
            // Drain the iterator — if we don't pull every io_object_t, IOKit
            // stops delivering further notifications on this iterator (the
            // arming model is "I've shown you everything new; come back when
            // you've consumed it"). Release each object after drain.
            while case let obj = IOIteratorNext(iterator), obj != 0 {
                IOObjectRelease(obj)
            }
            me.fire()
        }

        var publishIter: io_iterator_t = 0
        var termIter:    io_iterator_t = 0
        let kr1 = IOServiceAddMatchingNotification(port, kIOPublishNotification,
                                                   matchPublish, cb, ctx, &publishIter)
        let kr2 = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                                   matchTerm, cb, ctx, &termIter)
        guard kr1 == KERN_SUCCESS, kr2 == KERN_SUCCESS else {
            if publishIter != 0 { IOObjectRelease(publishIter) }
            if termIter    != 0 { IOObjectRelease(termIter) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            IONotificationPortDestroy(port)
            FileHandle.standardError.write(Data("stackd: USBObserver — IOServiceAddMatchingNotification failed\n".utf8))
            return nil
        }
        // Initial drain arms both iterators. Without this they never fire.
        while case let obj = IOIteratorNext(publishIter), obj != 0 { IOObjectRelease(obj) }
        while case let obj = IOIteratorNext(termIter),    obj != 0 { IOObjectRelease(obj) }

        return Token {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            IOObjectRelease(publishIter)
            IOObjectRelease(termIter)
            IONotificationPortDestroy(port)
        }
    }
}

// MARK: - Bluetooth
//
// Paired Bluetooth peripheral inventory via IOBluetooth (classic Bluetooth,
// not CoreBluetooth's BLE-only surface). Lists every device the user has
// paired — AirPods, Magic Mouse, Magic Keyboard, headphones, controllers —
// with its current connection state.
//
// Battery percentages are intentionally NOT exposed in this ship: AirPods
// report via the private AppleBluetoothBatteryStatistics IOService, Magic
// peripherals via separate private keys, and stable extraction across
// device classes is a focused follow-up. The list-only surface is still
// useful today (peripheral picker, "what's connected" widget).
//
// TCC: macOS 11+ requires the Bluetooth permission for IOBluetoothDevice
// access. The first `paired()` call triggers the prompt. Denial yields [].

enum Bluetooth {
    /// Snapshot of every paired device, regardless of current connection
    /// state. Returns `[{ name, address, connected, services?,
    /// classOfDevice? }, ...]`. `services` is the human-readable list of
    /// SDP service names this device advertises (e.g. "Hands-Free
    /// Audio Gateway", "Advanced Audio Distribution"); useful for telling
    /// AirPods from a generic Bluetooth controller without reading the
    /// device class bits.
    static func paired() -> [[String: Any]] {
        // IOBluetoothDevice.pairedDevices() returns nil on Bluetooth-off
        // hosts or when TCC has denied us; coerce to [] either way.
        guard let raw = IOBluetoothDevice.pairedDevices() else { return [] }
        var out: [[String: Any]] = []
        for case let device as IOBluetoothDevice in raw {
            out.append(describe(device))
        }
        return out
    }

    private static func describe(_ device: IOBluetoothDevice) -> [String: Any] {
        var entry: [String: Any] = [
            "address":   device.addressString ?? "",
            "connected": device.isConnected()
        ]
        if let name = device.name, !name.isEmpty { entry["name"] = name }

        // classOfDevice is a packed 24-bit field (major/minor class + service
        // bits). Exposing the raw integer lets stacks classify devices
        // (audio vs input vs phone) without us deciding the taxonomy.
        let cod = device.classOfDevice
        if cod != 0 { entry["classOfDevice"] = Int(cod) }

        // Service records — names of SDP services the device advertises.
        // Captures the difference between e.g. AirPods and a generic
        // headset without us having to enumerate device-class minutiae.
        if let services = device.services as? [IOBluetoothSDPServiceRecord] {
            var names: [String] = []
            for svc in services {
                if let attrs = svc.attributes as? [NSNumber: IOBluetoothSDPDataElement] {
                    // 0x0100 is the SDP "service name" attribute id.
                    if let nameElem = attrs[0x0100], let s = nameElem.getStringValue() {
                        names.append(s)
                    }
                }
            }
            if !names.isEmpty { entry["services"] = names }
        }

        return entry
    }
}

// MARK: - Camera (enumeration + in-use signal)
//
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

// MARK: - Camera capture (one-shot frame)
//
// One-shot webcam frame capture. The natural input source for the Vision
// request types (faces / featurePrint / subjectMask / bodyPose / ocr) —
// stacks pipe `sd.camera.frame()` into `sd.vision.faces()` and back into
// the WebView for live face tracking, presence detection, posture coaching.
//
// Stream variant (`sd.camera.stream({ fps }).subscribe(...)`) is a separate
// ship: it needs a Bridge handle table + push channel + per-stream Token
// adoption. The one-shot here is the foundation — anything stream-shaped
// can wrap it with a 100ms loop in JS for prototypes.
//
// TCC: AVCaptureSession.startRunning triggers the Camera permission prompt
// the first time. The existing sd.camera channel only enumerates devices
// (metadata, no stream) and does NOT trigger the prompt; this call is the
// first place the user sees it.
//
// Daemon-vs-stack check: capturing a frame requires AVCaptureSession plus
// the CMSampleBuffer → CGImage → dataURL pipeline. None of that is on the
// JS surface; this is a genuine primitive, not policy.

extension Camera {
    /// Grab a single frame. `deviceId` matches the `id` field on
    /// `sd.camera` channel entries (AVCaptureDevice.uniqueID); nil falls
    /// back to the system default video device (`.video` discovery).
    /// `format` is "jpeg" (default, smaller) or "png" (lossless).
    /// `quality` 0..1 applies to JPEG only.
    /// `timeoutSeconds` caps how long we wait for the first buffer before
    /// completing with nil — covers devices that fail to start cleanly.
    ///
    /// Returns `{ dataURL, width, height }` on success, nil on failure
    /// (no device, TCC denied, timeout, encoding error).
    static func frame(deviceId: String?,
                      format: String = "jpeg",
                      quality: Double = 0.85,
                      timeoutSeconds: Double = 3.0,
                      completion: @escaping ([String: Any]?) -> Void) {
        let device: AVCaptureDevice?
        if let id = deviceId, !id.isEmpty {
            device = AVCaptureDevice(uniqueID: id)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device = device else {
            // Hop to main so callers can rely on the same "always async"
            // contract the OneShotGrabber success path provides via its
            // sample-buffer delegate. Firing inline would force every caller
            // to handle two completion-timing flavors.
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let grabber = OneShotGrabber(
            device: device,
            format: format,
            quality: quality,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
        grabber.start()
    }
}

// The grabber holds the session + delegate alive for the duration of the
// capture. Self-retained inside the delegate closure; completion fires
// exactly once (gated by a flag) and tears down the retention.
private final class OneShotGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output  = AVCaptureVideoDataOutput()
    private let queue   = DispatchQueue(label: "stackd.camera.oneshot")
    private let device: AVCaptureDevice
    private let format: String
    private let quality: Double
    private let timeoutSeconds: Double
    private let completion: ([String: Any]?) -> Void
    private var fired = false
    private var retain: OneShotGrabber?  // self-retain until completion

    init(device: AVCaptureDevice,
         format: String, quality: Double,
         timeoutSeconds: Double,
         completion: @escaping ([String: Any]?) -> Void) {
        self.device = device
        self.format = format
        self.quality = quality
        self.timeoutSeconds = timeoutSeconds
        self.completion = completion
    }

    func start() {
        retain = self
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return finish(nil) }
            session.addInput(input)

            // BGRA is the format CIImage / CoreGraphics consume directly
            // without an extra colorspace hop.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return finish(nil) }
            session.addOutput(output)

            session.startRunning()

            // Timeout: if no frame in N seconds, give up. Some devices
            // bring up the session but never deliver a frame (e.g. another
            // app holds exclusive access, or the TCC prompt is pending).
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finish(nil)
            }
        } catch {
            finish(nil)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !fired,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let payload = encode(pixelBuffer: pixelBuffer,
                             format: format, quality: quality)
        finish(payload)
    }

    private func finish(_ result: [String: Any]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.fired else { return }
            self.fired = true
            self.session.stopRunning()
            self.completion(result)
            self.retain = nil
        }
    }

    /// CVPixelBuffer → CGImage → dataURL. CoreImage handles the pixel
    /// format conversion; CGImageDestination does the actual encode.
    private func encode(pixelBuffer: CVPixelBuffer,
                        format: String, quality: Double) -> [String: Any]? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let isPNG = (format == "png")
        let utType = (isPNG ? "public.png" : "public.jpeg") as CFString
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, utType, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = isPNG ? [:] : [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let base64 = (data as Data).base64EncodedString()
        let mime = isPNG ? "image/png" : "image/jpeg"
        return [
            "dataURL": "data:\(mime);base64,\(base64)",
            "width":   cgImage.width,
            "height":  cgImage.height
        ]
    }
}

// MARK: - Disks (mount / unmount lifecycle + snapshot)
//
// Mount / unmount lifecycle + a one-shot snapshot of currently-mounted
// volumes. DiskArbitration is the public-but-rarely-used framework: it
// surfaces "USB drive plugged in," "disk image mounted," "network share
// appeared," "volume ejected" as callbacks scheduled on the main runloop.
//
// Bangs (declared in a stack's `handles` array — no permission needed to
// receive them; the bang fires for every loaded stack that opts in):
//   sd.disk.mounted   — { name, mountPoint, fs?, removable?, ejectable?, size? }
//   sd.disk.unmounted — { mountPoint }  (volume name is gone by the time the
//                                        callback fires; mount point is the
//                                        only stable identifier)
//
// Read primitive:
//   sd.disks.list()   — synchronous snapshot of currently-mounted volumes
//                       in the same shape as the `mounted` bang.

enum Disks {
    /// Snapshot of currently-mounted volumes. Cheap — FileManager walks the
    /// VFS table, no IORegistry traversal needed.
    static func list() -> [[String: Any]] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { describe(mountPoint: $0) }
    }

    /// Build the dict shape stacks see. Used by both snapshot enumeration and
    /// the DA disk-appeared callback.
    fileprivate static func describe(mountPoint: URL) -> [String: Any]? {
        let vals = try? mountPoint.resourceValues(forKeys: [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeIsInternalKey
        ])
        var out: [String: Any] = ["mountPoint": mountPoint.path]
        if let name = vals?.volumeName, !name.isEmpty { out["name"] = name }
        if let fs   = vals?.volumeLocalizedFormatDescription { out["fs"] = fs }
        if let rem  = vals?.volumeIsRemovable { out["removable"] = rem }
        if let ej   = vals?.volumeIsEjectable { out["ejectable"] = ej }
        if let sz   = vals?.volumeTotalCapacity { out["size"] = sz }
        if let intl = vals?.volumeIsInternal  { out["internal"] = intl }
        return out
    }
}

// MARK: - Disks lifecycle bangs
//
// Install once at startup from AppDelegate. Same lifetime pattern as
// WindowEvents / DisplayHotplug — the DA session lives for the process; the
// host.bang fan-out is a no-op when no stack handles the bang.
//
// DA exposes a `matching` dict on each register call. We pass nil to match
// every disk; consumers filter in JS by reading `mountPoint` / `removable`.

enum DisksHotplug {
    private static var session: DASession?

    static func install() {
        guard session == nil else { return }
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            log("disks: DASessionCreate failed")
            return
        }
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        DARegisterDiskAppearedCallback(s, nil, diskAppeared, nil)
        DARegisterDiskDisappearedCallback(s, nil, diskDisappeared, nil)
        session = s
    }
}

private let diskAppeared: DADiskAppearedCallback = { disk, _ in
    // DA fires this for every mounted volume on session start too, not just
    // future mounts. That's the right shape — stacks loaded after a USB drive
    // is already plugged in still see it appear. Volumes without a mount
    // point (raw block devices, unmounted partitions) get filtered here.
    guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
          let url  = desc[kDADiskDescriptionVolumePathKey] as? URL
    else { return }
    DispatchQueue.main.async {
        guard let host = AppDelegate.shared?.host,
              let detail = Disks.describe(mountPoint: url) else { return }
        host.bang(name: "sd.disk.mounted", detail: detail)
    }
}

private let diskDisappeared: DADiskDisappearedCallback = { disk, _ in
    // By the time the callback fires the volume is unmounted — resource-value
    // queries fail, the volume name CFDictionary entry is often missing.
    // mountPoint is the only stable identifier consumers can match on.
    guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
          let url  = desc[kDADiskDescriptionVolumePathKey] as? URL
    else { return }
    DispatchQueue.main.async {
        AppDelegate.shared?.host?.bang(
            name: "sd.disk.unmounted",
            detail: ["mountPoint": url.path]
        )
    }
}
