import AppKit
import Foundation
import IOKit

// MARK: ============================================================
// MARK: TouchDevice — raw MultitouchSupport per-finger frames
// MARK: ============================================================

// Raw per-finger trackpad frames via the private MultitouchSupport.framework.
// Port of asmagill's hs._asm.undocumented.touchdevice. The framework fires its
// contact-frame callback (~90 Hz while a finger is down) on a private thread
// with every finger's stable identity, normalized position, velocity,
// pressure, angle, and ellipsoid axes — strictly BELOW the layer where
// AppKit recognizes "swipe"/"pinch"/"rotate" gestures.
//
// Event-driven delivery: the callback copies each frame into compact
// TouchFrame structs and offers them to a lock-guarded TouchFrameMailbox.
// The first offer of a burst schedules exactly one main-thread drain; the
// drain pushes every pending frame to subscribers. There is no poll: while
// the main thread is busy, consecutive "changed" frames with the same finger
// count merge (newest wins) and began/ended edges queue behind them, so a
// slow main thread costs intermediate positions, never a touch or release.
// The only timer is the lift watchdog, armed only while a finger is down:
// when no frame arrives for 120ms it synthesizes a release, so consumers
// never see a stuck finger after a device drops its final empty frame.

enum TouchDevice {
    /// Latest emitted frame payload, or nil if no frame has arrived yet
    /// (e.g. trackpad untouched since install). Used by Bridge for replay.
    static func snapshot() -> [String: Any]? {
        return TouchDeviceObserver.shared.latestFrame()
    }
}

// Top-level C-convention callback — MultitouchSupport.framework can't call
// a Swift closure. Runs on the framework's thread: resolve the refcon to a
// device identity, copy into compact structs and hand off, nothing else.
private func touchDeviceFrameCallback(_ device: UnsafeMutableRawPointer?,
                                      _ touches: UnsafeMutablePointer<MTTouch>?,
                                      _ numTouches: Int,
                                      _ timestamp: Double,
                                      _ frame: Int,
                                      _ refcon: UnsafeMutableRawPointer?) {
    let observer = TouchDeviceObserver.shared
    guard let deviceId = observer.deviceId(for: refcon) else { return }
    var contacts: [TouchContact] = []
    if let touches = touches, numTouches > 0 {
        contacts.reserveCapacity(numTouches)
        for i in 0..<numTouches { contacts.append(TouchContact(touches[i])) }
    }
    observer.accept(TouchFrame(device: deviceId, timestamp: timestamp, frame: frame, touches: contacts,
                               receivedAt: ProcessInfo.processInfo.systemUptime))
}

// IOKit matching callback for AppleMultitouchDevice arrival/removal. The
// iterator must be drained to re-arm the notification.
private func touchDeviceTopologyCallback(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    TouchDeviceObserver.drain(iterator)
    TouchDeviceObserver.shared.handleLifecycle(.topologyChanged)
}

final class TouchDeviceObserver: RefCountedObserver {
    static let shared = TouchDeviceObserver()
    private override init() { super.init() }

    private let mailbox = TouchFrameMailbox()

    // Registration table read by the MT callback thread.
    private let registrationLock = NSLock()
    private var generation: UInt = 0
    private var slotIds: [UInt64] = []

    // Main-thread only.
    private var lastEmitted: TouchFrame?
    private var watchdog: DispatchSourceTimer?
    private var watchdogDeadline: Double?
    private var lifecycle = TouchDeviceLifecycle()
    private var pendingRegister: DispatchWorkItem?
    private var deviceList: CFArray?
    private var registeredDevices: [MTDeviceRef] = []
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var notifyPort: IONotificationPortRef?
    private var topologyIterators: [io_iterator_t] = []

    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Called from the C callback on the MT thread. nil for a refcon from a
    /// superseded registration.
    func deviceId(for refcon: UnsafeMutableRawPointer?) -> UInt64? {
        guard let (gen, slot) = TouchDeviceRefcon.decode(refcon) else { return nil }
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard gen == generation, slot < slotIds.count else { return nil }
        return slotIds[slot]
    }

    /// Called from the C callback on the MT thread.
    func accept(_ frame: TouchFrame) {
        if mailbox.offer(frame, now: TouchDeviceObserver.uptime()) {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }

    func latestFrame() -> [String: Any]? {
        guard let f = lastEmitted else { return nil }
        return TouchFrame.payload(f, uptimeNow: TouchDeviceObserver.uptime(),
                                  epochMsNow: Date().timeIntervalSince1970 * 1000)
    }

    func handleLifecycle(_ event: TouchDeviceLifecycle.Event) {
        for action in lifecycle.handle(event) {
            switch action {
            case .cancelPending:
                pendingRegister?.cancel()
                pendingRegister = nil
            case .teardown:
                unregisterDevices()
            case .register(let delay):
                pendingRegister?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingRegister = nil
                    self?.registerDevices()
                }
                pendingRegister = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    override func install() -> Token? {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            self?.watchdogDeadline = nil
            self?.runWatchdog()
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        watchdog = timer

        startLifecycleSignals()
        registerDevices()
        return Token { [weak self] in self?.teardown() }
    }

    // MARK: Device registration

    private func registerDevices() {
        unregisterDevices()
        guard let list = MTDeviceCreateList() else {
            handleLifecycle(.registerFailed)
            return
        }
        let count = min(CFArrayGetCount(list), 256)
        var devices: [MTDeviceRef?] = []
        var ids: [UInt64] = []
        for i in 0..<count {
            let dev = CFArrayGetValueAtIndex(list, i).map { UnsafeMutableRawPointer(mutating: $0) }
            devices.append(dev)
            ids.append(dev.map(TouchDeviceObserver.identity(of:)) ?? 0)
        }

        // Publish the slot table before registering so the first frame of
        // each device resolves.
        registrationLock.lock()
        generation = generation &+ 1
        if generation == 0 || generation > (UInt.max >> 8) { generation = 1 }
        let gen = generation
        slotIds = ids
        registrationLock.unlock()

        var registered: [MTDeviceRef] = []
        for (slot, dev) in devices.enumerated() {
            guard let dev = dev,
                  let refcon = TouchDeviceRefcon.encode(generation: gen, slot: slot),
                  MTRegisterContactFrameCallbackWithRefcon(dev, touchDeviceFrameCallback, refcon)
            else { continue }
            if MTDeviceStart(dev, 0) != 0 {
                _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
                continue
            }
            registered.append(dev)
        }
        registeredDevices = registered
        deviceList = list
        log("touchdevice: registered \(registered.count)/\(count) multitouch device(s)")
        handleLifecycle(.registered(count: registered.count))
    }

    /// Teardown order from asmagill's userdata_gc (internal.m:1128-1134):
    /// unregister callback → check IsRunning → stop → release. Reordering
    /// crashes on the next-frame delivery the framework queues internally
    /// between stop and release. A device mid-touch gets its release from
    /// the lift watchdog once its frames stop.
    private func unregisterDevices() {
        for dev in registeredDevices {
            _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
            if MTDeviceIsRunning(dev) { _ = MTDeviceStop(dev) }
        }
        registeredDevices = []
        registrationLock.lock()
        generation = generation &+ 1
        slotIds = []
        registrationLock.unlock()
        deviceList = nil
    }

    /// Stable identity for a device: the registry ID of the IOHIDEventService
    /// above its AppleMultitouchDevice — the same value IOHIDEventGetSenderID
    /// reports on that device's scroll and gesture CGEvents — falling back to
    /// the multitouch service's own registry ID.
    static func identity(of device: MTDeviceRef) -> UInt64 {
        let service = MTDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return 0 }
        if let sender = hidEventServiceId(above: service) { return sender }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : 0
    }

    private static func hidEventServiceId(above service: io_service_t) -> UInt64? {
        var current = service
        var owned = false
        defer { if owned { IOObjectRelease(current) } }
        for _ in 0..<16 {
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard kr == KERN_SUCCESS, parent != 0 else { return nil }
            if owned { IOObjectRelease(current) }
            current = parent
            owned = true
            if IOObjectConformsTo(current, "IOHIDEventService") != 0 {
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(current, &id) == KERN_SUCCESS, id != 0 else { return nil }
                return id
            }
        }
        return nil
    }

    // MARK: Lifecycle signals

    private func startLifecycleSignals() {
        let ws = NSWorkspace.shared.notificationCenter
        notificationTokens.append((ws, ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleLifecycle(.sleep) }))
        notificationTokens.append((ws, ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleLifecycle(.wake) }))
        let dnc = DistributedNotificationCenter.default()
        notificationTokens.append((dnc, dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.handleLifecycle(.unlock) }))

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("AppleMultitouchDevice"),
                touchDeviceTopologyCallback, nil, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            // Arms the notification; existing devices are not a change.
            TouchDeviceObserver.drain(iterator)
            topologyIterators.append(iterator)
        }
    }

    static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func stopLifecycleSignals() {
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens = []
        for it in topologyIterators { IOObjectRelease(it) }
        topologyIterators = []
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
    }

    // MARK: Drain + watchdog

    private func drain() {
        let frames = mailbox.take()
        for f in frames {
            lastEmitted = f
            fire()
        }
        runWatchdog()
    }

    /// Re-arm lazily: an armed deadline earlier than the new one is left
    /// alone and re-evaluated when it fires, so a streaming touch reschedules
    /// the timer about once per lift timeout rather than once per frame.
    private func runWatchdog() {
        switch mailbox.checkWatchdog(now: TouchDeviceObserver.uptime()) {
        case .fired:
            drain()
        case .rearm(let at):
            if let armed = watchdogDeadline, armed <= at { return }
            watchdogDeadline = at
            let delay = max(0, at - TouchDeviceObserver.uptime())
            watchdog?.schedule(deadline: .now() + delay)
        case .idle:
            break
        }
    }

    private func teardown() {
        pendingRegister?.cancel()
        pendingRegister = nil
        stopLifecycleSignals()
        unregisterDevices()
        lifecycle = TouchDeviceLifecycle()

        watchdog?.cancel()
        watchdog = nil
        watchdogDeadline = nil
        mailbox.reset()
        lastEmitted = nil
    }
}
