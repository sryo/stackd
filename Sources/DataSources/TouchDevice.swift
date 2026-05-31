import Foundation

// Raw per-finger trackpad frames via the private MultitouchSupport.framework.
// Port of asmagill's hs._asm.undocumented.touchdevice. The framework fires its
// contact-frame callback at ~80 Hz on a private dispatch queue with every
// finger's stable identity, normalized + absolute position, velocity,
// pressure, angle, and ellipsoid axes — strictly BELOW the layer where
// AppKit recognizes "swipe"/"pinch"/"rotate" gestures.
//
// Coalescing strategy: the MT callback's only job is to atomically swap a
// snapshot dict into `pendingFrame`. A Timer on main runs at 30 Hz, reads
// the snapshot under the lock, diffs against the last emitted frame, and
// pushes to JS only on change. This caps WKWebView eval traffic and lets
// JS-side recognizers (TTTaps, future heatmap stacks) stay responsive
// without saturating the JS thread.

enum TouchDevice {
    /// Latest coalesced frame snapshot, or nil if no frame has arrived yet
    /// (e.g. trackpad untouched since install). Used by Bridge for replay.
    static func snapshot() -> [String: Any]? {
        return TouchDeviceObserver.shared.latestFrame()
    }
}

// MTPathStage → consumer-friendly state name. asmagill exposes the raw enum
// label; we collapse to a smaller "began/stationary/moved/ended/cancelled/
// lifted" vocabulary that matches the Gesture.swift wording (which TTTaps
// already speaks). MakeTouch=began, Touching=moved, BreakTouch=ended,
// OutOfRange=lifted, HoverInRange=stationary, StartInRange/LingerInRange
// are rare transient states — bucket them with the closest neighbor.
private func stateName(for stage: MTPathStage) -> String {
    switch stage {
    case MTPathStageMakeTouch:     return "began"
    case MTPathStageTouching:      return "moved"
    case MTPathStageBreakTouch:    return "ended"
    case MTPathStageOutOfRange:    return "lifted"
    case MTPathStageHoverInRange:  return "stationary"
    case MTPathStageStartInRange:  return "began"
    case MTPathStageLingerInRange: return "stationary"
    case MTPathStageNotTracking:   return "cancelled"
    default:                       return "cancelled"
    }
}

// Top-level C-convention callback — MultitouchSupport.framework can't call
// a Swift closure, and the refcon is the only safe way to reach the
// singleton without globals.
private func touchDeviceFrameCallback(_ device: UnsafeMutableRawPointer?,
                                      _ touches: UnsafeMutablePointer<MTTouch>?,
                                      _ numTouches: Int,
                                      _ timestamp: Double,
                                      _ frame: Int,
                                      _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let observer = Unmanaged<TouchDeviceObserver>.fromOpaque(refcon).takeUnretainedValue()
    var touchList: [[String: Any]] = []
    if let touches = touches, numTouches > 0 {
        touchList.reserveCapacity(numTouches)
        for i in 0..<numTouches {
            let t = touches[i]
            touchList.append([
                "identifier": Int(t.fingerID),
                "state":      stateName(for: t.stage),
                "x":          Double(t.normalizedVector.position.x),
                "y":          Double(t.normalizedVector.position.y),
                "vx":         Double(t.normalizedVector.velocity.x),
                "vy":         Double(t.normalizedVector.velocity.y),
                "angle":      Double(t.angle),
                "size":       Double(t.zTotal),
                "pressure":   Double(t.zPressure),
                "majorAxis":  Double(t.majorAxis),
                "minorAxis":  Double(t.minorAxis)
            ])
        }
    }
    let snapshot: [String: Any] = [
        "timestamp": timestamp,
        "frame":     frame,
        "touches":   touchList
    ]
    observer.acceptFrame(snapshot)
}

final class TouchDeviceObserver: RefCountedObserver {
    static let shared = TouchDeviceObserver()
    private override init() { super.init() }

    private let lock = NSLock()
    private var pendingFrame: [String: Any]?
    private var lastEmittedFrame: [String: Any]?

    private var device: UnsafeMutableRawPointer?
    private var coalescerTimer: Timer?

    // Keeps the singleton retained through Unmanaged.passRetained so the
    // refcon pointer the C callback receives is always valid — the install
    // path balances this with a passUnretained-style release on teardown.
    private var refconRetainer: Unmanaged<TouchDeviceObserver>?

    /// Called from the C callback on a private MT queue. Swaps the frame
    /// snapshot into pendingFrame under the lock; the main-thread timer
    /// drains it.
    func acceptFrame(_ snapshot: [String: Any]) {
        lock.lock()
        pendingFrame = snapshot
        lock.unlock()
    }

    func latestFrame() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return lastEmittedFrame ?? pendingFrame
    }

    override func install() -> Token? {
        guard let dev = MTDeviceCreateDefault() else { return nil }
        self.device = dev

        let retained = Unmanaged.passRetained(self)
        self.refconRetainer = retained
        let refcon = retained.toOpaque()

        guard MTRegisterContactFrameCallbackWithRefcon(dev, touchDeviceFrameCallback, refcon) else {
            retained.release()
            self.refconRetainer = nil
            MTDeviceRelease(dev)
            self.device = nil
            return nil
        }

        let startStatus = MTDeviceStart(dev, 0)
        if startStatus != 0 {
            _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
            retained.release()
            self.refconRetainer = nil
            MTDeviceRelease(dev)
            self.device = nil
            return nil
        }

        // 30 Hz coalescer. Reads pendingFrame under the lock, diffs against
        // lastEmittedFrame, fires subscribers only when the snapshot
        // actually changes. Empty-touches frames still count as a change
        // when the previous frame had touches — that's the "all fingers
        // lifted" edge JS-side state machines need.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.coalesce()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.coalescerTimer = timer

        return Token { [weak self] in self?.teardown() }
    }

    private func coalesce() {
        lock.lock()
        let pending = pendingFrame
        lock.unlock()
        guard let pending = pending else { return }

        // Cheap structural diff: same touches count + same per-finger
        // (identifier, x, y, state) is "no meaningful change". JSON
        // serialization-and-compare would be more robust but ~3-4x more
        // CPU at 30 Hz with 5 fingers — this is the hot path.
        if !frameDiffersMaterially(pending, lastEmittedFrame) { return }

        lock.lock()
        lastEmittedFrame = pending
        lock.unlock()
        fire()
    }

    private func frameDiffersMaterially(_ a: [String: Any], _ b: [String: Any]?) -> Bool {
        guard let b = b else { return true }
        let ta = a["touches"] as? [[String: Any]] ?? []
        let tb = b["touches"] as? [[String: Any]] ?? []
        if ta.count != tb.count { return true }
        for i in 0..<ta.count {
            let ai = ta[i], bi = tb[i]
            if (ai["identifier"] as? Int) != (bi["identifier"] as? Int) { return true }
            if (ai["state"] as? String) != (bi["state"] as? String) { return true }
            // Use a small epsilon: trackpad coordinates jitter in the 5th
            // decimal even when the finger is "stationary".
            let ax = (ai["x"] as? Double) ?? 0
            let bx = (bi["x"] as? Double) ?? 0
            let ay = (ai["y"] as? Double) ?? 0
            let by = (bi["y"] as? Double) ?? 0
            if abs(ax - bx) > 0.0005 || abs(ay - by) > 0.0005 { return true }
        }
        return false
    }

    private func teardown() {
        if let t = coalescerTimer { t.invalidate() }
        coalescerTimer = nil

        // Teardown order from asmagill's userdata_gc (internal.m:1128-1134):
        //   Unregister callback → check IsRunning → Stop → Release.
        // Reordering crashes on the next-frame delivery the framework
        // queues internally between Stop and Release.
        if let dev = device {
            _ = MTUnregisterContactFrameCallback(dev, touchDeviceFrameCallback)
            if MTDeviceIsRunning(dev) { _ = MTDeviceStop(dev) }
            MTDeviceRelease(dev)
        }
        device = nil

        if let retainer = refconRetainer {
            retainer.release()
            refconRetainer = nil
        }

        lock.lock()
        pendingFrame = nil
        lastEmittedFrame = nil
        lock.unlock()
    }
}
