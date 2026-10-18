import Foundation

/// One finger in a MultitouchSupport contact frame. `stage` is the raw
/// MTPathStage value; floats stay Float to keep the MT-thread copy small.
/// `id` is the contact's pathIndex: MultitouchSupport's fingerID is its
/// guess at which finger it is and gets revised mid-touch (0 at first
/// contact, then a classification), so it can't key a touch.
struct TouchContact: Equatable {
    var id: Int32
    var stage: Int32
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var angle: Float
    var size: Float
    var pressure: Float
    var majorAxis: Float
    var minorAxis: Float
}

extension TouchContact {
    init(_ t: MTTouch) {
        self.init(id: t.pathIndex,
                  stage: Int32(bitPattern: t.stage.rawValue),
                  x: t.normalizedVector.position.x,
                  y: t.normalizedVector.position.y,
                  vx: t.normalizedVector.velocity.x,
                  vy: t.normalizedVector.velocity.y,
                  angle: t.angle,
                  size: t.zTotal,
                  pressure: t.zPressure,
                  majorAxis: t.majorAxis,
                  minorAxis: t.minorAxis)
    }
}

/// One contact frame from one device. `timestamp` is the framework's
/// seconds-since-boot stamp (the mach uptime clock). `synthetic` marks a
/// release the lift watchdog made up.
struct TouchFrame: Equatable {
    var device: UInt64
    var timestamp: Double
    var frame: Int
    var touches: [TouchContact]
    var synthetic: Bool = false
    /// systemUptime when the MultitouchSupport callback delivered the frame.
    /// `timestamp` is the device's own clock, which isn't comparable to it.
    var receivedAt: Double? = nil

    /// MTPathStage → consumer-friendly state name. MakeTouch=began,
    /// Touching=moved, BreakTouch=ended, OutOfRange=lifted,
    /// HoverInRange=stationary; the rare StartInRange/LingerInRange
    /// transients bucket with their closest neighbor.
    static func stateName(_ stage: Int32) -> String {
        switch stage {
        case 3: return "began"        // MakeTouch
        case 4: return "moved"        // Touching
        case 5: return "ended"        // BreakTouch
        case 7: return "lifted"       // OutOfRange
        case 2: return "stationary"   // HoverInRange
        case 1: return "began"        // StartInRange
        case 6: return "stationary"   // LingerInRange
        default: return "cancelled"   // NotTracking + unknown
        }
    }

    /// Stages that start or end a finger. A frame holding one is an edge the
    /// mailbox never merges away.
    static func isEdgeStage(_ stage: Int32) -> Bool {
        stage != 2 && stage != 4 && stage != 6
    }

    /// The sd.touchdevice payload. `ageMs` is how long ago the daemon
    /// received the frame from MultitouchSupport (null when unknown), and `emittedAt` is
    /// the epoch-ms wall clock at emit, so a stack can add its own delivery
    /// lag: `ageMs + (performance.timeOrigin + performance.now() - emittedAt)`.
    static func payload(_ f: TouchFrame, uptimeNow: Double, epochMsNow: Double) -> [String: Any] {
        var touches: [[String: Any]] = []
        touches.reserveCapacity(f.touches.count)
        for t in f.touches {
            touches.append([
                "identifier": Int(t.id),
                "state":      stateName(t.stage),
                "x":          Double(t.x),
                "y":          Double(t.y),
                "vx":         Double(t.vx),
                "vy":         Double(t.vy),
                "angle":      Double(t.angle),
                "size":       Double(t.size),
                "pressure":   Double(t.pressure),
                "majorAxis":  Double(t.majorAxis),
                "minorAxis":  Double(t.minorAxis)
            ])
        }
        let age = f.receivedAt.map { (uptimeNow - $0) * 1000 }
        var p: [String: Any] = [
            "timestamp": f.timestamp,
            "frame":     f.frame,
            "device":    f.device,
            "touches":   touches,
            "emittedAt": epochMsNow,
            "ageMs":     age.flatMap { $0 >= 0 && $0 < 10_000 ? $0 : nil } as Any? ?? NSNull()
        ]
        if f.synthetic { p["synthetic"] = true }
        return p
    }
}

/// Hand-off between the MultitouchSupport callback thread and the main-thread
/// drain. All state sits behind one lock; `offer` runs on the MT thread,
/// `take` and `checkWatchdog` on main. Times passed as `now` must share one
/// monotonic clock (the observer uses ProcessInfo.systemUptime).
///
/// Policy per offered frame:
///   - an empty frame while the device is already idle is dropped;
///   - a frame is an edge when its finger count differs from the device's
///     last accepted frame or any finger is in a starting/ending stage;
///   - a non-edge frame within 0.0005 (normalized units) of the last
///     accepted frame is dropped as sensor jitter;
///   - a non-edge frame replaces a pending non-edge frame of the same device
///     and finger count at the tail of the queue; otherwise it is appended;
///   - past `capacity`, the oldest non-edge frame is evicted first.
/// `offer` returns true only for the offer that must schedule a drain; later
/// offers ride that drain until `take` runs.
final class TouchFrameMailbox {
    enum Watchdog: Equatable {
        case idle
        case rearm(at: Double)
        case fired
    }

    private struct Pending {
        var frame: TouchFrame
        var isEdge: Bool
    }

    private struct DeviceState {
        var lastAccepted: TouchFrame?
        var lastOfferAt: Double = 0
        var touching: Bool { !(lastAccepted?.touches.isEmpty ?? true) }
    }

    private let lock = NSLock()
    private let capacity: Int
    private let liftTimeout: Double
    private var pending: [Pending] = []
    private var devices: [UInt64: DeviceState] = [:]
    private var drainScheduled = false

    init(capacity: Int = 16, liftTimeout: Double = 0.12) {
        self.capacity = max(2, capacity)
        self.liftTimeout = liftTimeout
    }

    func offer(_ frame: TouchFrame, now: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var dev = devices[frame.device] ?? DeviceState()
        dev.lastOfferAt = now
        defer { devices[frame.device] = dev }

        let prevCount = dev.lastAccepted?.touches.count ?? 0
        if frame.touches.isEmpty && prevCount == 0 { return false }
        let isEdge = frame.touches.count != prevCount
            || frame.touches.contains { TouchFrame.isEdgeStage($0.stage) }
        if !isEdge, let last = dev.lastAccepted,
           !TouchFrameMailbox.differsMaterially(frame, last) {
            return false
        }
        dev.lastAccepted = frame
        enqueue(Pending(frame: frame, isEdge: isEdge))
        return scheduleDrainIfNeeded()
    }

    func take() -> [TouchFrame] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending.map(\.frame)
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        return out
    }

    /// Main-thread watchdog step. `.fired` means a synthetic release was
    /// queued for a device that went quiet mid-touch; the caller drains now.
    /// `.rearm(at:)` is the earliest time a quiet device could need one.
    func checkWatchdog(now: Double) -> Watchdog {
        lock.lock()
        defer { lock.unlock() }
        var fired = false
        var nextDeadline: Double?
        for (id, var dev) in devices where dev.touching {
            let deadline = dev.lastOfferAt + liftTimeout
            if now >= deadline, let last = dev.lastAccepted {
                let release = TouchFrame(device: id,
                                         timestamp: last.timestamp + (now - dev.lastOfferAt),
                                         frame: last.frame,
                                         touches: [],
                                         synthetic: true,
                                         receivedAt: now)
                dev.lastAccepted = release
                devices[id] = dev
                enqueue(Pending(frame: release, isEdge: true))
                fired = true
            } else {
                nextDeadline = min(nextDeadline ?? deadline, deadline)
            }
        }
        if fired { return .fired }
        if let d = nextDeadline { return .rearm(at: d) }
        return .idle
    }

    /// Forget a device (unplugged or unregistered) without emitting anything.
    func forget(device: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeValue(forKey: device)
        pending.removeAll { $0.frame.device == device }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        devices.removeAll()
        drainScheduled = false
    }

    private func enqueue(_ p: Pending) {
        if !p.isEdge, let i = pending.indices.last,
           !pending[i].isEdge,
           pending[i].frame.device == p.frame.device,
           pending[i].frame.touches.count == p.frame.touches.count {
            pending[i] = p
            return
        }
        if pending.count >= capacity {
            if let i = pending.firstIndex(where: { !$0.isEdge }) {
                pending.remove(at: i)
            } else {
                pending.removeFirst()
            }
        }
        pending.append(p)
    }

    private func scheduleDrainIfNeeded() -> Bool {
        guard !drainScheduled, !pending.isEmpty else { return false }
        drainScheduled = true
        return true
    }

    /// Same finger identities and states, and every finger within 0.0005 of
    /// its previous normalized position — trackpad coordinates jitter in the
    /// 5th decimal even when a finger rests.
    static func differsMaterially(_ a: TouchFrame, _ b: TouchFrame) -> Bool {
        if a.touches.count != b.touches.count { return true }
        for i in 0..<a.touches.count {
            let ta = a.touches[i], tb = b.touches[i]
            if ta.id != tb.id || ta.stage != tb.stage { return true }
            if abs(ta.x - tb.x) > 0.0005 || abs(ta.y - tb.y) > 0.0005 { return true }
        }
        return false
    }
}

/// Refcon for one MultitouchSupport registration. The pointer value itself
/// carries (generation, slot) and is never dereferenced, so a callback the
/// framework delivers after its device was unregistered decodes to a stale
/// generation and is dropped instead of touching freed memory.
enum TouchDeviceRefcon {
    static func encode(generation: UInt, slot: Int) -> UnsafeMutableRawPointer? {
        guard generation != 0, generation <= (UInt.max >> 8), (0..<256).contains(slot) else { return nil }
        return UnsafeMutableRawPointer(bitPattern: (generation << 8) | UInt(slot))
    }

    static func decode(_ refcon: UnsafeMutableRawPointer?) -> (generation: UInt, slot: Int)? {
        guard let refcon = refcon else { return nil }
        let v = UInt(bitPattern: refcon)
        return (v >> 8, Int(v & 0xFF))
    }
}

/// When to (re-)register multitouch devices. Sleep tears registrations
/// down; wake, unlock and IOKit hot-plug re-register after a settle delay
/// (devices re-enumerate for a moment after each); a registration that
/// finds no device or fails retries on a backoff, and any fresh signal
/// restarts an exhausted backoff.
struct TouchDeviceLifecycle {
    enum Event: Equatable {
        case sleep
        case wake
        case unlock
        case topologyChanged
        case registered(count: Int)
        case registerFailed
    }

    enum Action: Equatable {
        case cancelPending
        case teardown
        case register(after: Double)
    }

    let settleDelay: Double
    let retryDelays: [Double]
    private(set) var asleep = false
    private var failures = 0

    init(settleDelay: Double = 1.0, retryDelays: [Double] = [1, 2, 4, 8, 16]) {
        self.settleDelay = settleDelay
        self.retryDelays = retryDelays
    }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .sleep:
            asleep = true
            failures = 0
            return [.cancelPending, .teardown]
        case .wake, .unlock:
            asleep = false
            failures = 0
            return [.register(after: settleDelay)]
        case .topologyChanged:
            if asleep { return [] }
            failures = 0
            return [.register(after: settleDelay)]
        case .registered(let count) where count > 0:
            failures = 0
            return []
        case .registered, .registerFailed:
            if asleep || failures >= retryDelays.count { return [] }
            let delay = retryDelays[failures]
            failures += 1
            return [.register(after: delay)]
        }
    }
}
